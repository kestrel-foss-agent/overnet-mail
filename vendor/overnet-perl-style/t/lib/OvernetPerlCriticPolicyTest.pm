package OvernetPerlCriticPolicyTest;

use strictures 2;

use Exporter   qw(import);
use File::Temp qw(tempdir);
use FindBin;
use Perl::Critic;

our @EXPORT_OK = qw(has_policy);

my $profile = "$FindBin::Bin/../configs/perlcriticrc-overnet";
my $tmpdir  = tempdir(CLEANUP => 1);

sub policy_names_for_source {
  my ($source, $name) = @_;
  my $path = "$tmpdir/" . ($name || 'sample.pl');

  open my $handle, '>', $path
    or die "Cannot write $path: $!";
  print {$handle} $source
    or die "Cannot write source to $path: $!";
  close $handle
    or die "Cannot close $path: $!";

  my $critic = Perl::Critic->new(-profile => $profile);
  return map { $_->policy } $critic->critique($path);
}

sub has_policy {
  my ($source, $policy, $name) = @_;
  my %policies = map { $_ => 1 } policy_names_for_source($source, $name);
  return $policies{$policy} ? 1 : 0;
}

1;
