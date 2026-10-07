use strictures 2;

use FindBin;
use Test2::V0;

my $template = "$FindBin::Bin/../configs/test-templates/xt/author/perlcritic.t";

open my $handle, '<', $template
  or die "Cannot open $template: $!";

my $content = do { local $/; <$handle> };

like $content, qr/\Q-profile\E\s*=>\s*['"]\Q.perlcriticrc\E['"]/xm, 'template uses the synced profile';
like $content, qr/\Q-severity\E\s*=>\s*1\b/xm,                      'template uses brutal severity';
like $content, qr/\Q-only\E\s*=>\s*1\b/xm,                          'template only runs profile policies';

done_testing();
