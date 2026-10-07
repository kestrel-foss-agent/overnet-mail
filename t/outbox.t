use strictures 2;

use File::Temp qw(tempdir);
use Test2::V0;
use Overnet::Mail::Store;

my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/outbox.db";
my $store = Overnet::Mail::Store->new(path => $path);
my $raw   = Overnet::Mail::RawMessage->new(
  raw_bytes => "Message-ID: <opaque\@example.test>\r\nTo: visible\@example.test\r\n\r\nbody\0\xff\r\n");
my $submission = submission($raw, ['visible@example.test', 'blind@example.test', 'blind@example.test']);
my $archive    = $store->accept_item(mailbox_id => 'box', idempotency_key => 'archive', item => $submission);
$store->accept_item(mailbox_id => 'box', idempotency_key => 'inbound', item => $raw);
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM submissions'), 0,
  'archival acceptance never starts an outbound submission';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM deliveries'), 0,
  'RawMessage and archived Submission create no queue';

for my $bad (undef, {}, $raw, $submission->envelope) {
  like dies { enqueue($store, $bad) }, qr/requires a finalized Submission/,
    'explicit enqueue rejects non-submission input';
}
my $receipt = enqueue($store, $submission);
is $receipt->{message_id},     3,                    'acceptance creates its own logical message';
is $receipt->{submission_id},  1,                    'submission has a separate identity namespace';
is $receipt->{delivery_ids},   [1, 2, 3],            'one delivery ID for each ordered recipient including duplicates';
is $receipt->{content_sha256}, $raw->content_sha256, 'digest remains content-only identity';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1,
  'archive and queued submissions share only immutable bytes';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blobs'), 1,
  'archive and queued submissions share one immutable metadata record';
is enqueue($store, $submission), $receipt, 'duplicate enqueue returns identical receipt';
$receipt->{delivery_ids}->[0] = 999;
is enqueue($store, $submission)->{delivery_ids}, [1, 2, 3], 'receipt mutation cannot alter IDs';
my $promoted = $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'archive', item => $submission);
is $promoted->{message_id},    $archive->{message_id}, 'explicit enqueue can promote identical archival acceptance';
is $promoted->{submission_id}, 2,                      'promotion creates one separate submission';
is $store->accept_item(mailbox_id => 'box', idempotency_key => 'archive', item => $submission), $archive,
  'archival API retains original receipt shape';
is $store->deliveries(mailbox_id => 'wrong', submission_id => 1),   [], 'queue status is mailbox-scoped';
is $store->deliveries(mailbox_id => 'box',   submission_id => 999), [], 'missing queue status is empty';
my $rows = $store->deliveries(mailbox_id => 'box', submission_id => 1);
is [map { $_->{state} } @{$rows}],              ['ready', 'ready', 'ready'], 'each recipient starts ready';
is [map { $_->{position} } @{$rows}],           [0,       1,       2],       'recipient positions preserve duplicates';
is [map { $_->{attempt} } @{$rows}],            [0,       0,       0],       'enqueue does not consume attempts';
is [map { $_->{uncertain_attempts} } @{$rows}], [0,       0,       0],       'no invented ambiguity';
ok !exists $rows->[0]->{recipient}, 'status does not expose recipient addresses';
$rows->[0]->{state} = 'delivered';
is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'ready',
  'status mutation cannot affect queue';
my $conflict = submission($raw, ['other@example.test']);
like dies { enqueue($store, $conflict) }, qr/idempotency key conflicts/,
  'enqueue preserves original envelope idempotency';
my $other = $store->enqueue_submission(mailbox_id => 'other', idempotency_key => 'request', item => $submission);
is $other->{submission_id}, 3, 'same key in another mailbox has separate submission identity';
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
is enqueue($store, $submission)->{delivery_ids}, [1, 2, 3], 'submission and IDs survive reconnect';
is $store->load(mailbox_id => 'box', message_id => 3)->{message}->raw_bytes, $raw->raw_bytes,
  'queue never reserializes MIME';
$store->disconnect;

# Isolated queue for individual outcomes and retry deadlines.
$store = Overnet::Mail::Store->new(path => "$dir/outcomes.db");
my $accepted = enqueue($store, $submission);
ok !defined $store->claim_delivery(mailbox_id => 'other', now => 100), 'claim cannot cross mailbox boundary';
my $first = $store->claim_delivery(mailbox_id => 'box', now => 100);
is $first->{lease_until},        400,                    'default lease is five minutes';
is $first->{attempt},            1,                      'first claim creates fencing generation one';
is $first->{recipient},          'visible@example.test', 'claim has one explicit envelope recipient';
is $first->{sender},             q{},                    'null reverse path survives claim';
is $first->{message}->raw_bytes, $raw->raw_bytes,        'claim provides unchanged bytes';
ok !exists $first->{envelope}, 'claim does not return the full private envelope';
is $first->{submission_id}, $accepted->{submission_id}, 'claim identifies submission separately';
my $second = $store->claim_delivery(mailbox_id => 'box', now => 100, lease_seconds => 10);
is $second->{delivery_id}, 2,                    'live first lease cannot be claimed again';
is $second->{recipient},   'blind@example.test', 'private envelope recipient is not inferred from visible To';
my $third = $store->claim_delivery(mailbox_id => 'box', now => 100, lease_seconds => 10);
is $third->{delivery_id}, 3, 'duplicate recipient is a distinct delivery';
ok !defined $store->claim_delivery(mailbox_id => 'box', now => 100), 'all active leases leave queue empty';
my $sent = finish($store, $first, 101, 'confirmed');
is $sent->{state},        'delivered', 'only confirmed outcome marks delivery';
is $sent->{last_outcome}, 'confirmed', 'confirmed evidence classification is retained';
ok !defined $sent->{lease_until}, 'finish releases the local lease';
my $failed = finish($store, $second, 101, 'permanent');
is $failed->{state}, 'failed', 'permanent failure is terminal for only that recipient';
my $uncertain = finish($store, $third, 101, 'uncertain', retry_after => 30);
is $uncertain->{state},              'uncertain', 'lost remote acknowledgement remains visibly uncertain';
is $uncertain->{uncertain_attempts}, 1,           'uncertainty is counted durably';
is $uncertain->{next_attempt_at},    131,         'retry deadline is persisted';
my $replay = enqueue($store, $submission);
is $replay, $accepted, 'enqueue replay never resets completed or partial recipient outcomes';
is [map { $_->{state} } @{$store->deliveries(mailbox_id => 'box', submission_id => 1)}],
  ['delivered', 'failed', 'uncertain'], 'partial recipient outcomes are independent';
$store->disconnect;
$store = Overnet::Mail::Store->new(path => "$dir/outcomes.db");
ok !defined $store->claim_delivery(mailbox_id => 'box', now => 130), 'retry delay survives restart';
my $retried = $store->claim_delivery(mailbox_id => 'box', now => 131, lease_seconds => 1);
is $retried->{attempt},            2,           'exact retry deadline issues a new fencing token';
is $retried->{uncertain_attempts}, 1,           'retry does not erase ambiguity';
is $retried->{last_outcome},       'uncertain', 'retry retains previous outcome';
like dies { finish($store, $third, 131, 'confirmed') }, qr/lease is missing, stale or expired/,
  'old attempt cannot acknowledge a newer claim';
my $late = finish($store, $retried, 131, 'confirmed');
is $late->{state},              'delivered', 'a subsequent confirmed attempt may complete the recipient';
is $late->{uncertain_attempts}, 1, 'completion cannot hide duplicate-delivery risk from previous ambiguous attempt';
like dies { finish($store, $retried, 131, 'confirmed') }, qr/lease is missing, stale or expired/,
  'terminal outcome cannot be settled twice';
ok !defined $store->claim_delivery(mailbox_id => 'box', now => 500),
  'terminal recipients are never automatically retried';
$store->disconnect;

# Expiry fences stale workers even before another worker has reclaimed the row.
$store = Overnet::Mail::Store->new(path => "$dir/expiry.db");
enqueue($store, submission($raw, ['one@example.test']));
my $lease = $store->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
like dies { finish($store, $lease, 1, 'confirmed') }, qr/lease is missing, stale or expired/,
  'exact lease boundary rejects success';
like dies {
  $store->finish_delivery(mailbox_id => 'other', delivery_id => 1, attempt => 1, now => 0, outcome => 'confirmed')
}, qr/lease is missing, stale or expired/, 'settlement cannot cross mailbox boundary';
like dies {
  $store->finish_delivery(mailbox_id => 'box', delivery_id => 999, attempt => 1, now => 0, outcome => 'confirmed')
}, qr/lease is missing, stale or expired/, 'missing delivery cannot be settled';
my $reclaimed = $store->claim_delivery(mailbox_id => 'box', now => 1, lease_seconds => 1);
is $reclaimed->{attempt},            2,               'expired lease is reclaimed with a fresh attempt';
is $reclaimed->{uncertain_attempts}, 1,               'expired lease records potential unknown external outcome';
is $reclaimed->{last_outcome},       'lease_expired', 'lease recovery has explicit diagnostic';
like dies { finish($store, $lease, 1, 'permanent') }, qr/lease is missing, stale or expired/,
  'stale worker cannot overwrite newer attempt with failure';
for my $now (2 .. 4) {
  $reclaimed = $store->claim_delivery(mailbox_id => 'box', now => $now, lease_seconds => 1);
  is $reclaimed->{attempt}, $now + 1, 'each expiry consumes exactly one bounded attempt';
}
ok !defined $store->claim_delivery(mailbox_id => 'box', now => 5), 'fifth expired lease is never claimed a sixth time';
my $exhausted = $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0];
is $exhausted->{state},              'exhausted', 'ambiguous exhaustion is distinct from a remote permanent failure';
is $exhausted->{uncertain_attempts}, 5,           'all five unknown outcomes remain visible';
is $exhausted->{last_outcome},       'lease_expired', 'exhaustion keeps the last cause';
$store->disconnect;

# Retryable responses exhaust at a fixed bound, including ambiguous responses.
for my $outcome (qw(transient uncertain)) {
  my $file = "$dir/retry-$outcome.db";
  $store = Overnet::Mail::Store->new(path => $file);
  enqueue($store, submission($raw, ['one@example.test']));
  my $result;
  for my $attempt (1 .. 5) {
    my $claim = $store->claim_delivery(mailbox_id => 'box', now => $attempt, lease_seconds => 2);
    $result = finish($store, $claim, $attempt, $outcome, retry_after => 1);
    is $result->{attempt}, $attempt, 'retry attempt count persists';
    is $result->{state}, $attempt == 5 ? 'exhausted' : $outcome eq 'transient' ? 'deferred' : 'uncertain',
      'bounded transition matches outcome';
    $store->disconnect;
    $store = Overnet::Mail::Store->new(path => $file);
  }
  is $result->{uncertain_attempts}, $outcome eq 'uncertain' ? 5 : 0, 'transient failure is not invented ambiguity';
  ok !defined $store->claim_delivery(mailbox_id => 'box', now => 99), 'retry exhaustion survives restart';
  is enqueue($store, submission($raw, ['one@example.test']))->{delivery_ids}, [1],
    'replay cannot restart exhausted delivery';
  $store->disconnect;
}

# A final permitted attempt may still produce either conclusive terminal outcome.
for my $outcome (qw(confirmed permanent)) {
  $store = Overnet::Mail::Store->new(path => "$dir/final-$outcome.db");
  enqueue($store, submission($raw, ['one@example.test']));
  for my $now (1 .. 4) {
    my $claimed = $store->claim_delivery(mailbox_id => 'box', now => $now, lease_seconds => 1);
    finish($store, $claimed, $now, 'transient', retry_after => 1);
  }
  my $claimed = $store->claim_delivery(mailbox_id => 'box', now => 5);
  is finish($store, $claimed, 5, $outcome)->{state}, $outcome eq 'confirmed' ? 'delivered' : 'failed',
    'attempt five can finish conclusively';
  $store->disconnect;
}

# Claiming one mailbox must not even expire another mailbox's lease.
my $isolated = "$dir/isolated.db";
$store = Overnet::Mail::Store->new(path => $isolated);
enqueue($store, submission($raw, ['one@example.test']));
$store->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
$store->claim_delivery(mailbox_id => 'other', now => 1);
is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'leased',
  'expiry mutation is mailbox-local';
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $isolated, max_message_bytes => 1);
is $store->claim_delivery(mailbox_id => 'box', now => 1)->{message}->raw_bytes, $raw->raw_bytes,
  'lowered acceptance limit does not strand an already accepted queue';
$store->disconnect;

# Fail closed on input errors without placing values or addresses in diagnostics.
$store = Overnet::Mail::Store->new(path => "$dir/validation.db");
enqueue($store, submission($raw, ['secret@example.test']));
my %claim = (mailbox_id => 'box', now => 100, lease_seconds => 1);
for my $field (qw(now lease_seconds)) {
  for my $bad (undef, [], q{}, -1, '01', '1.5', 'x', '1' x 19) {
    like dies { $store->claim_delivery(%claim, $field => $bad) }, qr/bounded canonical integer/,
      'invalid claim integer rejected';
  }
}
for my $bad (0, 3_601) {
  like dies { $store->claim_delivery(%claim, lease_seconds => $bad) }, qr/bounded canonical integer/,
    'lease duration bounded';
}
like dies { $store->claim_delivery(%claim, now => 10_000_000_000) }, qr/bounded canonical integer/,
  'clock range bounded';
like dies { $store->claim_delivery(%claim, now => 9_999_999_999) }, qr/deadline exceeds/,
  'derived deadline cannot overflow clock range';
for my $method (qw(deliveries claim_delivery finish_delivery)) {
  like dies { $store->$method(mailbox_id => []) }, qr/bounded ASCII/, 'queue API validates mailbox';
}
like dies { $store->deliveries(mailbox_id => 'box', submission_id => 0) }, qr/bounded canonical integer/,
  'status validates submission ID';
my %finish = (mailbox_id => 'box', delivery_id => 1, attempt => 1, now => 100, outcome => 'confirmed');
for my $field (qw(delivery_id attempt now)) {
  like dies { $store->finish_delivery(%finish, $field => []) }, qr/bounded canonical integer/,
    'settlement validates identity and clock';
}
for my $bad (undef, [], 'delivered', 'secret@example.test') {
  my $error = dies { $store->finish_delivery(%finish, outcome => $bad) };
  like $error,   qr/invalid delivery outcome/, 'unknown settlement outcome rejected';
  unlike $error, qr/secret\@/,                 'invalid outcome value is not logged';
}
like dies { $store->finish_delivery(%finish, retry_after => 1) }, qr/requires a retryable outcome/,
  'terminal result rejects retry delay';
for my $bad (undef, 0, 86_401) {
  like dies { $store->finish_delivery(%finish, outcome => 'transient', retry_after => $bad) },
    qr/bounded canonical integer/, 'retry delay required and bounded';
}
like dies { $store->finish_delivery(%finish) }, qr/lease is missing, stale or expired/,
  'ready delivery cannot be settled before claiming';
my $valid = $store->claim_delivery(%claim, lease_seconds => 3_600);
my $retry = finish($store, $valid, 100, 'transient', retry_after => 86_400);
is $retry->{next_attempt_at}, 86_500, 'maximum permitted lease and retry delay work';
$store->disconnect;
like dies { $store->claim_delivery(%claim) }, qr/store is closed/, 'closed queue refuses claims';

done_testing;

sub enqueue {
  my ($storage, $item) = @_;
  return $storage->enqueue_submission(mailbox_id => 'box', idempotency_key => 'request', item => $item);
}

sub submission {
  my ($message, $recipients) = @_;
  return Overnet::Mail::Submission->new(
    message  => $message,
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => $recipients)
  );
}

sub finish {
  my ($storage, $claimed, $now, $outcome, %extra) = @_;
  return $storage->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $claimed->{delivery_id},
    attempt     => $claimed->{attempt},
    now         => $now,
    outcome     => $outcome,
    %extra
  );
}
