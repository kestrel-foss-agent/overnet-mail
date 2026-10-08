package Overnet::Mail::Store::Postgres;

use strictures 2;
use Moo;
extends 'Overnet::Mail::Store';

use Carp                                             qw(croak);
use JSON                                             ();
use Scalar::Util                                     qw(blessed);
use Net::Blossom::Server::Backend::Postgres 0.001004 ();
use Net::Blossom::Server::Backend::Postgres::BlobStore;
use Net::Blossom::Server::Backend::Postgres::MetadataStore;

our $VERSION = '0.001';

has '+path' => (required => 0);
has dbh     => (is       => 'ro', required => 1);
has _schema => (is       => 'ro', init_arg => undef);

sub _open_storage {
  my ($self) = @_;
  my $dbh = $self->dbh;
  croak 'Postgres store does not accept a SQLite path' if defined $self->path;
  if (!blessed($dbh) || !$dbh->isa('DBI::db') || $dbh->{Driver}{Name} ne 'Pg' || !$dbh->{AutoCommit}) {
    croak 'Postgres store requires an idle PostgreSQL DBI handle';
  }
  $dbh->{RaiseError}         = 1;
  $dbh->{PrintError}         = 0;
  $dbh->{ShowErrorStatement} = 0;
  $dbh->{HandleError}        = sub { croak 'mail store database operation failed' };
  $dbh->{pg_enable_utf8}     = 0;
  $self->{_dbh}              = $dbh;
  my $schema = $dbh->selectrow_array('SELECT current_schema()');

  if (!defined $schema || $schema !~ /\A[a-z][a-z0-9_]{0,62}\z/smx || $schema =~ /\Apg_/smx) {
    croak 'Postgres store requires an application schema';
  }
  $self->{_schema} = $schema;
  if ($dbh->selectrow_array('SHOW fsync') ne 'on' || $dbh->selectrow_array('SHOW full_page_writes') ne 'on') {
    croak 'mail store durability settings unavailable';
  }
  $self->{_blob_store}     = Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh);
  $self->{_metadata_store} = Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh);
  return;
}

around _transaction => sub {
  my ($original, $self, $code) = @_;
  return $self->$original(
    sub {
      my $dbh = $self->_dbh;
      $dbh->do('SET TRANSACTION ISOLATION LEVEL READ COMMITTED');
      $dbh->do(q{SET LOCAL synchronous_commit = 'on'});
      $dbh->do(q{SET LOCAL lock_timeout = '2500ms'});
      $dbh->do(q{SET LOCAL statement_timeout = '10000ms'});
      $dbh->do('SET LOCAL search_path = ' . $dbh->quote_identifier($self->_schema) . ', pg_catalog, pg_temp');

      # One-key lock space is separate from Blossom's two-key content locks.
      $dbh->do('SELECT pg_advisory_xact_lock(1330463049::bigint)');
      return $code->();
    }
  );
};

sub _initialize {
  my ($self) = @_;
  my $dbh = $self->_dbh;
  $self->_validate_blossom_schema;
  my $tables = $dbh->selectcol_arrayref(
q{SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? AND c.relkind IN ('r', 'v', 'm', 'f', 'p') ORDER BY c.relname},
    undef, $self->_schema
  );
  my $unsafe = $dbh->selectrow_array(
q{SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? AND (c.relpersistence != 'p' OR c.relkind IN ('v', 'm', 'f', 'p'))},
    undef, $self->_schema
  );
  croak 'unsupported mail store durability' if $unsafe;
  my @blossom  = qw(blossom_blob_data blossom_blobs blossom_owners);
  my $expected = JSON->new->encode(\@blossom);

  if (JSON->new->encode($tables) ne $expected) {
    my @complete = sort (@blossom, qw(deliveries messages overnet_mail_schema recipients submissions));
    croak 'unsupported mail store schema' if JSON->new->encode($tables) ne JSON->new->encode(\@complete);
    my $versions = $dbh->selectcol_arrayref('SELECT version FROM overnet_mail_schema');
    croak 'unsupported mail store schema' if @{$versions} != 1 || $versions->[0] != 1;
    return;
  }
  $self->_deploy_mail_tables('BIGINT GENERATED ALWAYS AS IDENTITY (MAXVALUE 999999999999999999) PRIMARY KEY', 'BIGINT');
  $dbh->do('CREATE TABLE overnet_mail_schema (version INTEGER PRIMARY KEY CHECK (version = 1))');
  $dbh->do('INSERT INTO overnet_mail_schema (version) VALUES (1)');
  return;
}

sub _validate_blossom_schema {
  my ($self)  = @_;
  my $dbh     = $self->_dbh;
  my %columns = (
    blossom_blob_data => 'storage_key:text,body_oid:oid',
    blossom_blobs     => 'sha256:text,storage_key:text,size:bigint,type:text,uploaded:bigint',
    blossom_owners    => 'pubkey:text,sha256:text,type:text,uploaded:bigint',
  );
  for my $table (sort keys %columns) {
    my $row = $dbh->selectrow_hashref(
q{SELECT c.relkind, c.relpersistence, string_agg(a.attname || ':' || format_type(a.atttypid, a.atttypmod), ',' ORDER BY a.attnum) AS columns, bool_and(a.attnotnull) AS required FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_attribute a ON a.attrelid = c.oid WHERE n.nspname = ? AND c.relname = ? AND a.attnum > 0 AND NOT a.attisdropped GROUP BY c.relkind, c.relpersistence},
      undef, $self->_schema, $table
    );
    if (!$row
      || $row->{relkind} ne 'r'
      || $row->{relpersistence} ne 'p'
      || !$row->{required}
      || $row->{columns} ne $columns{$table}) {
      croak 'unsupported Blossom PostgreSQL schema';
    }
  }
  my $keys = $dbh->selectcol_arrayref(
q{SELECT c.relname || ':' || pg_get_constraintdef(k.oid) FROM pg_constraint k JOIN pg_class c ON c.oid = k.conrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? AND c.relname IN ('blossom_blob_data', 'blossom_blobs', 'blossom_owners') AND k.convalidated ORDER BY c.relname, k.contype},
    undef, $self->_schema
  );
  my @expected = (
    'blossom_blob_data:PRIMARY KEY (storage_key)',
    'blossom_blobs:PRIMARY KEY (sha256)',
    'blossom_owners:FOREIGN KEY (sha256) REFERENCES blossom_blobs(sha256) ON DELETE CASCADE',
    'blossom_owners:PRIMARY KEY (pubkey, sha256)',
  );
  croak 'unsupported Blossom PostgreSQL constraints' if JSON->new->encode($keys) ne JSON->new->encode(\@expected);
  return;
}

sub _insert_id {
  my ($self, $table, $column) = @_;
  return $self->_dbh->selectrow_array(
    'SELECT currval(pg_get_serial_sequence(?, ?))',        undef,
    $self->_dbh->quote_identifier($self->_schema, $table), $column
  );
}

sub _blob_bytes {
  my ($self, $key) = @_;

  # Blossom 0.001004 get_blob clones its handle. That separate snapshot cannot
  # see a just-prepared large object. lo_get uses this transaction's snapshot.
  return $self->_dbh->selectrow_array('SELECT lo_get(body_oid) FROM blossom_blob_data WHERE storage_key = ?', undef,
    $key);
}

1;

__END__

=head1 NAME

Overnet::Mail::Store::Postgres - shared PostgreSQL Blossom mail custody

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  # Provision an application schema with the upstream Blossom components first.
  my $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh);
  my $receipt = $store->accept_item(
    mailbox_id => 'account-1', idempotency_key => 'request-1', item => $message,
  );

=head1 DESCRIPTION

Implements the Store API using Net::Blossom PostgreSQL metadata and large-object
uploads on one DBI handle. Acceptance, idempotency, outbox state, and large-object
creation commit or roll back together. SQLite Store remains available unchanged.

=head1 SUBROUTINES/METHODS

=head2 new

Requires C<dbh>, an idle DBD::Pg connection to a dedicated, preprovisioned
Net::Blossom 0.001004 application schema. The schema name is 1-63 lowercase ASCII
letters, digits or underscores, beginning with a letter, without the C<pg_>
prefix. The caller must provision with both upstream components' C<deploy_schema>
methods before constructing this adapter. These upstream deployment methods
must run in AutoCommit mode; this adapter never invokes them or their unbounded
schema-lock wait. No SQLite C<path> is accepted. C<max_message_bytes> is inherited.

The connection becomes exclusively owned by this Store, including error handling,
encoding and disconnect. Do not share it or change its settings. Never use or
run destructors on an inherited connection after fork. The LoopbackSMTP attempt
child is a narrow exception to the no-fork rule: it never touches this handle,
executes no inherited END/DESTROY callbacks, and terminates with C<POSIX::_exit>
or a default-action signal. Its parent retains sole connection ownership.
The current schema is captured at construction. Incomplete and foreign table
sets, incompatible Blossom columns and constraints, and unknown mail schema
versions are rejected. Mail tables and the version marker are initialized in one
transaction; no migration is implemented. Owner lookup indexes are not checked
because mail does not use Blossom owners. On reopen, mail relation names/kinds
and version are checked, without an exhaustive column/constraint fingerprint.

=head2 dbh

Returns the originally supplied connection. This is a configuration accessor,
not permission for callers to mutate it while the Store is in use.

=head1 CONFIGURATION AND ENVIRONMENT

Requires server C<fsync> and C<full_page_writes> enabled. Every operation uses
READ COMMITTED, synchronous_commit on, a 2500 ms lock timeout, a 10000 ms
statement timeout and a database-wide transaction advisory lock. All cooperating
mail operations serialize, including reads and different schemas: this bounded
first milestone does not provide parallel queue throughput. Blossom's per-hash
locks are also retained. Administrative or external direct writes are outside
this trusted application boundary.

The caller supplies connection authentication and transport configuration.
No credentials are accepted, stored or logged by this adapter. Use a dedicated
least-privilege database role and private schema; schema provisioning is an
explicit administrative step. Protect and clean the private temporary directory
used by upstream uploads; process termination can leave a 0600 staging file.

=head1 DIAGNOSTICS

Database failures use value-free exceptions. Transaction failure has the same
rollback, fencing and idempotent receipt-recovery contract as Store. Large-object
reads use PostgreSQL's public C<lo_get> function on the shared transaction: the
pinned upstream C<get_blob> creates a second connection and cannot observe new
uncommitted uploads. No upstream private implementation method is invoked.

=head1 DEPENDENCIES

Overnet::Mail::Store, DBD::Pg and Net::Blossom::Server::Backend::Postgres 0.001004.

=head1 INCOMPATIBILITIES

PostgreSQL mail schema version 1 is independent of SQLite schema versions.
No cross-backend migration, deletion or external network service is provided.

=head1 BUGS AND LIMITATIONS

Inherits Store's trusted-caller and uncertain-delivery limitations. Local crash
and rollback tests do not certify power-loss, replication or hardware durability.
Large-object ownership belongs to the database role; foreign keys protect mail
references to mapping and metadata rows, not against an administrator directly
unlinking a PostgreSQL large object. Content integrity is checked on each read.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
