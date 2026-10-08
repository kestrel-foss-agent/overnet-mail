use strictures 2;

use Errno     qw(EINTR EIO EAGAIN ECHILD);
use POSIX     qw(SA_NOCLDWAIT);
use Sub::Util qw(set_prototype);
use Test2::V0;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

# Compile this file's production helper against pass-through syscall wrappers.
# Flags replace only one selected operation, so failure cleanup is still real.
our ($fork_result, $pipe_failure, $read_error, $write_error, $wait_error, $close_after, $last_child);

our (%read_calls, %wait_calls);

BEGIN {
  *CORE::GLOBAL::fork = sub () {
    if (defined $fork_result) { $! = EAGAIN; return $fork_result eq 'fail' ? undef : 0; }
    my $pid = CORE::fork();
    $last_child = $pid if defined $pid && $pid > 0;
    return $pid;
  };
  *CORE::GLOBAL::pipe = sub (**) {
    return 0 if $pipe_failure;
    return CORE::pipe($_[0], $_[1]);
  };
  *CORE::GLOBAL::sysread = set_prototype(
    prototype('CORE::sysread'),
    sub {
      die 'fixture read retry budget exceeded' if ++$read_calls{$_[0]} > 100;
      if ($read_error) { $! = $read_error; $read_error = 0; return; }
      return CORE::sysread($_[0], ${$_[1]}, $_[2]);
    }
  );
  *CORE::GLOBAL::syswrite = set_prototype(
    prototype('CORE::syswrite'),
    sub {
      if ($write_error) { my $value = $write_error; $write_error = 0; $! = EIO; return $value eq 'short' ? 1 : undef; }
      return @_ == 2 ? CORE::syswrite($_[0], $_[1]) : CORE::syswrite($_[0], $_[1], $_[2]);
    }
  );
  *CORE::GLOBAL::waitpid = sub ($$) {
    die 'fixture wait retry budget exceeded' if ++$wait_calls{$_[0]} > 50;
    if ($wait_error) { $! = $wait_error; $wait_error = 0; return -1; }
    return CORE::waitpid($_[0], $_[1]);
  };
  *CORE::GLOBAL::close = sub (*) {
    my $closed = CORE::close($_[0]);
    return 0 if defined $close_after && --$close_after == 0;
    return $closed;
  };
}
use Overnet::Mail::Transport::Attempt;

local $SIG{ALRM} = sub { die 'syscall suite deadline'; };
alarm 5;
my $module = 'Overnet::Mail::Transport::Attempt';

sub attempt {
  return Overnet::Mail::Transport::Attempt::run(clock_gettime(CLOCK_MONOTONIC) + 1, sub { return; });
}

{
  my $sig = mock 'POSIX' => (override => [sigaction => sub { return; }]);
  like dies { attempt() }, qr/supervision unavailable/, 'failed signal inspection cannot start work';
}
{
  my $sig = mock 'POSIX::SigAction' => (override => [flags => sub { return SA_NOCLDWAIT; }]);
  like dies { attempt() }, qr/default SIGCHLD handling/, 'kernel auto-reaping mode is rejected';
}
{
  local $pipe_failure = 1;
  like dies { attempt() }, qr/supervision unavailable/, 'pipe failure prevents forking';
}
for my $close (undef, 1, 2) {
  local $fork_result = 'fail';
  local $close_after = $close;
  like dies { attempt() }, qr/supervision unavailable/, 'fork failure closes both owned pipe ends';
}
for my $throws (0, 1) {
  local $fork_result = 'child';
  my $child = mock $module => (override => [_child => sub { die 'startup failure' if $throws; return; }]);
  my $exit  = mock 'POSIX' => (override => [_exit  => sub { die "immediate exit $_[0]"; }]);
  like dies { attempt() }, $throws ? qr/immediate exit 125/ : qr/immediate exit 126/,
    'outer child guard cannot return or unwind into inherited caller objects';
}
for my $close (1, 2) {
  local $close_after = $close;
  like dies { attempt() }, qr/supervision interrupted|pipe cleanup failed/,
    'parent close failure still stops child and cannot invent custody';
}
for my $where (qw(collect drain)) {
  my $calls = 0;
  my $read  = mock $module => (
    override => [
      _read => sub {
        ++$calls;
        die 'read failed' if $where eq 'collect' || $calls > 1;
        return;
      }
    ]
  );
  like dies { attempt() }, qr/read failed/, 'collection and drain errors cannot imply no body was sent';
}
{
  my $read = mock $module => (override => [_read => sub { return 'x' x 1_025; }]);
  is attempt(), {outcome => 'uncertain', stage => 'connect', smtp_code => undef},
    'oversize evidence is bounded and uncertain';
}
{
  my $collect = mock $module => (override => [_collect => sub { return q{}; }]);
  my $calls   = 0;
  my $read    = mock $module => (override => [_read => sub { return ++$calls == 1 ? "stage body -\n" : undef; }]);
  is attempt(), {outcome => 'uncertain', stage => 'body', smtp_code => undef},
    'post-reap drain retains buffered body-start evidence';
}
{
  pipe my $reader, my $writer or die 'test pipe failed';
  print {$writer} "body\n";
  close $writer or die 'test close failed';
  local $read_error = EINTR;
  is Overnet::Mail::Transport::Attempt::_read($reader), "body\n",
    'interrupted read retries without losing queued bytes';
  $read_error = EIO;
  like dies { Overnet::Mail::Transport::Attempt::_read($reader) }, qr/evidence unavailable/,
    'non-interrupted read errors fail closed';
  close $reader or die 'test close failed';
}
for my $error (qw(fail short)) {
  pipe my $reader, my $writer or die 'test pipe failed';
  local $write_error = $error;
  like dies { Overnet::Mail::Transport::Attempt::_emit($writer, {stage => 'body'}) }, qr/evidence unavailable/,
    'failed or partial progress write cannot authorize body transmission';
  close $reader or die 'test close failed';
  close $writer or die 'test close failed';
}
{
  my $pid = fork;
  die 'test fork failed' if !defined $pid;
  if (!$pid) { POSIX::_exit(0); }
  local $wait_error = EINTR;
  is Overnet::Mail::Transport::Attempt::_wait($pid, 0), $pid, 'wait retries EINTR and reaps its child';
  $wait_error = ECHILD;
  Overnet::Mail::Transport::Attempt::_stop(999_999_999);
  pass 'already reaped PID is never signalled again';
}

{
  pipe my $reader, my $writer or die 'test pipe failed';
  print {$writer} "queued evidence\n";
  close $writer or die 'test close failed';
  is Overnet::Mail::Transport::Attempt::_collect($reader, clock_gettime(CLOCK_MONOTONIC) - 1), q{},
    'an absolute expired deadline is not restarted at collection';
  my @chunks = ("stage body -\n", "confirmed final 250\n", undef);
  my $read   = mock $module => (override => [_read => sub { return shift @chunks; }]);
  is Overnet::Mail::Transport::Attempt::_collect($reader, clock_gettime(CLOCK_MONOTONIC) + 1),
    "stage body -\nconfirmed final 250\n", 'collection continues across short pipe reads until complete evidence';
  close $reader or die 'test close failed';
}
{
  my $signals = mock 'POSIX' => (override => [sigprocmask => sub { return; }]);
  like dies { Overnet::Mail::Transport::Attempt::_block() }, qr/signal guard unavailable/,
    'failed guard installation is explicit';
}
for my $persistent (0, 1) {
  my $calls = 0;
  my $signals =
    mock 'POSIX' => (override => [sigprocmask => sub { return ++$calls == 1 || $persistent ? undef : '0 but true'; }]);
  my $error = dies { Overnet::Mail::Transport::Attempt::_restore(POSIX::SigSet->new); };
  if ($persistent) {
    like $error, qr/signal restoration failed/, 'unrestorable OS mask errors are explicit';
  } else {
    is $error, undef, 'one transient restoration syscall failure is retried';
  }
  is $calls, 2, 'signal restoration retries are bounded';
}
for my $where (qw(before_guard reap after_restore repeated_guard)) {
  my $blocks   = 0;
  my $stops    = 0;
  my $restores = 0;
  my $block    = \&Overnet::Mail::Transport::Attempt::_block;
  my $stop     = \&Overnet::Mail::Transport::Attempt::_stop;
  my $restore  = \&Overnet::Mail::Transport::Attempt::_restore;
  my $guard    = mock $module => (
    override => [
      _block => sub {
        ++$blocks;
        die "first cleanup interruption\n"
          if ($where eq 'before_guard' && $blocks == 2) || ($where eq 'repeated_guard' && $blocks >= 2);
        return $block->(@_);
      },
      _stop => sub {
        die "first cleanup interruption\n" if $where eq 'reap' && !$stops++;
        return $stop->(@_);
      },
      _restore => sub {
        $restore->(@_);
        die "first cleanup interruption\n" if $where eq 'after_restore' && ++$restores == 2;
        return;
      },
    ]
  );
  is dies { attempt() }, "first cleanup interruption\n", 'the first cleanup exception is preserved exactly';
  if ($where eq 'repeated_guard') {
    is $blocks, 3, 'repeated interruptions cannot create an unbounded retry loop';
    waitpid $last_child, 0;    # Deliberately unsupported repeated interruption: fixture owns final cleanup.
  } else {
    is waitpid($last_child, POSIX::WNOHANG()), -1, 'finite cleanup interruption leaves no unreaped child';
  }
  is $restores, 2, 'pending restoration exception does not repeat PID cleanup' if $where eq 'after_restore';
}
{
  my $restore = \&Overnet::Mail::Transport::Attempt::_restore;
  my $calls   = 0;
  my $guard   = mock $module => (
    override => [
      _collect => sub { die "original caller interruption\n"; },
      _restore => sub { $restore->(@_); die "later interruption\n" if ++$calls == 2; return; },
    ]
  );
  is dies { attempt() }, "original caller interruption\n",
    'original supervision exception wins over a later cleanup exception';
  is waitpid($last_child, POSIX::WNOHANG()), -1, 'both errors still leave the owned child reaped';
}

{
  pipe my $reader, my $writer or die 'test pipe failed';
  Overnet::Mail::Transport::Attempt::_emit($writer, {stage => 'body'});
  my $state = {reader => $reader, writer => $writer, pid => undef, bytes => q{}, complete => 0};
  is dies { Overnet::Mail::Transport::Attempt::_cleanup($state) }, undef,
    'cleanup closes an inherited open parent writer before draining';
  is $state->{bytes}, "stage body -\n", 'cleanup retains queued evidence before EOF';
  ok $state->{complete}, 'cleanup marks all owned resources settled before restoring signals';
  ok !defined fileno($reader) && !defined fileno($writer), 'both pipe ends are closed';
}

alarm 0;

done_testing;
