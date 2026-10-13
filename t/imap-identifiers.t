use strictures 2;

use File::Temp qw(tempdir);
use Test2::V0;
use Overnet::Mail::Store;

my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/imap.db";
my $store = Overnet::Mail::Store->new(path => $path);
my $raw   = Overnet::Mail::RawMessage->new(raw_bytes => "Bcc: opaque\@example.test\r\n\r\n" . pack('C*', 0 .. 255));
is $store->mailbox_state(mailbox_id => 'absent'),              undef, 'read-only state does not create a mailbox';
is $store->mailbox_uid_entries(mailbox_id => 'absent'),        [],    'absent UID listing is empty';
is $store->load_mailbox_uid(mailbox_id => 'absent', uid => 1), undef, 'absent UID fetch returns nothing';
is $store->_dbh->selectrow_array('SELECT next_value FROM mailbox_uidvalidity'), 1,
  'read-only calls do not consume UIDVALIDITY';
my $empty = $store->ensure_mailbox(mailbox_id => 'empty');
is $empty, {uidvalidity => 1, uidnext => 1, message_count => 0}, 'empty mailbox has durable initial state';
is $store->ensure_mailbox(mailbox_id => 'empty'), $empty, 'ensure is idempotent';
is $store->mailbox_state(mailbox_id => 'empty'),  $empty, 'state matches empty ensure';
$empty->{uidnext} = 900;
is $store->mailbox_state(mailbox_id => 'empty')->{uidnext}, 1, 'returned state is detached';
my $first  = receive('a', 'first',  20);
my $other  = receive('b', 'first',  30);
my $second = receive('a', 'second', 10);
is $store->mailbox_state(mailbox_id => 'a'), {uidvalidity => 2, uidnext => 3, message_count => 2},
  'implicit mailbox uses the durable global validity allocator';
is $store->mailbox_state(mailbox_id => 'b'), {uidvalidity => 3, uidnext => 2, message_count => 1},
  'other mailbox gets independent validity and UID sequence';
my $a = [{%{$first}, uid => 1}, {%{$second}, uid => 2}];
is $store->mailbox_uid_entries(mailbox_id => 'a'), $a, 'UIDs ignore global receipt gaps and timestamp order';
is $store->mailbox_uid_entries(mailbox_id => 'b'), [{%{$other}, uid => 1}], 'UID values can repeat in other mailboxes';
is $store->mailbox_uid_entries(mailbox_id => 'a', after_uid => 1, limit => 1), [$a->[1]],
  'UID cursor is exclusive and page limit is honored';
is $store->mailbox_uid_entries(mailbox_id => 'a', after_uid => 4_294_967_295), [], 'maximum cursor never wraps';
is $store->load_mailbox_uid(mailbox_id => 'a', uid => 4_294_967_295), undef, 'maximum UID lookup does not overflow';
is $store->load_mailbox_uid(mailbox_id => 'b', uid => 2), undef, 'UID lookup is scoped to the selected mailbox';
my $loaded = $store->load_mailbox_uid(mailbox_id => 'a', uid => 2);
is [sort keys %{$loaded}], [qw(content_sha256 entry_id message received_at uid)], 'UID fetch projects only safe fields';
is $loaded->{message}->raw_bytes, $raw->raw_bytes, 'UID fetch preserves every RFC822 octet';
ok !utf8::is_utf8($loaded->{message}->raw_bytes), 'UID fetch remains byte-oriented';
is receive('a', 'second', 99),                                 $second, 'replay retains the existing receipt shape';
is $store->mailbox_state(mailbox_id => 'a')->{uidnext},        3,       'replay does not allocate another UID';
is $store->ensure_mailbox(mailbox_id => 'a')->{message_count}, 2,       'ensure existing nonempty state reports count';
like dies {
  $store->receive_message(
    mailbox_id      => 'a',
    idempotency_key => 'second',
    received_at     => 1,
    message         => Overnet::Mail::RawMessage->new(raw_bytes => 'changed')
  )
}, qr/idempotency key conflicts/, 'changed bytes cannot reuse an existing UID';
is $store->mailbox_state(mailbox_id => 'a')->{uidnext}, 3, 'conflict does not advance UIDNEXT';
my $submission = Overnet::Mail::Submission->new(
  message  => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: outbound\r\n\r\noutbound"),
  envelope => Overnet::Mail::Envelope->new(sender => 'sender@example.test', recipients => ['blind@example.test'])
);
$store->enqueue_submission(mailbox_id => 'outgoing-only', idempotency_key => 'key', item => $submission);
is $store->mailbox_state(mailbox_id => 'outgoing-only'), undef, 'outgoing archives never create IMAP state';
my $copy = $store->receive_message(
  mailbox_id      => 'copy',
  idempotency_key => 'key',
  received_at     => 0,
  message         => $submission->message
);
is [sort keys %{$store->load_mailbox_uid(mailbox_id => 'copy', uid => 1)}],
  [qw(content_sha256 entry_id message received_at uid)], 'shared outgoing bytes do not expose private envelope';

# Read a bounded append-only snapshot without keeping a transaction open.
my $captured = $store->mailbox_state(mailbox_id => 'a');
receive('a', 'later', 0);
my @snapshot = grep { $_->{uid} < $captured->{uidnext} } @{$store->mailbox_uid_entries(mailbox_id => 'a')};
is \@snapshot,       $a,                         'captured UIDNEXT excludes concurrently appended entries';
is scalar @snapshot, $captured->{message_count}, 'captured count matches the immutable prefix';

for my $method (qw(ensure_mailbox mailbox_state mailbox_uid_entries load_mailbox_uid)) {
  for my $bad (undef, [], q{}, '_first', 'a;SELECT', "a\0", 'a' x 129, "\x{e9}") {
    like dies { $store->$method(mailbox_id => $bad, uid => 1) }, qr/bounded ASCII tokens/, "$method validates mailbox";
  }
}
for my $bad (undef, [], q{}, -1, '01', '1.5', '1e2', '+1', '1' x 19, 4_294_967_296) {
  like dies { $store->mailbox_uid_entries(mailbox_id => 'a', after_uid => $bad) }, qr/bounded canonical integer/,
    'UID cursor rejects invalid values';
  like dies { $store->load_mailbox_uid(mailbox_id => 'a', uid => $bad) }, qr/bounded canonical integer/,
    'UID fetch rejects invalid values';
}
like dies { $store->load_mailbox_uid(mailbox_id => 'a', uid => 0) }, qr/bounded canonical integer/, 'zero is not a UID';
for my $bad (undef, [], q{}, 0, -1, '01', '1.5', 1001) {
  like dies { $store->mailbox_uid_entries(mailbox_id => 'a', limit => $bad) }, qr/bounded canonical integer/,
    'explicit invalid limit never defaults';
}
for my $number (1 .. 105) { receive('many', "key-$number", $number) }
is scalar @{$store->mailbox_uid_entries(mailbox_id => 'many')},                100, 'default UID page limit is 100';
is scalar @{$store->mailbox_uid_entries(mailbox_id => 'many', limit => 1000)}, 105, 'explicit maximum limit is valid';
my $before = $store->mailbox_state(mailbox_id => 'a');
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
is $store->mailbox_state(mailbox_id => 'a'),                   $before, 'validity, next UID and count survive restart';
is $store->mailbox_uid_entries(mailbox_id => 'a', limit => 2), $a,      'committed UIDs survive restart';
is $store->load_mailbox_uid(mailbox_id => 'a', uid => 2)->{message}->raw_bytes, $raw->raw_bytes,
  'offline UID fetch preserves exact bytes after restart';

# SQLite constraints retain the same integer bounds as the public API.
for my $case (
  ['mailboxes',           'uidvalidity', 0],
  ['mailboxes',           'uidvalidity', 4_294_967_296],
  ['mailboxes',           'uidnext',     0],
  ['mailboxes',           'uidnext',     4_294_967_296],
  ['mailbox_entries',     'uid',         0],
  ['mailbox_entries',     'uid',         4_294_967_295],
  ['mailbox_uidvalidity', 'next_value',  0],
  ['mailbox_uidvalidity', 'next_value',  4_294_967_297],
) {
  my ($table, $column, $value) = @{$case};
  my $where =
      $table eq 'mailboxes'       ? q{mailbox_id = 'a'}
    : $table eq 'mailbox_entries' ? q{mailbox_id = 'a' AND uid = 2}
    :                               'singleton = 1';
  $store->_dbh->begin_work;
  my $error = dies { $store->_dbh->do("UPDATE $table SET $column = ? WHERE $where", undef, $value) };
  $store->_dbh->rollback;
  like $error, qr/database operation failed/, 'SQL constraints reject an out-of-range stored identifier';
}
like dies { $store->_dbh->do(q{UPDATE mailbox_entries SET uid = 1 WHERE mailbox_id = 'a' AND uid = 2}) },
  qr/database operation failed/, 'SQL enforces mailbox-local UID uniqueness';
like dies { $store->_dbh->do(q{DELETE FROM mailboxes WHERE mailbox_id = 'a'}) }, qr/database operation failed/,
  'receipt foreign key protects its mailbox state';
is $store->mailbox_state(mailbox_id => 'a'), $before, 'failed direct fixture mutations leave state intact';

# Corrupt bodies fail through the same integrity path as receipt-ID fetches.
$store->_dbh->do('UPDATE blossom_blob_data SET body = zeroblob(length(body)) WHERE storage_key = ?',
  undef, $raw->content_sha256);
like dies { $store->load_mailbox_uid(mailbox_id => 'a', uid => 1) }, qr/content integrity/,
  'UID fetch fails on corrupt body';
is $store->mailbox_state(mailbox_id => 'a'), $before,              'metadata reads do not pretend to audit content';
is $store->mailbox_uid_entries(mailbox_id => 'a', limit => 2), $a, 'metadata listing does not read bodies';
$store->disconnect;
for my $method (qw(ensure_mailbox mailbox_state mailbox_uid_entries load_mailbox_uid)) {
  like dies { $store->$method(mailbox_id => 'a', uid => 1) }, qr/store is closed/, "$method rejects closed handles";
}

done_testing;

sub receive {
  my ($box, $key, $time) = @_;
  return $store->receive_message(mailbox_id => $box, idempotency_key => $key, message => $raw, received_at => $time);
}
