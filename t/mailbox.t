use strictures 2;

use Digest::SHA qw(sha256_hex);
use File::Temp  qw(tempdir);
use Test2::V0;
use Overnet::Mail::Store;

my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/mailbox.db";
my $store = Overnet::Mail::Store->new(path => $path);
my $bytes = "To: visible\@example.test\r\nBcc: untrusted-header\@example.test\r\n\r\n" . pack('C*', 0 .. 255);
my $raw   = Overnet::Mail::RawMessage->new(raw_bytes => $bytes);
my $first = receive($store, 'recipient', 'first', 200);
is $first, {entry_id => 1, content_sha256 => sha256_hex($bytes), received_at => 200},
  'receipt identifies committed mailbox entry and first timestamp';
is receive($store, 'recipient', 'first', 900),         $first,   'replay keeps the original receipt and timestamp';
is $store->mailbox_entries(mailbox_id => 'recipient'), [$first], 'listing returns only receipt metadata';
my $loaded = $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => 1);
is [sort keys %{$loaded}], [qw(content_sha256 entry_id message received_at)], 'fetch is an explicit safe projection';
is $loaded->{message}->raw_bytes, $bytes, 'incoming MIME including arbitrary Bcc text remains opaque and exact';
ok !utf8::is_utf8($loaded->{message}->raw_bytes), 'fetch preserves byte semantics';
is $store->load_mailbox_entry(mailbox_id => 'other', entry_id => 1),       undef, 'fetch cannot cross mailbox boundary';
is $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => 900), undef, 'missing entry returns nothing';
is $store->mailbox_entries(mailbox_id => 'other'),                         [],    'absent mailbox listing is empty';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM messages'),         0,     'receipt creates no archive record';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM recipients'),       0,     'receipt creates no private envelope';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM deliveries'),       0, 'receipt does not enqueue outgoing mail';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_owners'),   0, 'receipt does not invent Blossom owners';
$first->{entry_id}     = 999;
$loaded->{received_at} = 999;
is receive($store, 'recipient', 'first', 0)->{entry_id},    1, 'mutating returned hashes cannot mutate persisted state';
is receive($store, 'recipient', 'first', 0)->{received_at}, 200, 'first timestamp survives result mutation';

my $foreign = receive($store, 'other',     'first',  0);
my $second  = receive($store, 'recipient', 'second', 100);
my $third   = receive($store, 'recipient', 'third',  9_999_999_999);
is [$foreign->{entry_id}, $second->{entry_id}, $third->{entry_id}], [2, 3, 4],
  'same content and key in another mailbox has distinct membership';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1, 'all memberships share exact blob bytes';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blobs'), 1,
  'all memberships share one Blossom metadata row';
is $store->mailbox_entries(mailbox_id => 'recipient', after_entry_id => 1, limit => 1), [$second],
  'cursor is exclusive and skips other mailbox entries';
is $store->mailbox_entries(mailbox_id => 'recipient', after_entry_id => 2, limit => 1000), [$second, $third],
  'entry order is independent of receipt timestamps';
is $store->mailbox_entries(mailbox_id => 'recipient', after_entry_id => 999_999_999_999_999_999), [],
  'maximum cursor is accepted without wrapping';
my $fourth = receive($store, 'recipient', 'fourth', 1);
is $store->mailbox_entries(mailbox_id => 'recipient', after_entry_id => $third->{entry_id}), [$fourth],
  'new committed entries appear after a prior page cursor';

# Archive ownership and inbound membership deliberately use independent key spaces.
my $outbound = Overnet::Mail::Submission->new(
  message  => Overnet::Mail::RawMessage->new(raw_bytes => "To: visible\@example.test\r\n\r\noutbound"),
  envelope => Overnet::Mail::Envelope->new(sender => 'sender@example.test', recipients => ['blind@example.test']),
);
my $archive = $store->enqueue_submission(mailbox_id => 'recipient', idempotency_key => 'first', item => $outbound);
is $store->load(mailbox_id => 'recipient', message_id => $archive->{message_id})->{envelope}->recipients,
  ['blind@example.test'], 'existing private outbound behavior is unchanged';
is receive($store, 'recipient', 'first', 5)->{content_sha256}, $raw->content_sha256,
  'same archive key cannot affect recipient receipt';
is $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => 1)->{message}->raw_bytes, $bytes,
  'recipient-safe fetch never follows sender archive records';
my $same_bytes = $store->receive_message(
  mailbox_id      => 'blind-recipient',
  idempotency_key => 'outbound-copy',
  message         => $outbound->message,
  received_at     => 1,
);
is [sort keys %{$store->load_mailbox_entry(mailbox_id => 'blind-recipient', entry_id => $same_bytes->{entry_id})}],
  [qw(content_sha256 entry_id message received_at)], 'sharing an outbound blob never shares its private envelope';

for my $value (undef, [], {}, $outbound, $outbound->envelope) {
  like
    dies { $store->receive_message(mailbox_id => 'box', idempotency_key => 'bad', message => $value, received_at => 0) }
  , qr/receive_message requires a RawMessage/, 'only explicit raw-message objects are accepted';
}
my $different = Overnet::Mail::RawMessage->new(raw_bytes => 'private changed bytes');
my $error     = dies {
  $store->receive_message(
    mailbox_id      => 'recipient',
    idempotency_key => 'first',
    message         => $different,
    received_at     => 1
  );
};
like $error,   qr/mailbox idempotency key conflicts/, 'same receipt key rejects different bytes';
unlike $error, qr/private changed|blind\@|sender\@/,  'replay mismatch does not leak message or envelope values';
{
  my $digest    = $raw->content_sha256;
  my $collision = mock 'Overnet::Mail::RawMessage' => override => [content_sha256 => sub { return $digest }];
  like dies {
    $store->receive_message(
      mailbox_id      => 'recipient',
      idempotency_key => 'first',
      message         => $different,
      received_at     => 1
    );
  }, qr/mailbox idempotency key conflicts/, 'same claimed digest cannot replay unequal exact bytes';
}

for my $name (qw(mailbox_id idempotency_key)) {
  for my $bad (undef, [], q{}, '_first', 'a;DROP TABLE mailbox_entries', "a\0", 'a' x 129, "\x{e9}") {
    like dies {
      $store->receive_message(
        mailbox_id      => 'box',
        idempotency_key => 'key',
        message         => $raw,
        received_at     => 0,
        $name           => $bad
      );
    }, qr/bounded ASCII tokens/, 'receipt validates both bounded token arguments';
  }
}
for my $bad (undef, [], q{}, -1, '01', '1.5', '1e2', '+1', '1' x 19, 10_000_000_000) {
  like dies {
    $store->receive_message(mailbox_id => 'box', idempotency_key => 'key', message => $raw, received_at => $bad)
  }, qr/bounded canonical integer/, 'receipt timestamp is a bounded canonical integer';
}
for my $bad (undef, [], q{}, 0, -1, '01', '1.5', '1' x 19) {
  like dies { $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => $bad) },
    qr/bounded canonical integer/, 'fetch ID is a positive bounded canonical integer';
}
for my $bad (undef, [], q{}, -1, '01', '1.5', '1' x 19) {
  like dies { $store->mailbox_entries(mailbox_id => 'recipient', after_entry_id => $bad) },
    qr/bounded canonical integer/, 'explicit invalid cursor cannot use default';
}
for my $bad (undef, [], q{}, 0, -1, '01', '1.5', 1001) {
  like dies { $store->mailbox_entries(mailbox_id => 'recipient', limit => $bad) },
    qr/bounded canonical integer/, 'explicit invalid page limit cannot use default';
}
like dies { $store->mailbox_entries(mailbox_id => undef) }, qr/bounded ASCII tokens/, 'listing validates mailbox';
like dies { $store->load_mailbox_entry(mailbox_id => undef, entry_id => 1) }, qr/bounded ASCII tokens/,
  'fetch validates mailbox';
ok $store->receive_message(mailbox_id => 'x' x 128, idempotency_key => 'Y._:-0', message => $raw, received_at => 0),
  'token and timestamp lower boundaries work';

for my $number (1 .. 105) {
  receive($store, 'many', "key-$number", $number);
}
is scalar @{$store->mailbox_entries(mailbox_id => 'many')},                100, 'default page size is bounded to 100';
is scalar @{$store->mailbox_entries(mailbox_id => 'many', limit => 1000)}, 105, 'explicit larger bounded page works';
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path, max_message_bytes => 1);
is $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => 1)->{message}->raw_bytes, $bytes,
  'offline reconnect preserves exact bytes despite lower acceptance limit';
is scalar @{$store->mailbox_entries(mailbox_id => 'recipient')}, 4, 'membership is durable after reconnect';
like dies { receive($store, 'recipient', 'first', 0) }, qr/exceeds max_message_bytes/,
  'acceptance size limit applies before replay too';
$store->disconnect;
like dies { $store->mailbox_entries(mailbox_id => 'recipient') }, qr/store is closed/, 'listing after close fails';
like dies { $store->load_mailbox_entry(mailbox_id => 'recipient', entry_id => 1) }, qr/store is closed/,
  'fetch after close fails';
like dies {
  $store->receive_message(
    mailbox_id      => 'box',
    idempotency_key => 'key',
    message         => Overnet::Mail::RawMessage->new(raw_bytes => 'x'),
    received_at     => 0
  );
}, qr/store is closed/, 'receipt after close fails';

# An old schema must never be silently marked as upgraded or adopted.
my $old_path = "$dir/schema-three.db";
my $old      = DBI->connect("dbi:SQLite:dbname=$old_path", q{}, q{}, {RaiseError => 1});
$old->do('PRAGMA application_id=1330463049');
$old->do('PRAGMA user_version=3');
$old->do('CREATE TABLE preserved (value TEXT)');
$old->do(q{INSERT INTO preserved VALUES ('old bytes')});
$old->disconnect;
like dies { Overnet::Mail::Store->new(path => $old_path) }, qr/unsupported mail store schema/,
  'prior mailbox-less schema rejected without automatic migration';
$old = DBI->connect("dbi:SQLite:dbname=$old_path", q{}, q{}, {RaiseError => 1});
is $old->selectrow_array('PRAGMA user_version'),         3,           'old schema version unchanged';
is $old->selectrow_array('SELECT value FROM preserved'), 'old bytes', 'old contents unchanged';
$old->disconnect;

my $bounded = Overnet::Mail::Store->new(path => "$dir/id-limit.db");
receive($bounded, 'box', 'start', 0);
$bounded->_dbh->do(q{UPDATE sqlite_sequence SET seq = 999999999999999998 WHERE name = 'mailbox_entries'});
my $last = receive($bounded, 'box', 'last', 0);
is $last->{entry_id}, 999_999_999_999_999_999, 'last supported entry ID is accepted exactly';
is $bounded->load_mailbox_entry(mailbox_id => 'box', entry_id => $last->{entry_id})->{content_sha256},
  $raw->content_sha256, 'last supported entry ID remains fetchable';
like dies {
  $bounded->receive_message(
    mailbox_id      => 'box',
    idempotency_key => 'overflow',
    message         => $different,
    received_at     => 0
  );
}, qr/database operation failed/, 'exhausted entry ID space cannot return an unreadable receipt';
is $bounded->_dbh->selectrow_array('SELECT COUNT(*) FROM mailbox_entries'),   2, 'exhaustion adds no membership';
is $bounded->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1, 'exhaustion rolls back new content';
$bounded->disconnect;

done_testing;

sub receive {
  my ($db, $box, $key, $time) = @_;
  return $db->receive_message(mailbox_id => $box, idempotency_key => $key, message => $raw, received_at => $time);
}
