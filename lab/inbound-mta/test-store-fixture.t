use strictures 2;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use JSON ();
use MIME::Base64 qw(encode_base64);
use Symbol qw(gensym);
use Test2::V0;
use Overnet::Mail::Store;

my $root = tempdir(CLEANUP => 1);
my $config = "$root/store.json";
my $database = "$root/store.sqlite";
my $fixture = "$RealBin/store-fixture.pl";
my $delivery = "$RealBin/store-delivery.pl";
my $json = JSON->new->canonical;
sub write_config {
    my ($value) = @_;
    open my $fh, '>:raw', $config or die "test config write: $!";
    print {$fh} $json->encode($value);
    close $fh or die "test config close: $!";
    return;
}
sub command {
    my ($input, @argv) = @_;
    my $error = gensym;
    my $pid = open3(my $stdin, my $stdout, $error, $^X, @argv);
    binmode $stdin, ':raw';
    print {$stdin} $input;
    close $stdin;
    my $out = do { local $/; <$stdout> } // q{};
    my $err = do { local $/; <$error> } // q{};
    close $stdout;
    close $error;
    waitpid $pid, 0;
    return ($? >> 8, $out, $err);
}
sub fixture {
    my (@args) = @_;
    return command(q{}, $fixture, $config, @args);
}
sub snapshot {
    my ($status, $out, $err) = fixture('snapshot');
    is $status, 0, 'snapshot exits successfully' or diag $err;
    return $status ? undef : $json->decode($out);
}
sub deliver {
    my ($raw, %args) = @_;
    return command($raw, $delivery, $config, $json->encode(\%args));
}

write_config({engine => 'sqlite', path => $database});
for my $bad (['snapshot'], ['route', 'alice@reference.invalid', 'alice'], ['unknown'],
    ['provision', 'alice@example.com', 'alice'], ['provision', 'alice@reference.invalid']) {
    my ($status) = fixture(@{$bad});
    isnt $status, 0, 'invalid or unprovisioned fixture operation fails';
    ok !-e $database, 'rejected operation does not create storage';
}

my ($status, $out, $err) = fixture('provision', 'alice@reference.invalid', 'alice');
is $status, 0, 'fresh SQLite fixture provisions' or diag $err;
is $json->decode($out), {routes => [{recipient => 'alice@reference.invalid', mailbox_id => 'alice'}]},
    'provision returns exact address mapping';
is((stat($database))[2] & 0777, 0600, 'database is private to fixture identity');
my $empty = snapshot();
is $empty, {
    routes => [{recipient => 'alice@reference.invalid', mailbox_id => 'alice'}],
    mailboxes => {alice => {uidvalidity => 1, uidnext => 1, message_count => 0, entries => []}},
    outbound_counts => {map { $_ => 0 } qw(messages recipients submissions deliveries blossom_owners)},
}, 'snapshot covers empty mailbox and every outbound table';
($status) = fixture('provision', 'alice@reference.invalid', 'alice');
isnt $status, 0, 'provision refuses existing fixture';
is snapshot(), $empty, 'failed reprovision leaves fixture unchanged';

my $raw = "From: sender\@example.test\r\nBcc: private\@example.test\r\n"
    . "Content-Type: application/octet-stream\r\n\r\n" . pack('C*', 0 .. 255);
my %args = (
    source_id => 'synthetic-intake', idempotency_key => 'intake-token-one',
    received_at => 1700000000, recipient => 'alice@reference.invalid',
);
($status, $out) = deliver($raw, %args);
is [$status, $out], [0, "received\n"], 'real delivery helper accepts immutable raw octets';
my $first = snapshot();
my $entry = {
    uid => 1, entry_id => 1, idempotency_key => $args{idempotency_key},
    receipt_namespace => sha256_hex(JSON->new->encode([$args{source_id}, $args{recipient}])),
    received_at => $args{received_at}, content_sha256 => sha256_hex($raw), raw_b64 => encode_base64($raw, q{}),
};
is $first->{mailboxes}{alice}, {uidvalidity => 1, uidnext => 2, message_count => 1, entries => [$entry]},
    'snapshot exposes exact UID, receipt identity, original timestamp, hash and all bytes';
($status) = deliver($raw, %args);
is $status, 0, 'identical delivery retry succeeds';
is snapshot(), $first, 'retry preserves exact snapshot';
($status) = deliver($raw, %args, recipient => 'bob@reference.invalid');
is $status, 75, 'missing recipient route defers through the real delivery helper';
is snapshot(), $first, 'partial-recipient deferral has no side effects';
($status) = fixture('route', 'bob@reference.invalid', 'bob');
is $status, 0, 'test controller can add the missing route later';
($status) = deliver($raw, %args, recipient => 'bob@reference.invalid');
is $status, 0, 'recipient retry receives after explicit provisioning';
my $both = snapshot();
is $both->{mailboxes}{alice}, $first->{mailboxes}{alice}, 'second recipient preserves first mailbox';
is $both->{mailboxes}{bob}, {
    uidvalidity => 2, uidnext => 2, message_count => 1,
    entries => [{%{$entry}, entry_id => 2,
        receipt_namespace => sha256_hex(JSON->new->encode([$args{source_id}, 'bob@reference.invalid']))}],
}, 'second recipient has independent UID sequence and same exact bytes';
($status) = fixture('route', 'bob@reference.invalid', 'bob');
is $status, 0, 'same route is idempotent';
($status) = fixture('route', 'alice@reference.invalid', 'bob');
isnt $status, 0, 'route rebinding is refused';
is snapshot(), $both, 'route retries and rejected rebinding preserve snapshot';
($status) = deliver($raw, %args, idempotency_key => 'intake-token-two', received_at => 1700000001);
is $status, 0, 'new byte-identical intake remains a separate delivery';
my $twice = snapshot();
is $twice->{mailboxes}{alice}{entries}, [$entry, {%{$entry}, uid => 2, entry_id => 3,
    idempotency_key => 'intake-token-two', received_at => 1700000001}],
    'second intake has new UID and its own immutable identity/time';
is $twice->{mailboxes}{alice}{uidnext}, 3, 'UIDNEXT advances exactly once';
is $twice->{mailboxes}{bob}, $both->{mailboxes}{bob}, 'separate intake does not affect unaddressed mailbox';

my $store = Overnet::Mail::Store->new(path => $database);
$store->_dbh->do('UPDATE blossom_blob_data SET body = ?', undef, 'corrupted fixture');
$store->disconnect;
($status, $out) = fixture('snapshot');
isnt $status, 0, 'snapshot refuses corrupted authoritative bytes';
is $out, q{}, 'corruption cannot emit a successful-looking snapshot';

my $outbound = "$root/outbound.sqlite";
write_config({engine => 'sqlite', path => $outbound});
($status) = fixture('provision');
is $status, 0, 'fixture can provision without recipient routes';
$store = Overnet::Mail::Store->new(path => $outbound);
$store->enqueue_submission(
    mailbox_id => 'sender', idempotency_key => 'outbound-negative-test',
    item => Overnet::Mail::Submission->new(
        message => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: synthetic\r\n\r\nfixture"),
        envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['nobody@reference.invalid']),
    ),
);
$store->disconnect;
($status, $out, $err) = fixture('snapshot');
isnt $status, 0, 'snapshot fails if outbound submission/delivery state appears';
is $out, q{}, 'outbound contamination cannot emit a successful-looking snapshot';
like $err, qr/unexpected outbound fixture state/, 'outbound failure is explicit';

for my $bad_config (
    {engine => 'sqlite', path => "$root/extra.sqlite", extra => 1},
    {engine => 'postgres', dsn => 'dbi:Pg:dbname=intake;host=/lab/postgres/socket;port=5432', schema => 'public'},
    {engine => 'postgres', dsn => 'dbi:Pg:dbname=intake;host=external.example.test;port=5432', schema => 'inbound_lab'},
) {
    write_config($bad_config);
    ($status) = fixture('provision');
    isnt $status, 0, 'unsafe or nonlocal fixture config rejected before connecting';
}
done_testing;
