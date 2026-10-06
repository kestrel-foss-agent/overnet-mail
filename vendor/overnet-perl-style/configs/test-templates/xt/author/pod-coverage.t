use strictures 2;

use Test2::V0;
use Test::Pod::Coverage;

all_pod_coverage_ok({also_private => [qr/\ABUILDARGS\z/]});
