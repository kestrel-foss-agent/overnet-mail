package Overnet::Mail;

use strictures 2;

our $VERSION = '0.001';

1;

__END__

=head1 NAME

Overnet::Mail - foundation for an interoperable Perl email application

=head1 SYNOPSIS

  use Overnet::Mail;

=head1 VERSION

Version 0.001.

=head1 DESCRIPTION

This distribution provides bounded in-memory raw-message, envelope and submission
value objects, backed by shared quality gates. It does not yet persist, retrieve
or deliver messages as a mail service.

Ordinary Internet email interoperability is a required application boundary.
Mature SMTP and mailbox protocol implementations will own their wire protocols;
CPAN libraries will own MIME parsing and composition.

=head1 SUBROUTINES/METHODS

No application methods are implemented in this foundation release.

=head1 DIAGNOSTICS

This module emits no application diagnostics. Perl reports missing dependencies
when the module cannot be loaded.

=head1 CONFIGURATION AND ENVIRONMENT

The module has no runtime configuration. Development-only quality gate settings
are documented in the repository README.

=head1 DEPENDENCIES

Perl 5.40 or newer and L<strictures> version 2. Development tests use L<Test2::V0>.

=head1 INCOMPATIBILITIES

Perl versions older than 5.40 are unsupported.

=head1 BUGS AND LIMITATIONS

Only the in-memory message boundary is implemented. This release must not be
used as a mail server, durable message store, or submission client.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

This program is free software under the GNU General Public License version 3.
See the LICENSE file distributed with this software.

=cut
