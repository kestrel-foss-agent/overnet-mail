use strictures 2;

use Config;
use File::Temp qw(tempdir);
use JSON       ();
use POSIX      ();
use Test2::V0;
use Time::HiRes qw(sleep time);

# These tests never discover a server or start one. A configured server must be
# disposable enough to permit dedicated schemas and PostgreSQL large objects.
my $required = ($ENV{OVERNET_REQUIRE_POSTGRES} || q{}) eq '1';
if (!$ENV{OVERNET_TEST_PG_DSN}) {
  bail_out 'OVERNET_REQUIRE_POSTGRES=1 requires OVERNET_TEST_PG_DSN' if $required;
  plan skip_all => 'set OVERNET_TEST_PG_DSN to run real PostgreSQL recovery tests';
}
my $dependencies = eval {
  require DBI;
  require DBD::Pg;
  require Overnet::Mail::Store::Postgres;
  1;
};
if (!$dependencies) {
  bail_out 'required PostgreSQL test dependencies are unavailable' if $required;
  plan skip_all => 'PostgreSQL test dependencies are unavailable';
}
if (!$Config{d_fork}) {
  bail_out 'required PostgreSQL recovery tests need fork' if $required;
  plan skip_all => 'fork is unavailable';
}

my $parent_pid = $$;
my $dir        = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my (@schemas, %children, %known_oids);
my $sequence = 0;
my @tables   = qw(blossom_blob_data blossom_blobs blossom_owners messages recipients submissions deliveries);
my $message = Overnet::Mail::RawMessage->new(raw_bytes => "Subject: PostgreSQL recovery\r\n\r\n" . ("\0\xff" x 50_000));
my $submission = Overnet::Mail::Submission->new(
  message  => $message,
  envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test', 'blind@example.test'])
);

subtest 'simultaneous identical keys return the same committed receipt' => sub {
  my $schema = provision();
  my @jobs   = map {
    spawn_job($schema, sub { return accept_record($_[0], 'same', $submission) })
  } 1 .. 4;
  start_jobs(@jobs);
  my @receipts = map { collect_job($_) } @jobs;
  is $_, $receipts[0], 'every independent process returns the original receipt' for @receipts;
  my $store = open_store($schema);
  is counts($store), [1, 1, 0, 1, 2, 0, 0], 'one acceptance, envelope, metadata record and byte mapping';
  is $store->load(mailbox_id => 'box', message_id => $receipts[0]->{message_id})->{message}->raw_bytes,
    $message->raw_bytes, 'the committed bytes survive independent reconnection';
  $store->disconnect;
};

subtest 'conflicting same-key acceptance has exactly one winner' => sub {
  my $schema = provision();
  my @items  = ($message, Overnet::Mail::RawMessage->new(raw_bytes => 'different content'));
  my @jobs;
  for my $item (@items) {
    push @jobs, spawn_job(
      $schema,
      sub {
        my ($store) = @_;
        my $receipt = eval { accept_record($store, 'conflict', $item) };
        return {receipt => $receipt, error => $@};
      }
    );
  }
  start_jobs(@jobs);
  my @results = map  { collect_job($_) } @jobs;
  my @winners = grep { $_->{receipt} } @results;
  my @losers  = grep { !$_->{receipt} } @results;
  is scalar @winners, 1, 'exactly one conflicting request commits';
  is scalar @losers,  1, 'exactly one conflicting request is rejected';
  like $losers[0]->{error}, qr/idempotency key conflicts/, 'loser gets a conflict, not phantom acceptance';
  my $store = open_store($schema);
  is counts($store), [1, 1, 0, 1, 0, 0, 0], 'loser leaves no additional content or acceptance';
  is $store->load(mailbox_id => 'box', message_id => $winners[0]->{receipt}->{message_id})->{content_sha256},
    $winners[0]->{receipt}->{content_sha256}, 'the persisted record belongs to the winning receipt';
  $store->disconnect;
};

subtest 'different request keys deduplicate one real large object' => sub {
  my $schema = provision();
  my @jobs;
  for my $key (qw(first second third fourth)) {
    push @jobs, spawn_job(
      $schema,
      sub {
        my ($store) = @_;
        my @imported;
        local $store->_dbh->{Callbacks} = {
          do => sub {
            my ($dbh, $sql, $attributes, @bind) = @_;
            push @imported, $bind[1] if is_insert($sql, 'blossom_blob_data');
            return;
          }
        };
        return {receipt => accept_record($store, $key, $submission), imported => \@imported};
      }
    );
  }
  start_jobs(@jobs);
  my @results = map { collect_job($_) } @jobs;
  my %ids     = map { $_->{receipt}->{message_id} => 1 } @results;
  is scalar keys %ids, 4, 'request keys preserve four distinct logical messages';
  my @imported = map { @{$_->{imported}} } @results;
  $known_oids{$_} = 1 for @imported;
  is scalar @imported, 1, 'only one PostgreSQL LO import reaches the mapping insert';
  my $store = open_store($schema);
  is counts($store), [1, 1, 0, 4, 8, 0, 0],     'four envelopes share one metadata record and one byte mapping';
  is existing_oids($store->_dbh, @imported), 1, 'the single imported LO is committed';
  is $store->_dbh->selectcol_arrayref('SELECT body_oid FROM blossom_blob_data'), \@imported,
    'the mapping references the sole imported object';
  $store->disconnect;
};

subtest 'concurrent queue claims have unique fences and stale workers cannot finish' => sub {
  is [fence(undef)], [undef], 'an absent claim preserves one null value in list context';
  my $schema = provision();
  my @jobs   = map {
    spawn_job(
      $schema,
      sub {
        my ($store) = @_;
        my $receipt = enqueue($store);
        my $claim   = $store->claim_delivery(mailbox_id => 'box', now => 10, lease_seconds => 1);
        return {receipt => $receipt, claim => fence($claim)};
      }
    )
  } 1 .. 4;
  start_jobs(@jobs);
  my @results = map { collect_job($_) } @jobs;
  is $_->{receipt}, $results[0]->{receipt}, 'all enqueues recover the original queue receipt' for @results;
  my @claims = grep { defined $_ } map { $_->{claim} } @results;
  is scalar @claims, 2, 'exactly one worker claims each recipient';
  my @delivery_ids = sort { $a <=> $b } map { $_->{delivery_id} } @claims;
  is \@delivery_ids,                  $results[0]->{receipt}->{delivery_ids}, 'no live delivery fence is issued twice';
  is [map { $_->{attempt} } @claims], [1, 1],                                 'first claims have first-attempt fences';
  my $store = open_store($schema);
  is $store->claim_delivery(mailbox_id => 'box', now => 10), undef, 'a live lease cannot be stolen';
  my $replacement = $store->claim_delivery(mailbox_id => 'box', now => 11, lease_seconds => 10);
  is $replacement->{attempt},            2, 'expiry issues a new attempt fence';
  is $replacement->{uncertain_attempts}, 1, 'expiry records the unknown prior outcome';
  my ($stale) = grep { $_->{delivery_id} == $replacement->{delivery_id} } @claims;
  like dies { finish($store, $stale, 11) }, qr/stale or expired/, 'stale worker cannot finish a reassigned delivery';
  like dies { finish($store, $stale, 10) }, qr/stale or expired/, 'old fence is rejected even with its old clock';
  is finish($store, $replacement, 11)->{state}, 'delivered', 'current fence can settle the delivery';
  $store->disconnect;
};

subtest 'lock wait refreshes visibility even with a REPEATABLE READ session default' => sub {
  my $schema = provision();
  my $first  = spawn_job(
    $schema,
    sub {
      my ($store, $job) = @_;
      local $store->_dbh->{Callbacks} = {
        commit => sub {
          write_event($job, 'holding', {isolation => $store->_dbh->selectrow_array('SHOW transaction_isolation')});
          await_event($job, 'release');
          return;
        }
      };
      return accept_record($store, 'snapshot', $submission);
    },
    'REPEATABLE READ'
  );
  my $second = spawn_job(
    $schema,
    sub {
      my ($store) = @_;
      return accept_record($store, 'snapshot', $submission);
    },
    'REPEATABLE READ'
  );
  my $first_ready  = await_event($first,  'ready');
  my $second_ready = await_event($second, 'ready');
  is $first_ready->{default_isolation},  'repeatable read', 'first session really defaults to REPEATABLE READ';
  is $second_ready->{default_isolation}, 'repeatable read', 'second session really defaults to REPEATABLE READ';
  write_event($first, 'go', 1);
  my $holding = await_event($first, 'holding');
  is $holding->{isolation}, 'read committed', 'adapter forces READ COMMITTED inside the operation';
  write_event($second, 'go', 1);

  # All forks already happened before this observer connection is opened.
  my $observer = connect_db($schema);
  ok waiting_for_mail_lock($observer, $second_ready->{backend_pid}),
    'second transaction waits on the first transaction';
  $observer->disconnect;
  write_event($first, 'release', 1);
  my $original = collect_job($first);
  is collect_job($second), $original, 'waiter sees the committed key instead of using a stale snapshot';
  my $store = open_store($schema);
  is counts($store), [1, 1, 0, 1, 2, 0, 0], 'the lock-and-snapshot protocol commits only one acceptance';
  $store->disconnect;
};

subtest 'database-wide lock blocks another schema and times out without partial writes' => sub {
  my $holding_schema = provision();
  my $waiting_schema = provision();
  my $job            = spawn_job(
    $waiting_schema,
    sub {
      my ($store, $task) = @_;
      my $start   = time;
      my $receipt = eval { accept_record($store, 'timeout', $submission) };
      my $error   = $@;
      write_event(
        $task,
        'timeout',
        {
          receipt    => $receipt,
          error      => $error,
          elapsed    => time - $start,
          autocommit => $store->_dbh->{AutoCommit} ? 1 : 0,
          counts     => counts($store),
        }
      );
      await_event($task, 'retry');
      return accept_record($store, 'timeout', $submission);
    }
  );
  my $ready  = await_event($job, 'ready');
  my $holder = connect_db($holding_schema);
  $holder->begin_work;
  $holder->do('SELECT pg_advisory_xact_lock(1330463049::bigint)');
  write_event($job, 'go', 1);
  ok waiting_for_mail_lock($holder, $ready->{backend_pid}), 'the same database lock serializes different schemas';
  my $timeout = await_event($job, 'timeout');
  is $timeout->{receipt}, undef, 'timeout does not return an acceptance receipt';
  like $timeout->{error},   qr/mail store database operation failed/, 'lock timeout has an explicit bounded failure';
  unlike $timeout->{error}, qr/SELECT|blind\@|pg_advisory/,           'timeout hides SQL and envelope data';
  cmp_ok $timeout->{elapsed}, '>=', 1.5, 'operation waited for the configured lock deadline';
  cmp_ok $timeout->{elapsed}, '<',  9,   'lock contention fails before the statement deadline';
  is $timeout->{autocommit}, 1,               'failed transaction rolls back to an idle connection';
  is $timeout->{counts},     [(0) x @tables], 'lock timeout persists no partial acceptance';
  $holder->rollback;
  $holder->disconnect;
  write_event($job, 'retry', 1);
  ok collect_job($job)->{message_id}, 'the same handle and key succeed after the holder releases';
};

for my $stage (qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries commit)) {
  subtest "SIGKILL before commit at $stage rolls back relational rows and large objects" => sub {
    my $schema = provision();
    my $job    = spawn_job(
      $schema,
      sub {
        my ($store, $task) = @_;
        my @imported;
        my $pause = sub {
          write_event(
            $task,
            'interrupted',
            {
              oids         => \@imported,
              counts       => counts($store),
              visible_oids => existing_oids($store->_dbh, @imported),
            }
          );
          await_event($task, 'never_release');
          return;
        };
        local $store->_dbh->{Callbacks} = {
          do => sub {
            my ($dbh, $sql, $attributes, @bind) = @_;
            push @imported, $bind[1] if is_insert($sql, 'blossom_blob_data');
            $pause->() if $stage ne 'commit' && is_insert($sql, $stage);
            return;
          },
          commit => sub { $pause->() if $stage eq 'commit'; return },
        };
        return enqueue($store);
      }
    );
    start_jobs($job);
    my $checkpoint = await_event($job, 'interrupted');
    $known_oids{$_} = 1 for @{$checkpoint->{oids}};
    is scalar @{$checkpoint->{oids}}, 1, 'the interrupted transaction already imported one LO';
    is $checkpoint->{visible_oids},   1, 'the LO is real and visible to its creating transaction';
    is $checkpoint->{counts}, [1, 1, 0, 1, 2, 1, 2], 'all enqueue rows exist before interrupted commit'
      if $stage eq 'commit';
    terminate_job($job);
    my $store = open_store($schema);
    is counts($store), [(0) x @tables],                        'disconnect rolls back every mail and Blossom row';
    is existing_oids($store->_dbh, @{$checkpoint->{oids}}), 0, 'rollback also removes the uncommitted LO';
    ok enqueue($store), 'original request key can safely be retried';
    is counts($store), [1, 1, 0, 1, 2, 1, 2], 'retry commits exactly one complete queue';
    $store->disconnect;
  };
}

for my $stage (qw(enqueue claim finish)) {
  subtest "lost $stage acknowledgement retains committed state after SIGKILL" => sub {
    my $schema = provision();
    my $job    = spawn_job(
      $schema,
      sub {
        my ($store, $task) = @_;
        my $receipt = enqueue($store);
        my $claim;
        if ($stage ne 'enqueue') {
          $claim = $store->claim_delivery(mailbox_id => 'box', now => 10, lease_seconds => 1);
          finish($store, $claim, 10) if $stage eq 'finish';
        }
        write_event(
          $task,
          'committed',
          {
            receipt    => $receipt,
            claim      => fence($claim),
            stage      => $stage,
            autocommit => $store->_dbh->{AutoCommit} ? 1 : 0,
          }
        );
        await_event($task, 'never_release');
        return;
      }
    );
    start_jobs($job);
    my $checkpoint = await_event($job, 'committed');
    is $checkpoint->{stage},      $stage, 'worker reached the requested postcommit interruption point';
    is $checkpoint->{autocommit}, 1,      'the operation committed before the worker is killed';
    ok exists $checkpoint->{claim}, 'checkpoint includes an explicit optional claim value';
    terminate_job($job);
    my $store = open_store($schema);
    is enqueue($store), $checkpoint->{receipt},
      'replay returns the exact original message, submission and delivery IDs';
    is counts($store), [1, 1, 0, 1, 2, 1, 2], 'lost receipt does not duplicate custody or outbox rows';
    my $rows = $store->deliveries(mailbox_id => 'box', submission_id => $checkpoint->{receipt}->{submission_id});
    is $rows->[0]->{state}, $stage eq 'enqueue' ? 'ready' : $stage eq 'claim' ? 'leased' : 'delivered',
      'a lost acknowledgement does not undo a committed state';

    if ($stage eq 'claim') {
      my $other = $store->claim_delivery(mailbox_id => 'box', now => 10, lease_seconds => 10);
      isnt $other->{delivery_id}, $checkpoint->{claim}->{delivery_id},
        'the interrupted worker keeps its lease until expiry';
      my $recovered = $store->claim_delivery(mailbox_id => 'box', now => 11, lease_seconds => 10);
      is $recovered->{delivery_id}, $checkpoint->{claim}->{delivery_id},
        'interrupted claim is reclaimable after expiry';
      is [$recovered->{attempt}, $recovered->{uncertain_attempts}], [2, 1],
        'recovery increments the fence and preserves uncertainty';
      like dies { finish($store, $checkpoint->{claim}, 11) }, qr/stale or expired/,
        'lost worker cannot settle the replacement fence';
    }
    $store->disconnect;
  };
}

for my $stage (qw(claim finish)) {
  subtest "SIGKILL during $stage commit preserves only the prior state" => sub {
    my $schema  = provision();
    my $initial = open_store($schema);
    my $receipt = enqueue($initial);
    $initial->disconnect;
    my $job = spawn_job(
      $schema,
      sub {
        my ($store, $task) = @_;
        my $claim;
        $claim = $store->claim_delivery(mailbox_id => 'box', now => 10, lease_seconds => 10) if $stage eq 'finish';
        local $store->_dbh->{Callbacks} = {
          commit => sub {
            write_event(
              $task,
              'interrupted',
              {
                stage      => $stage,
                autocommit => $store->_dbh->{AutoCommit} ? 1 : 0,
                row        =>
                  $store->_dbh->selectrow_hashref('SELECT state, attempt FROM deliveries ORDER BY delivery_id LIMIT 1'),
              }
            );
            await_event($task, 'never_release');
            return;
          }
        };
        return $stage eq 'claim'
          ? fence($store->claim_delivery(mailbox_id => 'box', now => 10))
          : finish($store, $claim, 10);
      }
    );
    start_jobs($job);
    my $checkpoint = await_event($job, 'interrupted');
    is $checkpoint->{stage},      $stage, 'worker reached the requested precommit interruption point';
    is $checkpoint->{autocommit}, 0,      'interruption occurs while the transaction is active';
    is $checkpoint->{row}, {state => $stage eq 'claim' ? 'leased' : 'delivered', attempt => 1},
      'the pending transition exists before its commit is interrupted';
    terminate_job($job);
    my $store = open_store($schema);
    my $row   = $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0];
    is [$row->{state}, $row->{attempt}], $stage eq 'claim' ? ['ready', 0] : ['leased', 1],
      'uncommitted state transition and fence are rolled back together';
    $store->disconnect;
  };
}

cleanup();
done_testing;

sub connect_db {
  my ($schema, $isolation) = @_;
  my $dbh = DBI->connect(
    $ENV{OVERNET_TEST_PG_DSN},
    $ENV{OVERNET_TEST_PG_USER},
    $ENV{OVERNET_TEST_PG_PASSWORD},
    {
      RaiseError         => 1,
      PrintError         => 0,
      AutoCommit         => 1,
      pg_enable_utf8     => 0,
      ShowErrorStatement => 0,
      HandleError        => sub { die "PostgreSQL test connection operation failed\n" },
    }
  );
  die "PostgreSQL test connection unavailable\n" if !$dbh;
  $dbh->do(q{SET client_min_messages = warning});
  $dbh->do(q{SET statement_timeout = '15000ms'});
  $dbh->do('SET search_path = ' . $dbh->quote_identifier($schema) . ', pg_catalog') if defined $schema;
  $dbh->do('SET default_transaction_isolation = ' . $dbh->quote(lc $isolation))     if defined $isolation;
  return $dbh;
}

sub provision {
  my $schema = 'om_recovery_' . $$ . '_' . ++$sequence . '_' . int(rand(1_000_000));
  my $dbh    = connect_db();
  $dbh->do('CREATE SCHEMA ' . $dbh->quote_identifier($schema));
  push @schemas, $schema;
  $dbh->do('SET search_path = ' . $dbh->quote_identifier($schema) . ', pg_catalog');
  Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
  Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
  my $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh);
  $store->disconnect;
  return $schema;
}

sub open_store {
  my ($schema, $isolation) = @_;
  return Overnet::Mail::Store::Postgres->new(dbh => connect_db($schema, $isolation));
}

sub accept_record {
  my ($store, $key, $item) = @_;
  return $store->accept_item(mailbox_id => 'box', idempotency_key => $key, item => $item);
}

sub enqueue {
  my ($store) = @_;
  return $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'request', item => $submission);
}

sub finish {
  my ($store, $claim, $now) = @_;
  return $store->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $claim->{delivery_id},
    attempt     => $claim->{attempt},
    now         => $now,
    outcome     => 'confirmed',
  );
}

sub fence {
  my ($claim) = @_;

  # This helper also occurs inside hash constructors: an absent claim must
  # contribute one value rather than collapsing the caller's key/value list.
  return undef if !defined $claim;
  return {map { $_ => $claim->{$_} } qw(delivery_id attempt lease_until uncertain_attempts)};
}

sub counts {
  my ($store) = @_;
  return [map { $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") } @tables];
}

sub existing_oids {
  my ($dbh, @oids) = @_;
  my $count = 0;
  $count += $dbh->selectrow_array('SELECT COUNT(*) FROM pg_largeobject_metadata WHERE oid = ?', undef, $_) for @oids;
  return $count;
}

sub is_insert {
  my ($sql, $table) = @_;
  return $sql =~ /\bINSERT\s+INTO\s+(?:"[^"]+"\.)?"?\Q$table\E\b/ismx;
}

# A single parent never forks with an active DB connection. Every worker opens
# its own handle, signals readiness, then waits for a filesystem barrier. IPC is
# private to the temporary directory, and atomic rename prevents partial JSON.
sub spawn_job {
  my ($schema, $code, $isolation) = @_;
  my $job = {path => "$dir/job-" . ++$sequence};
  my $pid = fork();
  die "fork failed: $!" if !defined $pid;
  if (!$pid) {
    my $ok = eval {
      my $store = open_store($schema, $isolation);
      write_event(
        $job, 'ready',
        {
          backend_pid       => $store->_dbh->selectrow_array('SELECT pg_backend_pid()'),
          default_isolation => $store->_dbh->selectrow_array('SHOW default_transaction_isolation'),
        }
      );
      await_event($job, 'go');
      my $result = $code->($store, $job);
      $store->disconnect;
      write_event($job, 'result', {value => $result});
      1;
    };
    if (!$ok) {
      my $error = $@;
      write_event($job, 'result', {error => $error});
      write_event($job, 'ready',  {error => $error}) if !-e "$job->{path}-ready";
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
  for my $job (@jobs) {
    my $ready = await_event($job, 'ready');
    die "worker could not initialize: $ready->{error}" if $ready->{error};
  }
  write_event($_, 'go', 1) for @jobs;
  return;
}

sub write_event {
  my ($job, $name, $data) = @_;
  my $path = "$job->{path}-$name";
  open my $fh, '>:raw', "$path-$$.tmp" or die "open checkpoint: $!";
  print {$fh} JSON->new->canonical->encode($data) or die "write checkpoint: $!";
  close $fh                                       or die "close checkpoint: $!";
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
      die "worker failed before checkpoint $name: $result->{error}" if $result->{error};
      die "worker finished before checkpoint $name\n";
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
  my $status = reap_job($job);
  is $status, 0, 'worker exits successfully';
  my $result = await_event($job, 'result');
  die "worker failed: $result->{error}" if $result->{error};
  return $result->{value};
}

sub terminate_job {
  my ($job) = @_;
  kill 9, $job->{pid} or die "kill interrupted worker: $!";
  is reap_job($job) & 127, 9, 'worker is killed without running DB rollback or destructors';
  return;
}

sub waiting_for_mail_lock {
  my ($dbh, $pid) = @_;
  my $deadline = time + 2;
  while (time < $deadline) {
    return 1
      if $dbh->selectrow_array(
q{SELECT COUNT(*) FROM pg_locks WHERE pid = ? AND locktype = 'advisory' AND classid = 0 AND objid = 1330463049 AND objsubid = 1 AND NOT granted},
      undef, $pid,
      );
    sleep 0.01;
  }
  return 0;
}

sub cleanup {
  return if !@schemas && !%known_oids && !%children;
  for my $pid (keys %children) {
    kill 9, $pid;
    waitpid $pid, 0;
    delete $children{$pid};
  }
  my $dbh = connect_db();
  for my $schema (@schemas) {
    my $table = $dbh->quote_identifier($schema, 'blossom_blob_data');
    if ($dbh->selectrow_array('SELECT to_regclass(?)', undef, $table)) {
      my $oids = $dbh->selectcol_arrayref("SELECT body_oid FROM $table");
      $known_oids{$_} = 1 for @{$oids};
    }
  }

  # Never use a database-wide LO deletion: only recorded imports and mappings
  # from schemas this exact process successfully created are eligible.
  for my $oid (keys %known_oids) {
    $dbh->selectrow_array('SELECT lo_unlink(oid) FROM pg_largeobject_metadata WHERE oid = ?', undef, $oid);
    delete $known_oids{$oid};
  }
  while (@schemas) {
    my $schema = $schemas[-1];
    $dbh->do('DROP SCHEMA ' . $dbh->quote_identifier($schema) . ' CASCADE');
    pop @schemas;
  }
  $dbh->disconnect;
  return;
}

END {
  if (defined $parent_pid && $$ == $parent_pid) {
    my $ok = eval { cleanup(); 1 };
    warn "PostgreSQL recovery test cleanup failed\n" if !$ok;
  }
}
