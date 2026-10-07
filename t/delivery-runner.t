use strictures 2;

use File::Temp qw(tempdir);
use Test2::V0;
use Tie::Hash;
use Overnet::Mail::DeliveryRunner;
use Overnet::Mail::Store;
use Overnet::Mail::Transport::LoopbackSMTP;

{

  package Local::MisleadingOutcome;
  use Moo;
  use overload q{""} => sub { return 'confirmed' }, fallback => 1;
}

my $dir       = tempdir(CLEANUP => 1);
my $serial    = 0;
my $now       = 100;
my $store     = fresh();
my $transport = Overnet::Mail::Transport::LoopbackSMTP->new(port => 1_024);
my %config    = (store => $store, transport => $transport, clock => sub {$now}, retry_after => 60);
my $runner    = Overnet::Mail::DeliveryRunner->new(%config);
is $runner->store,         $store,     'configured store accessor';
is $runner->transport,     $transport, 'configured transport accessor';
is $runner->clock->(),     100,        'injected trusted clock';
is $runner->retry_after,   60,         'explicit retry delay';
is $runner->lease_seconds, 300,        'default bounded lease';
is +Overnet::Mail::DeliveryRunner->new({%config, lease_seconds => 3_600, retry_after => 86_400})->lease_seconds, 3_600,
  'hashref constructor and exact upper bounds';
is +Overnet::Mail::DeliveryRunner->new(%config, lease_seconds => 1, retry_after => 1)->retry_after, 1,
  'exact lower bounds';

for my $name (qw(store transport)) {
  for my $bad (undef, {}, 'private', $name eq 'store' ? $transport : $store) {
    like dies { Overnet::Mail::DeliveryRunner->new(%config, $name => $bad) }, qr/requires Store and LoopbackSMTP/,
      'only the intended trusted object boundaries are accepted';
  }
}
for my $bad (undef, {}, [], 'private') {
  like dies { Overnet::Mail::DeliveryRunner->new(%config, clock => $bad) }, qr/clock must be a callback/,
    'clock must be callable';
}
for my $name (qw(retry_after lease_seconds)) {
  for my $bad (undef, [], q{}, 0, -1, '01', '1.5', 'private', 100_000, '10000000000') {
    like dies { Overnet::Mail::DeliveryRunner->new(%config, $name => $bad) }, qr/bounded canonical integer/,
      'durations are bounded canonical integers';
  }
}
for my $case ([retry_after => 86_401], [lease_seconds => 3_601]) {
  like dies { Overnet::Mail::DeliveryRunner->new(%config, @{$case}) }, qr/bounded canonical integer/,
    'duration exact upper bound enforced';
}
like dies { Overnet::Mail::DeliveryRunner->new(%config, host => 'private') }, qr/unsupported delivery runner option/,
  'unknown constructor options fail closed';
like dies { $runner->run_once(mailbox_id => 'box', now => 0) }, qr/unsupported delivery runner argument/,
  'run time cannot override trusted clock';
like dies { $runner->run_once }, qr/runner could not claim delivery/, 'mailbox remains required';
is $runner->run_once(mailbox_id => 'box'), {status => 'idle'}, 'empty queue has no handoff';

for my $bad (undef, [], q{}, -1, '01', '1.5', 'private', 10_000_000_000) {
  my $bad_clock = Overnet::Mail::DeliveryRunner->new(%config, clock => sub {$bad});
  like dies { $bad_clock->run_once(mailbox_id => 'box') }, qr/runner clock failed or moved backwards/,
    'invalid initial clock fails before claiming without leaking values';
}
my $throwing_clock = Overnet::Mail::DeliveryRunner->new(%config, clock => sub { die 'blind@example.test body' });
my $error          = dies { $throwing_clock->run_once(mailbox_id => 'box') };
like $error,   qr/runner clock failed/, 'clock exception is sanitized';
unlike $error, qr/blind|body/,          'private clock diagnostics never escape';
for my $boundary (0, 9_999_999_999) {
  my $r = Overnet::Mail::DeliveryRunner->new(%config, clock => sub {$boundary});

  # The upper timestamp is valid to the runner but Store refuses lease overflow.
  if ($boundary) {
    like dies { $r->run_once(mailbox_id => 'box') }, qr/runner could not claim delivery/,
      'Store rejects deadline overflow';
  } else {
    is $r->run_once(mailbox_id => 'box'), {status => 'idle'}, 'zero is a valid Unix clock boundary';
  }
}

my $called = 0;
my $report = {outcome => 'confirmed', stage => 'final', smtp_code => 250, private => 'never return'};
my $effect;
my $transport_mock = mock 'Overnet::Mail::Transport::LoopbackSMTP' =>
  (override => [deliver => sub { my ($self, $claim) = @_; ++$called; $effect->($claim) if $effect; return $report }],);
for
  my $case ([confirmed => 'delivered'], [permanent => 'failed'], [transient => 'deferred'], [uncertain => 'uncertain'])
{
  my ($outcome, $state) = @{$case};
  $store = fresh();
  my $receipt = enqueue($store);
  $report = {outcome => $outcome, stage => 'private', smtp_code => 550, private => 'blind@example.test'};
  $runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store);
  my $before = $called;
  is $runner->run_once(mailbox_id => 'box'),
    {
    status      => 'recorded',
    delivery_id => $receipt->{delivery_ids}[0],
    attempt     => 1,
    outcome     => $outcome,
    state       => $state
    },
    'only a durably recorded outcome is reported as recorded';
  is $called, $before + 1, 'exactly one transport call per invocation';
  my $row = $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0];
  is $row->{next_attempt_at}, $state eq 'deferred' || $state eq 'uncertain' ? 160 : 100,
    'retry delay applies only to retryable results';
  is $runner->run_once(mailbox_id => 'box'), {status => 'idle'}, 'no immediate retry or retry of terminal recipients';
  is $called, $before + 1, 'idle call never sends';
  $store->disconnect;
}

for my $bad (
  undef, [], 'private', {},
  {outcome => undef},
  {outcome => []},
  {outcome => 'delivered'},
  {outcome => Local::MisleadingOutcome->new},
  {outcome => "confirmed\n"}
) {
  $store = fresh();
  enqueue($store);
  $report = $bad;
  my $r = Overnet::Mail::DeliveryRunner->new(%config, store => $store);
  is $r->run_once(mailbox_id => 'box')->{outcome}, 'uncertain',
    'malformed reports cannot invent acceptance or rejection';
  is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'uncertain',
    'invalid report consumes bounded uncertain attempt';
  $store->disconnect;
}
$store = fresh();
enqueue($store);
$runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store);
$effect = sub { die 'secret body and blind@example.test' };
is $runner->run_once(mailbox_id => 'box'),
  {status => 'recorded', delivery_id => 1, attempt => 1, outcome => 'uncertain', state => 'uncertain'},
  'transport exception has unknown side effects and is recorded conservatively without exception text';
$effect = undef;
$store->disconnect;

for my $times ([100, 99], [100, 400], [100, 401], [100, undef]) {
  $store = fresh();
  enqueue($store);
  my @time   = @{$times};
  my $r      = Overnet::Mail::DeliveryRunner->new(%config, store => $store, clock => sub { shift @time });
  my $before = $called;
  is $r->run_once(mailbox_id => 'box'),
    {status => 'unrecorded', delivery_id => 1, attempt => 1, outcome => undef, error => 'lease_unavailable'},
    'invalid clock or expired lease after claim prevents known-stale sends';
  is $called, $before, 'pre-send lease failure never contacts transport';
  is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'leased',
    'unsettled lease remains for conservative recovery';
  $store->disconnect;
}
for my $times ([100, 100, 99], [100, 100, 400], [100, 100, 401], [100, 100, undef]) {
  $store = fresh();
  enqueue($store);
  $report = {outcome => 'confirmed'};
  my @time = @{$times};
  my $r    = Overnet::Mail::DeliveryRunner->new(%config, store => $store, clock => sub { shift @time });
  is $r->run_once(mailbox_id => 'box'),
    {status => 'unrecorded', delivery_id => 1, attempt => 1, outcome => 'confirmed', error => 'completion_failed'},
    'post-send bad clock or expired lease cannot masquerade as durable acceptance';
  is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'leased',
    'observed final250 does not bypass fenced local completion';
  $store->disconnect;
}

# The runner copies identity before a fault-injected transport can mutate its input.
$store = fresh();
enqueue($store);
$report = {outcome => 'permanent'};
$runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store);
$effect = sub { my ($claim) = @_; $claim->{delivery_id} = 99; $claim->{attempt} = 5; $claim->{mailbox_id} = 'other' };
is $runner->run_once(mailbox_id => 'box'),
  {status => 'recorded', delivery_id => 1, attempt => 1, outcome => 'permanent', state => 'failed'},
  'transport cannot replace original completion fence or result identity';
$effect = undef;
$store->disconnect;

# Store remains the single owner of the five-attempt cap and retry eligibility.
for my $outcome (qw(transient uncertain)) {
  $store = fresh();
  enqueue($store);
  $report = {outcome => $outcome};
  $now    = 0;
  $runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store, retry_after => 1, lease_seconds => 1);
  for my $attempt (1 .. 5) {
    my $r = $runner->run_once(mailbox_id => 'box');
    is $r->{attempt}, $attempt, 'one bounded attempt is consumed';
    is $r->{state}, $attempt == 5 ? 'exhausted' : $outcome eq 'uncertain' ? 'uncertain' : 'deferred',
      'retryable result exhausts only at Store cap';
    ++$now;
  }
  my $before = $called;
  is $runner->run_once(mailbox_id => 'box'), {status => 'idle'}, 'no sixth delivery attempt';
  is $called, $before, 'exhausted recipient is never sent again';
  $store->disconnect;
}

# Report decoding belongs to the sanitized boundary, even for a faulty injected transport.
$store = fresh();
enqueue($store);
$now    = 100;
$runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store);
{
  tie my %malformed, 'Tie::StdHash';
  $report = \%malformed;
  my $decoder =
    mock 'Tie::StdHash' => (override => [FETCH => sub { die 'private malformed report blind@example.test' }],);
  is $runner->run_once(mailbox_id => 'box'),
    {status => 'recorded', delivery_id => 1, attempt => 1, outcome => 'uncertain', state => 'uncertain'},
    'report decoding exceptions are sanitized and conservatively uncertain';
}
$store->disconnect;

# A lease can fit near the supported clock limit while a retry deadline cannot.
$store = fresh();
enqueue($store);
$now    = 9_999_999_990;
$report = {outcome => 'transient'};
$runner = Overnet::Mail::DeliveryRunner->new(%config, store => $store, lease_seconds => 1);
is $runner->run_once(mailbox_id => 'box'),
  {status => 'unrecorded', delivery_id => 1, attempt => 1, outcome => 'transient', error => 'completion_failed'},
  'Store retry deadline overflow cannot be misreported as durably deferred';
is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'leased',
  'deadline failure preserves lease for recovery';
$store->disconnect;

$transport_mock = undef;
done_testing;

sub fresh {
  return Overnet::Mail::Store->new(path => "$dir/runner-" . ++$serial . '.db');
}

sub enqueue {
  my ($db) = @_;
  my $submission = Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: runner\r\n\r\nbody\r\n"),
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test']),
  );
  return $db->enqueue_submission(mailbox_id => 'box', idempotency_key => 'key', item => $submission);
}
