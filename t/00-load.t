use strictures 2;

use Test2::V0;
use Overnet::Mail;

is $Overnet::Mail::VERSION, '0.001', 'foundation distribution loads';
ok !Overnet::Mail->can('send'), 'foundation does not advertise unimplemented delivery';

done_testing;
