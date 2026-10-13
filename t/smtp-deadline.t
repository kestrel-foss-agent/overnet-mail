use strictures 2;

use Config;
use DBI;
use File::Temp qw(tempdir);
use IO::Select;
use IO::Socket::INET;
use POSIX        ();
use Scalar::Util qw(refaddr);
use Test2::V0;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
use Overnet::Mail::RawMessage;
use Overnet::Mail::Transport::LoopbackSMTP;

plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};

my $dir      = tempdir(CLEANUP => 1);
my $sequence = 0;
my $claim    = {
  message   => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: deadline\r\n\r\nprivate body\r\n"),
  sender    => q{},
  recipient => 'blind@example.test',
};
our ($fixture, $fixture_code);
our $owner_pid   = $$;
our $exit_marker = "$dir/child-exit";
my $guard = bless [$owner_pid, "$dir/child-destroy"], 'SMTPDeadlineGuard';

END {
  append_file($exit_marker, "END\n") if defined $exit_marker && $$ != $owner_pid;
}

subtest 'whole-attempt configuration is bounded and additive' => sub {
  is +Overnet::Mail::Transport::LoopbackSMTP->new(port => 2_525)->attempt_seconds, 10,
    'whole-attempt limit defaults to ten seconds';
  is +Overnet::Mail::Transport::LoopbackSMTP->new({port => 2_525, attempt_seconds => 30})->attempt_seconds, 30,
    'hashref constructor accepts the upper bound';
  for my $bad (undef, [], q{}, 0, -1, '01', '1.5', 'private-value', 31, 100_000) {
    my $error = dies { Overnet::Mail::Transport::LoopbackSMTP->new(port => 2_525, attempt_seconds => $bad) };
    like $error,   qr/bounded integer/, 'invalid whole-attempt limits fail closed';
    unlike $error, qr/private-value/,   'configuration diagnostics do not expose values';
  }
};

subtest 'caller SIGCHLD ownership is never replaced' => sub {
  for my $handler ('IGNORE', sub { return; }) {
    local $SIG{CHLD} = $handler;
    my $path = next_path();
    local *Overnet::Mail::Transport::SMTPClient::new = sub { append_file($path, "connected\n"); return; };
    like dies { transport()->deliver($claim) }, qr/delivery requires default SIGCHLD handling/,
      'incompatible child handling is rejected before forking or connecting';
    is $SIG{CHLD}, $handler, 'the caller child handler is preserved';
    ok !-e $path, 'no SMTP constructor was reached';
  }
  for my $handler (undef, 'DEFAULT') {
    local $SIG{CHLD} = $handler;
    my ($outcome) = fake_attempt();
    is $outcome,   result('confirmed', 'final', 250), 'default child handling remains supported';
    is $SIG{CHLD}, $handler,                          'default disposition remains unchanged';
  }
};

subtest 'preflight exhaustion leaves no fresh network allowance' => sub {
  my $ticks = 0;
  my $path  = next_path();
  local *Overnet::Mail::Transport::LoopbackSMTP::clock_gettime = sub { return $ticks++ ? 102 : 100; };
  local *Overnet::Mail::Transport::SMTPClient::new             = sub { append_file($path, "connected\n"); return; };
  is transport()->deliver($claim), result('transient', 'connect'),
    'time already spent in preflight consumes the same attempt budget';
  ok !-e $path, 'an exhausted attempt never opens the SMTP connection';
};

for my $stage (qw(connect hello mail recipient data body final)) {
  subtest "hard child interruption at $stage" => sub {
    my ($outcome, $elapsed, $pid) = fake_attempt(stage => $stage, mode => 'exit');
    is $outcome, result($stage eq 'body' || $stage eq 'final' ? 'uncertain' : 'transient', $stage),
      'the last reported stage classifies abrupt process loss without fabricated peer evidence';
    ok $elapsed < 3, 'an already exited child does not consume the whole timeout';
    child_is_gone($pid);
  };
}

for my $stage (qw(connect data body final)) {
  subtest "unresponsive child is bounded at $stage" => sub {
    my ($outcome, $elapsed, $pid) = fake_attempt(stage => $stage, mode => 'stall');
    is $outcome, result($stage eq 'body' || $stage eq 'final' ? 'uncertain' : 'transient', $stage),
      'deadline classification respects whether body transmission may have begun';
    bounded_elapsed($elapsed);
    child_is_gone($pid);
  };
}

subtest 'completed peer evidence survives blocked socket cleanup' => sub {
  for my $code (250, 450, 550) {
    my ($outcome, $elapsed, $pid) = fake_attempt(stage => 'close', mode => 'stall', final_code => $code);
    my $expected = $code == 250 ? 'confirmed' : $code < 500 ? 'transient' : 'permanent';
    is $outcome, result($expected, 'final', $code), 'a complete final reply is retained before cleanup starts';
    bounded_elapsed($elapsed);
    child_is_gone($pid);
  }
};

subtest 'a pending caller alarm and its handler are preserved' => sub {
  my $fired   = 0;
  my $handler = sub { ++$fired; return; };
  local $SIG{ALRM} = $handler;
  Time::HiRes::alarm(4);
  my ($outcome, $elapsed, $pid) = fake_attempt(stage => 'hello', mode => 'stall');
  my $remaining = Time::HiRes::alarm(0);
  is $outcome, result('transient', 'hello'), 'the SMTP attempt reaches its own deadline';
  bounded_elapsed($elapsed);
  is refaddr($SIG{ALRM}), refaddr($handler), 'the caller alarm handler is unchanged';
  is $fired,              0,                 'the later caller alarm was not repurposed for the delivery';
  ok $remaining > 1 && $remaining < 3.5, 'the pending alarm kept its original deadline';
  child_is_gone($pid);
};

subtest 'a caller alarm can fire while supervision continues' => sub {
  my $fired = 0;
  local $SIG{ALRM} = sub { ++$fired; return; };
  Time::HiRes::alarm(0.2);
  my ($outcome, $elapsed, $pid) = fake_attempt(stage => 'hello', mode => 'stall');
  Time::HiRes::alarm(0);
  is $fired,   1,                            'the caller receives its own alarm during the attempt';
  is $outcome, result('transient', 'hello'), 'interrupted supervisor waits still enforce the attempt deadline';
  bounded_elapsed($elapsed);
  child_is_gone($pid);
};

subtest 'throwing caller alarms preserve exceptions and leave no unreaped child' => sub {
  for my $preblocked (0, 1) {
    for my $where (qw(collect reap startup)) {
      my ($pid, $waits, $restores, $stops) = (undef, 0, 0, 0);
      my (@reaped, @late_waits);
      my $wait    = \&Overnet::Mail::Transport::Attempt::_wait;
      my $restore = \&Overnet::Mail::Transport::Attempt::_restore;
      my $stop    = \&Overnet::Mail::Transport::Attempt::_stop;
      local *Overnet::Mail::Transport::Attempt::_wait = sub {
        $pid = $_[0];
        push @late_waits, $pid if grep { $_ == $pid } @reaped;
        sleep 0.3 if $where eq 'reap' && !$waits++;
        my $result = $wait->(@_);
        push @reaped, $result if $result == $pid;
        return $result;
      };
      local *Overnet::Mail::Transport::Attempt::_restore = sub {
        if ($where eq 'startup' && !$restores++) { sleep 0.3; }
        return $restore->(@_);
      };
      local *Overnet::Mail::Transport::Attempt::_stop = sub {
        ++$stops;
        return $stop->(@_);
      };
      my $exception = bless {}, 'SMTPDeadlineException';
      my $calls     = 0;
      my $handler   = sub { ++$calls; die $exception; };
      local $SIG{ALRM} = $handler;

      my $original = POSIX::SigSet->new;
      my $extra    = POSIX::SigSet->new($preblocked ? (POSIX::SIGUSR1()) : ());
      POSIX::sigprocmask(POSIX::SIG_BLOCK(), $extra, $original) or die 'fixture signal block failed';
      my $expected = POSIX::SigSet->new;
      POSIX::sigprocmask(POSIX::SIG_BLOCK(), POSIX::SigSet->new, $expected) or die 'fixture signal query failed';
      Time::HiRes::alarm(0.1);
      my $caught = dies { fake_attempt($where eq 'collect' ? (stage => 'hello', mode => 'stall') : ()); };
      Time::HiRes::alarm(0);
      my $observed = POSIX::SigSet->new;
      POSIX::sigprocmask(POSIX::SIG_SETMASK(), $original, $observed) or die 'fixture signal restore failed';

      my $label = "$where with " . ($preblocked ? 'a preexisting blocked signal' : 'the original signal mask');
      is refaddr($caught),    refaddr($exception), "$label preserves the original caller exception object";
      is $calls,              1,                   'the caller handler ran exactly once';
      is refaddr($SIG{ALRM}), refaddr($handler),   'the caller handler was not replaced';
      is \@reaped,            [$pid],              'the owned child was successfully reaped exactly once';
      is \@late_waits,        [], 'a pending callback never causes another wait on an already reaped PID';
      is $stops,              1,  'pending callback restoration never reenters the child stop or kill path';
      child_is_gone($pid);
      is signal_members($observed), signal_members($expected), 'cleanup restores the complete caller signal mask';
      is $observed->ismember(POSIX::SIGUSR1()), 1, 'the preexisting blocked signal survives the exception'
        if $preblocked;
    }
  }
};

subtest 'the caller blocked signal mask is unchanged' => sub {
  my $blocked  = POSIX::SigSet->new(POSIX::SIGALRM());
  my $original = POSIX::SigSet->new;
  POSIX::sigprocmask(POSIX::SIG_BLOCK(), $blocked, $original) or die 'fixture signal block failed';
  my ($outcome, $elapsed, $pid);
  my $ok      = eval { ($outcome, $elapsed, $pid) = fake_attempt(stage => 'hello', mode => 'stall'); 1 };
  my $current = POSIX::SigSet->new;
  POSIX::sigprocmask(POSIX::SIG_SETMASK(), $original, $current) or die 'fixture signal restore failed';
  die 'blocked-mask delivery failed' if !$ok;
  is $current->ismember(POSIX::SIGALRM()), 1, 'the parent SIGALRM mask was not unblocked by the child';
  is $outcome, result('transient', 'hello'),  'supervision succeeds while caller alarm delivery is blocked';
  bounded_elapsed($elapsed);
  child_is_gone($pid);
};

subtest 'an orphan has its own timer even when the caller blocked SIGALRM' => sub {
  plan skip_all => 'Linux child-subreaper support is required for a contained parent-death fixture' if $^O ne 'linux';
  my $syscall_loaded = eval { require 'syscall.ph'; 1 };
  die 'Linux syscall definitions are required for parent-death verification' if !$syscall_loaded || !defined &SYS_prctl;
  my $path     = next_path();
  my $guardian = fork;
  die 'guardian fork failed' if !defined $guardian;
  if (!$guardian) {

    # Reparent the SMTP orphan here rather than abandoning it to PID 1. This
    # setting belongs only to this disposable fixture process, not the caller.
    POSIX::_exit(3) if syscall(&SYS_prctl, 36, 1, 0, 0, 0) != 0;
    my ($supervisor, $smtp);
    my $ok = eval {
      my $blocked = POSIX::SigSet->new(POSIX::SIGALRM());
      POSIX::sigprocmask(POSIX::SIG_BLOCK(), $blocked) or die 'fixture signal block failed';
      local $SIG{ALRM} = sub { append_file("$path.handler", "caller handler\n"); };
      $supervisor = fork;
      die 'supervisor fork failed' if !defined $supervisor;
      if (!$supervisor) {
        local *Overnet::Mail::Transport::SMTPClient::new = sub {
          append_file("$path.smtp", "$$\n");
          sleep 5;
          return;
        };
        eval { transport()->deliver($claim); 1 };
        POSIX::_exit(4);
      }
      my $started = clock_gettime(CLOCK_MONOTONIC);
      while (!-s "$path.smtp" && clock_gettime(CLOCK_MONOTONIC) - $started < 3) {
        sleep 0.01;
      }
      $smtp = read_file("$path.smtp");
      chomp $smtp;
      die 'invalid SMTP child identity' if $smtp !~ /\A[1-9][0-9]*\z/;
      kill 'KILL', $supervisor or die 'supervisor termination failed';
      waitpid $supervisor, 0;
      $supervisor = undef;
      my $reaped;

      while (clock_gettime(CLOCK_MONOTONIC) - $started < 3) {
        $reaped = waitpid $smtp, POSIX::WNOHANG();
        last if $reaped;
        sleep 0.01;
      }
      my $status = $?;
      if (defined $reaped && $reaped == -1) {
        $smtp = undef;
        die 'orphan child was not owned by its guardian';
      }
      die 'orphan child did not expire independently' if !$reaped || $reaped != $smtp;
      $smtp = undef;
      append_file("$path.result", "$status\n" . (clock_gettime(CLOCK_MONOTONIC) - $started) . "\n");
      1;
    };
    for my $pid (grep {defined} $supervisor, $smtp) {
      kill 'KILL', $pid;
      waitpid $pid, 0;
    }
    POSIX::_exit($ok ? 0 : 1);
  }
  waitpid $guardian, 0;
  is $?, 0, 'guardian reaped both the lost supervisor and independently expired SMTP child';
  if (-e "$path.result") {
    my ($status, $elapsed) = split /\n/, read_file("$path.result");
    is $status & 127, POSIX::SIGALRM(), 'the child terminates through its own unblocked default SIGALRM';
    bounded_elapsed($elapsed);
  }
  ok !-e "$path.handler", 'the SMTP child never invokes the inherited caller alarm handler';
};

subtest 'child exit cannot run inherited process cleanup or destroy SQLite custody' => sub {
  my $dbh = DBI->connect("dbi:SQLite:dbname=$dir/inherited.sqlite",
    q{}, q{}, {RaiseError => 1, PrintError => 0, AutoCommit => 1});
  $dbh->do('CREATE TABLE parent_custody (value INTEGER NOT NULL)');
  $dbh->begin_work;
  $dbh->do('INSERT INTO parent_custody VALUES (7)');
  for my $options ({}, {stage => 'body', mode => 'exit'}, {stage => 'body', mode => 'stall'}) {
    my ($outcome, undef, $pid) = fake_attempt(%{$options});
    is $outcome->{outcome}, keys %{$options} ? 'uncertain' : 'confirmed', 'delivery returns its protocol outcome';
    child_is_gone($pid);
    ok !$dbh->{AutoCommit}, 'parent transaction remains active';
    is $dbh->selectrow_array('SELECT value FROM parent_custody'), 7, 'parent still owns its uncommitted row';
  }
  ok !-e $exit_marker,         'the SMTP child never ran inherited END blocks';
  ok !-e "$dir/child-destroy", 'the SMTP child never ran inherited object destructors';
  $dbh->rollback;
  is $dbh->selectrow_array('SELECT COUNT(*) FROM parent_custody'), 0, 'only the parent decides transaction custody';
  $dbh->disconnect;
};

subtest 'inherited PostgreSQL connection remains owned by the parent' => sub {
  plan skip_all => 'set OVERNET_TEST_PG_DSN to test inherited PostgreSQL resources' if !$ENV{OVERNET_TEST_PG_DSN};
  require DBD::Pg;
  my $dbh = DBI->connect(
    $ENV{OVERNET_TEST_PG_DSN},
    $ENV{OVERNET_TEST_PG_USER},
    $ENV{OVERNET_TEST_PG_PASSWORD},
    {RaiseError => 1, PrintError => 0, AutoCommit => 1, ShowErrorStatement => 0}
  );
  $dbh->do(q{SET statement_timeout = '5000ms'});
  $dbh->begin_work;
  my $backend = $dbh->selectrow_array('SELECT pg_backend_pid()');
  for my $options ({}, {stage => 'body', mode => 'exit'}, {stage => 'body', mode => 'stall'}) {
    my ($outcome, undef, $pid) = fake_attempt(%{$options});
    is $outcome->{outcome}, keys %{$options} ? 'uncertain' : 'confirmed', 'delivery child returns safely';
    child_is_gone($pid);
    ok !$dbh->{AutoCommit}, 'the parent PostgreSQL transaction remains active';
    is $dbh->selectrow_array('SELECT pg_backend_pid()'), $backend,
      'normal and interrupted child exits leave the same backend connection alive';
  }
  $dbh->rollback;
  $dbh->disconnect;
};

subtest 'slow loopback peers cannot extend the attempt through progress' => sub {
  for my $case (
    ['connect', 'partial'],
    ['hello',   'multiline'],
    ['data',    'stall'],
    ['body',    'stall'],
    ['final',   'stall'],
    ['final',   'partial'],
    ['final',   'multiline'],
    ['final',   'negative_multiline'],
  ) {
    my ($stage, $mode) = @{$case};
    my ($outcome, $elapsed, $events) = peer_attempt($claim, stage => $stage, mode => $mode);
    is $outcome, result($stage eq 'body' || $stage eq 'final' ? 'uncertain' : 'transient', $stage),
      "$stage $mode peer is classified conservatively";
    bounded_elapsed($elapsed);
    like $events, qr/\Q$stage\E\n/,    'the peer reached the intended fault point';
    like $events, qr/body_complete\n/, 'a final-stage timeout may follow complete message receipt' if $stage eq 'final';
  }
};

done_testing;

sub transport {
  my (%options) = @_;
  return Overnet::Mail::Transport::LoopbackSMTP->new(port => 2_525, timeout => 4, attempt_seconds => 1, %options);
}

sub result {
  my ($outcome, $stage, $code) = @_;
  return {outcome => $outcome, stage => $stage, smtp_code => $code};
}

sub next_path {
  return "$dir/fixture-" . ++$sequence;
}

sub signal_members {
  my ($mask)  = @_;
  my %signals = map { $_ => 1 } grep { $_ > 0 } split /\s+/, $Config{sig_num};
  return [grep { $mask->ismember($_) } sort { $a <=> $b } keys %signals];
}

sub append_file {
  my ($path, $text) = @_;
  open my $file, '>>:raw', $path or die 'fixture output open failed';
  print {$file} $text or die 'fixture output failed';
  close $file         or die 'fixture output close failed';
  return;
}

sub read_file {
  my ($path) = @_;
  open my $file, '<:raw', $path or die 'fixture input open failed';
  local $/;
  my $text = <$file>;
  close $file or die 'fixture input close failed';
  return $text // q{};
}

sub fake_attempt {
  my (%options) = @_;
  my $path = next_path();
  local $fixture                                   = {%options, path => $path};
  local $fixture_code                              = 220;
  local *Overnet::Mail::Transport::SMTPClient::new = sub {
    append_file($path, "$$\n");
    fake_step('connect', 220);
    open my $handle, '<', '/dev/null' or die 'fake client open failed';
    return bless $handle, 'SMTPDeadlineClient';
  };
  my $started = clock_gettime(CLOCK_MONOTONIC);
  my $outcome = transport()->deliver($claim);
  my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;
  my $pid     = read_file($path);
  chomp $pid;
  return ($outcome, $elapsed, $pid);
}

sub fake_step {
  my ($stage, $code) = @_;
  if (($fixture->{stage} // q{}) eq $stage) {
    POSIX::_exit(23) if ($fixture->{mode} // q{}) eq 'exit';
    sleep 5          if ($fixture->{mode} // q{}) eq 'stall';
  }
  $fixture_code = $code if defined $code;
  return defined $code && $code >= 400 ? 0 : 1;
}

sub child_is_gone {
  my ($pid) = @_;
  like $pid, qr/\A[1-9][0-9]*\z/, 'the transport ran in an identifiable child';
  isnt 0 + $pid,                      $$, 'the transport did not execute in its caller';
  is waitpid($pid, POSIX::WNOHANG()), -1, 'the SMTP child has already been reaped';
  ok !kill(0, $pid), 'the SMTP child no longer exists';
  return;
}

sub bounded_elapsed {
  my ($elapsed) = @_;
  ok $elapsed >= 0.7, 'fixture remained blocked until approximately the whole-attempt deadline';
  ok $elapsed < 3,    'whole attempt finished well before its four-second per-I/O wait';
  return;
}

sub peer_attempt {
  my ($input, %options) = @_;
  my $listener = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp')
    or die 'fixture listener failed';
  my $port = $listener->sockport;
  my $path = next_path();
  pipe my $cancel_read, my $cancel_write or die 'fixture cancel pipe failed';
  my $pid = fork;
  die 'fixture fork failed' if !defined $pid;
  if (!$pid) {
    close $cancel_write or POSIX::_exit(1);
    local $SIG{PIPE} = 'IGNORE';
    local $SIG{ALRM} = sub { POSIX::_exit(2); };
    Time::HiRes::alarm(6);
    my $ok = eval { serve_peer($listener, $cancel_read, $path, \%options); 1 };
    POSIX::_exit($ok ? 0 : 1);
  }
  close $cancel_read or die 'fixture parent pipe close failed';
  close $listener    or die 'fixture parent listener close failed';
  if ($options{stage} eq 'body') {
    $input = {
      %{$input},
      message => Overnet::Mail::RawMessage->new(
        raw_bytes => "Subject: large\r\n\r\n" . ((('x' x 998) . "\r\n") x 10_000)
      )
    };
  }
  my $started = clock_gettime(CLOCK_MONOTONIC);
  my $outcome = transport(port => $port)->deliver($input);
  my $elapsed = clock_gettime(CLOCK_MONOTONIC) - $started;
  close $cancel_write or die 'fixture cancellation failed';
  waitpid $pid, 0;
  is $?, 0, 'bounded loopback fixture exited cleanly';
  return ($outcome, $elapsed, read_file($path));
}

sub serve_peer {
  my ($listener, $cancel, $path, $options) = @_;
  my @ready = IO::Select->new($listener, $cancel)->can_read(5);
  return if !grep { fileno($_) == fileno($listener) } @ready;
  my $socket = $listener->accept or die 'fixture accept failed';
  close $listener                or die 'fixture listener close failed';
  $socket->autoflush(1);
  binmode $socket, ':raw' or die 'fixture binary mode failed';
  for my $stage (qw(connect hello mail recipient data body final)) {
    if ($stage eq 'final') {
      while (defined(my $line = <$socket>)) {
        last if $line eq ".\r\n";
      }
      append_file($path, "body_complete\n");
    } elsif ($stage ne 'connect' && $stage ne 'body') {
      my $line = <$socket>;
      return if !defined $line;
    }
    if ($stage eq $options->{stage}) {
      append_file($path, "$stage\n");
      if ($options->{mode} eq 'partial') {
        print {$socket} ($stage eq 'connect' ? '220 ' : '250 ') or return;
        while (!IO::Select->new($cancel)->can_read(0.12)) {
          print {$socket} 'x' or last;
        }
      } elsif ($options->{mode} =~ /multiline\z/) {
        my $code = $options->{mode} eq 'negative_multiline' ? 550 : 250;
        while (!IO::Select->new($cancel)->can_read(0.12)) {
          print {$socket} "$code-private continuation\r\n" or last;
        }
      } else {
        IO::Select->new($cancel)->can_read(5);
      }
      return;
    }
    next if $stage eq 'body';
    my $reply = $stage eq 'connect' ? "220 fixture\r\n" : $stage eq 'data' ? "354 send\r\n" : "250 accepted\r\n";
    print {$socket} $reply or return;
  }
  return;
}

{

  package SMTPDeadlineClient;

  sub reply_complete { return 1; }
  sub code           { return $main::fixture_code; }
  sub supports       { return; }
  sub hello          { return main::fake_step('hello',     250); }
  sub mail           { return main::fake_step('mail',      250); }
  sub recipient      { return main::fake_step('recipient', 250); }
  sub data           { return main::fake_step('data',      354); }
  sub datasend       { return main::fake_step('body',      354); }
  sub dataend        { return main::fake_step('final',     $main::fixture->{final_code} // 250); }
  sub close          { main::fake_step('close'); return CORE::close($_[0]); }
}

{

  package SMTPDeadlineGuard;

  sub DESTROY {
    my ($self) = @_;
    main::append_file($self->[1], "DESTROY\n") if $$ != $self->[0];
    return;
  }
}
