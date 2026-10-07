use strictures 2;

use DBI         qw(SQL_BLOB);
use Digest::SHA qw(sha256_hex);
use File::Temp  qw(tempdir);
use Test2::V0;
use Overnet::Mail::Store;

my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/mail.sqlite";
my $store = Overnet::Mail::Store->new({path => $path});
is $store->path,                                         $path,      'absolute local path retained';
is $store->max_message_bytes,                            10_485_760, 'default acceptance byte limit';
is $store->_dbh->selectrow_array('PRAGMA synchronous'),  3,          'EXTRA sync selected';
is $store->_dbh->selectrow_array('PRAGMA foreign_keys'), 1,          'foreign keys enforced';
is $store->_dbh->selectrow_array('PRAGMA journal_mode'), 'delete',   'rollback journal selected';
is $store->_dbh->selectrow_array('PRAGMA user_version'), 3,          'Blossom-backed store uses schema version three';
is $store->_dbh->selectrow_array(q{SELECT COUNT(*) FROM sqlite_master WHERE name = 'contents'}), 0,
  'legacy duplicate content table is absent';
like dies { $store->path($path) }, qr/read-only/, 'configuration accessors read-only';

my $wire    = "Message-ID: <same\@example.test>\r\nSubject: raw\r\n\r\n\0\xff\xc3\xa9\r\n";
my $raw     = Overnet::Mail::RawMessage->new(raw_bytes => $wire);
my $receipt = $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'request-1', item => $raw);
is $receipt, {message_id => 1, content_sha256 => sha256_hex($wire)}, 'receipt separates logical ID and content hash';
is $store->_dbh->selectrow_array('SELECT typeof(body) FROM blossom_blob_data'), 'blob', 'raw bytes bound as BLOB';
is $store->_dbh->selectrow_array('SELECT length(body) FROM blossom_blob_data'), length($wire),
  'BLOB includes bytes after NUL';
$store->disconnect;
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path, max_message_bytes => 1);
my $record = $store->load(mailbox_id => 'box-1', message_id => 1);
is $record->{message}->raw_bytes, $wire, 'exact octets survive close/reopen despite lower acceptance limit';
ok !utf8::is_utf8($record->{message}->raw_bytes), 'stored content returns octets';
ok !defined $record->{envelope},                  'opaque inbound content has no invented envelope';
is $record->{content_sha256}, sha256_hex($wire), 'reopened digest correct';
like dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'too-big', item => $raw) },
  qr/exceeds max_message_bytes/, 'store applies own independent size limit';
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
is $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'request-1', item => $raw), $receipt,
  'same key and exact item replays same receipt after reopen';
$receipt->{message_id} = 99;
$record->{message_id}  = 88;
is $store->load(mailbox_id => 'box-1', message_id => 1)->{message_id}, 1,
  'returned hashes cannot change stored identity';
ok !defined $store->load(mailbox_id => 'other-box', message_id => 1),   'logical lookup scoped to mailbox';
ok !defined $store->load(mailbox_id => 'box-1',     message_id => 999), 'missing message returns nothing';

my $second = $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'request-2', item => $raw);
is $second->{message_id}, 2, 'same content with new key is a distinct logical message';
is count_rows($store, 'blossom_blob_data'), 1, 'identical content shares one BLOB';
is count_rows($store, 'blossom_blobs'),     1, 'identical content shares one metadata record';
is count_rows($store, 'blossom_owners'),    0, 'local mail acceptance does not invent Blossom ownership';
is count_rows($store, 'messages'),          2, 'content sharing is not message deduplication';
my $other = $store->accept_item(mailbox_id => 'other-box', idempotency_key => 'request-1', item => $raw);
is $other->{message_id}, 3, 'idempotency namespace is mailbox-specific';
my $different = Overnet::Mail::RawMessage->new(raw_bytes => "$wire different");
like dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'request-1', item => $different) },
  qr/idempotency key conflicts/, 'changed bytes conflict with reused key';
my $different_id = $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'same-header-id', item => $different);
is $different_id->{message_id}, 4, 'duplicate RFC Message-ID does not deduplicate distinct content';

my $submission = submission($raw, q{}, ['visible@example.test', 'blind@example.test', 'blind@example.test']);
my $outbound   = $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'outbound', item => $submission);
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
my $saved = $store->load(mailbox_id => 'box-1', message_id => $outbound->{message_id});
is $saved->{message}->raw_bytes, $wire, 'submission MIME is not reserialized';
is $saved->{envelope}->sender,   q{},   'null reverse-path distinct from absent inbound envelope';
is $saved->{envelope}->recipients, ['visible@example.test', 'blind@example.test', 'blind@example.test'],
  'private recipient order and duplicates survive reopen';
unlike $saved->{message}->raw_bytes, qr/blind\@/, 'blind recipients never become MIME headers';
is $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'outbound', item => $submission), $outbound,
  'submission replay stable';

for my $conflict (
  $raw,
  submission($raw, 'sender@example.test', ['visible@example.test', 'blind@example.test',   'blind@example.test']),
  submission($raw, q{},                   ['blind@example.test',   'visible@example.test', 'blind@example.test']),
  submission($raw, q{},                   ['visible@example.test', 'blind@example.test']),
) {
  my $error = dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'outbound', item => $conflict) };
  like $error,   qr/idempotency key conflicts/, 'item kind, sender, recipient order or multiplicity conflict';
  unlike $error, qr/(?:blind|sender)\@/,        'conflict errors contain no private recipient or sender';
}
like dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'request-1', item => $submission) },
  qr/idempotency key conflicts/, 'raw item cannot replay as submission';

for my $name (qw(mailbox_id idempotency_key)) {
  for my $bad (undef, [], q{}, ' ', "x\0", 'x;DROP TABLE messages', 'x' x 129, '_leading', "\x{e9}") {
    like dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'invalid', item => $raw, $name => $bad) },
      qr/bounded ASCII tokens/, 'invalid or overlong identifiers rejected';
  }
}
for my $bad (undef, [], 0, -1, q{}, '1.5', '01', '1 OR 1', '1' x 19) {
  like dies { $store->load(mailbox_id => 'box-1', message_id => $bad) }, qr/message_id must be/,
    'invalid logical IDs rejected';
}
like dies { $store->load(mailbox_id => [], message_id => 1) }, qr/bounded ASCII/, 'load validates mailbox token';
for my $bad (undef, {}, $submission->envelope) {
  like dies { $store->accept_item(mailbox_id => 'box-1', idempotency_key => 'invalid', item => $bad) },
    qr/item must be/, 'invalid object types rejected';
}
for my $bad (undef, [], q{}, ':memory:', 'relative.db', "$dir/name;mode=memory", "$dir/control\n") {
  like dies { Overnet::Mail::Store->new(path => $bad) }, qr/absolute local filename/, 'unsafe/ephemeral paths rejected';
}
for my $bad (undef, [], q{}, 0, -1, '1.5') {
  like dies { Overnet::Mail::Store->new(path => $path, max_message_bytes => $bad) }, qr/positive integer/,
    'invalid size limit rejected';
}
my $tiny = Overnet::Mail::Store->new(path => "$dir/tiny.db", max_message_bytes => 1);
ok $tiny->accept_item(
  mailbox_id      => 'x' x 128,
  idempotency_key => 'Y._:-0',
  item            => Overnet::Mail::RawMessage->new(raw_bytes => 'x')
  ),
  'exact identifier and size limits accepted';
$tiny->disconnect;
like dies { $tiny->load(mailbox_id => 'box', message_id => 1) }, qr/store is closed/, 'reads after close rejected';
like dies { $tiny->accept_item(mailbox_id => 'box', idempotency_key => 'a', item => $raw) },
  qr/exceeds max_message_bytes/,
  'input validation still happens before storage';
like dies {
  $tiny->accept_item(
    mailbox_id      => 'box',
    idempotency_key => 'a',
    item            => Overnet::Mail::RawMessage->new(raw_bytes => 'x')
  )
}, qr/store is closed/, 'acceptance after close rejected';

# All stored envelope values remain constrained even if the caller used larger limits.
my $many =
  Overnet::Mail::Envelope->new(sender => q{}, recipients => [('x@example.test') x 1001], max_recipients => 1001);
like dies {
  $store->accept_item(
    mailbox_id      => 'box',
    idempotency_key => 'many',
    item            => Overnet::Mail::Submission->new(message => $raw, envelope => $many)
  )
}, qr/count exceeds/, 'store independently caps envelope recipient count';
my $all_octets     = join q{}, map {chr} 0 .. 255;
my $binary         = Overnet::Mail::RawMessage->new(raw_bytes => $all_octets);
my $binary_receipt = $store->accept_item(mailbox_id => 'box', idempotency_key => 'all-octets', item => $binary);
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
is $store->load(mailbox_id => 'box', message_id => $binary_receipt->{message_id})->{message}->raw_bytes,
  $all_octets, 'all 256 octet values survive a fresh connection unchanged';
$store->disconnect;

# Unknown/foreign databases are not silently adopted or migrated.
for my $setup (
  'CREATE TABLE foreign_data (x)',
  'PRAGMA user_version=2',
  'PRAGMA application_id=9',
  'PRAGMA user_version=1',
  'PRAGMA application_id=1330463049',
) {
  my $file = "$dir/foreign-" . ++$other->{message_id} . '.db';
  my $dbh  = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1});
  $dbh->do($setup);
  $dbh->disconnect;
  like dies { Overnet::Mail::Store->new(path => $file) }, qr/unsupported mail store schema/,
    'foreign database rejected';
}
my $wal = DBI->connect("dbi:SQLite:dbname=$dir/wal.db", q{}, q{}, {RaiseError => 1});
$wal->do('PRAGMA journal_mode=WAL');
$wal->disconnect;
like dies { Overnet::Mail::Store->new(path => "$dir/wal.db") }, qr/requires DELETE/,
  'different journal contract rejected';
my $missing = dies { Overnet::Mail::Store->new(path => "$dir/absent/private-name.db") };
like $missing,   qr/database operation failed/, 'open failure has stable sanitized diagnostic';
unlike $missing, qr/private-name/,              'database path omitted from error';

done_testing;

sub submission {
  my ($message, $sender, $recipients) = @_;
  return Overnet::Mail::Submission->new(
    message  => $message,
    envelope => Overnet::Mail::Envelope->new(sender => $sender, recipients => $recipients)
  );
}

sub count_rows {
  my ($storage, $table) = @_;
  return $storage->_dbh->selectrow_array("SELECT COUNT(*) FROM $table");
}
