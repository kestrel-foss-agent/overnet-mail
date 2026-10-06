use strictures 2;

use FindBin;
use Test2::V0;

my $template = "$FindBin::Bin/../configs/test-templates/xt/author/devel-cover.t";

ok -f $template, 'devel-cover template exists' or bail_out('no template to inspect');

open my $handle, '<', $template
  or die "Cannot open $template: $!";

my $content = do { local $/; <$handle> };

like $content, qr/\Quse strictures 2;\E/xm, 'template uses strictures 2';
like $content, qr/\QTest2::V0\E/xm,         'template uses Test2::V0';

like $content, qr/skip_all/xm,                          'template can skip itself';
like $content, qr/\$ENV\{OVERNET_COVERAGE\}/xm,         'coverage collection is opt-in via OVERNET_COVERAGE';
like $content, qr/\Qrequire Devel::Cover\E/xm,          'template skips when Devel::Cover is unavailable';
like $content, qr/\Q-MDevel::Cover\E/xm,                'tests run under Devel::Cover instrumentation';
like $content, qr/\QHARNESS_PERL_SWITCHES\E/xm,         'instrumentation is injected through the harness';
like $content, qr/\Q-blib,0\E/xm,                       'a stale blib/ directory cannot hijack coverage collection';
like $content, qr/\QDevel::Cover::DB\E/xm,              'results are read from the coverage database, not parsed from reports';

like $content, qr/\QFile::Find\E/xm, 'template walks lib/ for modules';
like $content, qr/\Qevery module under lib\E/xm,
  'modules the suite never loads are still pulled into the gate';

like $content, qr/statement\s*=>\s*\$ENV\{OVERNET_COVERAGE_MIN_STATEMENT\}\s*\/\/\s*95/xm,
  'statement minimum defaults to 95 and honors OVERNET_COVERAGE_MIN_STATEMENT';
like $content, qr/branch\s*=>\s*\$ENV\{OVERNET_COVERAGE_MIN_BRANCH\}\s*\/\/\s*85/xm,
  'branch minimum defaults to 85 and honors OVERNET_COVERAGE_MIN_BRANCH';
like $content, qr/subroutine\s*=>\s*\$ENV\{OVERNET_COVERAGE_MIN_SUBROUTINE\}\s*\/\/\s*100/xm,
  'subroutine minimum defaults to 100 and honors OVERNET_COVERAGE_MIN_SUBROUTINE';

like $content, qr{\Qlib/\E}xm, 'coverage is gated per file under lib/';

done_testing();
