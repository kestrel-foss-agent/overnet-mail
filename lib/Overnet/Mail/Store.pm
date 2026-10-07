package Overnet::Mail::Store;

use strictures 2;
use Moo;

use Carp         qw(croak);
use DBI          qw(SQL_BLOB);
use DBD::SQLite  ();
use Digest::SHA  qw(sha256_hex);
use English      qw(-no_match_vars);
use File::Spec   ();
use JSON         ();
use Scalar::Util qw(blessed);
use Overnet::Mail::Envelope;
use Overnet::Mail::RawMessage;
use Overnet::Mail::Submission;

our $VERSION = '0.001';

has path              => (is => 'ro', required => 1);
has max_message_bytes => (is => 'ro', default  => sub { return 10_485_760 });
has _dbh              => (is => 'ro', init_arg => undef);

sub BUILD {
  my ($self) = @_;
  my $path = $self->path;
  if (!defined $path || ref $path || $path =~ /[;\x00-\x1f\x7f]/smx || !File::Spec->file_name_is_absolute($path)) {
    croak 'path must be an absolute local filename without controls or semicolons';
  }
  my $limit = $self->max_message_bytes;
  if (!defined $limit || ref $limit || $limit !~ /\A[1-9][0-9]*\z/smx) {
    croak 'max_message_bytes must be a positive integer';
  }
  my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$path",
    q{}, q{},
    {
      RaiseError                       => 1,
      PrintError                       => 0,
      ShowErrorStatement               => 0,
      AutoCommit                       => 1,
      sqlite_unicode                   => 0,
      sqlite_use_immediate_transaction => 1,
      HandleError                      => sub { croak 'mail store database operation failed' },
    }
  );
  $self->{_dbh} = $dbh;
  $dbh->sqlite_busy_timeout(2_500);
  if ($dbh->selectrow_array('PRAGMA journal_mode') ne 'delete') {
    croak 'mail store requires DELETE journaling';
  }
  $dbh->do('PRAGMA synchronous = EXTRA');
  $dbh->do('PRAGMA foreign_keys = ON');
  if ($dbh->selectrow_array('PRAGMA synchronous') != 3 || $dbh->selectrow_array('PRAGMA foreign_keys') != 1) {
    croak 'mail store durability settings unavailable';
  }
  $self->_transaction(sub { $self->_initialize; return 1 });
  return;
}

sub _initialize {
  my ($self)      = @_;
  my $dbh         = $self->_dbh;
  my $version     = $dbh->selectrow_array('PRAGMA user_version');
  my $application = $dbh->selectrow_array('PRAGMA application_id');
  return if $version == 1 && $application == 1_330_463_049;
  my $tables = $dbh->selectrow_array('SELECT COUNT(*) FROM sqlite_master');
  if ($version || $application || $tables) {
    croak 'unsupported mail store schema';
  }
  for my $sql (
    <<'CONTENTS',
CREATE TABLE contents (
      content_sha256 TEXT PRIMARY KEY NOT NULL,
      raw_bytes BLOB NOT NULL CHECK(typeof(raw_bytes) = 'blob'),
      size_bytes INTEGER NOT NULL CHECK(size_bytes > 0 AND length(raw_bytes) = size_bytes)
)
CONTENTS
    <<'MESSAGES',
CREATE TABLE messages (
      message_id INTEGER PRIMARY KEY AUTOINCREMENT,
      mailbox_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      content_sha256 TEXT NOT NULL REFERENCES contents(content_sha256),
      sender TEXT,
      signature TEXT NOT NULL,
      UNIQUE(mailbox_id, idempotency_key)
)
MESSAGES
    'CREATE INDEX messages_content ON messages(content_sha256)',
    <<'RECIPIENTS',
CREATE TABLE recipients (
      message_id INTEGER NOT NULL REFERENCES messages(message_id),
      position INTEGER NOT NULL CHECK(position >= 0),
      address TEXT NOT NULL,
      PRIMARY KEY(message_id, position)
)
RECIPIENTS
    'PRAGMA application_id = 1330463049',
    'PRAGMA user_version = 1',
  ) {
    $dbh->do($sql);
  }
  return;
}

sub accept_item {
  my ($self, %args) = @_;
  _token($args{mailbox_id});
  _token($args{idempotency_key});
  my ($message, $envelope) = $self->_item($args{item});
  my $sha        = $message->content_sha256;
  my $sender     = $envelope ? $envelope->sender     : undef;
  my $recipients = $envelope ? $envelope->recipients : [];
  my $signature  = _signature($sha, $sender, $recipients);
  return $self->_transaction(
    sub {
      my $dbh      = $self->_dbh;
      my $existing = $dbh->selectrow_hashref('SELECT * FROM messages WHERE mailbox_id = ? AND idempotency_key = ?',
        undef, $args{mailbox_id}, $args{idempotency_key},);
      if ($existing) {
        my $stored = $self->_record($existing);
        if ($existing->{signature} ne $signature || $stored->{message}->raw_bytes ne $message->raw_bytes) {
          croak 'idempotency key conflicts with accepted item';
        }
        return _receipt($existing);
      }
      $self->_store_content($message);
      $dbh->do(
        'INSERT INTO messages (mailbox_id, idempotency_key, content_sha256, sender, signature) VALUES (?, ?, ?, ?, ?)',
        undef, $args{mailbox_id}, $args{idempotency_key}, $sha, $sender, $signature,
      );
      my $id       = $dbh->sqlite_last_insert_rowid;
      my $position = 0;
      for my $address (@{$recipients}) {
        $dbh->do('INSERT INTO recipients (message_id, position, address) VALUES (?, ?, ?)',
          undef, $id, $position, $address);
        ++$position;
      }
      return {message_id => $id, content_sha256 => $sha};
    }
  );
}

sub _item {
  my ($self, $item) = @_;
  if (!blessed($item)) {
    croak 'item must be a RawMessage or Submission object';
  }
  my ($message, $envelope);
  if ($item->isa('Overnet::Mail::Submission')) {
    ($message, $envelope) = ($item->message, $item->envelope);

    # Apply the persistence boundary's fixed envelope limits independently.
    $envelope = Overnet::Mail::Envelope->new(sender => $envelope->sender, recipients => $envelope->recipients);
  } elsif ($item->isa('Overnet::Mail::RawMessage')) {
    $message = $item;
  } else {
    croak 'item must be a RawMessage or Submission object';
  }
  if ($message->size_bytes > $self->max_message_bytes) {
    croak 'item exceeds max_message_bytes';
  }
  return ($message, $envelope);
}

sub _store_content {
  my ($self, $message) = @_;
  my $dbh    = $self->_dbh;
  my $sha    = $message->content_sha256;
  my $exists = $dbh->selectrow_array('SELECT 1 FROM contents WHERE content_sha256 = ?', undef, $sha);
  if ($exists) {
    if ($self->_content($sha)->raw_bytes ne $message->raw_bytes) {
      croak 'stored content conflicts with accepted bytes';
    }
    return;
  }
  if ($dbh->selectrow_array('SELECT 1 FROM messages WHERE content_sha256 = ? LIMIT 1', undef, $sha)) {
    croak 'stored content is missing';
  }
  my $sth = $dbh->prepare('INSERT INTO contents (content_sha256, raw_bytes, size_bytes) VALUES (?, ?, ?)');
  $sth->bind_param(1, $sha);
  $sth->bind_param(2, $message->raw_bytes, SQL_BLOB);
  $sth->bind_param(3, $message->size_bytes);
  $sth->execute;
  return;
}

sub load {
  my ($self, %args) = @_;
  _token($args{mailbox_id});
  my $id = $args{message_id};
  if (!defined $id || ref $id || $id !~ /\A[1-9][0-9]{0,17}\z/smx) {
    croak 'message_id must be a positive integer of at most 18 digits';
  }
  return $self->_transaction(
    sub {
      my $row = $self->_dbh->selectrow_hashref('SELECT * FROM messages WHERE mailbox_id = ? AND message_id = ?',
        undef, $args{mailbox_id}, $id,);
      return if !$row;
      return $self->_record($row);
    }
  );
}

sub _record {
  my ($self, $row) = @_;
  my $recipients =
    $self->_dbh->selectcol_arrayref('SELECT address FROM recipients WHERE message_id = ? ORDER BY position',
    undef, $row->{message_id},);
  if ($row->{signature} ne _signature($row->{content_sha256}, $row->{sender}, $recipients)) {
    croak 'stored envelope integrity check failed';
  }
  my $envelope;
  if (defined $row->{sender}) {
    $envelope = Overnet::Mail::Envelope->new(sender => $row->{sender}, recipients => $recipients);
  }
  return {%{_receipt($row)}, message => $self->_content($row->{content_sha256}), envelope => $envelope};
}

sub _content {
  my ($self, $sha) = @_;
  my $row = $self->_dbh->selectrow_hashref(
    'SELECT raw_bytes, size_bytes, typeof(raw_bytes) AS storage_type FROM contents WHERE content_sha256 = ?',
    undef, $sha,);
  if (!$row) {
    croak 'stored content is missing';
  }
  if ( $row->{storage_type} ne 'blob'
    || length($row->{raw_bytes}) != $row->{size_bytes}
    || sha256_hex($row->{raw_bytes}) ne $sha) {
    croak 'stored content integrity check failed';
  }
  return Overnet::Mail::RawMessage->new(raw_bytes => $row->{raw_bytes}, max_bytes => $row->{size_bytes});
}

sub _signature {
  my ($sha, $sender, $recipients) = @_;
  return sha256_hex(JSON->new->encode([$sha, $sender, $recipients]));
}

sub _receipt {
  my ($row) = @_;
  return {message_id => $row->{message_id}, content_sha256 => $row->{content_sha256}};
}

sub _token {
  my ($value) = @_;
  if (!defined $value || ref $value || $value !~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/smx) {
    croak 'mailbox_id and idempotency_key must be bounded ASCII tokens';
  }
  return;
}

sub _transaction {
  my ($self, $code) = @_;
  my $dbh = $self->_dbh;
  croak 'mail store is closed' if !$dbh;
  my $result;
  my $ok = eval {
    $dbh->begin_work;
    $result = $code->();
    $dbh->commit;
    1;
  };
  if (!$ok) {
    my $error       = $EVAL_ERROR;
    my $rolled_back = eval {
      if (!$dbh->{AutoCommit}) {
        $dbh->rollback;
      }
      1;
    };
    if (!$rolled_back) {
      $self->{_dbh} = undef;
      $dbh->disconnect;
      croak 'mail store rollback failed; reopen required';
    }
    croak $error;
  }
  return $result;
}

sub disconnect {
  my ($self) = @_;
  if ($self->_dbh) {
    $self->_dbh->disconnect;
    $self->{_dbh} = undef;
  }
  return;
}

1;

__END__

=head1 NAME

Overnet::Mail::Store - transactional local mailbox acceptance using SQLite

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

  my $store = Overnet::Mail::Store->new(path => '/private/mail.sqlite');
  my $receipt = $store->accept_item(
    mailbox_id => 'account-1', idempotency_key => 'request-1', item => $message,
  );
  my $stored = $store->load(
    mailbox_id => 'account-1', message_id => $receipt->{message_id},
  );
  $store->disconnect;

=head1 DESCRIPTION

One local SQLite database owns message records, exact raw BLOBs and private
submission envelopes. Acceptance returns only after the transaction commits.
A repeated mailbox-scoped idempotency key returns the original receipt only for
the identical item. Content hashes share storage; they do not deduplicate logical
messages. RFC Message-ID is opaque message content and has no uniqueness role.

=head1 SUBROUTINES/METHODS

=head2 new

Accepts named arguments or a hash reference. Required C<path> is an absolute local
filename without semicolons or controls. The parent directory must exist and be
private to the application. New or empty databases are initialized; unknown
schema versions and nonempty foreign databases are rejected.

=head2 BUILD

Moo initialization callback; opens the database and verifies required settings.

=head2 path

Returns the configured local database filename.

=head2 max_message_bytes

The positive acceptance size limit, default 10485760. Existing stored messages
can be read after lowering this limit. Envelopes use Envelope's default limits.

=head2 accept_item

Named arguments C<mailbox_id>, C<idempotency_key> and C<item> are required. Both IDs
are 1-128 ASCII characters: an alphanumeric first character, then alphanumeric,
dot, underscore, colon or hyphen. Item is RawMessage (opaque inbound content,
no envelope) or Submission (finalized outbound content plus private envelope).
Returns a new hash containing C<message_id> and C<content_sha256>. Separate keys
create separate message records, even when the bytes and Message-ID are equal.
Submission sender, recipient order and duplicate recipients are persisted; a
change to any of them conflicts with reuse of an existing idempotency key.

=head2 load

Takes C<mailbox_id> and a positive C<message_id> of at most 18 decimal digits.
Returns nothing if absent in that mailbox, otherwise a fresh hash with receipt
fields, a RawMessage in C<message>, and an Envelope in C<envelope> for submissions
(or undef for raw inbound content). This is a trusted, private application API:
the returned envelope can include blind recipients. Never expose it to recipients.
Content and envelope integrity are checked before returning a record.

=head2 disconnect

Disconnects; repeated calls are harmless. Further acceptance and reads fail.

=head1 DIAGNOSTICS

Invalid inputs, key conflicts, missing/corrupt content and database failures
throw value-free exceptions. DBI diagnostics are sanitized to avoid logging
message bytes, addresses or SQL parameters. A rollback failure invalidates the
connection; reopen before continuing.

=head1 CONFIGURATION AND ENVIRONMENT

Uses DELETE journaling, synchronous EXTRA, enforced foreign keys and a 2500 ms
busy timeout. Transactions acquire an immediate lock, including snapshot reads.
Use one Store per process; close before forking and reopen afterward. No DSN,
SQLite URI or ephemeral in-memory database is accepted. No environment is read.

=head1 DEPENDENCIES

Perl 5.40, strictures, Moo, DBI, DBD::SQLite, Digest::SHA and JSON.

=head1 INCOMPATIBILITIES

Schema version 1 only; no migration, external blob store or second mailbox
owner. Use a supported local SQLite filesystem; network filesystems are outside
this contract. Durability depends on SQLite, its VFS, filesystem and hardware.
Process-interruption tests are not power-loss or hardware-failure certification.

=head1 BUGS AND LIMITATIONS

No authentication, authorization, relay policy, delivery, outbox, message flags,
mailbox listing, deletion, quotas, encryption or backup API. Mailbox-scoped lookup
is not authorization. Trusted callers must authorize every operation and protect
the database and journal files. Logical IDs are local to this database, not global
transport IDs. Content hashes and IDs are not access credentials. Direct private
object/database changes are outside the application API trust boundary.

=head1 AUTHOR

Overnet Mail contributors.

=head1 LICENSE AND COPYRIGHT

GPL version 3; see the LICENSE file distributed with this software.

=cut
