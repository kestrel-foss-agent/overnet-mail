# PostgreSQL storage milestone

This branch's PostgreSQL adapter is experimental until the exact commit's
real-service CI is green. Local static checks or SQLite tests alone do not
validate PostgreSQL support.

`Overnet::Mail::Store::Postgres` implements the existing trusted Store API on
Net::Blossom::Server::Backend::Postgres 0.001004. It uses that distribution's
BlobStore uploads, MetadataStore records and transaction wrapper, with the mail
records and outbox in the same PostgreSQL transaction. No public Blossom server,
remote SMTP transport, mailbox authorization or background delivery daemon is
introduced.

## Explicit provisioning

Use a dedicated database role and private, already-created application schema.
The role must be able to create tables/sequences in that schema and create/read
its large objects. Other roles must not have CREATE or write privileges in that
schema. Supply authentication and TLS settings through your ordinary PostgreSQL
connection configuration; this adapter does not configure credentials or grants.

Select the application schema before constructing both upstream components:

```perl
use DBI;
use Net::Blossom::Server::Backend::Postgres::BlobStore;
use Net::Blossom::Server::Backend::Postgres::MetadataStore;
use Overnet::Mail::Store::Postgres;

# $dbh is an authenticated, dedicated DBD::Pg connection with AutoCommit enabled.
$dbh->do('SET search_path = mail_application, pg_catalog');
Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
my $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh);
```

Provisioning is a separate explicit administrative operation. Upstream metadata
schema deployment uses AutoCommit and concurrent indexes; it cannot be nested
in atomic mail initialization. Interrupted provisioning must be repaired by the
administrator using the upstream deployment workflow before constructing the
mail adapter. The adapter does not call upstream deployment or its unbounded
schema-lock wait. It validates ordinary logged Blossom tables, required column
shapes and keys, then atomically creates the mail tables and version marker.
Unknown/incomplete table sets and unsupported schema versions fail closed.

The caller transfers exclusive use of the DBI connection to the Store. Do not
share it with another object, reuse it after `disconnect`, or inherit it across
fork. Reconnect separately in every process. This remains a trusted local API;
mailbox-scoped queries are not authorization.

## Transaction and custody contract

Every mail operation, including reads, takes a transaction-level advisory lock
with the fixed database-wide key 1330463049. Operations across different schemas
also serialize. This deliberately preserves the proven bounded Store state
machine while PostgreSQL concurrency support develops; it is not a parallel
queue-throughput implementation. Lock waits fail after 2500 ms; each statement
is limited to 10000 ms. Callers may retry the original idempotency key after a
transient failure or lost receipt.

The transaction explicitly uses READ COMMITTED before obtaining the lock. This
is essential: a pre-lock REPEATABLE READ snapshot could miss another writer's
committed receipt after waiting for the lock. Blob hash locks are still taken
through Net::Blossom. Session synchronous_commit settings cannot weaken an
acceptance because every transaction sets it to on; fsync and full_page_writes
must be enabled on the server. Database tables must be logged. Durability still
depends on PostgreSQL, the OS, storage and replication configuration.

The upstream upload imports a PostgreSQL large object before inserting its
storage-key mapping. Both are transactional. Mail foreign keys protect both the
mapping and Blossom metadata; deletion failure must roll back an upstream
large-object unlink as well. Large-object creation remains owned by the database
role and does not invent Blossom pubkey ownership. Administrators can still
unlink large objects directly; read-time content verification catches missing
or changed bytes. No deletion API is provided by this milestone.

### Isolated compatibility seam

In the pinned upstream version, `BlobStore->get_blob` clones its connection to
create a streaming reader. That second transaction cannot see an upload that
has just been prepared in the acceptance transaction. The PostgreSQL adapter's
single `_blob_bytes` hook therefore reads `lo_get(body_oid)` through the same
DBD::Pg handle, using PostgreSQL's public large-object API and ordinary bytea
decoding. The common Store then verifies length, SHA-256 and exact accepted bytes
before committing. All other upload/metadata lifecycle operations use public
Net::Blossom methods, with no copied backend or private upstream call.

Staged uploads use upstream owner-only temporary files. Successful operations
and ordinary exceptions clean them; hard process termination can leave a 0600
staging file. Operate with a private application temp directory and a deliberate
stale-file retention/cleanup policy. Do not expose mail staging to other users.

## Validation

CI provisions a real PostgreSQL 17 service for both Perl versions and the
per-module coverage job. It requires PostgreSQL tests rather than allowing a
missing DSN or driver to silently skip them. To run the same suite against a
throwaway local database whose role may create private test schemas:

```sh
export OVERNET_REQUIRE_POSTGRES=1
export OVERNET_TEST_PG_DSN='dbi:Pg:dbname=overnet_mail_test;host=127.0.0.1;port=5432'
export OVERNET_TEST_PG_USER=postgres
bash scripts/check.sh all
```

Use only a disposable test database. Tests create uniquely named schemas and
large objects, exercise rollback, contention, hard process interruption and
receipt replay, and clean their own fixtures. Tests do not send external mail.
Without a DSN, normal install tests skip PostgreSQL integration; the full
per-module coverage gate still requires real database-backed execution to pass.

The development cloud executor could install PostgreSQL 17.11 and the CPAN
modules but could not create Unix-domain sockets, including with its normal
escalation flow. Consequently local validation is explicitly limited to static
checks and SQLite regression; real PostgreSQL evidence comes from the exact
branch/PR CI runs. Process crash tests are not power-loss or hardware tests.
