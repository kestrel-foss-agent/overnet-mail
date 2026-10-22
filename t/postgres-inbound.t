use strictures 2;

use Config;
use File::Temp qw(tempdir);
use JSON       ();
use POSIX      ();
use Test2::V0;
use Time::HiRes qw(sleep time);

# A caller must explicitly supply a disposable PostgreSQL service. Never
# discover/start a server or infer credentials. Mandatory CI must fail closed.
my $required = $ENV{OVERNET_REQUIRE_POSTGRES};
if (!$ENV{OVERNET_TEST_PG_DSN}) {
  bail_out 'OVERNET_REQUIRE_POSTGRES requires OVERNET_TEST_PG_DSN' if $required;
  plan skip_all => 'set OVERNET_TEST_PG_DSN to run real PostgreSQL inbound routing tests';
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

my $parent_pid = $$;
my $dir        = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my (@schemas, %children, %known_oids);
my $sequence = 0;
my @tables =
  qw(blossom_blob_data blossom_blobs blossom_owners mailbox_entries messages recipients submissions deliveries);
my $raw = Overnet::Mail::RawMessage->new(
  raw_bytes => "Message-ID: <mailbox\@example.test>\r\nSubject: PostgreSQL receipt\r\n\r\n"
    . (pack('C*', 0 .. 255) x 400));

subtest 'PostgreSQL inbound schema is explicit' => sub {
  my $store = open_store(new_storage());
  is $store->_dbh->selectrow_array('SELECT version FROM overnet_mail_schema'), 4, 'inbound schema marker is four';
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
subtest 'failed inbound imports roll back real PostgreSQL large objects' => sub {
  for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries commit)) {
    my $location     = new_storage();
    my $store        = prepared($location);
    my $original     = receive($store);
    my $original_oid = body_oid($store, $raw);
    my $before       = snapshot($store);
    install_failure($store, $stage, 'INSERT') if $stage ne 'commit';
    my $new = Overnet::Mail::RawMessage->new(raw_bytes => "private new LO $stage\0\xff");
    my @imports;
    my $error;
    {
      local $store->_dbh->{Callbacks} = {
        do => sub {
          my ($dbh, $sql, $attrs, @bind) = @_;
          push @imports, $bind[1] if is_insert($sql, 'blossom_blob_data');
          return;
        },
        commit => sub { die "LO commit interrupted\n" if $stage eq 'commit'; return },
      };
      $error = dies { receive($store, idempotency_key => 'new-key', message => $new) };
    }

    # DBI callback attributes need explicit restoration before same-handle retry.
    $store->_dbh->{Callbacks} = {};
    $known_oids{$_} = 1 for @imports;
    like $error, qr/(?:blob|database) operation failed|LO commit interrupted/,
      'real insertion or commit fault is not custody';
    is scalar @imports,                            1, 'real PostgreSQL large object was imported before failure';
    is existing_oids($store->_dbh, @imports),      0, 'rollback removes new large object itself, not only its mapping';
    is body_oid($store, $raw),                     $original_oid, 'earlier bytes retain same authoritative LO mapping';
    is existing_oids($store->_dbh, $original_oid), 1,             'earlier authoritative large object remains present';
    is snapshot($store), $before, 'failed import preserves original routes, counters, and custody rows';
    remove_failure($store, $stage) if $stage ne 'commit';
    is receive($store), $original, 'original routed receipt remains replayable';
    my $retry = receive($store, idempotency_key => 'new-key', message => $new);
    is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $retry->{entry_id})->{message}->raw_bytes,
      $new->raw_bytes, 'same request safely retries exactly its original bytes';
    is counts($store), [2, 2, 0, 2, 0, 0, 0, 0], 'retry adds only one membership and LO mapping';
    $store->disconnect;
  }
};

subtest 'real PostgreSQL SIGKILL recovery before and after routed commit' => sub {
  require_fork();
  for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries commit)) {
    my $location = new_storage();
    my $initial  = prepared($location);
    my $before   = snapshot($initial);
    $initial->disconnect;
    my $job = spawn_job(
      $location,
      sub {
        my ($store, $task) = @_;
        my @imports;
        my $pause = sub {
          write_event(
            $task,
            'interrupted',
            {
              oids         => \@imports,
              counts       => counts($store),
              visible_oids => existing_oids($store->_dbh, @imports),
            }
          );
          await_event($task, 'never_release');
          return;
        };
        local $store->_dbh->{Callbacks} = {
          do => sub {
            my ($dbh, $sql, @bind) = @_;
            push @imports, $bind[2] if is_insert($sql, 'blossom_blob_data');
            if ($stage ne 'commit' && is_insert($sql, $stage)) {
              local $dbh->{Callbacks} = {};
              $dbh->do($sql, @bind);
              $pause->();
              undef $_;
            }
            return;
          },
          commit => sub { $pause->() if $stage eq 'commit'; return },
        };
        return receive($store);
      }
    );
    start_jobs($job);
    my $checkpoint = await_event($job, 'interrupted');
    $known_oids{$_} = 1 for @{$checkpoint->{oids}};
    is scalar @{$checkpoint->{oids}}, 1, "$stage interruption follows real LO import";
    is $checkpoint->{visible_oids},   1, 'uncommitted LO exists inside worker transaction';
    my $expected =
        $stage eq 'blossom_blob_data' ? [1, 0, 0, 0, 0, 0, 0, 0]
      : $stage eq 'blossom_blobs'     ? [1, 1, 0, 0, 0, 0, 0, 0]
      :                                 [1, 1, 0, 1, 0, 0, 0, 0];
    is $checkpoint->{counts}, $expected, 'target mutation genuinely completed before hard interruption';
    terminate_job($job);
    my $store = open_store($location);
    is snapshot($store), $before, 'SIGKILL rolls back new custody but preserves durable route and mailbox';
    is existing_oids($store->_dbh, @{$checkpoint->{oids}}), 0, 'SIGKILL removes imported LO itself';
    my $receipt = receive($store);
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'original retry gets first UID';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'retry commits one membership and content copy';
    $store->disconnect;
  }
  my $location = new_storage();
  prepared($location)->disconnect;
  my $job = spawn_job(
    $location,
    sub {
      my ($store, $task) = @_;
      my $receipt = receive($store);
      write_event($task, 'committed', {receipt => $receipt, autocommit => $store->_dbh->{AutoCommit} ? 1 : 0});
      await_event($task, 'never_release');
      return;
    }
  );
  start_jobs($job);
  my $checkpoint = await_event($job, 'committed');
  is $checkpoint->{autocommit}, 1, 'receipt committed before acknowledgement was lost';
  terminate_job($job);
  my $store = open_store($location);
  is receive($store, received_at => 999), $checkpoint->{receipt},   'reopened replay recovers exact committed receipt';
  is counts($store),                      [1, 1, 0, 1, 0, 0, 0, 0], 'postcommit death never duplicates receipt or LO';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes,
    $raw->raw_bytes, 'postcommit death retains every opaque byte';
  receive($store, idempotency_key => 'after-recovery');
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1, 2],
    'later receipt never reuses committed UID';
  $store->disconnect;
};

subtest 'route lookup shares serialized acceptance under stronger connection defaults' => sub {
  require_fork();
  for my $isolation ('repeatable read', 'serializable') {
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
        my (@lookups, @inserts);
        local $store->_dbh->{Callbacks} = {
          selectrow_array => sub {
            my ($dbh, $sql) = @_;
            if ($sql =~ /FROM recipient_routes/sm) {
              local $dbh->{Callbacks} = {};
              push @lookups,
                {
                autocommit  => $dbh->{AutoCommit} ? 1 : 0,
                isolation   => $dbh->selectrow_array('SHOW transaction_isolation'),
                transaction => $dbh->selectrow_array('SELECT txid_current()'),
                };
            }
            return;
          },
          do => sub {
            my ($dbh, $sql) = @_;
            if (is_insert($sql, 'mailbox_entries')) {
              local $dbh->{Callbacks} = {};
              push @inserts, $dbh->selectrow_array('SELECT txid_current()');
            }
            return;
          },
        };
        write_event($task, 'attempting', 1);
        my $result = deliver($store);
        return {result => $result, lookups => \@lookups, inserts => \@inserts};
      },
      $isolation
    );
    await_event($registrar, 'ready');
    my $ready = await_event($receiver, 'ready');
    is $ready->{default_isolation}, $isolation, 'receiver genuinely inherits stronger default';
    write_event($registrar, 'go', 1);
    await_event($registrar, 'uncommitted');
    write_event($receiver, 'go', 1);
    await_event($receiver, 'attempting');
    my $observer = connect_db($location);
    my $deadline = time + 2;
    my $waiting;

    while (time < $deadline) {
      $waiting = $observer->selectrow_array(q{SELECT wait_event = 'advisory' FROM pg_stat_activity WHERE pid = ?},
        undef, $ready->{backend_pid});
      last if $waiting;
      sleep 0.01;
    }
    ok $waiting, 'receiver is blocked on real PostgreSQL serialization lock';
    $observer->disconnect;
    write_event($registrar, 'release', 1);
    collect_job($registrar);
    my $completed = collect_job($receiver);
    is $completed->{result}{status},         'received', 'receiver observes route committed by previous lock holder';
    is scalar @{$completed->{lookups}},      1,          'route lookup executes once';
    is $completed->{lookups}[0]{autocommit}, 0,          'route lookup is inside acceptance transaction';
    is $completed->{lookups}[0]{isolation}, 'read committed',
      'fresh read-committed snapshot observes waiting predecessor';
    is $completed->{inserts}, [$completed->{lookups}[0]{transaction}],
      'route and receipt insertion use same transaction ID';
    my $store = open_store($location);
    is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$completed->{result}{receipt}],
      'one routed receipt committed';
    $store->disconnect;
  }
};

subtest 'temporary recipient routes cannot shadow authoritative bindings' => sub {
  my $location = new_storage();
  my $store    = prepared($location);
  $store->_dbh->do(q{CREATE TEMP TABLE recipient_routes (recipient TEXT, mailbox_id TEXT)});
  $store->_dbh->do(q{INSERT INTO pg_temp.recipient_routes VALUES ('alice@example.test', 'attacker-box')});
  is register($store), {recipient => 'alice@example.test', mailbox_id => 'recipient-box'},
    'registration reads persistent route';
  my $receipt = receive($store);
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt], 'delivery follows persistent route';
  is $store->mailbox_state(mailbox_id => 'attacker-box'), undef,
    'shadow route cannot select or provision another mailbox';
  is $store->_dbh->selectall_arrayref('SELECT * FROM pg_temp.recipient_routes'),
    [['alice@example.test', 'attacker-box']],
    'temporary shadow remains untouched';
  $store->disconnect;
  $store = open_store($location);
  is receive($store), $receipt, 'authoritative receipt survives destruction of temporary route';
  $store->disconnect;
};

subtest 'schema three is rejected without modifying rows, constraints or LOs' => sub {
  my $location = new_storage();
  my $store    = prepared($location);
  receive($store);
  my $oid = body_oid($store, $raw);
  my $dbh = $store->_dbh;
  $dbh->do('DROP TABLE recipient_routes');
  $dbh->do('ALTER TABLE mailbox_entries DROP COLUMN receipt_namespace');
  $dbh->do('ALTER TABLE mailbox_entries ADD UNIQUE(mailbox_id, idempotency_key)');
  $dbh->do('ALTER TABLE overnet_mail_schema DROP CONSTRAINT overnet_mail_schema_version_check');
  $dbh->do('UPDATE overnet_mail_schema SET version = 3');
  $dbh->do('ALTER TABLE overnet_mail_schema ADD CHECK (version = 3)');
  my %rows = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY 1") }
    (@tables, qw(mailboxes mailbox_uidvalidity overnet_mail_schema));
  my $schema_sql = q{SELECT c.relname, c.relkind, c.relpersistence, a.attnum, a.attname,
    format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attidentity
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
    WHERE n.nspname = ? ORDER BY c.relname, a.attnum};
  my $constraint_sql = q{SELECT c.conname, pg_get_constraintdef(c.oid) FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = ? ORDER BY c.conname};
  my $before_schema      = $dbh->selectall_arrayref($schema_sql,     undef, $location);
  my $before_constraints = $dbh->selectall_arrayref($constraint_sql, undef, $location);
  $store->disconnect;
  $dbh = connect_db($location);
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/unsupported mail store schema/,
    'schema three is never migrated';
  is $dbh->selectall_arrayref($schema_sql,     undef, $location), $before_schema, 'old relations and indexes unchanged';
  is $dbh->selectall_arrayref($constraint_sql, undef, $location), $before_constraints, 'old constraints unchanged';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY 1"), $rows{$table}, "rejection preserves $table rows";
  }
  is $dbh->selectrow_array('SELECT lo_get(?)', undef, $oid), $raw->raw_bytes, 'rejection preserves every old LO byte';
  ok $dbh->{AutoCommit}, 'rejection leaves no open transaction';
  $dbh->disconnect;
};

cleanup();
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
sub new_storage { return provision(); }

sub require_fork {
  if (!$Config{d_fork}) {
    bail_out 'required PostgreSQL inbound recovery tests need fork' if $required;
    plan skip_all => 'fork is unavailable';
  }
  return;
}

sub install_failure {
  my ($store, $table, $event) = @_;
  $store->_dbh->do(
q{CREATE FUNCTION fail_inbound() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private@example.test secret'; END $$}
  );
  $store->_dbh->do("CREATE TRIGGER fail_inbound AFTER $event ON $table FOR EACH ROW EXECUTE FUNCTION fail_inbound()");
  return;
}

sub remove_failure {
  my ($store, $table) = @_;
  $store->_dbh->do("DROP TRIGGER fail_inbound ON $table");
  $store->_dbh->do('DROP FUNCTION fail_inbound()');
  return;
}

sub damage_content {
  my ($store, $damage) = @_;
  my $oid = body_oid($store, $raw);
  $known_oids{$oid} = 1;
  my $dbh = $store->_dbh;
  if ($damage eq 'changed_bytes') {
    $dbh->selectrow_array(q{SELECT lo_put(?, 0, decode(repeat('00', ?), 'hex'))}, undef, $oid, $raw->size_bytes);
  } elsif ($damage eq 'metadata_size') {
    $dbh->do('UPDATE blossom_blobs SET size = 1');
  } elsif ($damage eq 'metadata_type') {
    $dbh->do(q{UPDATE blossom_blobs SET type = 'private@example.test secret'});
  } elsif ($damage eq 'missing_bytes') {
    $dbh->selectrow_array('SELECT lo_unlink(?)', undef, $oid);
  } else {
    my $constraints = $dbh->selectcol_arrayref(
q{SELECT conname FROM pg_constraint WHERE conrelid = 'mailbox_entries'::regclass AND confrelid = 'blossom_blobs'::regclass}
    );
    $dbh->do('ALTER TABLE mailbox_entries DROP CONSTRAINT ' . $dbh->quote_identifier($_)) for @{$constraints};
    $dbh->do('DELETE FROM blossom_blobs');
  }
  return;
}

sub allocator {
  my ($store) = @_;
  return $store->_dbh->selectrow_array('SELECT next_value FROM mailbox_uidvalidity WHERE singleton = 1');
}

sub body_oid {
  my ($store, $raw) = @_;
  return $store->_dbh->selectrow_array('SELECT body_oid FROM blossom_blob_data WHERE storage_key = ?',
    undef, $raw->content_sha256);
}

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
  my $schema = 'om_inbound_' . $$ . '_' . ++$sequence . '_' . int(rand(1_000_000));
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
