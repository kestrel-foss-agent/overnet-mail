package Overnet::Mail::DeliveryRunner;

use strictures 2;
use Moo;

use Carp         qw(croak);
use Scalar::Util qw(blessed);
use Time::HiRes  qw(clock_gettime CLOCK_MONOTONIC);

our $VERSION = '0.001';

has store              => (is => 'ro', required => 1);
has transport          => (is => 'ro', required => 1);
has clock              => (is => 'ro', required => 1);
has retry_after        => (is => 'ro', required => 1);
has lease_seconds      => (is => 'ro', default  => sub { return 300 });
has settlement_seconds => (is => 'ro', default  => sub { return 5 });

sub BUILD {
  my ($self, $args) = @_;
  my %allowed = map { $_ => 1 } qw(store transport clock retry_after lease_seconds settlement_seconds);
  for my $key (keys %{$args}) {
    croak 'unsupported delivery runner option' if !exists $allowed{$key};
  }
  for my $type (['store', 'Overnet::Mail::Store'], ['transport', 'Overnet::Mail::Transport::LoopbackSMTP']) {
    my ($name, $class) = @{$type};
    croak 'runner requires Store and LoopbackSMTP objects' if !blessed($self->$name) || !$self->$name->isa($class);
  }
  croak 'runner clock must be a callback' if ref $self->clock ne 'CODE';
  _integer($self->retry_after,        1, 86_400);
  _integer($self->lease_seconds,      1, 3_600);
  _integer($self->settlement_seconds, 1, 30);
  croak 'runner lease must exceed attempt, settlement and rounding budgets'
    if $self->lease_seconds <= $self->transport->attempt_seconds + $self->settlement_seconds + 1;
  return;
}

sub run_once {
  my ($self, %args) = @_;
  for my $key (keys %args) {
    croak 'unsupported delivery runner argument' if $key ne 'mailbox_id';
  }

  # Anchor before the integer wall-clock callback and claim can consume time.
  my $started = clock_gettime(CLOCK_MONOTONIC);
  my $start   = $self->_now(0);
  my $claim;
  my $claimed = eval {
    $claim = $self->store->claim_delivery(
      mailbox_id    => $args{mailbox_id},
      now           => $start,
      lease_seconds => $self->lease_seconds,
    );
    1;
  };
  croak 'runner could not claim delivery' if !$claimed;
  return {status => 'idle'}               if !$claim;

  # Copy the fence before handing a mutable claim hash to the transport.
  my %fence = (mailbox_id => $args{mailbox_id}, delivery_id => $claim->{delivery_id}, attempt => $claim->{attempt});
  my $result =
    {status => 'unrecorded', delivery_id => $fence{delivery_id}, attempt => $fence{attempt}, outcome => undef};
  my ($before, $deadline);
  my $timed = eval { ($before, $deadline) = $self->_budget($claim->{lease_until}, $start, $started); 1 };
  if (!$timed) {
    $result->{error} = 'lease_unavailable';
    return $result;
  }

  my $outcome;
  my $sent = eval {
    $outcome = _outcome($self->transport->deliver($claim, deadline => $deadline - $self->settlement_seconds));
    1;
  };
  if (!$sent) {
    $outcome = 'uncertain';
  }
  $result->{outcome} = $outcome;
  my %retry = $outcome eq 'transient' || $outcome eq 'uncertain' ? (retry_after => $self->retry_after) : ();
  my $finished;
  my $recorded = eval {
    $finished = $self->store->finish_delivery(
      %fence,
      now     => $self->_finish_time($before, $deadline),
      outcome => $outcome,
      %retry
    );
    1;
  };
  if (!$recorded) {
    $result->{error} = 'completion_failed';
    return $result;
  }
  $result->{status} = 'recorded';
  $result->{state}  = $finished->{state};
  return $result;
}

sub _budget {
  my ($self, $lease_until, $start, $started) = @_;
  my $sampled = clock_gettime(CLOCK_MONOTONIC);
  my $before  = $self->_now($start);

  # A floor-rounded Unix clock can overstate remaining time by almost a second.
  # Neither a slow claim nor a wall-clock rollback may restart that allowance.
  my $deadline = $started + ($lease_until - $start) - 1;
  my $observed = $sampled + ($lease_until - $before) - 1;
  if ($observed < $deadline) { $deadline = $observed; }
  my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
  croak 'delivery lease has insufficient budget'
    if $remaining < $self->transport->attempt_seconds + $self->settlement_seconds;
  return ($before, $deadline);
}

sub _finish_time {
  my ($self, $before, $deadline) = @_;
  my $now = $self->_now($before);
  croak 'delivery lease budget expired' if clock_gettime(CLOCK_MONOTONIC) >= $deadline;
  return $now;
}

sub _now {
  my ($self, $minimum) = @_;
  my $now;
  my $ok = eval { $now = $self->clock->(); _integer($now, $minimum, 9_999_999_999); 1 };
  croak 'runner clock failed or moved backwards' if !$ok;
  return $now;
}

sub _integer {
  my ($value, $min, $max) = @_;
  if (!defined $value || ref $value || $value !~ /\A(?:0|[1-9][0-9]{0,9})\z/smx || $value < $min || $value > $max) {
    croak 'runner argument must be a bounded canonical integer';
  }
  return;
}

sub _outcome {
  my ($report) = @_;
  return 'uncertain' if ref $report ne 'HASH';
  my $value = $report->{outcome};
  my %valid = map { $_ => 1 } qw(confirmed permanent transient uncertain);
  return 'uncertain' if !defined $value || ref $value || !exists $valid{$value};
  return $value;
}

1;

__END__

=head1 NAME

Overnet::Mail::DeliveryRunner - one fenced outbox handoff to a loopback fixture

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $runner = Overnet::Mail::DeliveryRunner->new(
    store => $store, transport => $loopback, clock => sub { time },
    retry_after => 60,
  );
  my $result = $runner->run_once(mailbox_id => 'local-fixture');

=head1 DESCRIPTION

Claims at most one due recipient, sends it at most once, and records its outcome.
The Store commits the claim before SMTP I/O; no transaction spans the handoff.
This is a trusted-caller local fixture API, not an operational sender or daemon.
See docs/local-delivery-runner.md for the full failure and custody contract.

=head1 SUBROUTINES/METHODS

=head2 BUILD

Moo configuration validation callback; do not call directly.

=head2 new

Requires a Store, LoopbackSMTP transport, trusted clock callback returning integer
Unix seconds, and explicit C<retry_after> (1 through 86400 seconds). Optional
C<lease_seconds> is 1 through 3600 seconds, default 300. C<settlement_seconds>
is 1 through 30 seconds, default 5. The lease must exceed the sum of the adapter
attempt budget, settlement reserve and one second for integer rounding.
Unknown options fail.
Subclasses support controlled test fault injection, not arbitrary transport routing.

=head2 store

Returns the configured Store.

=head2 transport

Returns the configured loopback fixture adapter.

=head2 clock

Returns the trusted clock callback. It must be consistent and nondecreasing across
workers and calls. The runner also rejects backwards time within a single call.

=head2 retry_after

Returns the fixed explicit bounded retry delay, not an automatic retry policy.

=head2 lease_seconds

Returns the configured lease duration.

=head2 settlement_seconds

Returns the explicit settlement headroom reserved after the SMTP cutoff.
It does not bound database lock waits or commit latency.

=head2 run_once

Accepts only C<mailbox_id>. Returns C<status> equal to C<idle> when nothing is due.
Otherwise returns the original C<delivery_id>, C<attempt> and transport C<outcome>
(undefined when no handoff was attempted). C<recorded> also includes durable
C<state>. C<unrecorded> includes fixed C<error>: C<lease_unavailable> before sending,
or C<completion_failed> after sending. It does not mean that a DB commit failed:
a lost commit acknowledgement may leave a terminal record. Inspect Store status.
An unrecorded confirmed outcome is remote evidence only, never durable success.
Exceptions or malformed transport reports become uncertain; their text is hidden.
There is no internal retry, batch processing, enqueue operation or lease renewal.

=head1 DIAGNOSTICS

Invalid configuration, initial clock failures and claim errors throw value-free
errors. A claim error can follow a committed lease with a lost acknowledgement;
no SMTP call occurs. After a claim, failures leave recovery to Store lease expiry
and status inspection. Results omit addresses, message bytes and exception text.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables, network destinations or credentials are accepted.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, Moo, Store and the existing LoopbackSMTP adapter.

=head1 INCOMPATIBILITIES

Not a production worker. SMTP is bounded by a lease-derived monotonic deadline
and the adapter attempt budget. No operational supervisor, lease renewal,
authentication, TLS, Internet routing, downstream retries or DSN processing.

=head1 BUGS AND LIMITATIONS

Integer-clock rounding, elapsed claims and validation consume the fixed lease
budget. Settlement reserve cannot guarantee a timely commit. Clock jumps, OS
scheduling and crashes still limit timing guarantees. Store fencing protects
local outcomes only. A final SMTP 250 confirms local MTA custody, not
recipient delivery. A crash after 250 and before recording is ambiguous on recovery;
retry may duplicate mail. There is no exactly-once guarantee.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
