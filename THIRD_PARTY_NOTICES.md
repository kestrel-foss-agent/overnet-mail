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
