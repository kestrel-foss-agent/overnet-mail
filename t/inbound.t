use strictures 2;
use DBI        ();
use File::Temp qw(tempdir);
use Test2::V0;
use Overnet::Mail::Store;

my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/inbound.db";
my $store = Overnet::Mail::Store->new(path => $path, max_message_bytes => 2048);
my $raw   = Overnet::Mail::RawMessage->new(
  raw_bytes => "To: attacker\@example.test\r\nBcc: private\@example.test\r\n\r\n" . pack('C*', 0 .. 255));
my %args = (
  source_id       => 'mta-one',
  idempotency_key => 'queue-one',
  recipient       => 'Alice@EXAMPLE.TEST',
  message         => $raw,
  received_at     => 10
);
is $store->receive_delivery(%args), {status => 'unknown_recipient'}, 'unknown address rejects custody';

for my $table (qw(mailboxes mailbox_entries blossom_blob_data blossom_blobs)) {
  is $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $table"), 0, 'unknown delivery leaves no custody rows';
}
like dies { $store->register_recipient(recipient => $args{recipient}, mailbox_id => 'alice') }, qr/existing mailbox/,
  'route cannot provision an account';
for my $box (qw(alice bob)) { $store->ensure_mailbox(mailbox_id => $box) }
my $route = $store->register_recipient(recipient => $args{recipient}, mailbox_id => 'alice');
is $route, {recipient => 'Alice@example.test', mailbox_id => 'alice'}, 'only domain case folds';
is $store->register_recipient(recipient => 'Alice@example.test', mailbox_id => 'alice'), $route, 'registration replays';
$route->{mailbox_id} = 'bob';
is $store->register_recipient(recipient => $args{recipient}, mailbox_id => 'alice')->{mailbox_id}, 'alice',
  'result is detached';
like dies { $store->register_recipient(recipient => $args{recipient}, mailbox_id => 'bob') }, qr/already belongs/,
  'rebind rejected';
my $first = $store->receive_delivery(%args);
is [sort keys %{$first}],            [qw(receipt status)],                      'no routing identities in result';
is $first->{status},                 'received',                                'successful custody result';
is [sort keys %{$first->{receipt}}], [qw(content_sha256 entry_id received_at)], 'unchanged receipt projection';
is $store->receive_delivery(%args, recipient => 'Alice@example.test', received_at => 999), $first,
  'replay retains first time';
is $store->mailbox_state(mailbox_id => 'alice')->{uidnext}, 2, 'replay consumes no UID';
is $store->load_mailbox_uid(mailbox_id => 'alice', uid => 1)->{message}->raw_bytes, $raw->raw_bytes,
  'opaque headers and all octets survive';
is $store->mailbox_entries(mailbox_id => 'bob'), [], 'headers do not grant membership';
is $store->load_mailbox_entry(mailbox_id => 'bob', entry_id => $first->{receipt}{entry_id}), undef,
  'entry lookup is scoped';

for my $recipient ('alice@example.test', 'Alice+tag@example.test', 'Alice@elsewhere.test', 'private@example.test') {
  is $store->receive_delivery(%args, recipient => $recipient), {status => 'unknown_recipient'},
    'no case/tag/catch-all/header inference';
}
$store->register_recipient(recipient => 'alias@example.test', mailbox_id => 'alice');
$store->register_recipient(recipient => 'bob@example.test',   mailbox_id => 'bob');
for my $change ({recipient => 'alias@example.test'}, {source_id => 'mta-two'}, {idempotency_key => 'queue-two'}) {
  isnt $store->receive_delivery(%args, %{$change})->{receipt}{entry_id}, $first->{receipt}{entry_id},
    'alias/source/key define distinct receipts';
}
my $bob = $store->receive_delivery(%args, recipient => 'bob@example.test');
is $store->mailbox_uid_entries(mailbox_id => 'bob'), [{%{$bob->{receipt}}, uid => 1}], 'independent UID sequence';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1,         'one shared authoritative blob';
for my $table (qw(messages recipients submissions deliveries blossom_owners)) {
  is $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $table"), 0,
    'no sender archive, private envelope or outgoing work';
}
my $direct = $store->receive_message(
  mailbox_id      => 'alice',
  idempotency_key => $args{idempotency_key},
  message         => $raw,
  received_at     => 30
);
isnt $direct->{entry_id},           $first->{receipt}{entry_id}, 'direct namespace is independent';
is $store->receive_delivery(%args), $first,                      'direct receipt cannot replace routed receipt';
my $numeric = $store->receive_delivery(%args, source_id => 1);
is $store->receive_delivery(%args, source_id => '1'), $numeric, 'numeric scalar flags cannot split source identity';
$store->register_recipient(recipient => '"a@b"@EXAMPLE.TEST', mailbox_id => 'alice');
is $store->receive_delivery(%args, recipient => '"a@b"@example.test')->{status}, 'received',
  'quoted local-part parsed by maintained parser';

for my $bad (undef, [], q{}, '_first', 'a;SELECT', "a\0", 'a' x 129, "\x{e9}") {
  like dies { $store->receive_delivery(%args, source_id => $bad) }, qr/bounded ASCII token/, 'source validates tokens';
  like dies { $store->register_recipient(recipient => 'new@example.test', mailbox_id => $bad) },
    qr/bounded ASCII token/, 'mailbox validates tokens';
}
for my $bad (undef, [], q{}, 'not-an-address', 'Display <alice@example.test>',
  "alice\n\@example.test", 'a' x 1025, "\x{e9}\@example.test") {
  ok dies { $store->receive_delivery(%args, recipient => $bad) }, 'invalid delivery address rejected';
  ok dies { $store->register_recipient(recipient => $bad, mailbox_id => 'alice') },
    'invalid registration address rejected';
}
for my $name (qw(mailbox_id receipt_namespace sender envelope typo)) {
  like dies { $store->receive_delivery(%args, $name => 'bob') }, qr/unsupported inbound delivery argument/,
    'transport cannot override route';
}
for my $bad (undef, [], q{}, '01', -1, 10_000_000_000) {
  like dies { $store->receive_delivery(%args, received_at => $bad) }, qr/bounded canonical integer/,
    'timestamp validated on replay';
}
for my $bad (undef, [], 'a' x 129) {
  like dies { $store->receive_delivery(%args, idempotency_key => $bad) }, qr/bounded ASCII token/,
    'delivery key validated';
}
my $submission = Overnet::Mail::Submission->new(
  message  => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: plain\r\n\r\nplain"),
  envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['bob@example.test'])
);
for my $bad (undef, [], $store, $submission) {
  like dies { $store->receive_delivery(%args, message => $bad) }, qr/requires a RawMessage/, 'only RawMessage accepted';
}
like dies {
  $store->receive_delivery(%args, message => Overnet::Mail::RawMessage->new(raw_bytes => 'different private body'))
}, qr/idempotency key conflicts/, 'changed bytes conflict';
for my $recipient ($args{recipient}, 'unknown@example.test') {
  like dies {
    $store->receive_delivery(
      %args,
      recipient => $recipient,
      message   => Overnet::Mail::RawMessage->new(raw_bytes => 'x' x 2049)
    )
  }, qr/max_message_bytes/, 'size limit validates replay and unknown recipients';
}
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
is $store->receive_delivery(%args), $first, 'route and replay survive reopen';
is $store->load_mailbox_uid(mailbox_id => 'alice', uid => 1)->{message}->raw_bytes, $raw->raw_bytes,
  'offline exact retrieval';
$store->disconnect;
like dies { $store->register_recipient(recipient => $args{recipient}, mailbox_id => 'alice') }, qr/store is closed/,
  'closed registration rejected';
like dies { $store->receive_delivery(%args) }, qr/store is closed/, 'closed delivery rejected';
my $broken = "$dir/broken.db";
$store = Overnet::Mail::Store->new(path => $broken);
$store->ensure_mailbox(mailbox_id => 'alice');
$store->register_recipient(recipient => $args{recipient}, mailbox_id => 'alice');
$store->disconnect;
my $dbh = DBI->connect("dbi:SQLite:dbname=$broken", q{}, q{}, {RaiseError => 1, PrintError => 0});
$dbh->do('PRAGMA foreign_keys = OFF');
$dbh->do('DELETE FROM mailboxes');
$dbh->disconnect;
$store = Overnet::Mail::Store->new(path => $broken);
like dies { $store->receive_delivery(%args) }, qr/missing mailbox/, 'damaged route fails closed';
is $store->mailbox_state(mailbox_id => 'alice'), undef, 'damage does not silently provision account';
$store->disconnect;
done_testing;
