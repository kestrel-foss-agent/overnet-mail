#!/usr/bin/perl
# GPL-3.0-only. Local synthetic integration helper, not an account service.
use strictures 2;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use DBI ();
use DBD::SQLite::Constants qw(SQLITE_OPEN_READONLY);
use File::Spec ();
use JSON ();
use Overnet::Mail::Store;
use Overnet::Mail::Store::Postgres;

# Keep opening semantics local to the lab. All schema, UID and content rules
# remain in Store. SQLITE_OPEN_READONLY cannot create even a missing filename;
# query_only also rejects accidental mutation in a future Store code path.
{
    package Overnet::Mail::Lab::ReadOnlySQLite;
    use Moo;
    extends 'Overnet::Mail::Store';
    sub _open_storage {
        my ($self) = @_;
        my $path = $self->path;
        die "invalid path\n" if !defined $path || ref $path ||
            $path =~ /[;\x00-\x1f\x7f]/ || !File::Spec->file_name_is_absolute($path);
        my $dbh = DBI->connect("dbi:SQLite:dbname=$path", q{}, q{}, {
            RaiseError => 1, PrintError => 0, ShowErrorStatement => 0,
            AutoCommit => 1, sqlite_unicode => 0,
            sqlite_open_flags => DBD::SQLite::Constants::SQLITE_OPEN_READONLY(),
            sqlite_use_immediate_transaction => 0,
            HandleError => sub { die "database read failed\n" },
        });
        $dbh->sqlite_busy_timeout(2500);
        $dbh->do('PRAGMA query_only = ON');
        die "unsupported journaling\n" if $dbh->selectrow_array('PRAGMA journal_mode') ne 'delete';
        $self->{_dbh} = $dbh;
        $self->{_blob_store} = Net::Blossom::Server::Backend::SQLite::BlobStore->new(dbh => $dbh);
        $self->{_metadata_store} = Net::Blossom::Server::Backend::SQLite::MetadataStore->new(dbh => $dbh);
        return;
    }
}

sub integer {
    my ($value, $min, $max) = @_;
    die "invalid integer\n" if !defined $value || ref $value ||
        $value !~ /\A(?:0|[1-9][0-9]{0,9})\z/ || $value < $min || $value > $max;
    return 0 + $value;
}

sub open_store {
    my ($config) = @_;
    die "invalid mailbox\n" if !defined $config->{mailbox_id} || ref $config->{mailbox_id} ||
        $config->{mailbox_id} !~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/;
    my %allowed = map { $_ => 1 } qw(engine path dsn user schema mailbox_id);
    die "unexpected config\n" if grep { !$allowed{$_} } keys %{$config};
    if ($config->{engine} eq 'sqlite') {
        die "unexpected config\n" if grep { exists $config->{$_} } qw(dsn user schema);
        return Overnet::Mail::Lab::ReadOnlySQLite->new(path => $config->{path});
    }
    die "invalid engine\n" if $config->{engine} ne 'postgres' || exists $config->{path};
    # Only an explicit local fixture database, with no credentials in the DSN.
    die "invalid local DSN\n" if !defined $config->{dsn} || ref $config->{dsn} ||
        $config->{dsn} !~ m{\Adbi:Pg:dbname=[a-zA-Z0-9_]+;host=(?:127\.0\.0\.1|/[a-zA-Z0-9_/.-]+);port=[0-9]{1,5}\z};
    die "invalid schema\n" if !defined $config->{schema} || ref $config->{schema} ||
        $config->{schema} !~ /\A[a-z][a-z0-9_]{0,62}\z/ || $config->{schema} =~ /\Apg_/;
    die "invalid user\n" if !defined $config->{user} || ref $config->{user} ||
        $config->{user} !~ /\A[a-z][a-z0-9_]{0,62}\z/;
    my $dbh = DBI->connect($config->{dsn}, $config->{user}, q{}, {
        RaiseError => 1, PrintError => 0, ShowErrorStatement => 0, AutoCommit => 1,
        HandleError => sub { die "database read failed\n" },
    });
    $dbh->do('SET default_transaction_read_only = on');
    $dbh->do('SET search_path = ' . $dbh->quote_identifier($config->{schema}) . ', pg_catalog, pg_temp');
    return Overnet::Mail::Store::Postgres->new(dbh => $dbh);
}

sub snapshot {
    my ($store, $mailbox) = @_;
    my $state = $store->mailbox_state(mailbox_id => $mailbox);
    die "absent mailbox\n" if !$state;
    my $validity = integer($state->{uidvalidity}, 1, 4294967295);
    my $next = integer($state->{uidnext}, 1, 4294967295);
    my $count = integer($state->{message_count}, 0, 4096);
    my @entries;
    my $cursor = 0;
    while (@entries < $count) {
        my $page = $store->mailbox_uid_entries(mailbox_id => $mailbox, after_uid => $cursor, limit => 128);
        die "incomplete prefix\n" if !@{$page};
        for my $entry (@{$page}) {
            my $uid = integer($entry->{uid}, $cursor + 1, 4294967294);
            last if $uid >= $next;
            my $timestamp = integer($entry->{received_at}, 0, 9999999999);
            push @entries, "$uid $timestamp\n";
            die "count mismatch\n" if @entries > $count;
            $cursor = $uid;
        }
        # If a page reached the captured bound, another page cannot fill a
        # missing member of this immutable prefix.
        die "incomplete prefix\n" if @entries < $count && $page->[-1]{uid} >= $next;
    }
    # Probe the next row even when captured count was zero. This detects a
    # damaged count while permitting append-only arrivals at/above UIDNEXT.
    my $tail = $store->mailbox_uid_entries(mailbox_id => $mailbox, after_uid => $cursor, limit => 1);
    die "count mismatch\n" if @{$tail} && integer($tail->[0]{uid}, $cursor + 1, 4294967294) < $next;
    return "OK $validity $next $count\n" . join(q{}, @entries);
}

sub run {
    die "config required\n" if @ARGV != 1 || !File::Spec->file_name_is_absolute($ARGV[0]);
    open my $file, '<:raw', $ARGV[0] or die "config read failed\n";
    my $json;
    my $n = read $file, $json, 16385;
    die "config read failed\n" if !defined $n || $n > 16384;
    close $file or die "config close failed\n";
    my $config = JSON->new->utf8->decode($json);
    die "invalid config\n" if ref $config ne 'HASH' || !defined $config->{engine} || ref $config->{engine};
    # sysread prevents unbounded line allocation; exactly one request then EOF.
    my $request = q{};
    while (1) {
        my $n = sysread STDIN, my $part, 34 - length($request);
        die "request read failed\n" if !defined $n;
        last if !$n;
        $request .= $part;
        die "request too long\n" if length($request) > 32;
    }
    die "invalid request\n" if $request ne "SNAPSHOT\n" && $request !~ /\AFETCH ([1-9][0-9]{0,9})\n\z/;
    my $store = open_store($config);
    my $answer;
    if ($request eq "SNAPSHOT\n") {
        $answer = snapshot($store, $config->{mailbox_id});
    } else {
        $request =~ /\AFETCH ([1-9][0-9]{0,9})\n\z/ or die "invalid request\n";
        my $uid = integer($1, 1, 4294967294);
        my $entry = $store->load_mailbox_uid(mailbox_id => $config->{mailbox_id}, uid => $uid);
        die "absent message\n" if !$entry;
        my $raw = $entry->{message}->raw_bytes;
        die "message too large\n" if !length($raw) || length($raw) > 10485760;
        $answer = 'DATA ' . length($raw) . "\n" . $raw;
    }
    $store->disconnect;
    print STDOUT $answer or die "response write failed\n";
    close STDOUT or die "response close failed\n";
    return;
}

binmode STDIN, ':raw';
binmode STDOUT, ':raw';
$SIG{ALRM} = sub { die "helper deadline\n" };
alarm 9;
my $ok = eval { run(); 1 };
alarm 0;
if (!$ok) {
    # Deliberately no exception, DSN, SQL, path, recipient, envelope or bytes.
    print STDOUT "ERR\n";
    exit 1;
}
exit 0;
