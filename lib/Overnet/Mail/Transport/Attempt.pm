package Overnet::Mail::Transport::Attempt;

use strictures 2;

use Carp qw(croak);
use IO::Select;
use POSIX       qw(WNOHANG SIGALRM SIGCHLD SIG_UNBLOCK SIG_BLOCK SIG_SETMASK SA_NOCLDWAIT);
use English     qw(-no_match_vars);
use Errno       qw(EINTR);
use Time::HiRes qw(alarm clock_gettime CLOCK_MONOTONIC);

our $VERSION = '0.001';

# Internal process boundary. The callback can emit only small, fixed evidence.
sub run {
  my ($deadline, $work) = @_;
  my $action = POSIX::SigAction->new;
  POSIX::sigaction(SIGCHLD, undef, $action) or croak 'delivery supervision unavailable';
  croak 'delivery requires default SIGCHLD handling'
    if $action->handler ne 'DEFAULT' || ($action->flags & SA_NOCLDWAIT);
  pipe my $reader, my $writer or croak 'delivery supervision unavailable';
  my $state = {reader => $reader, writer => $writer, pid => undef, bytes => q{}, complete => 0};
  my $ok    = eval {

    # Record child ownership before allowing a caller handler to throw.
    $state->{mask} = _block();
    my $pid = fork;
    croak 'delivery supervision unavailable' if !defined $pid;
    if (!$pid) {
      my $ran = eval { _child($reader, $writer, $deadline, $work); 1 };
      return POSIX::_exit($ran ? 126 : 125);
    }
    $state->{pid} = $pid;
    _restore($state->{mask});
    $state->{mask} = undef;
    close $writer or croak 'delivery pipe cleanup failed';
    $state->{bytes} = _collect($reader, $deadline);
    1;
  };
  my $error         = $EVAL_ERROR;
  my $cleaned       = eval { _cleanup($state); 1 };
  my $cleanup_error = $EVAL_ERROR;
  if (!$cleaned && !$state->{complete}) {

    # One finite interruption before masking can race cleanup. Once reaped,
    # ownership is cleared while blocked: never signal that PID again.
    my $retried = eval { _cleanup($state); 1 };
    if (!$retried) { return _rethrow($ok ? $cleanup_error : $error); }
  }
  return _rethrow($error)         if !$ok;
  return _rethrow($cleanup_error) if !$cleaned;
  return _evidence($state->{bytes});
}

sub _rethrow {
  my ($error) = @_;

  # Preserve a caller's original asynchronous exception object and location.
  return die $error;    ## no critic (ErrorHandling::RequireCarping)
}

sub _block {
  my $signals = POSIX::SigSet->new;
  $signals->fillset;
  my $original = POSIX::SigSet->new;
  POSIX::sigprocmask(SIG_BLOCK, $signals, $original) or croak 'delivery signal guard unavailable';
  return $original;
}

sub _restore {
  my ($mask) = @_;
  my $restored = POSIX::sigprocmask(SIG_SETMASK, $mask);
  if (!$restored) { POSIX::sigprocmask(SIG_SETMASK, $mask) or croak 'delivery signal restoration failed'; }
  return;
}

sub _cleanup {
  my ($state) = @_;
  my $mask = _block();

  # A fork/startup exception may have left the caller's original mask pending.
  if (defined $state->{mask}) { $mask = $state->{mask}; }
  my $ok = eval {
    if (defined $state->{pid}) {
      _stop($state->{pid});
      $state->{pid} = undef;
    }

    # Do not wait for EOF with our own writer still open after a close failure.
    if (defined fileno $state->{writer}) { close $state->{writer} or croak 'delivery pipe cleanup failed'; }
    if (defined fileno $state->{reader}) {
      while (length($state->{bytes}) <= 1_024) {
        my $chunk = _read($state->{reader});
        last if !defined $chunk;
        $state->{bytes} .= $chunk;
      }
    }
    1;
  };
  my $error = $EVAL_ERROR;

  # Close every owned end even when a prior cleanup operation failed.
  for my $handle ($state->{writer}, $state->{reader}) {
    my $closed = eval {
      if (defined fileno $handle) { close $handle or croak 'delivery pipe cleanup failed'; }
      1;
    };
    if (!$closed && $ok) { $error = $EVAL_ERROR; $ok = 0; }
  }
  $state->{complete} = !defined $state->{pid} && !defined fileno($state->{reader}) && !defined fileno($state->{writer});
  my $restored      = eval { _restore($mask); 1 };
  my $restore_error = $EVAL_ERROR;
  return _rethrow($error)         if !$ok;
  return _rethrow($restore_error) if !$restored;
  return;
}

sub _collect {
  my ($reader, $deadline) = @_;
  my $bytes  = q{};
  my $select = IO::Select->new($reader);
  while (1) {
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    last if $remaining <= 0;
    next if !$select->can_read($remaining);
    my $chunk = _read($reader);
    last if !defined $chunk;
    $bytes .= $chunk;
    last if length($bytes) > 1_024;
  }
  return $bytes;
}

sub _read {
  my ($reader) = @_;
  my $count    = sysread $reader, my $chunk, 1_024;
  while (!defined $count && $ERRNO == EINTR) {
    $count = sysread $reader, $chunk, 1_024;
  }
  croak 'delivery evidence unavailable' if !defined $count;
  return $count ? $chunk : undef;
}

sub _stop {
  my ($pid) = @_;
  my $reaped = _wait($pid, WNOHANG);

  # Never signal a PID after a reaper reports that we no longer own it.
  if (!$reaped) {
    kill 'KILL', $pid;
    _wait($pid, 0);
  }
  return;
}

sub _wait {
  my ($pid, $flags) = @_;
  my $reaped = waitpid $pid, $flags;
  while ($reaped == -1 && $ERRNO == EINTR) {
    $reaped = waitpid $pid, $flags;
  }
  return $reaped;
}

sub _child {
  my ($reader, $writer, $deadline, $work) = @_;

  # Inherited callbacks must never unwind through the caller's DBI objects.
  my %handlers = map { $_ => /\A__/smx ? undef : 'DEFAULT' } keys %SIG;
  $handlers{PIPE} = 'IGNORE';
  $handlers{ALRM} = 'DEFAULT';
  local %SIG = %handlers;
  my $ok = eval {
    close $reader or croak 'delivery pipe cleanup failed';
    my $signals = POSIX::SigSet->new(SIGALRM);
    POSIX::sigprocmask(SIG_UNBLOCK, $signals) or croak 'delivery timer unavailable';
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    if ($remaining <= 0) {
      return POSIX::_exit(124);
    }

    # A kernel-default timer also bounds an orphan after parent death, without
    # depending on Perl safe-signal dispatch or an exception surviving eval.
    my $armed = alarm $remaining;
    croak 'delivery timer unavailable' if !defined $armed;
    $work->(sub { _emit($writer, @_) });
    1;
  };

  # Do not run inherited END blocks, DESTROY methods or database disconnects.
  return POSIX::_exit($ok ? 0 : 125);
}

sub _emit {
  my ($writer, $report) = @_;
  my $line = join(q{ }, $report->{outcome} // 'stage', $report->{stage}, $report->{smtp_code} // q{-}) . "\n";
  croak 'invalid delivery evidence' if length($line) > 128;
  my $written = syswrite $writer, $line;
  croak 'delivery evidence unavailable' if !defined $written || $written != length($line);
  return;
}

sub _evidence {
  my ($bytes)   = @_;
  my $stage     = 'connect';
  my $uncertain = 0;
  my $result;
  return {outcome => 'uncertain', stage => $stage, smtp_code => undef}
    if length($bytes) > 1_024 || (length($bytes) && substr($bytes, -1) ne "\n");
  my $stages   = qr/connect|hello|mail|recipient|data|body|final/smx;
  my $outcomes = qr/confirmed|permanent|transient|uncertain/smx;
  for my $line (split /\n/smx, $bytes) {
    return {outcome => 'uncertain', stage => $stage, smtp_code => undef} if $result;
    if ($line =~ /\Astage[ ]($stages)[ ]-\z/smx) {
      $stage = $1;
      if ($stage eq 'body' || $stage eq 'final') { $uncertain = 1; }
    } elsif ($line =~ /\A($outcomes)[ ]([a-z_]+)[ ](-|[245][0-9]{2})\z/smx) {
      my ($outcome, $where, $code) = ($1, $2, $3);
      if ($outcome eq 'confirmed' && ($where ne 'final' || $code ne '250')) {
        return {outcome => 'uncertain', stage => $stage, smtp_code => undef};
      }
      $result = {outcome => $outcome, stage => $where, smtp_code => $code eq q{-} ? undef : 0 + $code};
    } else {
      return {outcome => 'uncertain', stage => $stage, smtp_code => undef};
    }
  }
  return $result if defined $result;
  return {outcome => $uncertain ? 'uncertain' : 'transient', stage => $stage, smtp_code => undef};
}

1;

__END__

=head1 NAME

Overnet::Mail::Transport::Attempt - internal bounded local SMTP process boundary

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Internal helper used by LoopbackSMTP, not a general process runner.

=head1 DESCRIPTION

Supervises one trusted callback using a monotonic parent deadline and an isolated
child-local elapsed timer. Only fixed, bounded stage and outcome evidence crosses
the pipe. The parent preserves final evidence even when cleanup stalls.

=head1 SUBROUTINES/METHODS

=head2 run

Internal callback boundary. Requires default SIGCHLD ownership. The child exits
without inherited destructors; its timer also bounds I/O after supervisor loss.

=head1 DIAGNOSTICS

Process setup errors are value-free. Lost child evidence remains conservative.

=head1 CONFIGURATION AND ENVIRONMENT

Requires Unix fork, pipe, signals and a monotonic clock. No parent alarm or handler is changed. The caller mask is briefly guarded
during ownership acquisition and cleanup, then restored. Caller exceptions
propagate unchanged after finite guarded cleanup, never as report data.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, core IO::Select, POSIX and Time::HiRes.

=head1 INCOMPATIBILITIES

Single-threaded callers must own child reaping; custom or ignored SIGCHLD handlers
are rejected. Not a generic callback sandbox. No inherited object destructors run.

=head1 BUGS AND LIMITATIONS

Operating-system scheduling, process creation and uninterruptible kernel waits
are not hard real-time bounded. Arbitrary repeated throwing signal handlers and
OS failures during mask restoration are not covered by the preservation guarantee. Parent loss can lose evidence of remote custody.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
