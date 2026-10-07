use strictures 2;

use Config;
use DBI         qw(SQL_BLOB);
use File::Copy  qw(copy);
use File::Temp  qw(tempdir);
use JSON        ();
use Digest::SHA qw(sha256_hex);
use POSIX       ();
use Test2::V0;
use Overnet::Mail::Store;

my $dir = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my $raw        = Overnet::Mail::RawMessage->new(raw_bytes => "Subject: recovery\r\n\r\n" . ("\0\xff" x 50_000));
my $submission = Overnet::Mail::Submission->new(
  message  => $raw,
  envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test', 'blind@example.test'])
);

for my $table (qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries)) {
  my $store = Overnet::Mail::Store->new(path => "$dir/failure-$table.db");
  my $when  = $table eq 'deliveries' ? 'WHEN NEW.position = 1' : q{};
  $store->_dbh->do(
"CREATE TEMP TRIGGER fail_insert BEFORE INSERT ON $table $when BEGIN SELECT RAISE(ABORT, 'blind\@example.test secret'); END"
  );
  my $error = dies { enqueue($store) };
  like $error, $table =~ /\Ablossom_/ ? qr/blob operation failed/ : qr/database operation failed/,
    'insert failure aborts enqueue';
  unlike $error, qr/blind\@|secret/, 'failure hides recipient and trigger details';
  is counts($store), [0, 0, 0, 0, 0, 0], 'acceptance and complete recipient queue roll back together';
  $store->_dbh->do('DROP TRIGGER fail_insert');
  ok enqueue($store), 'same key succeeds after failure';
  is counts($store), [1, 1, 1, 2, 1, 2], 'successful retry has exactly one queue';
  $store->disconnect;
}
my $store = Overnet::Mail::Store->new(path => "$dir/commit.db");
{
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { enqueue($store) }, qr/commit interrupted/, 'enqueue returns no receipt when commit fails';
}
$store->_dbh->{Callbacks} = {};
is counts($store), [0, 0, 0, 0, 0, 0], 'failed commit rolls back queue and message together';
my $receipt = enqueue($store);
{
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { $store->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1) }, qr/commit interrupted/,
    'failed claim commit returns no lease';
}
$store->_dbh->{Callbacks} = {};
is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{attempt}, 0,
  'failed claim does not consume attempt';
my $claim = $store->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
{
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { finish($store, $claim, 0) }, qr/commit interrupted/, 'failed finish commit does not report delivered';
}
$store->_dbh->{Callbacks} = {};
is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0]->{state}, 'leased',
  'failed finish preserves prior lease';
{
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { $store->claim_delivery(mailbox_id => 'box', now => 1, lease_seconds => 1) }, qr/commit interrupted/,
    'expiry and next claim commit atomically';
}
$store->_dbh->{Callbacks} = {};
my $unchanged = $store->deliveries(mailbox_id => 'box', submission_id => 1)->[0];
is [$unchanged->{attempt}, $unchanged->{uncertain_attempts}, $unchanged->{state}], [1, 0, 'leased'],
  'failed expiry transaction does not double-count uncertainty';
$store->disconnect;

# A failed explicit promotion must leave existing archival acceptance untouched.
$store = Overnet::Mail::Store->new(path => "$dir/promotion.db");
$store->accept_item(mailbox_id => 'box', idempotency_key => 'request', item => $submission);
$store->_dbh->do(
q{CREATE TEMP TRIGGER fail_delivery BEFORE INSERT ON deliveries WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'failed'); END}
);
like dies { enqueue($store) }, qr/database operation failed/, 'promotion failure reported';
is counts($store), [1, 1, 1, 2, 0, 0], 'failed promotion retains archive with no partial queue';
$store->_dbh->do('DROP TRIGGER fail_delivery');
ok enqueue($store), 'explicit promotion can retry';

for my $sql (
  q{UPDATE deliveries SET state = 'invented'},
  q{UPDATE deliveries SET state = 'leased'},
  q{UPDATE deliveries SET attempt = 6},
  q{UPDATE deliveries SET attempt = 5},
  q{UPDATE deliveries SET uncertain_attempts = 1},
  q{UPDATE deliveries SET last_outcome = 'invented'},
  q{DELETE FROM recipients},
  q{DELETE FROM submissions},
) {
  like dies { $store->_dbh->do($sql) }, qr/database operation failed/,
    'schema rejects inconsistent queue state or broken reference';
}
$store->disconnect;

# Replaying a damaged queue fails instead of silently creating replacement delivery IDs.
for my $damage ('DELETE FROM deliveries WHERE position = 1', 'UPDATE deliveries SET position = 9 WHERE position = 1') {
  my $file = "$dir/damage-" . length($damage) . '.db';
  $store = Overnet::Mail::Store->new(path => $file);
  enqueue($store);
  $store->disconnect;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1});
  $dbh->do($damage);
  $dbh->disconnect;
  $store = Overnet::Mail::Store->new(path => $file);
  like dies { enqueue($store) }, qr/outbox integrity/, 'replay rejects missing or displaced delivery';

  if ($damage =~ /UPDATE/) {
    my $first = $store->claim_delivery(mailbox_id => 'box', now => 0);
    ok $first, 'first unaffected recipient can be claimed';
    like dies { $store->claim_delivery(mailbox_id => 'box', now => 0) }, qr/outbox integrity/,
      'out-of-range recipient cannot be dispatched';
  }
  $store->disconnect;
}

# Version 1 is explicitly rejected, with all existing content and markers preserved.
my $legacy = "$dir/version-one.db";
my $dbh    = DBI->connect("dbi:SQLite:dbname=$legacy", q{}, q{}, {RaiseError => 1});
$dbh->do(
'CREATE TABLE contents (content_sha256 TEXT PRIMARY KEY NOT NULL, raw_bytes BLOB NOT NULL CHECK(typeof(raw_bytes) = \'blob\'), size_bytes INTEGER NOT NULL CHECK(size_bytes > 0 AND length(raw_bytes) = size_bytes))'
);
$dbh->do(
'CREATE TABLE messages (message_id INTEGER PRIMARY KEY AUTOINCREMENT, mailbox_id TEXT NOT NULL, idempotency_key TEXT NOT NULL, content_sha256 TEXT NOT NULL REFERENCES contents(content_sha256), sender TEXT, signature TEXT NOT NULL, UNIQUE(mailbox_id, idempotency_key))'
);
$dbh->do('CREATE INDEX messages_content ON messages(content_sha256)');
$dbh->do(
'CREATE TABLE recipients (message_id INTEGER NOT NULL REFERENCES messages(message_id), position INTEGER NOT NULL CHECK(position >= 0), address TEXT NOT NULL, PRIMARY KEY(message_id, position))'
);
my $insert = $dbh->prepare('INSERT INTO contents VALUES (?, ?, ?)');
$insert->bind_param(1, $raw->content_sha256);
$insert->bind_param(2, $raw->raw_bytes, SQL_BLOB);
$insert->bind_param(3, $raw->size_bytes);
$insert->execute;
my $signature = sha256_hex(JSON->new->encode([$raw->content_sha256, q{}, $submission->envelope->recipients]));
$dbh->do('INSERT INTO messages VALUES (1, ?, ?, ?, ?, ?)',
  undef, 'box', 'request', $raw->content_sha256, q{}, $signature);

for my $position (0, 1) {
  $dbh->do('INSERT INTO recipients VALUES (1, ?, ?)', undef, $position, 'blind@example.test');
}
$dbh->do('PRAGMA user_version = 1');
$dbh->do('PRAGMA application_id = 1330463049');
my $schema_before = $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name');
$dbh->disconnect;
like dies { Overnet::Mail::Store->new(path => $legacy) }, qr/unsupported mail store schema/,
  'version-one archive cannot be implicitly migrated or enqueued';
$dbh = DBI->connect("dbi:SQLite:dbname=$legacy", q{}, q{}, {RaiseError => 1});
is $dbh->selectrow_array('PRAGMA user_version'), 1, 'rejection preserves old schema version';
is $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name'), $schema_before,
  'rejection does not alter legacy schema';
is $dbh->selectrow_array('SELECT raw_bytes FROM contents'), $raw->raw_bytes, 'rejection preserves every legacy byte';
is $dbh->selectall_arrayref('SELECT * FROM messages'), [[1, 'box', 'request', $raw->content_sha256, q{}, $signature]],
  'rejection preserves legacy logical acceptance';
is $dbh->selectall_arrayref('SELECT * FROM recipients ORDER BY position'),
  [[1, 0, 'blind@example.test'], [1, 1, 'blind@example.test']], 'rejection preserves private recipients';
$dbh->disconnect;

# Version 2's archived content and live/settled outbox also remain untouched.
my $legacy_two = "$dir/version-two.db";
copy($legacy, $legacy_two) or die 'legacy fixture copy failed';
$dbh = DBI->connect("dbi:SQLite:dbname=$legacy_two", q{}, q{}, {RaiseError => 1});
$dbh->do(<<'SUBMISSIONS');
CREATE TABLE submissions (
      submission_id INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id INTEGER NOT NULL UNIQUE REFERENCES messages(message_id)
)
SUBMISSIONS
$dbh->do(<<'DELIVERIES');
CREATE TABLE deliveries (
      delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
      message_id INTEGER NOT NULL REFERENCES submissions(message_id),
      position INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'ready'
        CHECK(state IN ('ready', 'leased', 'deferred', 'uncertain', 'delivered', 'failed', 'exhausted')),
      attempt INTEGER NOT NULL DEFAULT 0 CHECK(attempt BETWEEN 0 AND 5),
      next_attempt_at INTEGER NOT NULL DEFAULT 0 CHECK(next_attempt_at >= 0),
      lease_until INTEGER,
      uncertain_attempts INTEGER NOT NULL DEFAULT 0 CHECK(uncertain_attempts BETWEEN 0 AND attempt),
      last_outcome TEXT CHECK(last_outcome IN ('confirmed', 'transient', 'permanent', 'uncertain', 'lease_expired')),
      UNIQUE(message_id, position),
      FOREIGN KEY(message_id, position) REFERENCES recipients(message_id, position),
      CHECK((state = 'leased' AND lease_until IS NOT NULL AND lease_until >= 0 AND attempt > 0)
        OR (state != 'leased' AND lease_until IS NULL)),
      CHECK(state NOT IN ('ready', 'deferred', 'uncertain') OR attempt < 5)
)
DELIVERIES
$dbh->do('CREATE INDEX deliveries_due ON deliveries(state, next_attempt_at, delivery_id)');
$dbh->do('INSERT INTO submissions (message_id) VALUES (1)');
$dbh->do(
q{INSERT INTO deliveries (message_id, position, state, attempt, last_outcome) VALUES (1, 0, 'delivered', 1, 'confirmed')}
);
$dbh->do(
q{INSERT INTO deliveries (message_id, position, state, attempt, lease_until, uncertain_attempts, last_outcome) VALUES (1, 1, 'leased', 2, 500, 1, 'lease_expired')}
);
$dbh->do('PRAGMA user_version = 2');
my $v2_schema_before = $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name');
my %v2_rows_before   = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY rowid") }
  qw(contents messages recipients submissions deliveries sqlite_sequence);
$dbh->disconnect;
like dies { Overnet::Mail::Store->new(path => $legacy_two) }, qr/unsupported mail store schema/,
  'version-two outbox cannot be implicitly migrated or enqueued';
$dbh = DBI->connect("dbi:SQLite:dbname=$legacy_two", q{}, q{}, {RaiseError => 1});
is $dbh->selectrow_array('PRAGMA user_version'),   2,             'rejection preserves version-two schema marker';
is $dbh->selectrow_array('PRAGMA application_id'), 1_330_463_049, 'rejection preserves version-two application marker';
is $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name'), $v2_schema_before,
  'rejection preserves the complete version-two schema';

for my $table (sort keys %v2_rows_before) {
  is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY rowid"), $v2_rows_before{$table},
    "version-two rejection preserves $table rows exactly";
}
$dbh->disconnect;

SKIP: {
  skip 'fork unavailable on this platform', 40 if !$Config{d_fork};

  # No live parent connection crosses fork. Interruption occurs before disconnect/rollback.
  for my $stage (qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries commit)) {
    my $file    = "$dir/crash-$stage.db";
    my $initial = Overnet::Mail::Store->new(path => $file);
    $initial->disconnect;
    my $pid = fork();
    die "fork: $!" if !defined $pid;
    if (!$pid) {
      my $child = Overnet::Mail::Store->new(path => $file);
      $child->_dbh->do('PRAGMA cache_size=2');
      if ($stage eq 'commit') {
        $child->_dbh->sqlite_commit_hook(sub { POSIX::_exit(71) });
      } else {
        $child->_dbh->sqlite_create_function('interrupt_process', 0, sub { POSIX::_exit(71) });
        my $when = $stage eq 'deliveries' ? 'WHEN NEW.position = 1' : q{};
        $child->_dbh->do(
          "CREATE TEMP TRIGGER interrupt_insert AFTER INSERT ON $stage $when BEGIN SELECT interrupt_process(); END");
      }
      enqueue($child);
      POSIX::_exit(72);
    }
    waitpid $pid, 0;
    is $? >> 8, 71, "process interrupted at $stage";
    my $reopened = Overnet::Mail::Store->new(path => $file);
    is counts($reopened), [0, 0, 0, 0, 0, 0], 'unacknowledged pre-commit queue fully rolls back';
    ok enqueue($reopened), 'interrupted enqueue can be retried with same key';
    $reopened->disconnect;
  }
  for my $stage (qw(enqueue claim finish)) {
    my $file = "$dir/lost-ack-$stage.db";
    my $pid  = fork();
    die "fork: $!" if !defined $pid;
    if (!$pid) {
      my $child = Overnet::Mail::Store->new(path => $file);
      enqueue($child);
      if ($stage ne 'enqueue') {
        my $claimed = $child->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
        finish($child, $claimed, 0) if $stage eq 'finish';
      }
      POSIX::_exit(73);
    }
    waitpid $pid, 0;
    my $reopened = Overnet::Mail::Store->new(path => $file);
    is enqueue($reopened)->{delivery_ids}, [1, 2], 'post-commit exit preserves original enqueue receipt';
    my $rows = $reopened->deliveries(mailbox_id => 'box', submission_id => 1);
    is $rows->[0]->{state}, $stage eq 'enqueue' ? 'ready' : $stage eq 'claim' ? 'leased' : 'delivered',
      "lost $stage acknowledgement retains committed state";
    if ($stage eq 'claim') {
      $reopened->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
      my $recovered = $reopened->claim_delivery(mailbox_id => 'box', now => 1);
      is $recovered->{delivery_id},        1, 'lost claim acknowledgement does not delete the recipient';
      is $recovered->{attempt},            2, 'lost claim acknowledgement recovers after expiry with new fence';
      is $recovered->{uncertain_attempts}, 1, 'lost claim acknowledgement remains uncertain';
    }
    $reopened->disconnect;
  }

  # Abrupt interruption after a state UPDATE still cannot expose an uncommitted lease/outcome.
  for my $stage (qw(claim finish)) {
    my $file    = "$dir/crash-update-$stage.db";
    my $initial = Overnet::Mail::Store->new(path => $file);
    enqueue($initial);
    $initial->disconnect;
    my $pid = fork();
    die "fork: $!" if !defined $pid;
    if (!$pid) {
      my $child = Overnet::Mail::Store->new(path => $file);
      my $claimed;
      $claimed = $child->claim_delivery(mailbox_id => 'box', now => 0) if $stage eq 'finish';
      $child->_dbh->sqlite_create_function('interrupt_process', 0, sub { POSIX::_exit(74) });
      $child->_dbh->do(
        'CREATE TEMP TRIGGER interrupt_update AFTER UPDATE ON deliveries BEGIN SELECT interrupt_process(); END');
      if ($stage eq 'claim') {
        $child->claim_delivery(mailbox_id => 'box', now => 0);
      } else {
        finish($child, $claimed, 0);
      }
      POSIX::_exit(75);
    }
    waitpid $pid, 0;
    is $? >> 8, 74, "process interrupted during $stage update";
    my $reopened = Overnet::Mail::Store->new(path => $file);
    my $row      = $reopened->deliveries(mailbox_id => 'box', submission_id => 1)->[0];
    is $row->{state},   $stage eq 'claim' ? 'ready' : 'leased', 'uncommitted state update is rolled back';
    is $row->{attempt}, $stage eq 'claim' ? 0       : 1,        'only previously committed attempt remains';
    $reopened->disconnect;
  }

  # Multiple processes compete for one mailbox and may never claim the same live attempt.
  my $file    = "$dir/concurrent.db";
  my $initial = Overnet::Mail::Store->new(path => $file);
  $initial->disconnect;
  my @children;
  for (1 .. 6) {
    my $pid = fork();
    die "fork: $!" if !defined $pid;
    if (!$pid) {
      my $child    = Overnet::Mail::Store->new(path => $file);
      my $accepted = enqueue($child);
      POSIX::_exit(75) if $accepted->{submission_id} != 1;
      my $claimed = $child->claim_delivery(mailbox_id => 'box', now => 0, lease_seconds => 1);
      $child->disconnect;
      POSIX::_exit($claimed ? $claimed->{delivery_id} : 0);
    }
    push @children, $pid;
  }
  my @statuses;
  for my $pid (@children) {
    waitpid $pid, 0;
    push @statuses, $? >> 8;
  }
  is [sort { $a <=> $b } @statuses], [0, 0, 0, 0, 1, 2],
    'racing enqueue and claims produce exactly one lease for each recipient';
  my $reopened = Overnet::Mail::Store->new(path => $file);
  is counts($reopened), [1, 1, 1, 2, 1, 2], 'concurrent idempotent enqueues create one queue';
  my $reclaimed = $reopened->claim_delivery(mailbox_id => 'box', now => 1, lease_seconds => 1);
  is $reclaimed->{attempt},            2, 'post-crash lease can be reclaimed once';
  is $reclaimed->{uncertain_attempts}, 1, 'reclaim preserves unknown outcome';
  $reopened->disconnect;
}

done_testing;

sub enqueue {
  my ($storage) = @_;
  return $storage->enqueue_submission(mailbox_id => 'box', idempotency_key => 'request', item => $submission);
}

sub finish {
  my ($storage, $claimed, $now) = @_;
  return $storage->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $claimed->{delivery_id},
    attempt     => $claimed->{attempt},
    now         => $now,
    outcome     => 'confirmed'
  );
}

sub counts {
  my ($storage) = @_;
  return [map { $storage->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") }
      qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries)];
}
