use strictures 2;

use File::Compare qw(compare);
use File::Copy    qw(copy);
use File::Find    qw(find);
use File::Path    qw(make_path);
use File::Temp    qw(tempdir);
use FindBin;
use Test2::V0;

my $style_root = "$FindBin::Bin/..";
my $repo_root  = tempdir(CLEANUP => 1);
my $templates  = templates();

make_path("$repo_root/t");
for my $template (@{$templates}) {
  next unless $template =~ m{\Axt/author/([^/]+)\z}xm;
  copy("$style_root/configs/test-templates/$template", "$repo_root/t/$1")
    or die "Cannot create stale t/$1";
}

system('git', 'init', '-q', $repo_root) == 0
  or die "Cannot initialize temporary git repo";

system("$style_root/tools/sync-configs", $repo_root) == 0
  or die "sync-configs failed";

my @synced_files = (['configs/perlcriticrc-overnet', '.perlcriticrc'], ['configs/perltidyrc-overnet', '.perltidyrc'],);

for my $template (@{$templates}) {
  push @synced_files, ["configs/test-templates/$template", $template];
}

for my $file (@synced_files) {
  my ($source, $target) = @{$file};

  ok -f "$style_root/$source", "$source exists";
  ok -f "$repo_root/$target",  "$target installed";

  is compare("$style_root/$source", "$repo_root/$target"), 0, "$target matches source";
}

for my $template (@{$templates}) {
  next unless $template =~ m{\Axt/author/([^/]+)\z}xm;
  ok !-e "$repo_root/t/$1", "stale t/$1 author test removed";
}

done_testing();

sub templates {
  my @templates;
  find(
    {
      wanted => sub {
        return unless -f $File::Find::name;
        return unless $File::Find::name =~ /[.]t\z/xm;
        my $relative = $File::Find::name;
        $relative =~ s{\A\Q$style_root\E/configs/test-templates/}{}xm;
        push @templates, $relative;
      },
      no_chdir => 1,
    },
    "$style_root/configs/test-templates",
  );
  return [sort @templates];
}
