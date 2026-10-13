use strictures 2;

use File::Temp qw(tempdir);
use Test2::V0;
use Sub::Util qw(set_prototype);

# Never discover a server or choose a local connection implicitly. The CI
# PostgreSQL job requires this suite, while an unconfigured developer may skip.
my $dsn = $ENV{OVERNET_TEST_PG_DSN};
if (!defined $dsn || !length $dsn) {
  bail_out 'OVERNET_TEST_PG_DSN is required' if $ENV{OVERNET_REQUIRE_POSTGRES};
  plan skip_all => 'set OVERNET_TEST_PG_DSN to run PostgreSQL delivery runner tests';
}
my $dependencies = eval {
  require DBI;
  require DBD::Pg;
  require Overnet::Mail::Store::Postgres;
  require Overnet::Mail::DeliveryRunner;
  require Overnet::Mail::Transport::LoopbackSMTP;
  1;
};
if (!$dependencies) {
  bail_out 'PostgreSQL runner test dependencies are required' if $ENV{OVERNET_REQUIRE_POSTGRES};
  plan skip_all => 'DBD::Pg and Net::Blossom PostgreSQL 0.001004 are required';
}

my $directory = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $directory;
my (@schemas, @handles, %created_oids);
my $serial  = 0;
my $control = connect_db();
bail_out 'cannot connect to the configured PostgreSQL test database' if !$control;
my $cleanup_done;
END { cleanup() if $control && !$cleanup_done }

# Capture only this transaction's LOs, including any which might survive a
# fault. A database-wide before/after difference could include other clients.
my $prepare = Net::Blossom::Server::Backend::Postgres::BlobStore::_Upload->can('prepare');
my $capture = mock 'Net::Blossom::Server::Backend::Postgres::BlobStore::_Upload' => override => [
  prepare => sub {
    my ($upload) = @_;
    my $key      = $prepare->(@_);
    my $oids     = $upload->store->dbh->selectcol_arrayref(
      q{SELECT oid FROM pg_largeobject_metadata WHERE xmin::text = (txid_current() % 4294967296)::text});
    $created_oids{$_} = 1 for @{$oids};
    return $key;
  }
];

# These tests exercise real Pg custody and fencing, not SMTP wire behavior.
# Deterministic clock advancement at genuine DB calls avoids sleep races and
# proves that time inside claim/finish is charged to the correct budget.
my ($monotonic, $wall, $sent, $handoff);
my @deadlines;
my $clock_mock = mock 'Overnet::Mail::DeliveryRunner' => override =>
  [clock_gettime => set_prototype(q{;$}, sub { return $monotonic })];
my $transport      = Overnet::Mail::Transport::LoopbackSMTP->new(port => 1_024, attempt_seconds => 4);
my $transport_mock = mock 'Overnet::Mail::Transport::LoopbackSMTP' => override => [
  deliver => sub {
    my ($self, $claim, %args) = @_;
    ++$sent;
    push @deadlines, $args{deadline};
    $handoff->($claim) if $handoff;
    return {outcome => 'confirmed', stage => 'final', smtp_code => 250, private => 'blind@example.test body'};
  }
];

subtest 'impossible lease configuration fails before claiming PostgreSQL custody' => sub {
  my ($fixture, $store, $receipt) = fixture('impossible');
  my $commits = 0;
  {
    local $store->dbh->{Callbacks} = {commit => sub { ++$commits; return }};
    like dies { runner($store, lease_seconds => 8)->run_once(mailbox_id => 'box') },
      qr/runner lease must exceed attempt, settlement and rounding budgets/sm,
      'a nominal lease without usable attempt and reserve headroom is rejected';
  }
  is $commits,                                      0, 'invalid configuration never enters a claim transaction';
  is $sent,                                         0, 'invalid configuration never invokes transport';
  is [@{row($store, $receipt)}{qw(state attempt)}], ['ready', 0], 'no attempt is consumed';
  $store->disconnect;
};

subtest 'claim latency consumes the fixed attempt and settlement admission budget' => sub {
  for my $case (
    ['short',          9,  2,    'commit', 0],
    ['exact',          9,  1,    'commit', 1],
    ['body_latency',   9,  1.25, 'body',   0],
    ['commit_latency', 20, 13,   'commit', 0],
    ['remaining',      20, 2,    'commit', 1],
  ) {
    my ($label, $lease, $latency, $stage, $admitted) = @{$case};
    subtest $label => sub {
      my ($fixture, $store, $receipt) = fixture($label);
      my ($commits, $bodies) = (0, 0);
      my $result;
      {
        local $store->dbh->{Callbacks} = {
          selectrow_array => sub {
            my ($dbh, $sql) = @_;
            if ($sql =~ /\ASELECT lo_get\(/sm) {
              ++$bodies;
              $monotonic += $latency if $stage eq 'body';
            }
            return;
          },
          commit => sub {
            ++$commits;
            $monotonic += $latency if $stage eq 'commit' && $commits == 1;
            return;
          },
        };
        $result = runner($store, lease_seconds => $lease)->run_once(mailbox_id => 'box');
      }
      is $bodies,  1,                 'claim loaded the real PostgreSQL large object';
      is $commits, $admitted ? 2 : 1, 'only admitted handoffs attempt a settlement transaction';
      is $sent,    $admitted,         'insufficient post-claim headroom never calls transport';
      is $result,
        result(
        $receipt,
        $admitted ? 'recorded'                                     : 'unrecorded',
        $admitted ? (state => 'delivered', outcome => 'confirmed') : (error => 'lease_unavailable')
        ),
        'result distinguishes durable delivery from an unsent committed lease';
      if ($admitted) {
        is $deadlines[0], 1_000 + $lease - 1 - 3,
          'SMTP receives the original lease deadline less rounding and settlement headroom';
      }
      is $transport->attempt_seconds, 4, 'admission never shortens the configured SMTP attempt';
      $store->disconnect;
      $store = open_store($fixture->{schema});
      my $row = row($store, $receipt);
      is [@{$row}{qw(state attempt)}], [$admitted ? 'delivered' : 'leased', 1],
        'reconnection observes the real claim and any acknowledged settlement';
      $store->disconnect;
    };
  }
};

subtest 'later wall observation may tighten but cannot extend the lease cutoff' => sub {
  my ($fixture, $store, $receipt) = fixture('wall_cutoff');
  my $commits = 0;
  my $result;
  {
    local $store->dbh->{Callbacks} = {
      commit => sub {
        if (++$commits == 1) {
          $monotonic += 2;
          $wall = 108;
        }
        return;
      }
    };
    $result = runner($store)->run_once(mailbox_id => 'box');
  }
  is $result, result($receipt, 'recorded', outcome => 'confirmed', state => 'delivered'),
    'remaining full attempt and reserve are admitted after a forward wall observation';
  is $deadlines[0], 1_010, 'earlier second-sample cutoff limits SMTP, including one-second integer rounding';
  is $sent,         1,     'one fixed attempt runs';
  $store->disconnect;
  $store = open_store($fixture->{schema});
  is row($store, $receipt)->{state}, 'delivered', 'confirmed settlement survives a new Pg connection';
  is runner($store)->run_once(mailbox_id => 'box'), {status => 'idle'}, 'terminal custody never resends';
  is $sent,                                                             1, 'idle runner leaves transport untouched';
  $store->disconnect;
};

subtest 'failed or lost finish acknowledgement never invents durable success' => sub {
  for my $failure (qw(update commit lost_ack)) {
    subtest $failure => sub {
      my ($fixture, $store, $receipt) = fixture($failure);
      my $faults = 0;
      my $result;
      {
        local $store->dbh->{Callbacks} = {
          do => sub {
            my ($dbh, $sql) = @_;
            if ($failure eq 'update' && $sent && $sql =~ /\AUPDATE deliveries SET state = \?/sm) {
              ++$faults;
              die 'private blind@example.test completion update fault';
            }
            return;
          },
          commit => sub {
            my ($dbh) = @_;
            if ($failure ne 'update' && $sent) {
              ++$faults;
              if ($failure eq 'lost_ack') {
                local $dbh->{Callbacks} = {};
                $dbh->commit;
              }
              die 'private blind@example.test completion acknowledgement fault';
            }
            return;
          },
        };
        $result = runner($store)->run_once(mailbox_id => 'box');
      }
      is $faults, 1, 'fault occurs only at the intended real settlement boundary';
      is $result, result($receipt, 'unrecorded', outcome => 'confirmed', error => 'completion_failed'),
        'remote custody evidence remains honest and private exception text cannot escape';
      is $sent, 1, 'no internal resend follows an ambiguous settlement';
      $store->disconnect;
      $store = open_store($fixture->{schema});
      my $lost = $failure eq 'lost_ack';
      is [@{row($store, $receipt)}{qw(state attempt last_outcome lease_until)}],
        [$lost ? 'delivered' : 'leased', 1, $lost ? 'confirmed' : undef, $lost ? undef : 120],
        'fresh connection distinguishes rollback from committed custody with a lost acknowledgement';
      $monotonic = 2_000;
      $wall      = 120;
      my $recovered = runner($store)->run_once(mailbox_id => 'box');
      is $recovered,
        $lost ? {status => 'idle'} : result(
        $receipt, 'recorded',
        attempt => 2,
        outcome => 'confirmed',
        state   => 'delivered'
        ),
        'recovery uses durable state instead of interpreting unrecorded as a known rollback';
      is $sent, $lost ? 1 : 2, 'only a genuinely expired unsettled lease may retry';
      is row($store, $receipt)->{uncertain_attempts}, $lost ? 0 : 1,
        'recovery retains the duplicate-delivery risk after a failed settlement';
      is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
        message_bytes(), 'immutable accepted bytes survive every completion fault and recovery';
      $store->disconnect;
    };
  }
};

subtest 'monotonic expiry refuses completion even when the wall clock stalls' => sub {
  my ($fixture, $store, $receipt) = fixture('mono_expiry');
  $handoff = sub { $monotonic += 19; return };
  my $updates = 0;
  my $result;
  {
    local $store->dbh->{Callbacks} = {
      do => sub {
        my ($dbh, $sql) = @_;
        ++$updates if $sql =~ /\AUPDATE deliveries SET state = \?/sm;
        return;
      }
    };
    $result = runner($store)->run_once(mailbox_id => 'box');
  }
  is $result, result($receipt, 'unrecorded', outcome => 'confirmed', error => 'completion_failed'),
    'exact conservative monotonic cutoff cannot be settled using a stale but nondecreasing wall time';
  is $updates, 0, 'expired completion is refused before the database update';
  is $sent,    1, 'one remote outcome remains evidence only';
  $store->disconnect;
  $store = open_store($fixture->{schema});
  is [@{row($store, $receipt)}{qw(state attempt last_outcome)}], ['leased', 1, undef],
    'no local confirmation appears after reconnect';
  $store->disconnect;
};

subtest 'settlement reserve is headroom and does not bound Pg commit latency' => sub {
  my ($fixture, $store, $receipt) = fixture('slow_settlement');
  my $commits = 0;
  my $result;
  {
    local $store->dbh->{Callbacks} = {
      commit => sub {
        $monotonic += 30 if ++$commits == 2;
        return;
      }
    };
    $result = runner($store)->run_once(mailbox_id => 'box');
  }
  is $commits, 2, 'claim and finish both commit through the real database';
  cmp_ok $monotonic, '>', 1_019, 'injected database latency outlasts the conservative lease cutoff';
  is $result, result($receipt, 'recorded', outcome => 'confirmed', state => 'delivered'),
    'an acknowledged fenced commit remains durable success after slow database completion';
  $store->disconnect;
  $store = open_store($fixture->{schema});
  is row($store, $receipt)->{state}, 'delivered', 'status proves slow settlement really committed';
  $store->disconnect;
};

subtest 'replacement worker fences a delayed finish even with its old clock' => sub {
  my ($fixture, $store, $receipt) = fixture('replacement');
  my $replacement_store = open_store($fixture->{schema});
  my $original          = Overnet::Mail::Store->can('finish_delivery');
  my ($replacement, $sampled_now, $result);
  {
    # Pause immediately before the original Store transaction, after the runner
    # sampled completion time. A replacement owns the next generation before the
    # delayed original reaches the real Pg fence check. No transaction is faked.
    my $delay = mock 'Overnet::Mail::Store' => override => [
      finish_delivery => sub {
        my ($self, %args) = @_;
        $sampled_now = $args{now};
        $monotonic += 20;
        $wall        = 120;
        $replacement = $replacement_store->claim_delivery(mailbox_id => 'box', now => 120, lease_seconds => 20);
        return $original->($self, %args);
      }
    ];
    $result = runner($store)->run_once(mailbox_id => 'box');
  }
  is $sampled_now, 100, 'delayed completion really holds the original unexpired wall sample';
  is $result, result($receipt, 'unrecorded', outcome => 'confirmed', error => 'completion_failed'),
    'old remote confirmation cannot overwrite the replacement fence';
  is $replacement->{attempt},            2, 'replacement receives a distinct durable attempt token';
  is $replacement->{uncertain_attempts}, 1, 'replacement records ambiguous prior custody';
  is [@{row($replacement_store, $receipt)}{qw(state attempt last_outcome)}], ['leased', 2, 'lease_expired'],
    'failed original completion leaves replacement ownership intact';
  is $replacement_store->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $replacement->{delivery_id},
    attempt     => $replacement->{attempt},
    now         => 121,
    outcome     => 'confirmed'
  )->{state}, 'delivered', 'only the current fence may settle';
  $store->disconnect;
  $replacement_store->disconnect;
  $store = open_store($fixture->{schema});
  is [@{row($store, $receipt)}{qw(state attempt uncertain_attempts)}], ['delivered', 2, 1],
    'new connection retains replacement success and the original uncertainty';
  is $sent, 1, 'stale completion never initiates another handoff';
  $store->disconnect;
};

ok cleanup(), 'cleanup removes only this suite schemas and transaction-owned large objects';
done_testing;

sub connect_db {
  return eval {
    DBI->connect(
      $dsn,
      $ENV{OVERNET_TEST_PG_USER}     // q{},
      $ENV{OVERNET_TEST_PG_PASSWORD} // q{},
      {RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 0}
    );
  };
}

sub fixture {
  my ($label) = @_;
  ($monotonic, $wall, $sent, $handoff) = (1_000, 100, 0, undef);
  @deadlines = ();
  my $schema = 'pgmail_runner_' . $$ . q{_} . ++$serial . q{_} . $label;
  $control->do('CREATE SCHEMA ' . $control->quote_identifier($schema));
  push @schemas, $schema;
  my $dbh = open_schema($schema);
  Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
  Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
  my $store      = Overnet::Mail::Store::Postgres->new(dbh => $dbh);
  my $submission = Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => message_bytes()),
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test']),
  );
  my $receipt = $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'key', item => $submission);
  return ({schema => $schema}, $store, $receipt);
}

sub open_schema {
  my ($schema) = @_;
  my $dbh = connect_db();
  die "test connection unavailable\n" if !$dbh;
  push @handles, $dbh;
  $dbh->do('SET search_path = ' . $dbh->quote_identifier($schema) . ', pg_catalog');
  return $dbh;
}

sub open_store {
  my ($schema) = @_;
  return Overnet::Mail::Store::Postgres->new(dbh => open_schema($schema));
}

sub runner {
  my ($store, %options) = @_;
  return Overnet::Mail::DeliveryRunner->new(
    store              => $store,
    transport          => $transport,
    clock              => sub { return $wall },
    retry_after        => 60,
    lease_seconds      => 20,
    settlement_seconds => 3,
    %options,
  );
}

sub result {
  my ($receipt, $status, %extra) = @_;
  return {status => $status, delivery_id => $receipt->{delivery_ids}[0], attempt => 1, outcome => undef, %extra};
}

sub row {
  my ($store, $receipt) = @_;
  return $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0];
}

sub message_bytes {
  return "Subject: PostgreSQL lease runner\r\n\r\n" . ("opaque custody bytes\r\n" x 4_000);
}

sub cleanup {
  return 1 if $cleanup_done;
  my $ok = 1;
  for my $dbh (@handles) {
    next if !$dbh->{Active};
    eval {
      $dbh->{Callbacks}   = {};
      $dbh->{HandleError} = undef;
      $dbh->rollback if !$dbh->{AutoCommit};
      $dbh->disconnect;
      1;
    } or $ok = 0;
  }
  for my $schema (@schemas) {
    eval {
      $control->do('DROP SCHEMA ' . $control->quote_identifier($schema) . ' CASCADE');
      1;
    } or $ok = 0;
  }
  for my $oid (keys %created_oids) {
    eval {
      $control->selectrow_array(
        'SELECT lo_unlink(?) WHERE EXISTS (SELECT 1 FROM pg_largeobject_metadata WHERE oid = ?)',
        undef, $oid, $oid);
      1;
    } or $ok = 0;
  }
  $control->disconnect;
  $cleanup_done = 1;
  return $ok;
}
