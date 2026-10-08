# Third-party notices

The complete `vendor/overnet-perl-style/` package is copied without source changes
from [overnet-project/overnet-perl](https://github.com/overnet-project/overnet-perl/tree/63c450f5d36582e260e73e931271a9b02e0c9197/overnet-perl-style),
commit `63c450f5d36582e260e73e931271a9b02e0c9197`. Its original README,
license, source notices and file modes are retained. The machine-readable manifest
`vendor/overnet-perl-style.json` records every original Git blob hash.

The root `.perlcriticrc`, `.perltidyrc` and five `xt/author/*.t` templates are
verbatim copies installed using that package's `tools/sync-configs` script.
Its custom policies are installed as a development dependency, not copied into
application `lib/`. The application's workflows adapt the pinned Actions from
upstream `.github/workflows/style-test.yml` and `style-mutation.yml` at the same
commit; repository paths, dependency setup and fail-closed preflights are changed.

The upstream package declares GPL version 3 (`gpl_3`) in its Makefile.PL. The
license text is preserved in `vendor/overnet-perl-style/LICENSE` and root `LICENSE`.
New Overnet Mail source is licensed GPL-3.0-only as an explicit project choice.
No upstream author or copyright notice is replaced by this notice.

## SMTP client dependency

The local SMTP adapter depends on CPAN libnet / Net::SMTP 3.15 or newer.
No libnet source is vendored or copied. Its published license is the same terms
as Perl (Artistic License or GNU General Public License); original notices remain
with the installed dependency. See [Net::SMTP documentation and license](https://metacpan.org/pod/Net::SMTP).
The application adapter and tests remain GPL-3.0-only.

## Net::Blossom storage dependency

The application uses the published Net::Blossom::Server::Backend::SQLite
distribution (minimum 0.001004), under GPL-3.0, as an external CPAN dependency.
No Net::Blossom source is copied into this repository. SQLite 0.001004’s three
runtime modules and Makefile.PL were verified byte-for-byte against upstream
commit `084c7db09465f3470fec9748b4e467bea5f567f9`.

- Source: https://github.com/NicholasBHubbard/Net-Blossom/tree/084c7db09465f3470fec9748b4e467bea5f567f9/dist/Net-Blossom-Server-Backend-SQLite
- License: https://github.com/NicholasBHubbard/Net-Blossom/blob/084c7db09465f3470fec9748b4e467bea5f567f9/LICENSE
- CPAN archive SHA-256: `32080b478b26698ade1529955652ae6d6348b4a013d4cd92fce1f50f432805a9`

The mail adapter uses the public BlobStore/MetadataStore components rather than
copying their backend infrastructure. Mail-specific policy and recovery guards
remain in Overnet::Mail::Store. See `docs/blossom-storage.md`.

The PostgreSQL adapter likewise uses Net::Blossom::Server::Backend::Postgres
0.001004 as an external GPL-3.0 CPAN dependency; no backend implementation is
vendored or copied. DBD::Pg 3.21.2 provides the PostgreSQL client interface.
The adapter's same-transaction large-object read uses PostgreSQL's public
`lo_get` function because upstream streaming readers clone their DBI handle.

- PostgreSQL backend source: https://cpan.metacpan.org/authors/id/N/NH/NHUBBARD/Net-Blossom-Server-Backend-Postgres-0.001004.tar.gz
- Archive SHA-256: `b753b532b6253ee07c1766c7df01b83ef3fbadbb0630f6aefbeb91715c9141b1`
- DBD::Pg source: https://cpan.metacpan.org/authors/id/T/TU/TURNSTEP/DBD-Pg-3.21.2.tar.gz
- Archive SHA-256: `d79179255ccb0c87b029db2eecaea56828e581255c48445d5fc0e79fa4e9245b`
