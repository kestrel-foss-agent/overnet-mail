use strictures 2;
use Test2::V0;
use lib 'lab/real-mta';
use QueueObservation ();

my $alice = row('70FB69132B9', 'alice@reference.invalid');
my $blind = row('7D8869132F8', 'blind@reference.invalid');
my $moved = {
  %$alice,
  queue_name => 'deferred',
  recipients => [{address => 'alice@reference.invalid', delay_reason => 'connection refused'},]
};
my @expected = ($alice->{queue_id}, $blind->{queue_id});
is QueueObservation::unique_rows([$alice, $blind, $moved]), [$alice, $blind],
  'same queue ID observed in active and deferred counts as one queue file';
is QueueObservation::matching_ids([$alice, $blind, $moved], \@expected), [$alice, $blind],
  'documented duplicate observation preserves the complete original ID set';
is QueueObservation::unique_rows([$alice, $moved], stable_recipients => 1), [$alice],
  'strict custody observation ignores queue movement and recipient delay details';
my $changed_recipient = {%$moved, recipients => $blind->{recipients}};
like dies { QueueObservation::unique_rows([$alice, $changed_recipient], stable_recipients => 1) },
  qr/conflicting Postfix queue identity/, 'strict custody observation rejects conflicting recipients at the same ID';
like dies { QueueObservation::matching_ids([$alice, $blind, $changed_recipient], \@expected) },
  qr/conflicting Postfix queue identity/, 'expected-ID matching always enforces stable custody recipients';
is QueueObservation::unique_rows([$alice, $changed_recipient]), [$alice],
  'non-custody observations allow recipient membership to change during delivery';
my $drained = {%$alice, recipients => []};
is QueueObservation::unique_rows([$alice, $drained]), [$alice],
  'draining observations permit recipients to be removed as delivery completes';
like dies { QueueObservation::unique_rows([$alice, $drained], stable_recipients => 1) },
  qr/conflicting Postfix queue identity/, 'recipient removal is invalid while LMTP is stopped';
my $both      = {%$alice, recipients => [@{$alice->{recipients}}, @{$blind->{recipients}}]};
my $reordered = {%$both,  recipients => [reverse @{$both->{recipients}}]};
is QueueObservation::unique_rows([$both, $reordered], stable_recipients => 1), [$both],
  'recipient ordering does not change the custody identity';
my $repeated_recipient = {%$alice, recipients => [@{$alice->{recipients}}, @{$alice->{recipients}}]};
like dies { QueueObservation::unique_rows([$alice, $repeated_recipient], stable_recipients => 1) },
  qr/conflicting Postfix queue identity/, 'custody comparison preserves recipient multiplicity';
is QueueObservation::unique_rows([]), [], 'an empty scan remains empty';
is QueueObservation::matching_ids([$alice, $moved], \@expected), undef,
  'two observations of one ID cannot replace the missing second message';
is QueueObservation::matching_ids([], \@expected), undef, 'an empty scan cannot establish custody';

my @scans = ([$alice], [$alice, $blind]);
is QueueObservation::matching_ids(shift @scans, \@expected), undef, 'a temporarily missed expected ID requests retry';
is QueueObservation::matching_ids(shift @scans, \@expected), [$alice, $blind],
  'a later complete scan establishes the exact original ID set';
for (1 .. 3) {
  is QueueObservation::matching_ids([$alice], \@expected), undef,
    'a persistently missing ID never becomes a successful observation';
}
is QueueObservation::matching_ids([$blind], \@expected), undef,
  'different incomplete scans do not accumulate into a false complete set';

my $extra = {%$alice, queue_id => 'EXTRA123'};
is QueueObservation::unique_rows([$alice, $blind, $extra]), [$alice, $blind, $extra],
  'identical envelope and message metadata at distinct IDs remain distinct';
like dies { QueueObservation::matching_ids([$alice, $blind, $extra], \@expected) },
  qr/unexpected Postfix queue ID: EXTRA123/, 'an extra distinct ID fails immediately';
like dies { QueueObservation::matching_ids([$alice, $extra], \@expected) },
  qr/unexpected Postfix queue ID: EXTRA123/, 'replacement IDs fail despite an unchanged message count';
my $calls = 0;
like dies {
  for my $scan ([$alice, $blind, $extra], [$alice, $blind]) {
    ++$calls;
    last if QueueObservation::matching_ids($scan, \@expected);
  }
}, qr/unexpected Postfix queue ID: EXTRA123/, 'a later omission cannot hide an observed extra ID';
is $calls, 1, 'unexpected IDs abort before another observation';

for my $field (qw(sender arrival_time message_size)) {
  my $conflict = {%$moved, $field => 'changed'};
  like dies { QueueObservation::unique_rows([$alice, $conflict]) }, qr/conflicting Postfix queue identity/,
    "repeated ID with conflicting $field is not silently collapsed";
}
for my $invalid (undef, '', [], 'bad id') {
  like dies { QueueObservation::unique_rows([{%$alice, queue_id => $invalid}]) }, qr/invalid Postfix queue ID/,
    'missing or malformed IDs fail closed';
}
like dies { QueueObservation::unique_rows({}) },      qr/invalid Postfix queue rows/, 'non-array observation fails';
like dies { QueueObservation::unique_rows([undef]) }, qr/invalid Postfix queue row/,  'non-object row fails';

done_testing;

sub row {
  my ($id, $recipient) = @_;
  return {
    queue_id     => $id,
    queue_name   => 'active',
    sender       => '',
    arrival_time => 1791915000,
    message_size => 1024,
    recipients   => [{address => $recipient}],
  };
}
