use strictures 2;

use CPAN::Meta;
use Test2::V0;

# Use a temporary output file: tests must also run without a generated Makefile.
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Path qw(make_path);
use Cwd        qw(getcwd);

my $cwd = getcwd();
my $dir = tempdir(CLEANUP => 1);
make_path("$dir/lib/Overnet");
for my $file (qw(Makefile.PL lib/Overnet/Mail.pm)) {
  copy($file, "$dir/$file") or die "copy $file: $!";
}
chdir $dir or die "chdir $dir: $!";
is system($^X, 'Makefile.PL'), 0, 'MakeMaker configures from distribution metadata';
my $meta = CPAN::Meta->load_file('MYMETA.json');
is $meta->name,      'Overnet-Mail', 'distribution name';
is $meta->version,   '0.001',        'version is loaded from the source module';
is [$meta->license], ['gpl_3'],      'GPLv3 distribution metadata';
my $prereqs = $meta->effective_prereqs;
is $prereqs->requirements_for('runtime', 'requires')->requirements_for_module('strictures'), '2', 'strictures declared';
is $prereqs->requirements_for('test', 'requires')->requirements_for_module('Test2::V0'), '0',
  'Test2::V0 explicitly declared';
is $prereqs->requirements_for('runtime', 'requires')->requirements_for_module('perl'), '5.040', 'Perl 5.40 minimum';

for my $module (qw(DBI DBD::SQLite JSON Net::SMTP)) {
  ok defined $prereqs->requirements_for('runtime', 'requires')->requirements_for_module($module),
    "$module runtime dependency declared";
}
chdir $cwd or die "chdir $cwd: $!";

done_testing;
