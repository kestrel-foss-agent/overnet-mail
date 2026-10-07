package Overnet::Mail::Transport::SMTPClient;

use strictures 2;
use parent 'Net::SMTP';

our $VERSION = '0.001';

# Net::Cmd documents this override for distinguishing local pseudo responses.
sub DEF_REPLY_CODE {
  return 0;
}

sub response {
  my ($self) = @_;
  my $fields = *{$self}{HASH};
  $fields->{overnet_reply_complete} = 0;
  $fields->{overnet_reply_code}     = undef;
  $fields->{overnet_reply_invalid}  = 0;
  return $self->SUPER::response;
}

sub parse_response {
  my $self   = shift;
  my $fields = *{$self}{HASH};
  my @reply  = $self->SUPER::parse_response(@_);
  if (@reply) {
    my $first = $fields->{overnet_reply_code};
    if (defined $first && $first ne $reply[0]) {
      $fields->{overnet_reply_invalid} = 1;
    }
    $fields->{overnet_reply_code}     = $reply[0];
    $fields->{overnet_reply_complete} = !$reply[1];
  } else {
    $fields->{overnet_reply_invalid} = 1;
  }
  return @reply;
}

sub reply_complete {
  my ($self) = @_;
  my $fields = *{$self}{HASH};
  return $fields->{overnet_reply_complete} && !$fields->{overnet_reply_invalid};
}

1;

__END__

=head1 NAME

Overnet::Mail::Transport::SMTPClient - observe libnet response completeness

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Used internally by LoopbackSMTP; not an operational transport entry point.

=head1 DESCRIPTION

Inherits Net::SMTP unchanged command, socket and data handling. Net::Cmd's
response and parsing hooks record whether a response completed with consistent
multiline codes. All parsing is delegated to the library. Local synthetic
responses use code zero rather than overloading the peer's SMTP 421 reply.

=head1 SUBROUTINES/METHODS

=head2 DEF_REPLY_CODE

Documented Net::Cmd hook returning zero for local errors and missing responses.

=head2 response

Resets observation state and delegates response collection to Net::Cmd.

=head2 parse_response

Delegates parsing and observes its result without changing command semantics.

=head2 reply_complete

True only when the last response ended and its multiline codes were consistent.
A synthetic code zero still cannot be treated as a peer reply.

=head1 DIAGNOSTICS

This helper emits no diagnostics itself. Its owner disables library debugging.

=head1 CONFIGURATION AND ENVIRONMENT

Internal helper; use LoopbackSMTP instead. Direct inherited construction retains
Net::SMTP's configuration and is outside the loopback adapter's public contract.

=head1 DEPENDENCIES

Perl 5.40, strictures 2 and Net::SMTP 3.15 (libnet).

=head1 INCOMPATIBILITIES

Does not replace libnet's protocol grammar or promise strict RFC conformance.

=head1 BUGS AND LIMITATIONS

Response observation does not authenticate a peer or implement TLS verification.
No SMTP or IMAP server is implemented.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
