use strictures 2;

use Test2::V0;
use Sub::Util   qw(set_prototype);
use POSIX       qw(SIGCHLD SA_NOCLDWAIT);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Overnet::Mail::Transport::Attempt;

local $SIG{ALRM} = sub { die 'unit suite deadline'; };
alarm 5;
my $prefix = 'Overnet::Mail::Transport::Attempt';
for my $case (
  [q{},                                          'transient', 'connect',         undef],
  ["stage hello -\n",                            'transient', 'hello',           undef],
  ["stage data -\nstage body -\n",               'uncertain', 'body',            undef],
  ["stage final -\n",                            'uncertain', 'final',           undef],
  ["stage final -\nconfirmed final 250\n",       'confirmed', 'final',           250],
  ["permanent peer_size_limit -\n",              'permanent', 'peer_size_limit', undef],
  ["transient recipient 450\n",                  'transient', 'recipient',       450],
  ["confirmed final 250",                        'uncertain', 'connect',         undef],
  ["confirmed final 250\nconfirmed final 250\n", 'uncertain', 'connect',         undef],
  ["confirmed hello 250\n",                      'uncertain', 'connect',         undef],
  ["confirmed final 251\n",                      'uncertain', 'connect',         undef],
  ["private\n",                                  'uncertain', 'connect',         undef],
  [('x' x 1_025) . "\n",                         'uncertain', 'connect',         undef],
) {
  my ($bytes, $outcome, $stage, $code) = @{$case};
  is Overnet::Mail::Transport::Attempt::_evidence($bytes),
    {outcome => $outcome, stage => $stage, smtp_code => $code}, 'bounded evidence classification';
}

{
  pipe my $reader, my $writer or die 'unit pipe failed';
  Overnet::Mail::Transport::Attempt::_emit($writer, {stage   => 'body'});
  Overnet::Mail::Transport::Attempt::_emit($writer, {outcome => 'confirmed', stage => 'final', smtp_code => 250});
  close $writer or die 'unit close failed';
  is Overnet::Mail::Transport::Attempt::_read($reader), "stage body -\nconfirmed final 250\n",
    'small fixed records cross pipe unchanged';
  is Overnet::Mail::Transport::Attempt::_read($reader), undef, 'EOF is distinct from a read failure';
  close $reader or die 'unit close failed';
  like dies { Overnet::Mail::Transport::Attempt::_emit($writer, {stage => 'x' x 129}) }, qr/invalid delivery evidence/,
    'oversize record is rejected before a write';
  like dies { Overnet::Mail::Transport::Attempt::_read($reader) }, qr/closed filehandle|evidence unavailable/,
    'read errors throw rather than masquerading as no body evidence';
}

# Exercise child control flow synchronously with ALL process/signal effects
# replaced. Actual alarm, _exit and inherited resource behavior has a separate
# real-process suite. No production coverage hooks or altered child exit path.
for my $case (qw(success exception expired signal_failure timer_failure reader_failure emit_failure)) {
  pipe my $reader, my $writer or die 'unit pipe failed';
  open my $keep_reader, '<&', $reader or die 'unit duplicate failed';
  if ($case eq 'reader_failure') { close $reader or die 'unit close failed'; }
  if ($case eq 'emit_failure')   { close $writer or die 'unit close failed'; }
  my @exits;
  my $posix = mock 'POSIX' => (
    override => [
      sigprocmask => sub { return $case eq 'signal_failure' ? undef : '0 but true'; },
      _exit       => sub { push @exits, $_[0]; die 'test child exit'; },
    ],
  );
  my $timer = mock $prefix =>
    (override => [alarm => set_prototype(q{$;$}, sub { return $case eq 'timer_failure' ? undef : 0; })]);
  my $ran      = 0;
  my $warnings = warnings {
    like dies {
      Overnet::Mail::Transport::Attempt::_child(
        $reader, $writer,
        clock_gettime(CLOCK_MONOTONIC) + ($case eq 'expired' ? -1 : 10),
        sub {
          my ($report) = @_;
          ++$ran;
          die 'private callback failure' if $case eq 'exception';
          $report->({outcome => 'confirmed', stage => 'final', smtp_code => 250});
          return;
        }
      );
    }, qr/test child exit/, 'every child path terminates through immediate exit';
  };
  is $exits[-1], $case eq 'success' ? 0 : 125, 'only successful child work has zero status';
  is $ran, ($case eq 'success' || $case eq 'exception' || $case eq 'emit_failure') ? 1 : 0,
    'timer, signal and preflight failures prevent work';
  if ($case eq 'expired') { is $exits[0], 124, 'expired child never arms a fresh budget'; }
  close $keep_reader or die 'unit close failed';
  close $writer      or die 'unit close failed' if $case ne 'emit_failure';
}

{
  pipe my $reader, my $writer or die 'unit pipe failed';
  Overnet::Mail::Transport::Attempt::_emit($writer, {outcome => q{}, stage => 'body', smtp_code => 0});
  close $writer or die 'unit close failed';
  my $bytes = Overnet::Mail::Transport::Attempt::_read($reader);
  is $bytes, " body 0\n", 'defined invalid fields are never normalized into a valid stage record';
  is Overnet::Mail::Transport::Attempt::_evidence($bytes)->{outcome}, 'uncertain',
    'invalid explicit fields fail closed at the evidence boundary';
  close $reader or die 'unit close failed';
}
alarm 0;

done_testing;
