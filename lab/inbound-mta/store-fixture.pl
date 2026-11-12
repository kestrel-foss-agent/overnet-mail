#!/usr/bin/env perl
# GPL-3.0-only. Trusted, disposable test setup/inspection, never a delivery API.
use strictures 2;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use DBI ();
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use JSON ();
use MIME::Base64 qw(encode_base64);
use Overnet::Mail::Store;

# Usage:
#   store-fixture.pl CONFIG provision [ADDRESS MAILBOX ...]
#   store-fixture.pl CONFIG route ADDRESS MAILBOX
#   store-fixture.pl CONFIG snapshot
# CONFIG has exactly the same engine/path or engine/dsn/schema fields as
# store-delivery.pl. This fixture is invoked explicitly by the test controller,
# never from message input, and exposes no submission or message insertion path.
umask 0077;
my ($config_path, $command, @pairs) = @ARGV;
defined $command && ($command eq 'provision' || $command eq 'route' || $command eq 'snapshot')
    or die "usage: store-fixture.pl CONFIG provision|route|snapshot [ADDRESS MAILBOX ...]\n";
die "fixture arguments\n" if @pairs % 2 || @pairs > 64
    || ($command eq 'route' && @pairs != 2)
    || ($command eq 'snapshot' && @pairs);
for (my $i = 0; $i < @pairs; $i += 2) {
    # The lab needs only explicit synthetic recipients, not general provisioning.
    $pairs[$i] =~ /\A[A-Za-z0-9][A-Za-z0-9._+-]*\@(?:[A-Za-z0-9-]+\.)+(?:invalid|test)\z/
        && length($pairs[$i]) <= 254 or die "synthetic fixture recipient required\n";
    $pairs[$i + 1] =~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
        or die "fixture mailbox required\n";
}

open my $fh, '<:raw', $config_path or die "fixture config read failed\n";
my $length = read $fh, my $bytes, 8193;
defined $length && $length <= 8192 or die "fixture config size\n";
close $fh or die "fixture config close failed\n";
my $config = JSON->new->decode($bytes);
ref $config eq 'HASH' && defined $config->{engine} && !ref $config->{engine}
    or die "fixture config shape\n";
my ($store, $dbh);
if ($config->{engine} eq 'sqlite') {
    my $path = $config->{path};
    keys(%{$config}) == 2 && defined $path && !ref $path
        && $path =~ m{\A/[^\x00-\x1f\x7f;]+\z}
        or die "fixture SQLite config\n";
    if ($command eq 'provision') {
        # O_EXCL refuses accidental reuse, including an existing symlink. Failed
        # setup is left in place for inspection rather than destructively reset.
        sysopen my $new, $path, O_WRONLY | O_CREAT | O_EXCL, 0600
            or die "fixture requires a new SQLite path\n";
        close $new or die "fixture SQLite create failed\n";
    } else {
        -f $path && !-l $path && -s $path or die "fixture SQLite store missing\n";
    }
    $store = Overnet::Mail::Store->new(path => $path, max_message_bytes => 65536);
    $dbh = $store->_dbh;
} elsif ($config->{engine} eq 'postgres') {
    keys(%{$config}) == 3 && defined $config->{dsn} && !ref $config->{dsn}
        && defined $config->{schema} && !ref $config->{schema}
        && $config->{schema} =~ /\A(?:inbound_lab|overnet_inbound_[a-z0-9_]{1,40})\z/
        or die "synthetic PostgreSQL fixture config required\n";
    # Only a disposable, local server is eligible. Authentication uses the same
    # current service identity as store-delivery.pl, without fixture credentials.
    $config->{dsn} =~ m{\Adbi:Pg:dbname=[A-Za-z0-9_]+;host=(?:127\.0\.0\.1|/[A-Za-z0-9_/.-]+);port=[0-9]{1,5}\z}
        or die "local PostgreSQL fixture DSN required\n";
    require Overnet::Mail::Store::Postgres;
    require Net::Blossom::Server::Backend::Postgres::BlobStore;
    require Net::Blossom::Server::Backend::Postgres::MetadataStore;
    $dbh = DBI->connect($config->{dsn}, q{}, q{}, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 0,
    });
    $dbh->do('SET client_min_messages = warning');
    $dbh->do(q{SET lock_timeout = '2500ms'});
    $dbh->do(q{SET statement_timeout = '10000ms'});
    my $schema = $dbh->quote_identifier($config->{schema});
    if ($command eq 'provision') {
        # Intentionally no IF NOT EXISTS, DROP, repair, or reuse operation.
        $dbh->do("CREATE SCHEMA $schema");
    } else {
        $dbh->selectrow_array('SELECT 1 FROM pg_namespace WHERE nspname = ?', undef, $config->{schema})
            or die "fixture PostgreSQL schema missing\n";
        $dbh->selectrow_array('SELECT to_regclass(?)', undef, "$schema.overnet_mail_schema")
            or die "fixture PostgreSQL store missing\n";
    }
    $dbh->do("SET search_path = $schema, pg_catalog");
    if ($command eq 'provision') {
        # Supported upstream provisioning is separate from the Store transaction.
        Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
        Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
    }
    $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh, max_message_bytes => 65536);
} else {
    die "fixture engine\n";
}

my $answer;
if ($command eq 'snapshot') {
    # Keep metadata/counts at one coherent point in time even while the test
    # polls a live queue. These are test-only reads, not new runtime Store APIs.
    $answer = $store->_transaction(sub {
        my %outbound;
        for my $table (qw(messages recipients submissions deliveries blossom_owners)) {
            $outbound{$table} = 0 + $dbh->selectrow_array("SELECT COUNT(*) FROM $table");
        }
        die "unexpected outbound fixture state\n" if grep { $_ != 0 } values %outbound;
        my $routes = $dbh->selectall_arrayref(
            'SELECT recipient, mailbox_id FROM recipient_routes ORDER BY recipient', {Slice => {}});
        my $mailboxes = {};
        my $states = $dbh->selectall_arrayref(
            'SELECT mailbox_id, uidvalidity, uidnext FROM mailboxes ORDER BY mailbox_id', {Slice => {}});
        for my $state (@{$states}) {
            my $mailbox = delete $state->{mailbox_id};
            $state->{uidvalidity} = 0 + $state->{uidvalidity};
            $state->{uidnext} = 0 + $state->{uidnext};
            my $entries = $dbh->selectall_arrayref(
                'SELECT uid, entry_id, receipt_namespace, idempotency_key, content_sha256, received_at FROM mailbox_entries WHERE mailbox_id = ? ORDER BY uid',
                {Slice => {}}, $mailbox);
            for my $entry (@{$entries}) {
                $entry->{$_} = 0 + $entry->{$_} for qw(uid entry_id received_at);
            }
            $mailboxes->{$mailbox} = {%{$state}, message_count => 0 + @{$entries}, entries => $entries};
        }
        return {routes => $routes, mailboxes => $mailboxes, outbound_counts => \%outbound};
    });
    # Store entries and their bytes are immutable. Fetch the selected entries
    # through the public integrity-checking API after the metadata transaction;
    # later append-only delivery cannot alter this snapshot's membership.
    for my $mailbox (sort keys %{$answer->{mailboxes}}) {
        for my $entry (@{$answer->{mailboxes}{$mailbox}{entries}}) {
            my $loaded = $store->load_mailbox_uid(mailbox_id => $mailbox, uid => $entry->{uid});
            $loaded or die "fixture snapshot entry missing\n";
            for my $key (qw(uid entry_id received_at content_sha256)) {
                $loaded->{$key} eq $entry->{$key} or die "fixture snapshot entry changed\n";
            }
            $entry->{raw_b64} = encode_base64($loaded->{message}->raw_bytes, q{});
        }
    }
} else {
    my @routes;
    while (@pairs) {
        my ($recipient, $mailbox) = splice @pairs, 0, 2;
        $store->ensure_mailbox(mailbox_id => $mailbox);
        push @routes, $store->register_recipient(recipient => $recipient, mailbox_id => $mailbox);
    }
    $answer = {routes => \@routes};
}
$store->disconnect;
print JSON->new->canonical->encode($answer), "\n" or die "fixture output\n";
close STDOUT or die "fixture output close\n";
