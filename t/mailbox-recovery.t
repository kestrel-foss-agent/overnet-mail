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
  raw_bytes => "Message-ID: <recovery\@example.test>\r\nSubject: opaque mailbox\r\n\r\n" . ("\0\xff" x 50_000));

for my $table (qw(blossom_blob_data blossom_blobs mailbox_entries)) {
  subtest "failure inserting $table rolls back the complete receipt" => sub {
    my $store = Overnet::Mail::Store->new(path => "$dir/failure-$table.db");
    $store->_dbh->do(
"CREATE TEMP TRIGGER fail_insert BEFORE INSERT ON $table BEGIN SELECT RAISE(ABORT, 'blind\@example.test secret'); END"
    );
    my $error = dies { receive($store) };
    like $error,   qr/(?:blob|database) operation failed/,   'insertion failure returns no receipt';
    unlike $error, qr/blind\@|secret|INSERT|opaque mailbox/, 'driver failure hides private data and SQL';
    is counts($store), [(0) x @tables],                            'bytes, metadata, and membership roll back together';
    is $store->mailbox_entries(mailbox_id => 'recipient-box'), [], 'no phantom membership is visible';
    $store->_dbh->do('DROP TRIGGER fail_insert');
    ok receive($store), 'same receipt key is reusable after rollback';
    is counts($store), [1, 1, 1, 0, 0, 0, 0], 'retry stores one content and membership, with no archive or outbox';
    $store->disconnect;
  };
}

subtest 'commit failure and lost commit acknowledgement are distinct' => sub {
  my $file  = "$dir/commit.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
    like dies { receive($store) }, qr/commit interrupted/, 'failed commit returns no receipt';
  }
  is counts($store), [(0) x @tables], 'failed commit rolls back all receipt custody';
  {
    local $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "commit acknowledgement interrupted\n";
      }
    };
    like dies { receive($store) }, qr/commit acknowledgement interrupted/, 'lost acknowledgement is not success';
  }
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $file);
  my $receipt = receive($store, received_at => 900);
  is $receipt->{received_at}, 123, 'replay after committed acknowledgement loss retains original arrival time';
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt], 'one committed membership survives reopen';
  is counts($store), [1, 1, 1, 0, 0, 0, 0], 'recovery does not create a second mailbox copy';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id})->{message}->raw_bytes,
    $raw->raw_bytes, 'offline reopened mailbox has every original octet';
  $store->disconnect;
};

subtest 'failed membership insert preserves content already held by another receipt' => sub {
  my $store    = Overnet::Mail::Store->new(path => "$dir/shared-rollback.db");
  my $original = receive($store);
  $store->_dbh->do(
    q{CREATE TEMP TRIGGER fail_entry BEFORE INSERT ON mailbox_entries BEGIN SELECT RAISE(ABORT, 'private failure'); END}
  );
  like dies { receive($store, mailbox_id => 'another-recipient') }, qr/database operation failed/,
    'second membership failure does not acknowledge receipt';
  is counts($store), [1, 1, 1, 0, 0, 0, 0], 'rollback preserves earlier shared content and its only membership';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $original->{entry_id})->{message}->raw_bytes,
    $raw->raw_bytes, 'previously committed recipient can still retrieve exact bytes';
  is $store->mailbox_entries(mailbox_id => 'another-recipient'), [], 'failed recipient has no membership';
  $store->_dbh->do('DROP TRIGGER fail_entry');
  ok receive($store, mailbox_id => 'another-recipient'), 'second recipient can retry the same key';
  is counts($store), [1, 1, 2, 0, 0, 0, 0], 'retry shares the original bytes without copying';
  $store->disconnect;
};

subtest 'membership alone protects both shared Blossom content halves' => sub {
  my $store   = Overnet::Mail::Store->new(path => "$dir/foreign-keys.db");
  my $receipt = receive($store);
  for my $table (qw(blossom_blob_data blossom_blobs)) {
    like dies { $store->_dbh->do("DELETE FROM $table") }, qr/database operation failed/,
      "recipient membership directly prevents deletion of $table";
  }
  is counts($store),  [1, 1, 1, 0, 0, 0, 0], 'foreign keys do not need a hidden archival record';
  is receive($store), $receipt,              'foreign-key failures leave the original receipt intact';
  $store->disconnect;
};

my @damage = (
  ['changed bytes',    q{UPDATE blossom_blob_data SET body = zeroblob(length(body))}],
  ['metadata size',    q{UPDATE blossom_blobs SET size = 1}],
  ['metadata type',    q{UPDATE blossom_blobs SET type = 'blind@example.test private'}],
  ['missing bytes',    q{DELETE FROM blossom_blob_data}],
  ['missing metadata', q{DELETE FROM blossom_blobs}],
  ['both content halves missing', q{DELETE FROM blossom_blob_data}, q{DELETE FROM blossom_blobs}],
);
for my $case (@damage) {
  subtest "corrupt $case->[0] fails closed" => sub {
    my $file    = "$dir/damage-" . ++$sequence . '.db';
    my $store   = Overnet::Mail::Store->new(path => $file);
    my $receipt = receive($store);
    $store->disconnect;
    my $dbh = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1, PrintError => 0});
    $dbh->do('PRAGMA foreign_keys = OFF');
    $dbh->do($_) for @{$case}[1 .. $#{$case}];
    $dbh->disconnect;
    $store = Overnet::Mail::Store->new(path => $file);
    my $baseline = counts($store);
    my $error    = dies {
      $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id});
    };
    like $error,   qr/content (?:integrity|is missing)/, 'retrieval cannot return corrupt or missing content';
    unlike $error, qr/blind\@|private|opaque mailbox/,   'corruption diagnostics do not leak stored private data';
    like dies { receive($store) }, qr/content (?:integrity|is missing)/, 'replay verifies its existing content';
    like dies { receive($store, idempotency_key => 'new-key') }, qr/content (?:integrity|is missing)/,
      'new membership cannot repair missing custody behind an existing receipt';
    is counts($store), $baseline, 'failed operations neither duplicate nor silently repair corrupt content';
    $store->disconnect;
  };
}

subtest 'version-three archive and outbox are rejected without changes' => sub {
  my $file  = "$dir/version-three.db";
  my $store = Overnet::Mail::Store->new(path => $file);
  my $item  = Overnet::Mail::Submission->new(
    message  => $raw,
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test'])
  );
  $store->enqueue_submission(mailbox_id => 'sender-box', idempotency_key => 'old-outbox', item => $item);
  $store->disconnect;
  my $dbh = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1, PrintError => 0});
  $dbh->do('DROP TABLE mailbox_entries');
  $dbh->do('PRAGMA user_version = 3');
  my $schema = $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name');
  my %rows   = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY rowid") }
    qw(blossom_blob_data blossom_blobs blossom_owners messages recipients submissions deliveries sqlite_sequence);
  $dbh->disconnect;
  like dies { Overnet::Mail::Store->new(path => $file) }, qr/unsupported mail store schema/,
    'version-three archive is not silently upgraded';
  $dbh = DBI->connect("dbi:SQLite:dbname=$file", q{}, q{}, {RaiseError => 1, PrintError => 0});
  is $dbh->selectrow_array('PRAGMA user_version'),   3,             'old version marker is unchanged';
  is $dbh->selectrow_array('PRAGMA application_id'), 1_330_463_049, 'application marker is unchanged';
  is $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name'), $schema,
    'all old schema definitions and sequence definitions remain unchanged';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY rowid"), $rows{$table},
      "old $table rows remain byte-for-byte unchanged";
  }
  $dbh->disconnect;
};

subtest 'hard process interruptions and concurrent receipt retries' => sub {
  plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};

  # Close all parent handles before fork. SIGKILL runs no cleanup or destructors.
  for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries commit)) {
    my $file    = "$dir/crash-$stage.db";
    my $initial = Overnet::Mail::Store->new(path => $file);
    $initial->disconnect;
    my $job = spawn_job(
      $file,
      sub {
        my ($store) = @_;
        $store->_dbh->do('PRAGMA cache_size = 2');
        my $interrupt = sub { kill 9, $$; POSIX::_exit(91) };
        if ($stage eq 'commit') {
          $store->_dbh->sqlite_commit_hook($interrupt);
        } else {
          $store->_dbh->sqlite_create_function('interrupt_process', 0, $interrupt);
          $store->_dbh->do(
            "CREATE TEMP TRIGGER interrupt_insert AFTER INSERT ON $stage BEGIN SELECT interrupt_process(); END");
        }
        return receive($store);
      }
    );
    start_jobs($job);
    is reap_job($job) & 127, 9, "SIGKILL reached $stage before receipt acknowledgement";
    my $reopened = Overnet::Mail::Store->new(path => $file);
    is counts($reopened), [(0) x @tables], "no partial receipt survives interruption at $stage";
    my $receipt = receive($reopened);
    is $reopened->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt], 'retry creates exactly one membership';
    is $reopened->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id})->{message}
      ->raw_bytes,
      $raw->raw_bytes, 'retry restores exact large binary bytes';
    $reopened->disconnect;
  }

  my $file = "$dir/killed-after-commit.db";
  my $job  = spawn_job(
    $file,
    sub {
      my ($store, $task) = @_;
      my $receipt = receive($store);
      write_event($task, 'committed', $receipt);
      kill 9, $$;
      POSIX::_exit(91);
    }
  );
  start_jobs($job);
  is reap_job($job) & 127, 9, 'postcommit worker exits without closing its connection';
  my $committed = await_event($job, 'committed');
  my $store     = Overnet::Mail::Store->new(path => $file);
  is receive($store, received_at => 999), $committed, 'lost acknowledgement replay returns the original full receipt';
  is counts($store), [1, 1, 1, 0, 0, 0, 0],           'committed membership is not duplicated after abrupt exit';
  $store->disconnect;

  for my $conflicting (0, 1) {
    my $race_file = "$dir/concurrent-$conflicting.db";
    my $initial   = Overnet::Mail::Store->new(path => $race_file);
    $initial->disconnect;
    my @jobs;
    for my $index (0 .. 5) {
      my $message =
        $conflicting && $index % 2 ? Overnet::Mail::RawMessage->new(raw_bytes => 'unequal private bytes') : $raw;
      push @jobs, spawn_job(
        $race_file,
        sub {
          my ($child) = @_;
          my $receipt = eval { receive($child, message => $message, received_at => 100 + $index) };
          return {receipt => $receipt, error => $@};
        }
      );
    }
    start_jobs(@jobs);
    my @results   = map  { collect_job($_) } @jobs;
    my @successes = grep { defined $_->{receipt} } @results;
    my @failures  = grep { length $_->{error} } @results;
    is scalar @successes, $conflicting ? 3 : 6, 'only byte-identical requests share the winning receipt';
    is scalar @failures,  $conflicting ? 3 : 0, 'conflicting concurrent requests are rejected';
    my $receipt = $successes[0]->{receipt};
    is $_->{receipt}, $receipt, 'all successful concurrent retries return exactly the first timestamp and identity'
      for @successes;

    for my $failure (@failures) {
      like $failure->{error},   qr/idempotency key conflicts/,      'losing content conflicts with the committed key';
      unlike $failure->{error}, qr/unequal|private|opaque mailbox/, 'concurrent conflict hides message data';
    }
    $store = Overnet::Mail::Store->new(path => $race_file);
    is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt], 'race leaves one stable mailbox receipt';
    is counts($store), [1, 1, 1, 0, 0, 0, 0], 'race leaves no losing content, duplicate bytes, or hidden outbox';
    $store->disconnect;
  }
};

done_testing;

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
