use strictures 2;

use Config;
use DBI        qw(SQL_BLOB);
use File::Temp qw(tempdir);
use POSIX      ();
use Test2::V0;
use Overnet::Mail::Store;

my $dir        = tempdir(CLEANUP => 1);
my $raw        = Overnet::Mail::RawMessage->new(raw_bytes => "Subject: recovery\r\n\r\n\0\xfforiginal");
my $submission = Overnet::Mail::Submission->new(
  message  => $raw,
  envelope => Overnet::Mail::Envelope->new(sender => 'sender@example.test', recipients => ['blind@example.test'])
);

# A late SQL failure must roll back the BLOB, logical message and all recipients.
my $store = Overnet::Mail::Store->new(path => "$dir/rollback.db");
$store->_dbh->do(
q{CREATE TRIGGER fail_recipient BEFORE INSERT ON recipients BEGIN SELECT RAISE(ABORT, 'blind@example.test secret'); END}
);
my $error = dies { accept_item($store, $submission) };
like $error,   qr/database operation failed/,  'late recipient insertion failure reported';
unlike $error, qr/blind\@|secret|INSERT INTO/, 'driver errors omit sensitive SQL and trigger values';
is counts($store), [0, 0, 0], 'all acceptance rows rolled back together';
$store->_dbh->do('DROP TRIGGER fail_recipient');
my $receipt = accept_item($store, $submission);
is counts($store), [1, 1, 1], 'retry succeeds after rollback using same key';
$store->disconnect;

# Corruption, including a missing blob, must fail instead of accepting phantom success.
my @damage = (
  [q{UPDATE contents SET raw_bytes = CAST('different' AS BLOB), size_bytes = 9}, qr/content integrity/],
  [q{PRAGMA ignore_check_constraints=ON}, qr/content integrity/, q{UPDATE contents SET size_bytes = 1}],
  [
    q{PRAGMA ignore_check_constraints=ON},
    qr/content integrity/,
    q{UPDATE contents SET raw_bytes = CAST(raw_bytes AS TEXT)}
  ],
  [q{PRAGMA foreign_keys=OFF},                                qr/content is missing/, q{DELETE FROM contents}],
  [q{DELETE FROM recipients},                                 qr/envelope integrity/],
  [q{UPDATE recipients SET address = 'changed@example.test'}, qr/envelope integrity/],
  [q{UPDATE messages SET sender = 'changed@example.test'},    qr/envelope integrity/],
);
my $index = 0;
for my $case (@damage) {
  my $file  = "$dir/damage-" . ++$index . '.db';
  my $db    = Overnet::Mail::Store->new(path => $file);
  my $saved = accept_item($db, $submission);
  $db->disconnect;
  my $direct = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1});
  $direct->do($case->[0]);
  $direct->do($case->[2]) if defined $case->[2];
  $direct->disconnect;
  $db = Overnet::Mail::Store->new(path => $file);
  like dies { $db->load(mailbox_id => 'box', message_id => $saved->{message_id}) }, $case->[1],
    'corrupt read fails closed';
  like dies { accept_item($db, $submission) }, $case->[1], 'idempotent replay verifies persisted integrity';

  if ($index <= 4) {
    like dies { $db->accept_item(mailbox_id => 'box', idempotency_key => 'new', item => $submission) }, $case->[1],
      'shared content must validate before a new reference is accepted';
  }
  $db->disconnect;
}

# SQLite foreign keys prevent ordinary orphan creation.
$store = Overnet::Mail::Store->new(path => "$dir/rollback.db");
like dies { $store->_dbh->do('DELETE FROM contents') }, qr/database operation failed/, 'foreign key rejects orphan';

# A simulated digest collision must not alias unequal raw bytes.
{
  my $digest    = $raw->content_sha256;
  my $collision = mock 'Overnet::Mail::RawMessage' => override => [content_sha256 => sub { return $digest }];
  like dies {
    $store->accept_item(
      mailbox_id      => 'box',
      idempotency_key => 'collision',
      item            => Overnet::Mail::RawMessage->new(raw_bytes => 'unequal bytes')
    )
  }, qr/content conflicts/, 'content address reuse still compares the exact bytes';
}

# Refuse to open when SQLite cannot supply the required durability/constraint settings.
for my $pragma ('PRAGMA synchronous', 'PRAGMA foreign_keys') {
  my $connect = DBI->can('connect');
  my $fault   = mock 'DBI' => override => [
    connect => sub {
      my $dbh = $connect->(@_);
      $dbh->{Callbacks} = {
        selectrow_array => sub {
          if ($_[1] eq $pragma) {
            undef $_;
            return 0;
          }
          return;
        }
      };
      return $dbh;
    }
  ];
  like dies { Overnet::Mail::Store->new(path => "$dir/unavailable.db") }, qr/durability settings unavailable/,
    'unavailable required setting fails closed';
}

# Force begin/commit/rollback failures through DBI callbacks, without altering the application API.
{
  local $store->_dbh->{Callbacks} = {begin_work => sub { die "begin interrupted\n" }};
  like dies { accept_item($store, $submission) }, qr/begin interrupted/,
    'begin failure does not attempt invalid rollback';
}
{
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { $store->accept_item(mailbox_id => 'box', idempotency_key => 'new', item => $submission) },
    qr/commit interrupted/,
    'commit failure is not reported as acceptance';
}
is counts($store), [1, 1, 1], 'commit failure was rolled back';
{
  local $store->_dbh->{Callbacks} = {
    commit   => sub { die "commit interrupted\n" },
    rollback => sub { die "rollback interrupted\n" },
  };
  like dies { accept_item($store, $submission) }, qr/rollback failed; reopen required/,
    'failed rollback invalidates handle';
}
like dies { $store->load(mailbox_id => 'box', message_id => 1) }, qr/store is closed/,
  'failed transaction handle cannot be reused';
$store->disconnect;

# Process-interruption coverage: close all parent handles before fork, and reopen only in the child.
SKIP: {
  skip 'fork unavailable on this platform', 19 if !$Config{d_fork};
  my $large = Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => "Subject: crash\r\n\r\n" . ('x' x 200_000)),
    envelope => $submission->envelope,
  );
  for my $stage (qw(contents messages recipients commit)) {
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
        $child->_dbh->do(
          "CREATE TEMP TRIGGER interrupt_insert AFTER INSERT ON $stage BEGIN SELECT interrupt_process(); END");
      }
      accept_item($child, $large);
      POSIX::_exit(72);
    }
    waitpid $pid, 0;
    is $? >> 8, 71, "process interrupted during $stage stage";
    my $reopened = Overnet::Mail::Store->new(path => $file);
    is counts($reopened), [0, 0, 0], "no partial acceptance survives $stage interruption";
    ok accept_item($reopened, $large), "same key can retry after $stage interruption";
    is $reopened->load(mailbox_id => 'box', message_id => 1)->{message}->raw_bytes, $large->message->raw_bytes,
      "retry after $stage restores exact content";
    $reopened->disconnect;
  }
  my $file = "$dir/ack-lost.db";
  my $pid  = fork();
  die "fork: $!" if !defined $pid;
  if (!$pid) {
    my $child = Overnet::Mail::Store->new(path => $file);
    accept_item($child, $submission);
    POSIX::_exit(73);
  }
  waitpid $pid, 0;
  my $reopened = Overnet::Mail::Store->new(path => $file);
  is accept_item($reopened, $submission)->{message_id}, 1,
    'commit survives process exit; lost-ack replay returns original ID';
  $reopened->disconnect;

  my $concurrent_file = "$dir/concurrent.db";
  my $initial         = Overnet::Mail::Store->new(path => $concurrent_file);
  $initial->disconnect;
  my @children;
  for (1 .. 6) {
    my $child_pid = fork();
    die "fork: $!" if !defined $child_pid;
    if (!$child_pid) {
      my $child    = Overnet::Mail::Store->new(path => $concurrent_file);
      my $accepted = accept_item($child, $submission);
      $child->disconnect;
      POSIX::_exit($accepted->{message_id} == 1 ? 0 : 74);
    }
    push @children, $child_pid;
  }
  my @statuses;
  for my $child_pid (@children) {
    waitpid $child_pid, 0;
    push @statuses, $?;
  }
  is \@statuses, [(0) x 6], 'concurrent same-key callers all observe the original logical ID';
  my $concurrent = Overnet::Mail::Store->new(path => $concurrent_file);
  is counts($concurrent), [1, 1, 1], 'concurrent retries persist one acceptance and envelope';
  $concurrent->disconnect;
}

done_testing;

sub accept_item {
  my ($storage, $item) = @_;
  return $storage->accept_item(mailbox_id => 'box', idempotency_key => 'request', item => $item);
}

sub counts {
  my ($storage) = @_;
  return [map { $storage->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") } qw(contents messages recipients)];
}
