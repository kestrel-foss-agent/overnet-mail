use strictures 2;

use Test2::V0;
use Overnet::Mail::Transport::Attempt;

# Run the same protocol contract in-process as well as through the real isolated
# process (local-smtp.t). This directly observes libnet/adapter branches without
# changing production _exit semantics or running inherited child destructors.
my $supervisor = mock 'Overnet::Mail::Transport::Attempt' => (
  override => [
    run => sub {
      my ($deadline, $work) = @_;
      my $result;
      $work->(sub { my ($report) = @_; $result = $report if exists $report->{outcome}; });
      return $result;
    },
  ],
);
do './t/local-smtp.t';
die 'synchronous SMTP contract failed to load' if $@;
