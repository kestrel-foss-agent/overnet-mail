package Overnet::Mail::Transport::LoopbackSMTP;

use strictures 2;
use Moo;

use Carp         qw(croak);
use Scalar::Util qw(blessed);
use Time::HiRes  qw(clock_gettime CLOCK_MONOTONIC);
use Overnet::Mail::Transport::Attempt;
use Overnet::Mail::Envelope;
use Overnet::Mail::Submission;
use Overnet::Mail::Transport::SMTPClient;

our $VERSION = '0.001';

has port            => (is => 'ro', required => 1);
has timeout         => (is => 'ro', default  => sub { return 2 });
has attempt_seconds => (is => 'ro', default  => sub { return 10 });

sub BUILD {
  my ($self, $args) = @_;
  for my $key (keys %{$args}) {
    croak 'unsupported loopback adapter option' if $key ne 'port' && $key ne 'timeout' && $key ne 'attempt_seconds';
  }
  for my $range (['port', 1_024, 65_535], ['timeout', 1, 30], ['attempt_seconds', 1, 30]) {
    my ($name, $min, $max) = @{$range};
    my $value = $self->$name;
    if (!defined $value || ref $value || $value !~ /\A[1-9][0-9]{0,4}\z/smx || $value < $min || $value > $max) {
      croak 'adapter port or timeout is outside its bounded integer range';
    }
  }
  return;
}

sub deliver {
  my ($self, $claim) = @_;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + $self->attempt_seconds;
  if (ref $claim ne 'HASH' || !blessed($claim->{message}) || !$claim->{message}->isa('Overnet::Mail::RawMessage')) {
    croak 'delivery requires a single-recipient claim with RawMessage';
  }
  my $envelope = Overnet::Mail::Envelope->new(sender => $claim->{sender}, recipients => [$claim->{recipient}]);
  Overnet::Mail::Submission->new(message => $claim->{message}, envelope => $envelope);
  my $raw     = $claim->{message}->raw_bytes;
  my $invalid = _wire_error($raw, $envelope);
  return _result('permanent', $invalid) if defined $invalid;

  my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
  return _result('transient', 'connect') if $remaining <= 0;
  return Overnet::Mail::Transport::Attempt::run($deadline, sub { $self->_attempt($raw, $envelope, @_) });
}

sub _attempt {
  my ($self, $raw, $envelope, $report) = @_;
  my $state = {stage => 'connect', uncertain => 0, report => $report};
  my ($smtp, $result);
  local $SIG{PIPE} = 'IGNORE';
  my $ok = eval {
    $smtp = Overnet::Mail::Transport::SMTPClient->new(
      Host           => '127.0.0.1',
      Port           => $self->port,
      Timeout        => $self->timeout,
      SendHello      => 0,
      ExactAddresses => 1,
      Debug          => 0,
    );
    $result = $smtp ? _exchange($smtp, $state, $raw, $envelope) : _result('transient', 'connect');
    1;
  };
  if (!$ok) {
    $result = _result($state->{uncertain} ? 'uncertain' : 'transient', $state->{stage});
  }

  $report->($result);

  # Never QUIT/RSET a failed DATA stream: Net::Cmd may implicitly finish it.
  if ($smtp && defined fileno $smtp) {
    my $closed = eval { $smtp->close; 1 };
    return $result if !$closed;
  }
  return $result;
}

sub _wire_error {
  my ($raw, $envelope) = @_;
  return 'message_size'    if length($raw) > 10_485_760;
  return 'message_framing' if substr($raw, -2) ne "\r\n";
  for my $line (split /\r\n/smx, $raw) {
    return 'message_framing'     if $line =~ /[\r\n\x00]/smx;
    return 'message_line_length' if length($line) > 998;
  }
  my ($headers) = split /\r\n\r\n/smx, $raw, 2;
  return 'smtputf8_unsupported' if $headers =~ /[^\x00-\x7f]/smx;
  for my $address ($envelope->sender, @{$envelope->recipients}) {
    return 'envelope_path_length' if length($address) > 254;
  }
  return;
}

sub _exchange {
  my ($smtp, $state, $raw, $envelope) = @_;
  return _failure($smtp, $state) if !$smtp->reply_complete || $smtp->code != 220;
  _stage($state, 'hello');
  my $hello = $smtp->hello('fixture.invalid');
  return _failure($smtp, $state) if !$hello || !$smtp->reply_complete || $smtp->code != 250;

  my ($options, $invalid) = _mail_options($smtp, $raw);
  return $invalid if $invalid;
  _stage($state, 'mail');
  my $mail = $smtp->mail($envelope->sender, %{$options});
  return _failure($smtp, $state) if !$mail || !$smtp->reply_complete || $smtp->code != 250;

  _stage($state, 'recipient');
  my $recipient = $smtp->recipient($envelope->recipients->[0]);
  return _failure($smtp, $state) if !$recipient || !$smtp->reply_complete || $smtp->code !~ /\A25[012]\z/smx;

  _stage($state, 'data');
  my $data = $smtp->data;
  return _failure($smtp, $state) if !$data || !$smtp->reply_complete || $smtp->code != 354;

  _stage($state, 'body');
  $state->{uncertain} = 1;
  return _failure($smtp, $state) if !$smtp->datasend($raw);
  _stage($state, 'final');
  my $accepted = $smtp->dataend;
  return _failure($smtp, $state) if !$accepted || !$smtp->reply_complete || $smtp->code != 250;
  return _result('confirmed', 'final', 250);
}

sub _stage {
  my ($state, $stage) = @_;
  $state->{stage} = $stage;
  $state->{report}->({stage => $stage});
  return;
}

sub _mail_options {
  my ($smtp, $raw) = @_;
  my %options;
  if ($raw =~ /[^\x00-\x7f]/smx) {
    return (undef, _result('permanent', 'eight_bit_unsupported')) if !defined $smtp->supports('8BITMIME');
    $options{Bits} = '8';
  }
  my $size = $smtp->supports('SIZE');
  if (defined $size) {
    return (undef, _result('transient', 'invalid_size_capability')) if $size !~ /\A[0-9]*\z/smx;
    return (undef, _result('permanent', 'peer_size_limit')) if length($size) && $size > 0 && length($raw) > $size;
    $options{Size} = length $raw;
  }
  return (\%options, undef);
}

sub _failure {
  my ($smtp, $state) = @_;
  my $code = $smtp->code;
  if ($smtp->reply_complete && $code =~ /\A[45][0-9]{2}\z/smx) {
    return _result($code < 500 ? 'transient' : 'permanent', $state->{stage}, 0 + $code);
  }
  return _result($state->{uncertain} ? 'uncertain' : 'transient', $state->{stage});
}

sub _result {
  my ($outcome, $stage, $code) = @_;
  return {outcome => $outcome, stage => $stage, smtp_code => $code};
}

1;

__END__

=head1 NAME

Overnet::Mail::Transport::LoopbackSMTP - local SMTP fixture adapter for one claim

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $adapter = Overnet::Mail::Transport::LoopbackSMTP->new(port => $fixture_port);
  my $result = $adapter->deliver($claim);
  # A trusted caller decides how/when to finish this still-fenced outbox claim.

=head1 DESCRIPTION

Experimental one-shot adapter for scripted loopback fixtures only. Uses libnet
for SMTP, ESMTP, reply parsing, data framing and dot-stuffing. The sole destination
is literal 127.0.0.1. It neither resolves recipient domains nor operates a mail
service. See docs/local-smtp-adapter.md for the full trust and outcome contract.

=head1 SUBROUTINES/METHODS

=head2 BUILD

Moo lifecycle callback validating configuration; do not call directly.

=head2 new

Required C<port> is an integer from 1024 through 65535, selected by a local
fixture using an ephemeral listener. Optional C<timeout> is 1 through 30 seconds,
default 2, per library I/O wait. Optional C<attempt_seconds> is 1 through 30,
default 10, for the total SMTP I/O attempt, including socket cleanup. The two
limits are independent; the earlier bound wins. This is not a lease deadline.
Unknown options are rejected. No host, credentials, TLS or debug options exist.

=head2 port

Returns the explicitly selected local fixture port.

=head2 timeout

Returns the configured bounded library I/O timeout.

=head2 attempt_seconds

Returns the configured total SMTP attempt budget in seconds.

=head2 deliver

Accepts an outbox claim hash containing a RawMessage, sender and one recipient.
Rechecks the Submission privacy boundary. Returns a fresh hash with C<outcome>,
C<stage> and C<smtp_code> (undefined without complete peer evidence). Outcomes
map to the existing queue contract: confirmed, permanent, transient, uncertain.
Confirmed means the local peer accepted custody after DATA, not final recipient
delivery. No queue writes, retries, connection reuse or sibling recipients.

=head1 DIAGNOSTICS

Invalid arguments throw value-free errors. Unsupported wire forms return local
permanent outcomes. Network errors return bounded classifications. Peer text,
message bytes, addresses and library exceptions are never included in results.

=head1 CONFIGURATION AND ENVIRONMENT

No application environment variables or Net::Config default hosts are used.
The numeric IPv4 loopback destination and fixed greeting identity are hardcoded.

=head1 DEPENDENCIES

Perl 5.40, strictures 2, Moo, the existing value objects, core process/timing
modules and Net::SMTP 3.15. Tested on Linux; Unix fork/signals are required.

=head1 INCOMPATIBILITIES

Requires CRLF-only framing and a final CRLF, no NUL, lines at most 998 octets,
ASCII headers and envelope paths at most 254 octets. Never normalizes bytes.
Eight-bit bodies require 8BITMIME. SMTPUTF8 and BINARYMIME are unsupported.

=head1 BUGS AND LIMITATIONS

Fixture-only, cleartext, no authentication or verified TLS. Never use for real
mail or expose to untrusted callers. A production adapter must fail closed on
TLS certificate/hostname verification and authentication policy before sending
credentials or message data. Existing MTAs must own Internet routing/retries;
this adapter is not an Internet MTA. Uncertain outcomes may have been accepted;
a retry can duplicate delivery. A Unix child process bounds slow-drip I/O; see the
adapter contract for process ownership, signal, preflight and timing limits.
The caller must size its lease to include the attempt plus settlement margin.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
