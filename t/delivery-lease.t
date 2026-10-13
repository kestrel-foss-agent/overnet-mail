use strictures 2;

use File::Temp qw(tempdir);
use Test2::V0;
use Sub::Util qw(set_prototype);
use Overnet::Mail::DeliveryRunner;
use Overnet::Mail::Store;
use Overnet::Mail::Transport::LoopbackSMTP;

my $dir    = tempdir(CLEANUP => 1);
my $serial = 0;

subtest 'settlement reserve is an independently bounded runner option' => sub {
  my $store = fresh();
  enqueue($store);
  my $before = $store->deliveries(mailbox_id => 'box', submission_id => 1);
  my %config = (
    store       => $store,
    transport   => transport(),
    clock       => sub { return 100; },
    retry_after => 60,
  );
  is +Overnet::Mail::DeliveryRunner->new(%config)->settlement_seconds, 5, 'five seconds reserved by default';
  for my $reserve (1, 30) {
    is +Overnet::Mail::DeliveryRunner->new({%config, settlement_seconds => $reserve})->settlement_seconds,
      $reserve, 'both inclusive reserve boundaries are accepted';
  }
  for my $bad (undef, [], {}, q{}, 0, -1, '01', '1.5', 'private-value', 31, 100_000) {
    my $error = dies { Overnet::Mail::DeliveryRunner->new(%config, settlement_seconds => $bad) };
    like $error,   qr/bounded canonical integer/, 'invalid reserve fails closed';
    unlike $error, qr/private-value/,             'reserve validation never exposes supplied values';
  }
  for my $lease (1, 2, 15, 16) {
    like dies { Overnet::Mail::DeliveryRunner->new(%config, lease_seconds => $lease) },
      qr/lease must exceed attempt, settlement and rounding budgets/,
      'impossible lease configuration is rejected before any claim';
  }
  for my $budget ([1, 1, 3], [30, 30, 61]) {
    my ($attempt, $reserve, $lease) = @{$budget};
    like dies {
      Overnet::Mail::DeliveryRunner->new(
        %config,
        transport          => transport($attempt),
        settlement_seconds => $reserve,
        lease_seconds      => $lease
      );
    }, qr/lease must exceed attempt, settlement and rounding budgets/,
      'configuration guard uses the configured attempt and settlement limits';
  }
  is $store->deliveries(mailbox_id => 'box', submission_id => 1), $before,
    'configuration errors leave the queued recipient and attempt counter untouched';
  $store->disconnect;
};

subtest 'admission includes the full attempt, reserve and integer-clock safety' => sub {
  for my $case (
    {label => 'exact default fit',     lease_seconds => 17, claim_delay => 1, admitted => 1, deadline => 1_011},
    {label => 'one millisecond short', lease_seconds => 17, claim_delay => 1.001},
    {label => 'one second short',      lease_seconds => 17, claim_delay => 2},
    {
      label              => 'smallest budgets fit',
      lease_seconds      => 4,
      claim_delay        => 1,
      attempt_seconds    => 1,
      settlement_seconds => 1,
      admitted           => 1,
      deadline           => 1_002
    },
    {
      label              => 'largest budgets fit',
      lease_seconds      => 62,
      claim_delay        => 1,
      attempt_seconds    => 30,
      settlement_seconds => 30,
      admitted           => 1,
      deadline           => 1_031
    },
    {
      label              => 'largest reserve still charged',
      lease_seconds      => 62,
      claim_delay        => 2,
      attempt_seconds    => 30,
      settlement_seconds => 30
    },
  ) {
    subtest $case->{label} => sub {
      my $seen = runner_case(%{$case});
      if ($case->{admitted}) {
        is $seen->{result},     recorded(),          'a full-budget handoff is durably recorded';
        is $seen->{deadlines},  [$case->{deadline}], 'SMTP gets only the absolute pre-settlement deadline';
        is $seen->{row}{state}, 'delivered',         'accepted handoff settled the real SQLite lease';
      } else {
        refused($seen);
      }
    };
  }
};

subtest 'slow claim and both wall-clock callbacks consume the original allowance' => sub {
  for my $case (
    {
      label         => 'claim finishes at exact fit',
      lease_seconds => 30,
      claim_delay   => 14,
      admitted      => 1,
      deadline      => 1_024
    },
    {label => 'claim finishes epsilon late', lease_seconds => 30, claim_delay => 14.001},
    {label => 'slow initial clock',          lease_seconds => 17, wall_delays => [1.001]},
    {label => 'slow pre-send clock',         lease_seconds => 17, wall_delays => [0, 1.001]},
    {
      label         => 'initial clock leaves exact fit',
      lease_seconds => 17,
      wall_delays   => [1],
      admitted      => 1,
      deadline      => 1_011
    },
    {
      label         => 'pre-send clock leaves exact fit',
      lease_seconds => 17,
      wall_delays   => [0, 1],
      admitted      => 1,
      deadline      => 1_011
    },
  ) {
    subtest $case->{label} => sub {
      my $seen = runner_case(%{$case});
      if ($case->{admitted}) {
        is $seen->{result},    recorded(),          'remaining exact fit is accepted';
        is $seen->{deadlines}, [$case->{deadline}], 'frozen wall clock cannot restart the monotonic budget';
      } else {
        refused($seen);
      }
    };
  }
};

subtest 'new wall samples can shorten but never extend the saved deadline' => sub {
  my $forward = runner_case(lease_seconds => 30, wall_values => [100, 110, 110]);
  is $forward->{result},    recorded(), 'a forward wall change with enough time still permits delivery';
  is $forward->{deadlines}, [1_014],    'forward wall change subtracts ten seconds from the SMTP deadline';

  my $slower = runner_case(lease_seconds => 30, claim_delay => 10, wall_values => [100, 101, 101]);
  is $slower->{result},    recorded(), 'wall progression slower than elapsed monotonic time remains usable';
  is $slower->{deadlines}, [1_024],    'later wall-derived deadline cannot extend the original monotonic deadline';

  my $exact = runner_case(lease_seconds => 30, wall_values => [100, 114, 114]);
  is $exact->{result},    recorded(), 'forward jump leaving exactly attempt plus reserve is accepted';
  is $exact->{deadlines}, [1_010],    'exact-fit forward jump preserves the entire reserve';
  refused(runner_case(lease_seconds => 30, wall_values => [100, 115]));
  refused(runner_case(lease_seconds => 30, wall_values => [100, 110], wall_delays => [0, 4.001]));
  for my $bad (99, undef, [], q{}, '100.1', '0100', 'private-value') {
    refused(runner_case(lease_seconds => 30, wall_values => [100, $bad]));
  }
};

subtest 'completion needs both a usable wall clock and an unexpired monotonic lease' => sub {
  my $before = runner_case(lease_seconds => 30, send_delay => 28.999);
  is $before->{result},             recorded(), 'completion epsilon before the conservative deadline is allowed';
  is scalar @{$before->{finishes}}, 1,          'Store gets one completion while the lease budget remains';
  for my $delay (29, 29.001, 35) {
    completion_refused(runner_case(lease_seconds => 30, send_delay => $delay));
  }
  completion_refused(
    runner_case(
      lease_seconds => 30,
      send_delay    => 24,
      wall_delays   => [0, 0, 5]
    )
  );
  completion_refused(runner_case(lease_seconds => 30, wall_values => [100, 110, 110], send_delay => 19));
  for my $bad (99, undef, [], 'private-value') {
    completion_refused(runner_case(lease_seconds => 30, wall_values => [100, 100, $bad]));
  }
};

subtest 'a mutable handoff cannot replace the completion fence or lease deadline' => sub {
  for my $replacement (0, 9_999_999_999) {
    my $seen = runner_case(lease_seconds => 30, mutate_lease => $replacement, send_delay => 28.999);
    is $seen->{result},    recorded(), 'result identity remains the saved original claim';
    is $seen->{deadlines}, [1_024],    'transport received the original lease-derived SMTP deadline';
    is $seen->{finishes},
      [
      {
        mailbox_id  => 'box',
        delivery_id => 1,
        attempt     => 1,
        now         => 100,
        outcome     => 'confirmed'
      }
      ],
      'Store receives the original copied fence';
    is $seen->{row}{state}, 'delivered', 'original SQLite row, not a replacement identity, is settled';
  }
  completion_refused(runner_case(lease_seconds => 30, mutate_lease => 9_999_999_999, send_delay => 29));
};

subtest 'adapter rejects invalid or unknown deadline options before SMTP' => sub {
  my $runs    = 0;
  my $attempt = mock 'Overnet::Mail::Transport::Attempt' =>
    (override => [run => sub { ++$runs; return {outcome => 'confirmed'}; }]);
  my $clock = mock 'Overnet::Mail::Transport::LoopbackSMTP' =>
    (override => [clock_gettime => set_prototype(q{;$}, sub { return 1_000; })]);
  my $adapter = transport();
  my $claim   = claim();
  for my $bad (undef, [], {}, sub { return; }, q{}, 'private-value', -1, -0.001, 'NaN', 'Inf', '-Inf', 'Infinity') {
    my $error = dies { $adapter->deliver($claim, deadline => $bad) };
    like $error,   qr/finite nonnegative monotonic time/, 'deadline must be a finite nonnegative scalar';
    unlike $error, qr/private-value/,                     'deadline errors never echo supplied values';
  }
  for my $args ([timeout => 10], [deadline => 1_001, private => 'blind@example.test']) {
    like dies { $adapter->deliver($claim, @{$args}) }, qr/unsupported delivery argument/,
      'unknown per-call options fail closed';
  }
  for my $args (['deadline'], ['deadline', 1_001, 'private-value']) {
    my $error = dies { $adapter->deliver($claim, @{$args}) };
    like $error,   qr/Odd number of elements in hash assignment/, 'strictures rejects odd option lists before delivery';
    unlike $error, qr/private-value|blind\@example/,              'malformed-option failure contains no supplied value';
  }
  is $runs, 0, 'invalid options never start an SMTP attempt';
};

subtest 'adapter passes the minimum fixed absolute deadline through to Attempt' => sub {
  for my $case (
    {label => 'independent budget',     expected => 1_010},
    {label => 'earlier external bound', deadline => 1_004.25, expected => 1_004.25},
    {label => 'later external bound',   deadline => 1_020,    expected => 1_010},
    {label => 'equal bounds',           deadline => 1_010,    expected => 1_010},
    {label => 'validation consumes external bound',    deadline => 1_005, validation_delay => 4.999, expected => 1_005},
    {label => 'validation consumes independent bound', validation_delay => 9.999, expected => 1_010},
  ) {
    subtest $case->{label} => sub {
      my $seen = adapter_case(%{$case});
      is $seen->{deadlines}, [$case->{expected}], 'supervisor receives the earliest original absolute deadline';
      is $seen->{result},    smtp_confirmed(),    'supervisor outcome passes through unchanged';
      is $seen->{validated}, 1,                   'real wire validation occurs before the attempt';
    };
  }
};

subtest 'expired external or validation budgets never start an SMTP attempt' => sub {
  for my $case (
    {deadline         => 0},
    {deadline         => 999.999},
    {deadline         => 1_000},
    {deadline         => 1_005, validation_delay => 5},
    {deadline         => 1_005, validation_delay => 5.001},
    {validation_delay => 10},
    {deadline         => 1_020, validation_delay => 10},
  ) {
    my $seen = adapter_case(%{$case});
    is $seen->{deadlines}, [], 'exhausted budget never forks or opens SMTP';
    is $seen->{result}, {outcome => 'transient', stage => 'connect', smtp_code => undef},
      'exhaustion before SMTP is retryable with no peer evidence';
  }
};

done_testing;

sub fresh {
  return Overnet::Mail::Store->new(path => "$dir/lease-" . ++$serial . '.db');
}

sub transport {
  my ($seconds) = @_;
  return Overnet::Mail::Transport::LoopbackSMTP->new(
    port            => 1_024,
    attempt_seconds => defined $seconds ? $seconds : 10
  );
}

sub claim {
  return {
    message   => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: lease\r\n\r\nprivate body\r\n"),
    sender    => q{},
    recipient => 'blind@example.test',
  };
}

sub enqueue {
  my ($store) = @_;
  my $input   = claim();
  my $item    = Overnet::Mail::Submission->new(
    message  => $input->{message},
    envelope => Overnet::Mail::Envelope->new(sender => $input->{sender}, recipients => [$input->{recipient}])
  );
  return $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'lease', item => $item);
}

sub runner_case {
  my (%args) = @_;
  my $store = fresh();
  enqueue($store);
  my $tick  = 1_000;
  my $calls = 0;
  my (@deadlines, @finishes);
  my $original_claim  = \&Overnet::Mail::Store::claim_delivery;
  my $original_finish = \&Overnet::Mail::Store::finish_delivery;
  my $store_mock      = mock 'Overnet::Mail::Store' => (
    override => [
      claim_delivery => sub {
        my $claimed = $original_claim->(@_);
        $tick += $args{claim_delay} // 0;
        return $claimed;
      },
      finish_delivery => sub {
        my ($db, %finish) = @_;
        push @finishes, {%finish};
        return $original_finish->($db, %finish);
      },
    ]
  );
  my $runner_mock = mock 'Overnet::Mail::DeliveryRunner' =>
    (override => [clock_gettime => set_prototype(q{;$}, sub { return $tick; })]);
  my $transport_mock = mock 'Overnet::Mail::Transport::LoopbackSMTP' => (
    override => [
      deliver => sub {
        my ($adapter, $claimed, %options) = @_;
        push @deadlines, $options{deadline};
        if (exists $args{mutate_lease}) {
          @{$claimed}{qw(delivery_id attempt mailbox_id lease_until)} = (99, 99, 'other', $args{mutate_lease});
        }
        $tick += $args{send_delay} // 0;
        return smtp_confirmed();
      },
    ]
  );
  my $runner = Overnet::Mail::DeliveryRunner->new(
    store              => $store,
    transport          => transport($args{attempt_seconds}),
    retry_after        => 60,
    lease_seconds      => $args{lease_seconds}      // 30,
    settlement_seconds => $args{settlement_seconds} // 5,
    clock              => sub {
      my $index = $calls++;
      $tick += $args{wall_delays}[$index] // 0;
      return $args{wall_values}[$index] if exists $args{wall_values}[$index];
      return 100;
    },
  );
  my $result = $runner->run_once(mailbox_id => 'box');
  my $row    = $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0];
  $store->disconnect;
  return {result => $result, row => $row, deadlines => \@deadlines, finishes => \@finishes};
}

sub adapter_case {
  my (%args)    = @_;
  my $tick      = 1_000;
  my $validated = 0;
  my @deadlines;
  my $wire         = \&Overnet::Mail::Transport::LoopbackSMTP::_wire_error;
  my $adapter_mock = mock 'Overnet::Mail::Transport::LoopbackSMTP' => (
    override => [
      clock_gettime => set_prototype(q{;$}, sub { return $tick; }),
      _wire_error   => sub {
        ++$validated;
        $tick += $args{validation_delay} // 0;
        return $wire->(@_);
      },
    ]
  );
  my $attempt_mock = mock 'Overnet::Mail::Transport::Attempt' => (
    override => [
      run => sub { push @deadlines, $_[0]; return smtp_confirmed(); },
    ]
  );
  my %options = exists $args{deadline} ? (deadline => $args{deadline}) : ();
  my $result  = transport()->deliver(claim(), %options);
  return {result => $result, deadlines => \@deadlines, validated => $validated};
}

sub smtp_confirmed {
  return {outcome => 'confirmed', stage => 'final', smtp_code => 250};
}

sub recorded {
  return {status => 'recorded', delivery_id => 1, attempt => 1, outcome => 'confirmed', state => 'delivered'};
}

sub refused {
  my ($seen) = @_;
  is $seen->{result},
    {
    status      => 'unrecorded',
    delivery_id => 1,
    attempt     => 1,
    outcome     => undef,
    error       => 'lease_unavailable'
    },
    'insufficient or unusable lease fails closed';
  is $seen->{deadlines},  [],       'no SMTP handoff was attempted';
  is $seen->{finishes},   [],       'an unattempted handoff is never completed';
  is $seen->{row}{state}, 'leased', 'the real SQLite lease remains available for normal expiry recovery';
  return;
}

sub completion_refused {
  my ($seen) = @_;
  is $seen->{result},
    {
    status      => 'unrecorded',
    delivery_id => 1,
    attempt     => 1,
    outcome     => 'confirmed',
    error       => 'completion_failed'
    },
    'remote acceptance does not invent durable completion';
  is scalar @{$seen->{deadlines}}, 1,        'SMTP was attempted exactly once';
  is $seen->{finishes},            [],       'expired or unusable completion time is rejected before invoking Store';
  is $seen->{row}{state},          'leased', 'failed completion leaves the original real lease untouched';
  return;
}
