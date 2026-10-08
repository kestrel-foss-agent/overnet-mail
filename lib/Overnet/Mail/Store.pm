package Overnet::Mail::Store;

use strictures 2;
use Moo;

use Carp                                           qw(croak);
use DBI                                            ();
use DBD::SQLite                                    ();
use Digest::SHA                                    qw(sha256_hex);
use English                                        qw(-no_match_vars);
use File::Spec                                     ();
use JSON                                           ();
use Scalar::Util                                   qw(blessed);
use Net::Blossom::Server::Backend::SQLite 0.001004 ();
use Net::Blossom::Server::Backend::SQLite::BlobStore;
use Net::Blossom::Server::Backend::SQLite::MetadataStore;
use Overnet::Mail::Envelope;
use Overnet::Mail::RawMessage;
use Overnet::Mail::Submission;

our $VERSION = '0.001';

has path              => (is => 'ro', required => 1);
has max_message_bytes => (is => 'ro', default  => sub { return 10_485_760 });
has _dbh              => (is => 'ro', init_arg => undef);
has _blob_store       => (is => 'ro', init_arg => undef);
has _metadata_store   => (is => 'ro', init_arg => undef);

sub BUILD {
  my ($self) = @_;
  my $limit = $self->max_message_bytes;
  if (!defined $limit || ref $limit || $limit !~ /\A[1-9][0-9]*\z/smx) {
    croak 'max_message_bytes must be a positive integer';
  }
  $self->_open_storage;
  $self->_transaction(sub { $self->_initialize; return 1 });
  return;
}

sub _open_storage {
  my ($self) = @_;
  my $path = $self->path;
  if (!defined $path || ref $path || $path =~ /[;\x00-\x1f\x7f]/smx || !File::Spec->file_name_is_absolute($path)) {
    croak 'path must be an absolute local filename without controls or semicolons';
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
  $self->{_blob_store}     = Net::Blossom::Server::Backend::SQLite::BlobStore->new(dbh => $dbh);
  $self->{_metadata_store} = Net::Blossom::Server::Backend::SQLite::MetadataStore->new(dbh => $dbh);
  return;
}

sub _initialize {
  my ($self)      = @_;
  my $dbh         = $self->_dbh;
  my $version     = $dbh->selectrow_array('PRAGMA user_version');
  my $application = $dbh->selectrow_array('PRAGMA application_id');
  return if $version == 3 && $application == 1_330_463_049;
  my $tables = $dbh->selectrow_array('SELECT COUNT(*) FROM sqlite_master');
  if ($version || $application || $tables) {
    croak 'unsupported mail store schema';
  }
  $self->_blob_store->deploy_schema;
  $self->_metadata_store->deploy_schema;
  $self->_deploy_mail_tables('INTEGER PRIMARY KEY AUTOINCREMENT', 'INTEGER');
  $dbh->do('PRAGMA application_id = 1330463049');
  $dbh->do('PRAGMA user_version = 3');
  return;
}

sub _deploy_mail_tables {
  my ($self, $primary_key, $integer) = @_;
  my $dbh = $self->_dbh;
  for my $sql (
    <<"MESSAGES",
CREATE TABLE messages (
      message_id $primary_key,
      mailbox_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      content_sha256 TEXT NOT NULL REFERENCES blossom_blobs(sha256)
        REFERENCES blossom_blob_data(storage_key),
      sender TEXT,
      signature TEXT NOT NULL,
      UNIQUE(mailbox_id, idempotency_key)
)
MESSAGES
    'CREATE INDEX messages_content ON messages(content_sha256)',
    <<"RECIPIENTS",
CREATE TABLE recipients (
      message_id $integer NOT NULL REFERENCES messages(message_id),
      position $integer NOT NULL CHECK(position >= 0),
      address TEXT NOT NULL,
      PRIMARY KEY(message_id, position)
)
RECIPIENTS
    <<"SUBMISSIONS",
CREATE TABLE submissions (
      submission_id $primary_key,
      message_id $integer NOT NULL UNIQUE REFERENCES messages(message_id)
)
SUBMISSIONS
    <<"DELIVERIES",
CREATE TABLE deliveries (
      delivery_id $primary_key,
      message_id $integer NOT NULL REFERENCES submissions(message_id),
      position $integer NOT NULL,
      state TEXT NOT NULL DEFAULT 'ready'
        CHECK(state IN ('ready', 'leased', 'deferred', 'uncertain', 'delivered', 'failed', 'exhausted')),
      attempt $integer NOT NULL DEFAULT 0 CHECK(attempt BETWEEN 0 AND 5),
      next_attempt_at $integer NOT NULL DEFAULT 0 CHECK(next_attempt_at >= 0),
      lease_until $integer,
      uncertain_attempts $integer NOT NULL DEFAULT 0 CHECK(uncertain_attempts BETWEEN 0 AND attempt),
      last_outcome TEXT CHECK(last_outcome IN ('confirmed', 'transient', 'permanent', 'uncertain', 'lease_expired')),
      UNIQUE(message_id, position),
      FOREIGN KEY(message_id, position) REFERENCES recipients(message_id, position),
      CHECK((state = 'leased' AND lease_until IS NOT NULL AND lease_until >= 0 AND attempt > 0)
        OR (state != 'leased' AND lease_until IS NULL)),
      CHECK(state NOT IN ('ready', 'deferred', 'uncertain') OR attempt < 5)
)
DELIVERIES
    'CREATE INDEX deliveries_due ON deliveries(state, next_attempt_at, delivery_id)',
  ) {
    $dbh->do($sql);
  }
  return;
}

sub accept_item {
  my ($self, %args) = @_;
  my @item = $self->_acceptance_args(\%args);
  return $self->_transaction(sub { return $self->_accept_item(\%args, @item) });
}

sub _acceptance_args {
  my ($self, $args) = @_;
  _token($args->{mailbox_id});
  _token($args->{idempotency_key});
  return $self->_item($args->{item});
}

sub _accept_item {
  my ($self, $args, $message, $envelope) = @_;
  my $sha        = $message->content_sha256;
  my $sender     = $envelope ? $envelope->sender     : undef;
  my $recipients = $envelope ? $envelope->recipients : [];
  my $signature  = _signature($sha, $sender, $recipients);
  my $dbh        = $self->_dbh;
  my $existing   = $dbh->selectrow_hashref(
    'SELECT * FROM messages WHERE mailbox_id = ? AND idempotency_key = ?',
    undef, $args->{mailbox_id}, $args->{idempotency_key},
  );
  if ($existing) {
    my $stored = $self->_record($existing);
    if ( $existing->{signature} ne $signature
      || $stored->{message}->raw_bytes ne $message->raw_bytes) {
      croak 'idempotency key conflicts with accepted item';
    }
    return _receipt($existing);
  }
  $self->_store_content($message);
  $dbh->do(
    'INSERT INTO messages (mailbox_id, idempotency_key, content_sha256, sender, signature) VALUES (?, ?, ?, ?, ?)',
    undef, $args->{mailbox_id}, $args->{idempotency_key},
    $sha,  $sender,             $signature,
  );
  my $id       = $self->_insert_id('messages', 'message_id');
  my $position = 0;
  for my $address (@{$recipients}) {
    $dbh->do('INSERT INTO recipients (message_id, position, address) VALUES (?, ?, ?)',
      undef, $id, $position, $address);
    ++$position;
  }
  return {message_id => $id, content_sha256 => $sha};
}

sub enqueue_submission {
  my ($self, %args) = @_;
  if ( !blessed($args{item})
    || !$args{item}->isa('Overnet::Mail::Submission')) {
    croak 'enqueue_submission requires a finalized Submission';
  }
  my @item = $self->_acceptance_args(\%args);
  return $self->_transaction(
    sub {
      my $receipt = $self->_accept_item(\%args, @item);
      my $dbh     = $self->_dbh;
      my $id      = $receipt->{message_id};
      my $submission_id =
        $dbh->selectrow_array('SELECT submission_id FROM submissions WHERE message_id = ?', undef, $id);
      if (!$submission_id) {
        $dbh->do('INSERT INTO submissions (message_id) VALUES (?)', undef, $id);
        $submission_id = $self->_insert_id('submissions', 'submission_id');
        $dbh->do(
'INSERT INTO deliveries (message_id, position) SELECT message_id, position FROM recipients WHERE message_id = ? ORDER BY position',
          undef, $id
        );
      }
      my $rows =
        $dbh->selectall_arrayref('SELECT delivery_id, position FROM deliveries WHERE message_id = ? ORDER BY position',
        {Slice => {}}, $id);
      my $count = scalar @{$item[1]->recipients};
      if (@{$rows} != $count) {
        croak 'stored outbox integrity check failed';
      }
      my @ids;
      for my $position (0 .. $count - 1) {
        if ($rows->[$position]->{position} != $position) {
          croak 'stored outbox integrity check failed';
        }
        push @ids, $rows->[$position]->{delivery_id};
      }
      return {
        %{$receipt},
        submission_id => $submission_id,
        delivery_ids  => \@ids
      };
    }
  );
}

sub deliveries {
  my ($self, %args) = @_;
  _token($args{mailbox_id});
  _queue_integer($args{submission_id}, 1, 999_999_999_999_999_999);
  return $self->_transaction(
    sub {
      return $self->_dbh->selectall_arrayref(
'SELECT d.*, s.submission_id FROM deliveries d JOIN submissions s USING(message_id) JOIN messages m USING(message_id) WHERE m.mailbox_id = ? AND s.submission_id = ? ORDER BY d.position',
        {Slice => {}}, $args{mailbox_id}, $args{submission_id},
      );
    }
  );
}

sub claim_delivery {
  my ($self, %args) = @_;
  _token($args{mailbox_id});
  _queue_integer($args{now}, 0, 9_999_999_999);
  my $duration = exists $args{lease_seconds} ? $args{lease_seconds} : 300;
  _queue_integer($duration, 1, 3_600);
  my $deadline = _deadline($args{now}, $duration);
  return $self->_transaction(
    sub {
      my $dbh = $self->_dbh;
      $dbh->do(
q{UPDATE deliveries SET state = CASE WHEN attempt = 5 THEN 'exhausted' ELSE 'uncertain' END, lease_until = NULL, next_attempt_at = ?, uncertain_attempts = uncertain_attempts + 1, last_outcome = 'lease_expired' WHERE state = 'leased' AND lease_until <= ? AND message_id IN (SELECT message_id FROM messages WHERE mailbox_id = ?)},
        undef, $args{now}, $args{now}, $args{mailbox_id},
      );
      my $row = $dbh->selectrow_hashref(
q{SELECT d.*, s.submission_id FROM deliveries d JOIN submissions s USING(message_id) JOIN messages m USING(message_id) WHERE m.mailbox_id = ? AND d.state IN ('ready', 'deferred', 'uncertain') AND d.next_attempt_at <= ? ORDER BY d.next_attempt_at, d.delivery_id LIMIT 1},
        undef, $args{mailbox_id}, $args{now},
      );
      return if !$row;
      my $message_row =
        $dbh->selectrow_hashref('SELECT * FROM messages WHERE message_id = ?', undef, $row->{message_id});
      my $stored = $self->_record($message_row);
      my $recipient =
        $stored->{envelope}->recipients->[$row->{position}];
      if (!defined $recipient) {
        croak 'stored outbox integrity check failed';
      }
      $dbh->do(q{UPDATE deliveries SET state = 'leased', attempt = attempt + 1, lease_until = ? WHERE delivery_id = ?},
        undef, $deadline, $row->{delivery_id});
      return {
        %{$row},
        state          => 'leased',
        attempt        => $row->{attempt} + 1,
        lease_until    => $deadline,
        message        => $stored->{message},
        content_sha256 => $stored->{content_sha256},
        sender         => $stored->{envelope}->sender,
        recipient      => $recipient
      };
    }
  );
}

sub finish_delivery {
  my ($self, %args) = @_;
  _token($args{mailbox_id});
  _queue_integer($args{delivery_id}, 1, 999_999_999_999_999_999);
  _queue_integer($args{attempt},     1, 5);
  _queue_integer($args{now},         0, 9_999_999_999);
  my %states = (
    confirmed => 'delivered',
    permanent => 'failed',
    transient => 'deferred',
    uncertain => 'uncertain',
  );
  my $outcome = $args{outcome};
  if (!defined $outcome || ref $outcome || !exists $states{$outcome}) {
    croak 'invalid delivery outcome';
  }
  my $retry = $outcome eq 'transient' || $outcome eq 'uncertain';
  my $next  = $args{now};
  if ($retry) {
    _queue_integer($args{retry_after}, 1, 86_400);
    $next = _deadline($args{now}, $args{retry_after});
  } elsif (exists $args{retry_after}) {
    croak 'retry_after requires a retryable outcome';
  }
  return $self->_transaction(
    sub {
      my $row = $self->_dbh->selectrow_hashref(
'SELECT d.*, s.submission_id FROM deliveries d JOIN submissions s USING(message_id) JOIN messages m USING(message_id) WHERE m.mailbox_id = ? AND d.delivery_id = ?',
        undef, $args{mailbox_id}, $args{delivery_id},
      );
      if (!$row
        || $row->{state} ne 'leased'
        || $row->{attempt} != $args{attempt}
        || $row->{lease_until} <= $args{now}) {
        croak 'delivery lease is missing, stale or expired';
      }
      my $state     = $retry && $row->{attempt} == 5 ? 'exhausted' : $states{$outcome};
      my $uncertain = $row->{uncertain_attempts} + ($outcome eq 'uncertain' ? 1 : 0);
      $self->_dbh->do(
'UPDATE deliveries SET state = ?, lease_until = NULL, next_attempt_at = ?, uncertain_attempts = ?, last_outcome = ? WHERE delivery_id = ?',
        undef, $state, $next, $uncertain, $outcome, $args{delivery_id},
      );
      return {
        %{$row},
        state              => $state,
        lease_until        => undef,
        next_attempt_at    => $next,
        uncertain_attempts => $uncertain,
        last_outcome       => $outcome
      };
    }
  );
}

sub _queue_integer {
  my ($value, $min, $max) = @_;
  if (!defined $value
    || ref $value
    || $value !~ /\A(?:0|[1-9][0-9]{0,17})\z/smx
    || $value < $min
    || $value > $max) {
    croak 'queue argument must be a bounded canonical integer';
  }
  return;
}

sub _deadline {
  my ($now, $duration) = @_;
  my $deadline = $now + $duration;
  if ($deadline > 9_999_999_999) {
    croak 'queue deadline exceeds supported clock range';
  }
  return $deadline;
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
  my $dbh = $self->_dbh;
  my $sha = $message->content_sha256;
  $self->_metadata_store->lock_blob($sha);
  if ($self->_metadata_store->find_blob($sha)) {
    if ($self->_content($sha)->raw_bytes ne $message->raw_bytes) {
      croak 'stored content conflicts with accepted bytes';
    }
    return;
  }
  if ( $dbh->selectrow_array('SELECT 1 FROM messages WHERE content_sha256 = ? LIMIT 1', undef, $sha)
    || $dbh->selectrow_array('SELECT 1 FROM blossom_blob_data WHERE storage_key = ?', undef, $sha)) {
    croak 'stored content is missing';
  }
  my $ok = eval {
    my $upload = $self->_blob_store->begin_upload;
    push @{$self->{_uploads}}, $upload;
    $upload->write($message->raw_bytes);
    my %metadata = (
      sha256   => $sha,
      size     => $message->size_bytes,
      type     => 'application/octet-stream',
      uploaded => time,
    );
    my $key = $upload->prepare(%metadata);
    $self->_metadata_store->insert_blob(%metadata, storage_key => $key);
    1;
  };
  croak 'mail store blob operation failed' if !$ok;
  if ($self->_content($sha)->raw_bytes ne $message->raw_bytes) {
    croak 'stored content conflicts with accepted bytes';
  }
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
  my $row = $self->_metadata_store->find_blob($sha);
  croak 'stored content is missing' if !$row;
  my $bytes = $self->_blob_bytes($row->{storage_key});
  croak 'stored content is missing' if !defined $bytes;
  if ( $row->{storage_key} ne $sha
    || $row->{type} ne 'application/octet-stream'
    || $row->{size} !~ /\A[1-9][0-9]*\z/smx
    || length($bytes) != $row->{size}
    || sha256_hex($bytes) ne $sha) {
    croak 'stored content integrity check failed';
  }
  return Overnet::Mail::RawMessage->new(raw_bytes => $bytes, max_bytes => $row->{size});
}

sub _insert_id {
  my ($self) = @_;
  return $self->_dbh->sqlite_last_insert_rowid;
}

sub _blob_bytes {
  my ($self, $key) = @_;
  my $bytes = $self->_blob_store->get_blob($key);
  return if !defined $bytes;
  my $type =
    $self->_dbh->selectrow_array('SELECT typeof(body) FROM blossom_blob_data WHERE storage_key = ?', undef, $key);
  croak 'stored content integrity check failed' if $type ne 'blob';
  return $bytes;
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
  croak 'mail store is closed'                     if !$dbh;
  croak 'mail store transaction is already active' if !$dbh->{AutoCommit};
  $self->{_uploads} = [];
  my $result;
  my $ok = eval {
    $result = $self->_metadata_store->with_transaction($code);
    1;
  };
  my $error = $EVAL_ERROR;
  if (!$ok) {
    my $rolled_back = eval {
      if (!$dbh->{AutoCommit}) {
        $dbh->rollback;
      }
      1;
    };
    my $cleaned = $self->_cleanup_uploads(0);
    if (!$rolled_back) {
      $self->{_dbh} = undef;
      $dbh->disconnect;
      croak 'mail store rollback failed; reopen required';
    }
    croak 'mail store upload cleanup failed; retry the original request key' if !$cleaned;
    croak $error;
  }
  croak 'mail store upload cleanup failed; acceptance committed, retry the original request key'
    if !$self->_cleanup_uploads(1);
  return $result;
}

sub _cleanup_uploads {
  my ($self, $committed) = @_;
  my $ok      = 1;
  my $uploads = delete $self->{_uploads};
  for my $upload (@{$uploads}) {
    my $cleaned = eval { $committed ? $upload->commit : $upload->abort; 1 };
    if (!$cleaned) {
      $ok = 0;
    }
  }
  return $ok;
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

Overnet::Mail::Store - transactional mailbox acceptance on Net::Blossom SQLite storage

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

Net::Blossom SQLite byte and metadata components share one DBI handle with mail
tables. One transaction owns message records, exact raw BLOBs, private
submission envelopes and an explicitly requested per-recipient outbox. Acceptance returns only after the transaction commits.
A repeated mailbox-scoped idempotency key returns the original receipt only for
the identical item. Content hashes share storage; they do not deduplicate logical
messages. RFC Message-ID is opaque message content and has no uniqueness role.

=head1 SUBROUTINES/METHODS

=head2 new

Accepts named arguments or a hash reference. Required C<path> is an absolute local
filename without semicolons or controls. The parent directory must exist and be
private to the application. New or empty databases are initialized; unknown
schema versions and nonempty foreign databases are rejected. Schema version 3
rejects prior mail versions 1 and 2 without migration or alteration. For PostgreSQL,
use L<Overnet::Mail::Store::Postgres>. Filesystem and S3 backends are not supported
by this adapter.

=head2 BUILD

Moo initialization callback; opens the database, constructs shared Net::Blossom
components and verifies required settings.

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
This method archives only; it never queues outbound delivery.

=head2 enqueue_submission

Takes the same arguments as C<accept_item>, but requires a finalized Submission.
Atomically accepts its bytes and private envelope, creates a distinct
C<submission_id> and one C<delivery_id> per ordered recipient (duplicates remain
separate). Returns the acceptance receipt plus C<submission_id> and ordered
C<delivery_ids>. Same-key replay returns stable IDs without resetting delivery
state. An identical archival acceptance can be explicitly promoted with this
method and the same key; C<accept_item> alone never causes a promotion.

=head2 deliveries

Takes C<mailbox_id> and C<submission_id>. Returns a fresh array reference of
recipient state hashes in position order; absent or wrong-mailbox submissions
return an empty array. Status includes C<delivery_id>, C<message_id>,
C<submission_id>, C<position>, C<state>, C<attempt>, C<next_attempt_at>,
C<lease_until>, C<uncertain_attempts> and C<last_outcome>. No addresses or message
bytes are included. This is a trusted diagnostic API, not authorization.

=head2 claim_delivery

Takes C<mailbox_id>, C<now> (integer Unix seconds, 0 through 9999999999), and
optional C<lease_seconds> (1 through 3600, default 300). Atomically expires that
mailbox's elapsed leases, then claims one due recipient, ordered by due time and
delivery ID. Returns nothing if none is available. A claim contains status fields
plus immutable C<message>, C<content_sha256>, C<sender> and just that C<recipient>;
it never returns the entire private envelope. C<attempt> increments and is the
fencing token for subsequent completion. Five claims are allowed per recipient.

Expired leases record C<lease_expired>, increment C<uncertain_attempts>, and
become immediately retryable or C<exhausted> at five attempts. Reclaiming does
not erase ambiguity. This operation performs no network activity.

=head2 finish_delivery

Takes C<mailbox_id>, C<delivery_id>, the claimed C<attempt>, C<now> and C<outcome>.
Only the current, unexpired lease can finish; missing, stale, terminal and
expired attempts fail, including at exactly C<lease_until>. Returns updated
status. Outcomes are C<confirmed> (delivered), C<permanent> (failed),
C<transient> (deferred), and C<uncertain> (explicitly ambiguous). C<confirmed> is
an assertion by the trusted caller of conclusive transport evidence, not a
recipient read receipt. No transport is implemented here.

Transient and uncertain outcomes require C<retry_after>, 1 through 86400 seconds;
terminal outcomes prohibit it. Retryable attempt five becomes C<exhausted>, not
C<failed> or C<delivered>. The last outcome and count of uncertain attempts remain
visible, including after later confirmed delivery. Terminal rows are never
implicitly requeued. No manual requeue, scheduling daemon or bounce exists.

Callers supply trusted, consistent, nondecreasing wall-clock seconds for every
queue operation. Derived deadlines must also fit the supported clock range.
Clock rollback can delay recovery; clock jumps can expire active workers. Leases
and attempt fencing protect local state updates, not an already-started remote
send. Uncertain attempts can cause duplicate Internet deliveries; this API makes
no exactly-once guarantee. See F<docs/transactional-outbox.md>.

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

SQLite schema version 3 only; prior versions are rejected without changing
their data. No migration or external blob store is implemented. Use a supported local SQLite filesystem; network filesystems are outside
this contract. Durability depends on SQLite, its VFS, filesystem and hardware.
Process-interruption tests are not power-loss or hardware-failure certification.

=head1 BUGS AND LIMITATIONS

No authentication, authorization, relay policy, network delivery, message flags,
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
