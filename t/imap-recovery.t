use strictures 2;

use Config;
use DBI        ();
use File::Temp qw(tempdir);
use JSON       ();
use POSIX      ();
use Test2::V0;
use Time::HiRes qw(sleep time);
use Overnet::Mail::Store;

my $dir = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my $parent_pid = $$;
my (%children, $sequence);
my @tables = qw(blossom_blob_data blossom_blobs mailbox_entries messages recipients submissions deliveries);
my $raw    = Overnet::Mail::RawMessage->new(
  raw_bytes => "Message-ID: <imap-recovery\@example.test>\r\nSubject: opaque UID recovery\r\n\r\n"
    . ("\0\xff" x 50_000));
my $empty = {uidvalidity => 1, uidnext => 1, message_count => 0};

subtest 'mailbox initialization is durable and read-only queries do not allocate identifiers' => sub {
  my $file  = "$dir/empty.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  is $store->_dbh->selectrow_array('PRAGMA user_version'),              6,     'durable routing schema is version six';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),              undef, 'unknown mailbox has no state';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'),        [],    'unknown mailbox has no UIDs';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1), undef, 'unknown mailbox has no UID content';
  is allocator($store),                                     1, 'read-only lookups leave the global allocator unused';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $empty, 'empty mailbox receives first durable UIDVALIDITY';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $empty, 'repeat initialization returns unchanged state';
  is allocator($store), 2,               'only the initial mailbox allocation advances UIDVALIDITY';
  is counts($store),    [(0) x @tables], 'empty mailbox does not invent a receipt or stored content';
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $file);
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $empty, 'empty state survives reopening';
  is $store->ensure_mailbox(mailbox_id => 'another-box'),
    {uidvalidity => 2, uidnext => 1, message_count => 0}, 'different mailbox gets a distinct durable validity';
  $store->disconnect;
};

for my $table (qw(mailboxes blossom_blob_data blossom_blobs mailbox_entries)) {
  subtest "$table insertion failure rolls back automatic UIDVALIDITY and UID allocation" => sub {
    my $store = Overnet::Mail::Store->new(path => "$dir/failure-$table.db");
    $store->_dbh->do(
      "CREATE TEMP TRIGGER fail_uid AFTER INSERT ON $table BEGIN SELECT RAISE(ABORT, 'private UID failure'); END");
    like dies { receive($store) }, qr/(?:blob|database) operation failed/, 'failed transaction returns no receipt';
    is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'failed first receipt creates no mailbox';
    is allocator($store),                                    1,     'failed first receipt consumes no UIDVALIDITY';
    is counts($store), [(0) x @tables], 'failure leaves no membership, content, archive, or outbox';
    $store->_dbh->do('DROP TRIGGER fail_uid');
    my $receipt = receive($store);
    is $store->mailbox_state(mailbox_id => 'recipient-box'),
      {uidvalidity => 1, uidnext => 2, message_count => 1}, 'retry commits the first validity and UID exactly once';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'retry retains the original public receipt shape while exposing UID separately';
    $store->disconnect;
  };
}

subtest 'failed state update and failed initialization commit consume no identifiers' => sub {
  my $store = Overnet::Mail::Store->new(path => "$dir/state-failure.db");
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "initialize commit interrupted\n" }};
    like dies { $store->ensure_mailbox(mailbox_id => 'recipient-box') }, qr/initialize commit interrupted/,
      'failed empty mailbox commit is not acknowledged';
  }
  $store->_dbh->{Callbacks} = {};
  is allocator($store),                                    1,     'failed mailbox commit restores the global allocator';
  is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'failed mailbox commit leaves no row';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $empty, 'retry initializes the original UIDVALIDITY';
  $store->_dbh->do(
    q{CREATE TEMP TRIGGER fail_uid AFTER UPDATE ON mailboxes BEGIN SELECT RAISE(ABORT, 'private state failure'); END});
  like dies { receive($store) }, qr/database operation failed/, 'failed UIDNEXT update cannot acknowledge receipt';
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $empty, 'failed state update leaves empty state intact';
  is counts($store), [(0) x @tables], 'failed state update rolls back content and receipt too';
  $store->_dbh->do('DROP TRIGGER fail_uid');
  ok receive($store), 'original key remains reusable';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box')->[0]->{uid}, 1, 'retry uses UID one without a gap';
  $store->disconnect;
};

subtest 'receipt commit failure and lost acknowledgement preserve durable counters' => sub {
  my $file  = "$dir/commit.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
    like dies { receive($store) }, qr/commit interrupted/, 'failed commit returns no receipt';
  }
  $store->_dbh->{Callbacks} = {};
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $empty, 'commit failure consumes no UID';
  is counts($store), [(0) x @tables],                              'commit failure rolls back content and receipt';
  {
    local $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "commit acknowledgement interrupted\n";
      }
    };
    like dies { receive($store) }, qr/commit acknowledgement interrupted/, 'lost acknowledgement reports failure';
  }
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $file);
  my $receipt = receive($store, received_at => 999);
  is $receipt->{received_at}, 123, 'replay retains first committed arrival time';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
    'lost acknowledgement replay retains the first UID';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1}, 'replay does not advance UIDNEXT or count';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes, $raw->raw_bytes,
    'committed UID retains exact offline binary bytes';
  receive($store, idempotency_key => 'second');
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1, 2],
    'next distinct receipt follows committed UID with no extra allocation';
  $store->disconnect;
};

subtest 'captured UIDNEXT bounds a snapshot while subsequent pages see new receipts' => sub {
  my $file  = "$dir/snapshot.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  receive($store);
  receive($store, idempotency_key => 'second', received_at => 1);
  my $snapshot = $store->mailbox_state(mailbox_id => 'recipient-box');
  my $first    = $store->mailbox_uid_entries(mailbox_id => 'recipient-box', limit => 1);
  my $writer   = Overnet::Mail::Store->new(path => $file);
  receive($writer, idempotency_key => 'later', received_at => 0);
  $writer->disconnect;
  my $later = $store->mailbox_uid_entries(mailbox_id => 'recipient-box', after_uid => $first->[0]->{uid});
  is [map { $_->{uid} } @{$later}], [2, 3], 'later page includes a receipt committed since state capture';
  is [map { $_->{uid} } grep { $_->{uid} < $snapshot->{uidnext} } (@{$first}, @{$later})], [1, 2],
    'adapter filtering UID below captured UIDNEXT reproduces the original snapshot';
  is $snapshot->{message_count}, 2, 'captured snapshot count agrees with filtered membership';
  $store->disconnect;
};

subtest 'terminal UIDNEXT fails new receipts without affecting replay or other mailboxes' => sub {
  my $file  = "$dir/uid-exhaustion.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  $store->_dbh->do(q{UPDATE mailboxes SET uidnext = 4294967294 WHERE mailbox_id = 'recipient-box'});
  my $receipt = receive($store);
  my $state   = {uidvalidity => 1, uidnext => 4_294_967_295, message_count => 1};
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $state, 'last assignable UID advances to terminal UIDNEXT';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 4_294_967_294}],
    'terminal marker is never assigned as a message UID';
  my $baseline = counts($store);
  like dies {
    receive($store, idempotency_key => 'overflow', message => Overnet::Mail::RawMessage->new(raw_bytes => 'overflow'));
  }, qr/(?:UID|uid).*exhaust/, 'new receipt fails closed when UID space is exhausted';
  is counts($store),                                       $baseline, 'exhaustion writes no content or membership';
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $state,    'exhaustion neither wraps nor advances state';
  is receive($store, received_at => 999), $receipt, 'exact replay remains available at terminal UIDNEXT';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $state,
    'initialization of existing terminal mailbox is safe';
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $file);
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $state, 'exhausted state persists across reopen';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 4_294_967_294)->{message}->raw_bytes,
    $raw->raw_bytes, 'last legal UID stays readable';
  receive($store, mailbox_id => 'another-box');
  is $store->mailbox_uid_entries(mailbox_id => 'another-box')->[0]->{uid}, 1, 'exhaustion is local to one mailbox';
  $store->disconnect;
};

subtest 'UIDVALIDITY exhaustion neither wraps nor prevents using existing mailboxes' => sub {
  my $store = Overnet::Mail::Store->new(path => "$dir/validity-exhaustion.db");
  $store->_dbh->do('UPDATE mailbox_uidvalidity SET next_value = 4294967295 WHERE singleton = 1');
  my $state = {uidvalidity => 4_294_967_295, uidnext => 1, message_count => 0};
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $state, 'last legal UIDVALIDITY can be allocated';
  is allocator($store), 4_294_967_296,                              'allocator records durable exhausted sentinel';
  like dies { $store->ensure_mailbox(mailbox_id => 'overflow-box') }, qr/(?:UID|uid).*exhaust/,
    'new mailbox fails at UIDVALIDITY exhaustion';
  like dies { receive($store, mailbox_id => 'overflow-box') }, qr/(?:UID|uid).*exhaust/,
    'implicit mailbox creation also fails at UIDVALIDITY exhaustion';
  is allocator($store), 4_294_967_296, 'failed creation leaves exhaustion sentinel unchanged';
  is $store->mailbox_state(mailbox_id => 'overflow-box'),   undef,           'exhaustion creates no phantom mailbox';
  is counts($store),                                        [(0) x @tables], 'exhaustion retains no partial content';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $state,          'existing mailbox does not allocate again';
  my $receipt = receive($store);
  is receive($store), $receipt, 'existing mailbox still accepts and replays receipts';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 4_294_967_295, uidnext => 2, message_count => 1}, 'existing mailbox preserves maximal validity';
  $store->disconnect;
};

subtest 'version-four receipt history is rejected byte-for-byte unchanged' => sub {
  my $file  = "$dir/version-four.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  receive($store);
  my $dbh = $store->_dbh;
  $dbh->do(
    q{CREATE TABLE old_entries (
    entry_id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(entry_id BETWEEN 1 AND 999999999999999999),
    mailbox_id TEXT NOT NULL, idempotency_key TEXT NOT NULL,
    content_sha256 TEXT NOT NULL REFERENCES blossom_blobs(sha256) REFERENCES blossom_blob_data(storage_key),
    received_at INTEGER NOT NULL CHECK(received_at BETWEEN 0 AND 9999999999), UNIQUE(mailbox_id, idempotency_key))}
  );
  $dbh->do(
q{INSERT INTO old_entries SELECT entry_id, mailbox_id, idempotency_key, content_sha256, received_at FROM mailbox_entries}
  );
  $dbh->do('DROP TABLE mailbox_entries');
  $dbh->do('ALTER TABLE old_entries RENAME TO mailbox_entries');
  $dbh->do('CREATE INDEX mailbox_entries_cursor ON mailbox_entries(mailbox_id, entry_id)');
  $dbh->do('CREATE INDEX mailbox_entries_content ON mailbox_entries(content_sha256)');
  $dbh->do('DROP TABLE mailboxes');
  $dbh->do('DROP TABLE mailbox_uidvalidity');
  $dbh->do('PRAGMA user_version = 4');
  my $schema = $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name');
  my %rows   = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY rowid") }
    (@tables, qw(blossom_owners sqlite_sequence));
  $store->disconnect;
  like dies { Overnet::Mail::Store->new(path => $file) }, qr/unsupported mail store schema/,
    'old recipient storage is not silently migrated';
  $dbh = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1, PrintError => 0});
  is $dbh->selectrow_array('PRAGMA user_version'),   4,             'old schema marker is unchanged';
  is $dbh->selectrow_array('PRAGMA application_id'), 1_330_463_049, 'old application marker is unchanged';
  is $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name'), $schema,
    'rejection preserves every old schema and sequence definition';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY rowid"), $rows{$table},
      "rejection preserves $table including opaque bytes and receipt identity";
  }
  $dbh->disconnect;
};

subtest 'concurrent mailbox creation and receipt allocation use durable serialized identifiers' => sub {
  plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};
  my $file  = "$dir/concurrent.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  $store->disconnect;
  my @jobs = map {
    spawn_job($file, sub { return $_[0]->ensure_mailbox(mailbox_id => 'recipient-box') })
  } 1 .. 6;
  start_jobs(@jobs);
  is collect_job($_), $empty, 'concurrent empty initialization returns the same state' for @jobs;
  $store = Overnet::Mail::Store->new(path => $file);
  is allocator($store), 2, 'concurrent initialization consumes one UIDVALIDITY';
  $store->disconnect;
  @jobs = map {
    my $index = $_;
    spawn_job($file, sub { return $_[0]->ensure_mailbox(mailbox_id => "another-$index") });
  } 1 .. 6;
  start_jobs(@jobs);
  my @states = map { collect_job($_) } @jobs;
  is [sort { $a <=> $b } map { $_->{uidvalidity} } @states], [2 .. 7],
    'concurrent distinct mailboxes allocate globally unique consecutive UIDVALIDITY values';
  @jobs = map {
    my $index = $_;
    spawn_job($file, sub { return receive($_[0], idempotency_key => "distinct-$index", received_at => 100 - $index) });
  } 1 .. 6;
  start_jobs(@jobs);
  my @receipts = map { collect_job($_) } @jobs;
  $store = Overnet::Mail::Store->new(path => $file);
  my $entries = $store->mailbox_uid_entries(mailbox_id => 'recipient-box');
  is [map { $_->{uid} } @{$entries}], [1 .. 6], 'concurrent distinct receipts receive unique monotonic mailbox UIDs';
  is [sort { $a <=> $b } map { $_->{entry_id} } @{$entries}],
    [sort { $a <=> $b } map { $_->{entry_id} } @receipts], 'every successful receipt owns exactly one UID';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 7, message_count => 6}, 'counter matches all committed distinct receipts';
  $store->disconnect;
  @jobs = map {
    spawn_job($file, sub { return receive($_[0]) })
  } 1 .. 6;
  start_jobs(@jobs);
  @receipts = map { collect_job($_) } @jobs;
  is $_, $receipts[0], 'same-key concurrent replay retains exactly one receipt' for @receipts;
  $store = Overnet::Mail::Store->new(path => $file);
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1 .. 7],
    'six same-key attempts consume only one additional UID';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 8, message_count => 7}, 'replay does not advance counters';
  $store->disconnect;
};

subtest 'empty initialization racing receipt replay uses one mailbox identity' => sub {
  plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};
  my $file  = "$dir/ensure-receive-race.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  $store->disconnect;
  my @jobs = map {
    my $index = $_;
    spawn_job(
      $file,
      sub {
        my ($child) = @_;
        return $index % 2 ? $child->ensure_mailbox(mailbox_id => 'recipient-box') : receive($child);
      }
    );
  } 1 .. 6;
  start_jobs(@jobs);
  collect_job($_) for @jobs;
  $store = Overnet::Mail::Store->new(path => $file);
  is allocator($store), 2, 'ensure-versus-receive race allocates one UIDVALIDITY';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1}, 'race initializes exactly one committed mailbox and UID';
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1],
    'replay racing initialization consumes no extra UIDs';
  $store->disconnect;
};

subtest 'hard interruption before and after commit never reuses a committed UID' => sub {
  plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};
  for my $stage (qw(mailboxes mailbox_entries commit)) {
    my $file  = "$dir/killed-$stage.db";
    my $store = Overnet::Mail::Store->new(path => $file);
    $store->disconnect;
    my $job = spawn_job(
      $file,
      sub {
        my ($child) = @_;
        my $interrupt = sub { kill 9, $$; POSIX::_exit(91) };
        if ($stage eq 'commit') {
          $child->_dbh->sqlite_commit_hook($interrupt);
        } else {
          $child->_dbh->sqlite_create_function('interrupt_process', 0, $interrupt);
          $child->_dbh->do(
            "CREATE TEMP TRIGGER interrupt_uid AFTER INSERT ON $stage BEGIN SELECT interrupt_process(); END");
        }
        return receive($child);
      }
    );
    start_jobs($job);
    is reap_job($job) & 127, 9, "worker is killed at $stage before commit acknowledgement";
    $store = Overnet::Mail::Store->new(path => $file);
    is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'interrupted first receipt leaves no mailbox state';
    is allocator($store),                                    1,     'uncommitted UIDVALIDITY is recovered';
    is counts($store), [(0) x @tables],                             'hard interruption rolls back membership and bytes';
    my $receipt = receive($store);
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'retry uses first UID after genuine process interruption';
    $store->disconnect;
  }
  my $file = "$dir/killed-after-commit.db";
  my $job  = spawn_job(
    $file,
    sub {
      my ($child, $task) = @_;
      my $receipt = receive($child);
      write_event($task, 'committed',
        {receipt => $receipt, state => $child->mailbox_state(mailbox_id => 'recipient-box')});
      kill 9, $$;
      POSIX::_exit(91);
    }
  );
  start_jobs($job);
  is reap_job($job) & 127, 9, 'committed writer is killed without disconnect or destructors';
  my $checkpoint = await_event($job, 'committed');
  my $store      = Overnet::Mail::Store->new(path => $file);
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $checkpoint->{state},
    'committed state survives abrupt death';
  is receive($store, received_at => 999), $checkpoint->{receipt},
    'lost receipt acknowledgement replays committed identity';
  receive($store, idempotency_key => 'after-recovery');
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1, 2],
    'new receipt never reuses the UID committed before process death';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 3, message_count => 2}, 'durable counters include exactly the two committed receipts';
  $store->disconnect;
};

done_testing;

sub allocator {
  my ($store) = @_;
  return $store->_dbh->selectrow_array('SELECT next_value FROM mailbox_uidvalidity WHERE singleton = 1');
}

sub receive {
  my ($store, %extra) = @_;
  return $store->receive_message(
    mailbox_id      => 'recipient-box',
    idempotency_key => 'delivery-key',
    message         => $raw,
    received_at     => 123,
    %extra
  );
}

sub counts {
  my ($store) = @_;
  return [map { $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") } @tables];
}

sub spawn_job {
  my ($file, $code) = @_;
  my $job = {path => "$dir/job-" . ++$sequence};
  my $pid = fork();
  die "fork failed: $!" if !defined $pid;
  if (!$pid) {
    my $ok = eval {
      my $store = Overnet::Mail::Store->new(path => $file);
      write_event($job, 'ready', 1);
      await_event($job, 'go');
      my $result = $code->($store, $job);
      $store->disconnect;
      write_event($job, 'result', {value => $result});
      1;
    };
    if (!$ok) {
      write_event($job, 'result', {error => $@});
      POSIX::_exit(90);
    }
    POSIX::_exit(0);
  }
  $job->{pid} = $pid;
  $children{$pid} = $job;
  return $job;
}

sub start_jobs {
  my (@jobs) = @_;
  await_event($_, 'ready') for @jobs;
  write_event($_, 'go', 1) for @jobs;
  return;
}

sub write_event {
  my ($job, $name, $value) = @_;
  my $path = "$job->{path}-$name";
  open my $fh, '>:raw', "$path-$$.tmp" or die "open checkpoint: $!";
  print {$fh} JSON->new->canonical->encode($value) or die "write checkpoint: $!";
  close $fh                                        or die "close checkpoint: $!";
  rename "$path-$$.tmp", $path or die "publish checkpoint: $!";
  return;
}

sub await_event {
  my ($job, $name) = @_;
  my $path     = "$job->{path}-$name";
  my $deadline = time + 20;
  while (!-e $path) {
    if ($name ne 'result' && -e "$job->{path}-result") {
      my $result = await_event($job, 'result');
      die "worker failed before $name: $result->{error}" if $result->{error};
      die "worker finished before $name\n";
    }
    die "worker checkpoint timed out: $name\n" if time > $deadline;
    sleep 0.01;
  }
  open my $fh, '<:raw', $path or die "read checkpoint: $!";
  my $json = do { local $/ = undef; <$fh> };
  close $fh or die "close checkpoint: $!";
  return JSON->new->decode($json);
}

sub reap_job {
  my ($job) = @_;
  my $deadline = time + 20;
  while (1) {
    my $pid = waitpid $job->{pid}, POSIX::WNOHANG();
    if ($pid == $job->{pid}) {
      my $status = $?;
      delete $children{$pid};
      return $status;
    }
    die "worker wait failed: $!"        if $pid == -1;
    die "worker completion timed out\n" if time > $deadline;
    sleep 0.01;
  }
  return;
}

sub collect_job {
  my ($job) = @_;
  is reap_job($job), 0, 'worker exits successfully';
  my $result = await_event($job, 'result');
  die "worker failed: $result->{error}" if $result->{error};
  return $result->{value};
}

END {
  if (defined $parent_pid && $$ == $parent_pid) {
    for my $pid (keys %children) {
      kill 9, $pid;
      waitpid $pid, 0;
    }
  }
}
