#!/usr/bin/env perl
# GPL-3.0-only. Trusted synthetic adapter. Never accepts administrative methods.
use strictures 2;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use JSON ();
use Overnet::Mail::Store;

sub run {
    die "arguments\n" if @ARGV != 2 || length($ARGV[1]) > 2048;
    open my $fh, '<:raw', $ARGV[0] or die "config\n";
    my $length = read $fh, my $bytes, 8193;
    die "config\n" if !defined $length || $length > 8192;
    close $fh or die "config\n";
    my $config = JSON->new->decode($bytes);
    my $args = JSON->new->decode($ARGV[1]);
    die "arguments\n" if ref $args ne 'HASH' || keys(%{$args}) != 4;
    my %allowed = map { $_ => 1 } qw(source_id idempotency_key recipient received_at);
    die "arguments\n" if grep { !$allowed{$_} } keys %{$args};
    my $store;
    if ($config->{engine} eq 'sqlite') {
        $store = Overnet::Mail::Store->new(path => $config->{path}, max_message_bytes => 65536);
    } elsif ($config->{engine} eq 'postgres') {
        require DBI;
        require Overnet::Mail::Store::Postgres;
        my $dbh = DBI->connect($config->{dsn}, q{}, q{}, {RaiseError => 1, PrintError => 0});
        die "schema\n" if $config->{schema} !~ /\A[a-z][a-z0-9_]{0,62}\z/;
        $dbh->do('SET search_path TO ' . $dbh->quote_identifier($config->{schema}));
        $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh, max_message_bytes => 65536);
    } else {
        die "engine\n";
    }
    my $raw = q{};
    while (1) {
        my $n = sysread STDIN, my $part, 65537 - length($raw);
        die "input\n" if !defined $n;
        last if !$n;
        $raw .= $part;
        die "size\n" if length($raw) > 65536;
    }
    $args->{message} = Overnet::Mail::RawMessage->new(raw_bytes => $raw);
    my $result = $store->receive_delivery(%{$args});
    die "custody\n" if ref $result ne 'HASH' || $result->{status} ne 'received'
        || ref $result->{receipt} ne 'HASH';
    my $receipt = $result->{receipt};
    die "receipt\n" if keys(%{$receipt}) != 3;
    for my $key (qw(entry_id content_sha256 received_at)) {
        die "receipt\n" if !defined $receipt->{$key} || ref $receipt->{$key};
    }
    die "receipt\n" if $receipt->{entry_id} !~ /\A[1-9][0-9]{0,17}\z/
        || $receipt->{content_sha256} ne $args->{message}->content_sha256
        || $receipt->{received_at} !~ /\A[0-9]{1,10}\z/
        || $receipt->{received_at} != $args->{received_at};
    print "received\n" or die "acknowledgement\n";
    close STDOUT or die "acknowledgement\n";
    return;
}
my $ok = eval { local $SIG{ALRM} = sub { die "deadline\n" }; alarm 12; run(); alarm 0; 1 };
exit($ok ? 0 : 75);
