use strictures 2;

use Digest::SHA   qw(sha1_hex);
use File::Compare qw(compare);
use File::Find    qw(find);
use JSON::PP      ();
use Test2::V0;

my $manifest = JSON::PP::decode_json(slurp('vendor/overnet-perl-style.json'));
is $manifest->{commit},          '63c450f5d36582e260e73e931271a9b02e0c9197', 'upstream revision is immutable';
is scalar @{$manifest->{files}}, 42, 'complete pinned style package is retained';
my @expected_paths = sort map { $_->{path} } @{$manifest->{files}};
my %unique         = map      { $_ => 1 } @expected_paths;
is scalar(keys %unique), scalar(@expected_paths), 'upstream manifest paths are unique';
my @actual_paths;
my $vendor_root = 'vendor/overnet-perl-style';
find(
  {
    no_chdir => 1,
    wanted   => sub {
      return if !-f $_;
      my $path = $File::Find::name;
      $path =~ s{\A\Q$vendor_root\E/}{};

      # Only local MakeMaker/coverage products are exempt from the source audit.
      return if $path =~ m{\A(?:blib|_build|cover_db)/};
      return if $path =~ m{\A(?:Makefile|MYMETA[.]json|MYMETA[.]yml|pm_to_blib|nytprof[.]out)\z};
      push @actual_paths, $path;
    },
  },
  $vendor_root,
);
is [sort @actual_paths], \@expected_paths, 'vendored source inventory has no unpinned additions';
for my $file (@{$manifest->{files}}) {
  my $path  = "vendor/overnet-perl-style/$file->{path}";
  my $bytes = slurp($path);
  is sha1_hex('blob ' . length($bytes) . "\0" . $bytes), $file->{sha}, "$path matches original Git blob";
  my $executable = ((stat $path)[2] & 0111) ? 1 : 0;
  is $executable, $file->{mode} eq '100755' ? 1 : 0, "$path retains executable mode";
}

my @copies = (
  ['configs/perlcriticrc-overnet', '.perlcriticrc'],
  ['configs/perltidyrc-overnet',   '.perltidyrc'],
  map { ["configs/test-templates/xt/author/$_.t", "xt/author/$_.t"] }
    qw(devel-cover mutation perlcritic pod-coverage pod-syntax),
);
for my $copy (@copies) {
  is compare("vendor/overnet-perl-style/$copy->[0]", $copy->[1]), 0, "$copy->[1] is synced verbatim";
}

my @nested;
find(
  {
    no_chdir => 1,
    wanted   => sub {
      push @nested, $File::Find::name if -f $_ && m{\At/.+/[^/]+[.]t\z};
    }
  },
  't'
);
is \@nested, [], 'all install tests are visible to upstream t/*.t coverage collection';

done_testing;

sub slurp {
  my ($path) = @_;
  open my $handle, '<:raw', $path or die "$path: $!";
  local $/;
  my $bytes = <$handle>;
  close $handle or die "$path: $!";
  return $bytes;
}
