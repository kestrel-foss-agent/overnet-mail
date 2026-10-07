use strictures 2;

use Test2::V0;
use Overnet::Mail::Envelope;

my @recipients = ('Visible@example.test', 'Blind@example.test', 'Visible@example.test');
my $envelope   = Overnet::Mail::Envelope->new(sender => 'Sender@example.test', recipients => \@recipients);
is $envelope->sender,            'Sender@example.test', 'sender local-part case preserved';
is $envelope->recipients,        \@recipients,          'recipient order, local case and duplicates preserved';
is $envelope->max_recipients,    1000,                  'default recipient limit';
is $envelope->max_address_bytes, 1024,                  'default address input bound';
$recipients[1] = 'changed@example.test';
is $envelope->recipients->[1], 'Blind@example.test', 'input array cloned';
my $returned = $envelope->recipients;
$returned->[1] = 'another@example.test';
is $envelope->recipients->[1], 'Blind@example.test', 'returned array cloned';
like dies { $envelope->sender('other@example.test') }, qr/read-only/, 'sender read-only';

my $null = Overnet::Mail::Envelope->new({sender => q{}, recipients => ['to@example.test'], max_recipients => 1});
is $null->sender,         q{}, 'empty sender represents SMTP null reverse-path';
is $null->max_recipients, 1,   'hashref constructor and custom limit';
for my $address ('"Quoted Local"@example.test', 'Case.Sensitive@example.test') {
  my $value = Overnet::Mail::Envelope->new(sender => $address, recipients => [$address]);
  is $value->sender, $address, 'CPAN formatter preserves valid quoted or case-sensitive local part';
}
my $cfws = Overnet::Mail::Envelope->new(sender => 'User(comment)@example.test', recipients => ['to@example.test']);
is $cfws->sender, 'User@example.test', 'CPAN addr-spec formatter removes header comments instead of replaying them';
my $short = 'a@b.test';
my $bounded =
  Overnet::Mail::Envelope->new(sender => $short, recipients => [$short], max_address_bytes => length($short));
is $bounded->sender, $short, 'exact address byte bound accepted';

for my $name (qw(max_recipients max_address_bytes)) {
  for my $bad (undef, [], 0, -1, '1.5', q{}) {
    like dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => ['to@example.test'], $name => $bad) },
      qr/\Q$name\E must be a positive integer/, 'invalid configured limit rejected';
  }
}
for my $bad (undef, {}, []) {
  like dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => $bad) },
    qr/nonempty array/, 'invalid recipient collection rejected';
}
like dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => ['a@b.test', 'b@b.test'], max_recipients => 1) },
  qr/count exceeds/, 'recipient count bounded before address parsing';
for my $bad (undef, [], q{}, '<>', 'Person <person@example.test>', 'a@example.test,b@example.test', 'bad',
  'x@@example.test') {
  like dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => [$bad]) },
    qr/(?:scalar string|invalid bare)/, 'invalid recipient address rejected';
}
for my $bad (undef, [], '<>', 'bad') {
  like dies { Overnet::Mail::Envelope->new(sender => $bad, recipients => ['to@example.test']) },
    qr/(?:scalar string|invalid bare)/, 'invalid sender rejected';
}
for my $control ("\0", "\t", "\n", "\r", "\x7f", "\xff", "\x{100}") {
  my $private = 'blind' . $control . '@example.test';
  my $error   = dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => [$private]) };
  like $error,   qr/printable ASCII; SMTPUTF8/, 'controls and SMTPUTF8 addresses explicitly unsupported';
  unlike $error, qr/\Q$private\E/,              'exception omits private recipient';
}
like dies {
  Overnet::Mail::Envelope->new(sender => $short, recipients => [$short], max_address_bytes => length($short) - 1)
}, qr/address exceeds/, 'oversized sender rejected';
like
  dies { Overnet::Mail::Envelope->new(sender => q{}, recipients => [$short], max_address_bytes => length($short) - 1) },
  qr/address exceeds/, 'oversized recipient rejected';
like dies { Overnet::Mail::Envelope->new(recipients => [$short]) }, qr/sender/,
  'sender must be explicit even when null';
like dies { Overnet::Mail::Envelope->new(sender => q{}) }, qr/recipients/, 'recipients required';

done_testing;
