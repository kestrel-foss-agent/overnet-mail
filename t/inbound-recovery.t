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
my @tables =
  qw(blossom_blob_data blossom_blobs blossom_owners mailbox_entries messages recipients submissions deliveries);
my $raw = Overnet::Mail::RawMessage->new(
  raw_bytes => "Message-ID: <recovery\@example.test>\r\nSubject: opaque mailbox\r\n\r\n" . ("\0\xff" x 50_000));

subtest 'SQLite inbound schema is explicit' => sub {
  my $store = open_store(new_storage());
  is $store->_dbh->selectrow_array('PRAGMA user_version'), 6, 'inbound schema marker is six';
  $store->disconnect;
};
subtest 'immutable route persistence and unknown recipient custody boundary' => sub {
  my $location = new_storage();
  my $store    = open_store($location);
  my $before   = snapshot($store);
  is deliver($store), {status => 'unknown_recipient'}, 'unknown recipient has no accepted receipt';
  is snapshot($store), $before, 'unknown recipient creates no route, mailbox, content, UID, or outbox';
  ok dies { register($store) }, 'a route requires an existing mailbox';
  is snapshot($store), $before, 'failed registration cannot implicitly provision a mailbox';
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  my $route = register($store, recipient => 'Alice@EXAMPLE.TEST');
  is $route, {recipient => 'Alice@example.test', mailbox_id => 'recipient-box'}, 'only domain is case folded';
  is register($store, recipient => 'Alice@example.test'), $route, 'canonical route registration is idempotent';
  is deliver($store), {status => 'unknown_recipient'},    'local part case remains significant';
  $store->ensure_mailbox(mailbox_id => 'other-box');
  $before = snapshot($store);
  my $error = dies { register($store, recipient => 'Alice@example.test', mailbox_id => 'other-box') };
  ok $error, 'existing route cannot be rebound';
  unlike $error, qr/Alice\@|recipient-box|other-box|INSERT|UPDATE/, 'rebind diagnostics omit private route values';
  is snapshot($store), $before, 'rebind refusal changes no route or mailbox';
  $store->disconnect;
  $store = open_store($location);
  is register($store, recipient => 'Alice@example.test'), $route, 'route survives authoritative storage reopen';
  my $result = deliver($store, recipient => 'Alice@EXAMPLE.TEST');
  is [sort keys %{$result}],            [qw(receipt status)], 'received result has only status and receipt';
  is $result->{status},                 'received',           'canonical recipient selects registered mailbox';
  is [sort keys %{$result->{receipt}}], [qw(content_sha256 entry_id received_at)], 'receipt exposes only safe metadata';
  is $store->mailbox_entries(mailbox_id => 'other-box'), [], 'opaque message headers cannot select destination';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes,
    $raw->raw_bytes, 'received binary message remains byte exact';
  $store->disconnect;
};

subtest 'route registration faults and lost acknowledgement remain retryable' => sub {
  my $location = new_storage();
  my $store    = open_store($location);
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  my $before = snapshot($store);
  install_failure($store, 'recipient_routes', 'INSERT');
  my $error = dies { register($store) };
  like $error,   qr/database operation failed/,     'real route insertion failure returns no success';
  unlike $error, qr/private\@|secret|INSERT|RAISE/, 'route storage error hides SQL and private data';
  is snapshot($store), $before, 'trigger failure rolls back binding';
  remove_failure($store, 'recipient_routes');
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "route commit interrupted\n" }};
    like dies { register($store) }, qr/route commit interrupted/, 'route precommit failure propagates';
  }
  is snapshot($store), $before, 'precommit failure leaves route absent';
  {
    local $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "route acknowledgement interrupted\n";
      }
    };
    like dies { register($store) }, qr/route acknowledgement interrupted/, 'lost acknowledgement is not success';
  }
  $store->disconnect;
  $store = open_store($location);
  is register($store), {recipient => 'alice@example.test', mailbox_id => 'recipient-box'},
    'retry recovers committed binding';
  is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM recipient_routes'), 1, 'retry does not duplicate route';
  is counts($store), [(0) x @tables], 'route registration never acquires message custody';
  $store->disconnect;
};

for my $table (qw(blossom_blob_data blossom_blobs mailbox_entries mailboxes)) {
  subtest "delivery failure at $table preserves earlier custody and returns no receipt" => sub {
    my $location = new_storage();
    my $store    = prepared($location);
    register($store, recipient => 'alias@example.test');
    my $first  = receive($store);
    my $before = snapshot($store);
    install_failure($store, $table, $table eq 'mailboxes' ? 'UPDATE' : 'INSERT');
    my $new   = Overnet::Mail::RawMessage->new(raw_bytes => "new private bytes $table\0\xff");
    my $error = dies { receive($store, idempotency_key => 'failed-key', message => $new) };
    like $error,   qr/(?:blob|database) operation failed/, 'real storage fault cannot return an accepted receipt';
    unlike $error, qr/private\@|secret|INSERT|To:/,        'storage error hides SQL and private data';
    is snapshot($store), $before, 'failure changes no route, UID, content, or membership';
    is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $first->{entry_id})->{message}->raw_bytes,
      $raw->raw_bytes, 'rollback preserves every byte held by original receipt';

    if ($table eq 'mailbox_entries' || $table eq 'mailboxes') {
      like dies { receive($store, recipient => 'alias@example.test') }, qr/database operation failed/,
        'late failure also rejects new membership sharing existing content';
      is snapshot($store), $before, 'failed alias membership preserves shared content and UID';
    }
    remove_failure($store, $table);
    is receive($store), $first, 'original receipt remains replayable';
    my $retry = receive($store, idempotency_key => 'failed-key', message => $new);
    is counts($store), [2, 2, 0, 2, 0, 0, 0, 0], 'original request safely retries into one new content and membership';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$first}, uid => 1}, {%{$retry}, uid => 2}],
      'failed attempt consumes no durable UID';
    $store->disconnect;
  };
}

subtest 'commit failure and lost delivery acknowledgement preserve exact replay' => sub {
  my $location = new_storage();
  my $store    = prepared($location);
  my $before   = snapshot($store);
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "delivery commit interrupted\n" }};
    like dies { receive($store) }, qr/delivery commit interrupted/, 'precommit fault yields no receipt';
  }
  is snapshot($store), $before, 'commit failure rolls back new custody but preserves durable route';
  {
    local $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "delivery acknowledgement interrupted\n";
      }
    };
    like dies { receive($store) }, qr/delivery acknowledgement interrupted/, 'lost acknowledgement returns no success';
  }
  $store->disconnect;
  $store = open_store($location);
  my $receipt = receive($store, received_at => 999);
  is $receipt->{received_at}, 123,                      'reopened replay preserves first committed arrival time';
  is counts($store),          [1, 1, 0, 1, 0, 0, 0, 0], 'acknowledgement loss never duplicates custody';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}], 'replay retains first UID';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id})->{message}->raw_bytes,
    $raw->raw_bytes, 'offline replay retains exact large binary content';
  $store->disconnect;
};

subtest 'post-transaction upload cleanup faults never return an inbound acknowledgement' => sub {
  for my $committed (0, 1) {
    my $location     = new_storage();
    my $store        = prepared($location);
    my $before       = snapshot($store);
    my $upload_class = ref($store->_blob_store) . '::_Upload';
    my $error;
    {
      my $fault = mock $upload_class => override => [_cleanup => sub { die "private staging cleanup secret\n" }];
      local $store->_dbh->{Callbacks} = $committed ? {} : {commit => sub { die "commit interrupted\n" }};
      $error = dies { deliver($store) };
    }
    like $error, qr/upload cleanup failed/, 'cleanup failure returns no received status';
    unlike $error, qr/private staging|secret|alice\@|delivery-key/,
      'cleanup diagnostic hides private staging and routing values';
    if ($committed) {
      like $error, qr/acceptance committed, retry the original/,
        'postcommit error explicitly requires original request retry';
      is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'cleanup cannot erase actual committed membership or bytes';
    } else {
      is snapshot($store), $before, 'abort cleanup failure retains actual rollback and original route';
    }
    $store->disconnect;
    $store = open_store($location);
    my $receipt = receive($store, received_at => 999);
    is $receipt->{received_at}, $committed ? 123 : 999, 'reopened replay reflects actual SQL custody boundary';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'retry resolves custody once without consuming an extra UID';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'retry leaves exactly one routed membership and content copy';
    is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes,
      $raw->raw_bytes, 'recovered inbound receipt retains exact original bytes';
    $store->disconnect;
  }
};

subtest 'aliases, sources, recipients and direct API have independent namespaces' => sub {
  my $location = new_storage();
  my $store    = prepared($location);
  register($store, recipient => 'alias@example.test');
  $store->ensure_mailbox(mailbox_id => 'other-box');
  register($store, recipient => 'other@example.test', mailbox_id => 'other-box');
  my $first     = receive($store);
  my $alias     = receive($store, recipient => 'alias@example.test');
  my $source    = receive($store, source_id => 'other-mta');
  my $other     = receive($store, recipient => 'other@example.test');
  my $different = Overnet::Mail::RawMessage->new(raw_bytes => 'different direct private bytes');
  my $direct    = $store->receive_message(
    mailbox_id      => 'recipient-box',
    idempotency_key => 'delivery-key',
    message         => $different,
    received_at     => 400
  );
  my %identities = map { $_->{entry_id} => 1 } ($first, $alias, $source, $other, $direct);
  is scalar keys %identities, 5, 'five independent namespaces have five distinct memberships';
  is receive($store, recipient => 'alice@EXAMPLE.TEST', received_at => 999), $first,
    'domain normalization shares replay identity';
  is receive($store, recipient => 'alias@example.test', received_at => 999), $alias,  'alias owns separate receipt';
  is receive($store, source_id => 'other-mta',          received_at => 999), $source, 'source owns separate receipt';
  is $store->load_mailbox_entry(mailbox_id => 'other-box', entry_id => $first->{entry_id}), undef,
    'global entry ID cannot bypass mailbox scope';
  is counts($store), [2, 2, 0, 5, 0, 0, 0, 0], 'namespaces share bytes without private sender records';
  my $before = snapshot($store);
  like dies { receive($store, message => $different) }, qr/idempotency key conflicts/,
    'changed bytes cannot reuse routed receipt';
  is snapshot($store), $before, 'conflicting replay consumes no UID or custody';
  $store->disconnect;
  $store = open_store($location);
  is receive($store), $first, 'routed namespace survives reopen alongside same-key direct receipt';
  is $store->receive_message(
    mailbox_id      => 'recipient-box',
    idempotency_key => 'delivery-key',
    message         => $different,
    received_at     => 900
    ),
    $direct, 'direct receipt remains independently replayable';
  $store->disconnect;
};

for my $damage (qw(changed_bytes metadata_size metadata_type missing_bytes missing_metadata)) {
  subtest "corrupt $damage fails closed without repairing routed custody" => sub {
    my $location = new_storage();
    my $store    = prepared($location);
    receive($store);
    damage_content($store, $damage);
    $store->disconnect;
    $store = open_store($location);
    my $before = snapshot($store);
    for my $key ('delivery-key', 'new-key') {
      my $error = dies { receive($store, idempotency_key => $key) };
      like $error, qr/content (?:integrity|is missing)|database operation failed/,
        'existing and fresh keys cannot silently repair authoritative corruption';
      unlike $error, qr/private\@|secret|Bcc:/, 'corruption diagnostics hide private content';
    }
    like dies { $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1) },
      qr/content (?:integrity|is missing)|database operation failed/, 'retrieval refuses corrupted custody';
    is snapshot($store), $before, 'failed acceptance preserves corrupt rows, route, and counters';
    $store->disconnect;
  };
}

subtest 'concurrent immutable registrations and byte-exact receipt retries' => sub {
  require_fork();
  for my $conflicting (0, 1) {
    my $location = new_storage();
    my $initial  = open_store($location);
    $initial->ensure_mailbox(mailbox_id => $_) for qw(recipient-box other-box);
    $initial->disconnect;
    my @jobs = map {
      my $target = $conflicting && $_ % 2 ? 'other-box' : 'recipient-box';
      spawn_job(
        $location,
        sub {
          my $route = eval { register($_[0], mailbox_id => $target) };
          return {route => $route, error => $@};
        }
      );
    } 0 .. 5;
    start_jobs(@jobs);
    my @results   = map  { collect_job($_) } @jobs;
    my @successes = grep { $_->{route} } @results;
    my @failures  = grep { length $_->{error} } @results;
    is scalar @successes, $conflicting ? 3 : 6, 'only requests matching winning binding succeed';
    is scalar @failures,  $conflicting ? 3 : 0, 'conflicting concurrent rebinds fail';
    my $route = $successes[0]->{route};
    is $_->{route}, $route, 'successful registrations agree on same canonical binding' for @successes;
    my $store = open_store($location);
    is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM recipient_routes'), 1, 'race commits one route';
    my $receipt = receive($store);
    is $store->mailbox_entries(mailbox_id => $route->{mailbox_id}), [$receipt], 'delivery follows winning route';
    my $loser = $route->{mailbox_id} eq 'recipient-box' ? 'other-box' : 'recipient-box';
    is $store->mailbox_entries(mailbox_id => $loser), [], 'losing target receives no custody';
    $store->disconnect;
  }
  for my $conflicting (0, 1) {
    my $location = new_storage();
    prepared($location)->disconnect;
    my @jobs = map {
      my $index = $_;
      my $message =
        $conflicting && $index % 2 ? Overnet::Mail::RawMessage->new(raw_bytes => 'conflicting private bytes') : $raw;
      spawn_job(
        $location,
        sub {
          my $receipt = eval { receive($_[0], message => $message, received_at => 100 + $index) };
          return {receipt => $receipt, error => $@};
        }
      );
    } 0 .. 5;
    start_jobs(@jobs);
    my @results   = map  { collect_job($_) } @jobs;
    my @successes = grep { $_->{receipt} } @results;
    my @failures  = grep { length $_->{error} } @results;
    is scalar @successes, $conflicting ? 3 : 6, 'only identical bytes share winning receipt';
    is scalar @failures,  $conflicting ? 3 : 0, 'concurrent changed bytes fail closed';
    my $receipt = $successes[0]->{receipt};
    is $_->{receipt}, $receipt, 'all successful retries preserve first identity and timestamp' for @successes;
    like $_->{error}, qr/idempotency key conflicts/, 'losing bytes conflict with committed key' for @failures;
    my $store = open_store($location);
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}], 'race allocates one UID';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'losers leave no stray content or hidden sender records';
    $store->disconnect;
  }
};
subtest 'SIGKILL before and after commit preserves routed receipt custody' => sub {
  require_fork();
  for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries commit)) {
    my $location = new_storage();
    my $initial  = prepared($location);
    my $before   = snapshot($initial);
    $initial->disconnect;
    my $job = spawn_job(
      $location,
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
    is reap_job($job) & 127, 9, "SIGKILL reaches $stage before receipt acknowledgement";
    my $store = open_store($location);
    is snapshot($store), $before, 'hot-journal recovery retains only durable route and mailbox';
    my $receipt = receive($store);
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'retry commits first membership';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'recovery leaves no partial content or phantom membership';
    $store->disconnect;
  }
  my $location = new_storage();
  prepared($location)->disconnect;
  my $job = spawn_job(
    $location,
    sub {
      my ($store, $task) = @_;
      my $receipt = receive($store);
      write_event($task, 'committed', $receipt);
      kill 9, $$;
      POSIX::_exit(91);
    }
  );
  start_jobs($job);
  is reap_job($job) & 127, 9, 'postcommit process death runs no disconnect or destructor';
  my $committed = await_event($job, 'committed');
  my $store     = open_store($location);
  is receive($store, received_at => 999), $committed, 'reopened retry returns exact committed receipt';
  is counts($store), [1, 1, 0, 1, 0, 0, 0, 0],        'postcommit recovery creates no duplicate membership';
  $store->disconnect;
};

subtest 'registration and acceptance serialize rather than caching an unknown route' => sub {
  require_fork();
  my $location = new_storage();
  my $initial  = open_store($location);
  $initial->ensure_mailbox(mailbox_id => 'recipient-box');
  $initial->disconnect;
  my $registrar = spawn_job(
    $location,
    sub {
      my ($store, $task) = @_;
      local $store->_dbh->{Callbacks} = {
        commit => sub {
          write_event($task, 'uncommitted', 1);
          await_event($task, 'release');
          return;
        }
      };
      return register($store);
    }
  );
  my $receiver = spawn_job(
    $location,
    sub {
      my ($store, $task) = @_;
      write_event($task, 'attempting', 1);
      return deliver($store);
    }
  );
  await_event($_, 'ready') for ($registrar, $receiver);
  write_event($registrar, 'go', 1);
  await_event($registrar, 'uncommitted');
  write_event($receiver, 'go', 1);
  await_event($receiver, 'attempting');
  sleep 0.1;
  ok !-e "$receiver->{path}-result", 'delivery waits behind in-flight serialized route registration';
  write_event($registrar, 'release', 1);
  collect_job($registrar);
  my $result = collect_job($receiver);
  is $result->{status}, 'received', 'waiting delivery sees committed route inside acceptance transaction';
  my $store = open_store($location);
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$result->{receipt}],
    'one receipt follows winning registration';
  $store->disconnect;
};

subtest 'previous schema five is rejected without modifying schema or custody' => sub {
  my $location = new_storage();
  my $store    = prepared($location);
  receive($store);
  my $dbh = $store->_dbh;
  $dbh->do('DROP TABLE recipient_routes');
  $dbh->do('ALTER TABLE mailbox_entries RENAME TO inbound_entries');
  $dbh->do(
    q{CREATE TABLE mailbox_entries (
    entry_id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(entry_id BETWEEN 1 AND 999999999999999999),
    mailbox_id TEXT NOT NULL REFERENCES mailboxes(mailbox_id),
    uid INTEGER NOT NULL CHECK(uid BETWEEN 1 AND 4294967294),
    idempotency_key TEXT NOT NULL,
    content_sha256 TEXT NOT NULL REFERENCES blossom_blobs(sha256) REFERENCES blossom_blob_data(storage_key),
    received_at INTEGER NOT NULL CHECK(received_at BETWEEN 0 AND 9999999999),
    UNIQUE(mailbox_id, idempotency_key), UNIQUE(mailbox_id, uid))}
  );
  $dbh->do(
    q{INSERT INTO mailbox_entries (entry_id, mailbox_id, uid, idempotency_key, content_sha256, received_at)
    SELECT entry_id, mailbox_id, uid, idempotency_key, content_sha256, received_at FROM inbound_entries}
  );
  $dbh->do('DROP TABLE inbound_entries');
  $dbh->do('CREATE INDEX mailbox_entries_cursor ON mailbox_entries(mailbox_id, entry_id)');
  $dbh->do('CREATE INDEX mailbox_entries_content ON mailbox_entries(content_sha256)');
  $dbh->do('PRAGMA user_version = 5');
  my $schema = $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name');
  my %rows   = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY rowid") }
    (@tables, qw(mailboxes mailbox_uidvalidity sqlite_sequence));
  $store->disconnect;
  like dies { open_store($location) }, qr/unsupported mail store schema/, 'schema five is never implicitly migrated';
  $dbh = DBI->connect("dbi:SQLite:dbname=$location", q{}, q{}, {RaiseError => 1, PrintError => 0});
  is $dbh->selectrow_array('PRAGMA user_version'), 5, 'prior version marker stays unchanged';
  is $dbh->selectall_arrayref('SELECT * FROM sqlite_master ORDER BY name'), $schema,
    'prior schema and indexes stay unchanged';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY rowid"), $rows{$table},
      "rejection preserves $table exactly";
  }
  $dbh->disconnect;
};

done_testing;

sub register {
  my ($store, %extra) = @_;
  return $store->register_recipient(recipient => 'alice@example.test', mailbox_id => 'recipient-box', %extra);
}

sub deliver {
  my ($store, %extra) = @_;
  return $store->receive_delivery(
    source_id       => 'local-mta',
    idempotency_key => 'delivery-key',
    recipient       => 'alice@example.test',
    message         => $raw,
    received_at     => 123,
    %extra
  );
}

sub receive {
  my ($store, %extra) = @_;
  my $result = deliver($store, %extra);
  die "expected received result\n" if $result->{status} ne 'received' || ref $result->{receipt} ne 'HASH';
  return $result->{receipt};
}

sub prepared {
  my ($location) = @_;
  my $store = open_store($location);
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  register($store);
  return $store;
}

sub snapshot {
  my ($store) = @_;
  return {
    counts    => counts($store),
    routes    => $store->_dbh->selectall_arrayref('SELECT * FROM recipient_routes ORDER BY recipient'),
    mailboxes => $store->_dbh->selectall_arrayref('SELECT * FROM mailboxes ORDER BY mailbox_id'),
    allocator => $store->_dbh->selectrow_array('SELECT next_value FROM mailbox_uidvalidity WHERE singleton = 1'),
  };
}
sub new_storage  { return "$dir/inbound-" . ++$sequence . '.db'; }
sub open_store   { return Overnet::Mail::Store->new(path => $_[0]); }
sub require_fork { plan skip_all => 'fork is unavailable' if !$Config{d_fork}; return; }

sub counts {
  return [map { $_[0]->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") } @tables];
}

sub install_failure {
  my ($store, $table, $event) = @_;
  $store->_dbh->do(
"CREATE TEMP TRIGGER fail_inbound AFTER $event ON $table BEGIN SELECT RAISE(ABORT, 'private\@example.test secret'); END"
  );
  return;
}
sub remove_failure { $_[0]->_dbh->do('DROP TRIGGER fail_inbound'); return; }

sub damage_content {
  my ($store, $damage) = @_;
  my %sql = (
    changed_bytes    => q{UPDATE blossom_blob_data SET body = zeroblob(length(body))},
    metadata_size    => q{UPDATE blossom_blobs SET size = 1},
    metadata_type    => q{UPDATE blossom_blobs SET type = 'private@example.test secret'},
    missing_bytes    => q{DELETE FROM blossom_blob_data},
    missing_metadata => q{DELETE FROM blossom_blobs},
  );
  $store->_dbh->do('PRAGMA foreign_keys = OFF');
  $store->_dbh->do($sql{$damage});
  $store->_dbh->do('PRAGMA foreign_keys = ON');
  return;
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
