use strictures 2;

use File::Temp   qw(tempdir);
use Scalar::Util qw(refaddr);
use Test2::V0;

# This suite must never choose a host, database, or local transport on its own.
# CI sets REQUIRE_POSTGRES so a missing service/dependency cannot masquerade as green.
my $dsn = $ENV{OVERNET_TEST_PG_DSN};
if (!defined $dsn || !length $dsn) {
  bail_out 'OVERNET_TEST_PG_DSN is required' if $ENV{OVERNET_REQUIRE_POSTGRES};
  plan skip_all => 'set OVERNET_TEST_PG_DSN to run real PostgreSQL custody tests';
}
my $dependencies = eval {
  require DBI;
  require DBD::Pg;
  require Overnet::Mail::Store::Postgres;
  1;
};
if (!$dependencies) {
  bail_out 'PostgreSQL test dependencies are required' if $ENV{OVERNET_REQUIRE_POSTGRES};
  plan skip_all => 'DBD::Pg and Net::Blossom PostgreSQL 0.001004 are required';
}

my $directory = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $directory;
my (@schemas, @handles, %created_oids, @staging_paths);
my $serial  = 0;
my $control = connect_db();
bail_out 'cannot connect to the configured PostgreSQL test database' if !$control;
my $cleanup_done;
is Net::Blossom::Server::Backend::Postgres->VERSION, '0.001004',
  'integration suite targets pinned upstream PostgreSQL backend';
END { cleanup() if $control && !$cleanup_done }

# Observe only large objects created by our own transaction. Never clean up a
# database-wide before/after difference, which could belong to another client.
my $prepare = Net::Blossom::Server::Backend::Postgres::BlobStore::_Upload->can('prepare');
my $begin   = Net::Blossom::Server::Backend::Postgres::BlobStore->can('begin_upload');
my $capture = mock 'Net::Blossom::Server::Backend::Postgres::BlobStore::_Upload' => override => [
  prepare => sub {
    my ($upload) = @_;
    my $key = $prepare->(@_);
    remember_transaction_los($upload->store->dbh);
    return $key;
  }
];
my $capture_paths = mock 'Net::Blossom::Server::Backend::Postgres::BlobStore' => override => [
  begin_upload => sub {
    my $upload = $begin->(@_);
    push @staging_paths, $upload->path;
    is((stat($upload->path))[2] & 0777, 0600, 'staged message is readable only by its owner');
    return $upload;
  }
];

subtest 'all octets and upstream shared-handle interoperability' => sub {
  my $fixture = fixture('octets');
  my $store   = make_store($fixture);
  my $dbh     = $fixture->{dbh};
  my $bytes   = "Subject: opaque bytes\r\n\r\n" . pack('C*', 0 .. 255) x 300;
  my $raw     = raw($bytes);
  is refaddr($store->dbh),                  refaddr($dbh), 'constructor preserves the supplied handle';
  is refaddr($store->_blob_store->dbh),     refaddr($dbh), 'upstream bytes share the mail transaction handle';
  is refaddr($store->_metadata_store->dbh), refaddr($dbh), 'upstream metadata shares the mail transaction handle';
  is $dbh->selectrow_array('SELECT version FROM overnet_mail_schema'), 1, 'PostgreSQL schema version is explicit';
  is $dbh->selectrow_array(
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = 'contents'",
    undef, $fixture->{schema}),
    0,
    'mail has no duplicate body table';

  my $receipt = accept_item($store, 'octets', $raw);
  is $receipt->{content_sha256}, $raw->content_sha256, 'digest covers exact opaque bytes';
  my $record = $store->load(mailbox_id => 'box', message_id => $receipt->{message_id});
  is $record->{message}->raw_bytes, $bytes, 'all 256 octets survive acceptance and lo_get';
  ok !utf8::is_utf8($record->{message}->raw_bytes), 'returned content is a byte string';
  ok !defined $record->{envelope},                  'raw inbound content has no invented envelope';
  is stream_bytes($store->_blob_store->get_blob($raw->content_sha256)), $bytes,
    'public upstream stream reads committed mail bytes across multiple reads';
  is stream_bytes(
    $store->_blob_store->get_blob_range($raw->content_sha256, offset => 29, length => 260, size => length($bytes))),
    substr($bytes, 29, 260),
    'upstream range stream interoperates with mail-created large objects';
  my $metadata = $store->_metadata_store->find_blob($raw->content_sha256);
  is $metadata->{size}, length($bytes),             'upstream metadata holds byte length';
  is $metadata->{type}, 'application/octet-stream', 'mail uses opaque content type';
  is $dbh->selectrow_array('SELECT COUNT(*) FROM blossom_owners'), 0,
    'mail does not invent public Blossom owners from private mailboxes';
  my $oid = body_oid($dbh, $raw);
  is $dbh->selectrow_array('SELECT pg_get_userbyid(lomowner) = current_user FROM pg_largeobject_metadata WHERE oid = ?',
    undef, $oid),
    1,
    'accepted large object is owned by the connected database role';
  ok !-e $staging_paths[-1], 'successful acceptance removes staging';

  my $stream_raw = raw("upstream first\0\xff\r\n");
  upstream_upload($store, $stream_raw);
  my $oid_before = body_oid($dbh, $stream_raw);
  my $adopted    = accept_item($store, 'upstream', $stream_raw);
  is body_oid($dbh, $stream_raw), $oid_before, 'existing valid upstream bytes are reused without copying';
  is $store->load(mailbox_id => 'box', message_id => $adopted->{message_id})->{message}->raw_bytes,
    $stream_raw->raw_bytes, 'mail reads content first stored by the public upstream components';
  is counts($dbh), [2, 2, 2, 0, 0, 0], 'two contents have two logical records and no outbox';

  # Upstream creates and then unlinks a temporary LO for a duplicate upload.
  my $before = transaction_lo_count($store);
  upstream_upload($store, $stream_raw);
  is body_oid($dbh, $stream_raw),  $oid_before, 'duplicate upstream preparation retains the original large object';
  is transaction_lo_count($store), $before,     'duplicate upload leaves no test-created large-object leak';
  is counts($dbh),                 [2, 2, 2, 0, 0, 0], 'duplicate upload changes neither mapping nor metadata';

  $store->disconnect;
  $store = reopen($fixture);
  is accept_item($store, 'octets', $raw), $receipt, 'receipt survives a new connection';
  is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
    $bytes, 'binary bytes survive reconnect';
};

subtest 'idempotency, private envelopes, and explicit archival promotion' => sub {
  my $fixture = fixture('identity');
  my $store   = make_store($fixture);
  my $dbh     = $fixture->{dbh};
  my $raw     = raw("Message-ID: <same\@example.test>\r\nTo: visible\@example.test\r\n\r\nbody\0\xff");
  my $item    = submission($raw, ['visible@example.test', 'blind@example.test', 'blind@example.test']);
  my $archive = accept_item($store, 'archive', $item);
  is counts($dbh), [1, 1, 1, 3, 0, 0],                'archival submission stores its envelope but creates no queue';
  is accept_item($store, 'archive', $item), $archive, 'identical archival replay has stable identity';
  my $other = accept_item($store, 'another-key', $item);
  isnt $other->{message_id}, $archive->{message_id}, 'same bytes and Message-ID do not deduplicate logical messages';
  my $foreign = $store->accept_item(mailbox_id => 'other', idempotency_key => 'archive', item => $item);
  isnt $foreign->{message_id}, $archive->{message_id}, 'idempotency key is mailbox-scoped';
  ok !defined $store->load(mailbox_id => 'other', message_id => $archive->{message_id}), 'load is mailbox-scoped';
  my $loaded = $store->load(mailbox_id => 'box', message_id => $archive->{message_id});
  is $loaded->{envelope}->sender,     q{},                         'null reverse path is preserved';
  is $loaded->{envelope}->recipients, $item->envelope->recipients, 'private recipient order and duplicates persist';
  unlike $loaded->{message}->raw_bytes, qr/blind\@/, 'blind envelope recipients never enter raw bytes';

  for my $changed (
    raw('different content'),
    submission($raw, ['blind@example.test',   'visible@example.test', 'blind@example.test']),
    submission($raw, ['visible@example.test', 'blind@example.test']),
    submission($raw, $item->envelope->recipients, 'sender@example.test'),
    $raw,
  ) {
    like dies { accept_item($store, 'archive', $changed) }, qr/idempotency key conflicts/,
      'changed same-key content or envelope is rejected';
  }
  is $dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1, 'logical records share one immutable body';
  my $receipt = $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'archive', item => $item);
  is $receipt->{message_id}, $archive->{message_id}, 'same-key explicit enqueue promotes the archived message';
  is scalar @{$receipt->{delivery_ids}},    3, 'one stable delivery for every ordered recipient, including duplicates';
  is enqueue($store, $item, 'archive'),     $receipt, 'promotion replay preserves submission and delivery IDs';
  is accept_item($store, 'archive', $item), $archive, 'archive API keeps its original receipt shape';
  is $store->deliveries(mailbox_id => 'other', submission_id => $receipt->{submission_id}), [],
    'outbox status is mailbox-scoped';
  my $rows = $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id});
  is [map { $_->{position} } @{$rows}], [0, 1, 2], 'recipient positions are stable';
  ok !exists $rows->[0]->{recipient} && !exists $rows->[0]->{message}, 'status exposes neither addresses nor bytes';
  my $claim = $store->claim_delivery(mailbox_id => 'box', now => 100);
  is $claim->{recipient}, 'visible@example.test', 'claim returns only its own explicit recipient';
  ok !exists $claim->{envelope}, 'claim cannot disclose the complete private envelope';
  is $claim->{message}->raw_bytes,                      $raw->raw_bytes, 'claim preserves original MIME bytes';
  is finish($store, $claim, 101, 'confirmed')->{state}, 'delivered',     'confirmed evidence settles one recipient';
  is enqueue($store, $item, 'archive'),                 $receipt,        'replay after delivery keeps stable IDs';
  is $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0]->{state}, 'delivered',
    'replay cannot reset a settled delivery';
  $store->disconnect;
  $store = reopen($fixture);
  is enqueue($store, $item, 'archive'), $receipt, 'promoted receipt persists across connection ownership changes';
};

subtest 'outbox retry deadlines, fencing, and terminal states' => sub {
  my $fixture = fixture('outcomes');
  my $store   = make_store($fixture);
  my $item    = submission(raw('queue outcomes'), ['one@example.test', 'two@example.test', 'three@example.test']);
  my $receipt = enqueue($store, $item);
  ok !defined $store->claim_delivery(mailbox_id => 'wrong', now => 100), 'wrong mailbox cannot claim';
  my @claims = map { $store->claim_delivery(mailbox_id => 'box', now => 100, lease_seconds => 10) } 1 .. 3;
  is [map { $_->{attempt} } @claims], [1, 1, 1], 'independent recipients start with fencing generation one';
  ok !defined $store->claim_delivery(mailbox_id => 'box', now => 100), 'live leases are not reclaimable';
  is finish($store, $claims[0], 101, 'confirmed')->{state}, 'delivered', 'confirmed is terminal';
  is finish($store, $claims[1], 101, 'permanent')->{state}, 'failed',    'permanent failure affects only its recipient';
  my $uncertain = finish($store, $claims[2], 101, 'uncertain', retry_after => 30);
  is $uncertain->{state},              'uncertain', 'lost acknowledgement is explicitly uncertain';
  is $uncertain->{uncertain_attempts}, 1,           'ambiguity is counted';
  is $uncertain->{next_attempt_at},    131,         'retry deadline is durable';
  $store->disconnect;
  $store = reopen($fixture);
  ok !defined $store->claim_delivery(mailbox_id => 'box', now => 130), 'reconnect does not shorten retry delay';
  my $retried = $store->claim_delivery(mailbox_id => 'box', now => 131, lease_seconds => 10);
  is $retried->{attempt}, 2, 'exact retry deadline creates a new fencing token';
  like dies { finish($store, $claims[2], 131, 'confirmed') }, qr/lease is missing, stale or expired/,
    'old token cannot acknowledge new work';
  my $settled = finish($store, $retried, 132, 'confirmed');
  is $settled->{state},              'delivered', 'a fresh confirmed result can settle ambiguity';
  is $settled->{uncertain_attempts}, 1,           'confirmation preserves prior duplicate-delivery risk';
  like dies { finish($store, $retried, 132, 'permanent') }, qr/lease is missing, stale or expired/,
    'terminal delivery cannot settle twice';
  ok !defined $store->claim_delivery(mailbox_id => 'box', now => 999),
    'terminal rows are never automatically restarted';
  is enqueue($store, $item), $receipt, 'stable replay cannot restart terminal rows';
};

for my $outcome (qw(transient uncertain lease_expired)) {
  subtest "five-attempt exhaustion for $outcome" => sub {
    my $fixture = fixture("exhaust_$outcome");
    my $store   = make_store($fixture);
    my $item    = submission(raw("exhaust $outcome"), ['one@example.test']);
    my $receipt = enqueue($store, $item);
    my $last;
    for my $attempt (1 .. 5) {
      my $claim = $store->claim_delivery(mailbox_id => 'box', now => $attempt, lease_seconds => 1);
      is $claim->{attempt}, $attempt, 'attempt token increases monotonically';
      if ($outcome eq 'lease_expired') {
        like dies { finish($store, $claim, $attempt + 1, 'confirmed') }, qr/lease is missing, stale or expired/,
          'exact lease boundary fences late settlement';
        ok !defined $store->claim_delivery(mailbox_id => 'other', now => $attempt + 1), 'other mailbox has no claim';
        is $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0]->{state}, 'leased',
          'another mailbox cannot expire this lease';
      } else {
        $last = finish($store, $claim, $attempt, $outcome, retry_after => 1);
        is $last->{state}, $attempt == 5 ? 'exhausted' : $outcome eq 'transient' ? 'deferred' : 'uncertain',
          'retry transition obeys fixed attempt bound';
      }
      $store->disconnect;
      $store = reopen($fixture);
    }
    ok !defined $store->claim_delivery(mailbox_id => 'box', now => 6),
      'sixth claim is refused after final expiry or retry';
    $last = $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0];
    is $last->{state}, 'exhausted', 'exhaustion is distinct from confirmed delivery or permanent rejection';
    is $last->{uncertain_attempts}, $outcome eq 'transient' ? 0 : 5, 'unknown outcomes remain visible';
    is $last->{last_outcome},       $outcome,                        'last cause survives reconnect';
    is enqueue($store, $item),      $receipt,                        'same-key replay cannot restart exhaustion';
  };
}

subtest 'rollback restores mapping, metadata, mail, and large-object bytes' => sub {
  my $fixture  = fixture('rollback');
  my $store    = make_store($fixture);
  my $dbh      = $fixture->{dbh};
  my $raw      = raw("retained custody\0\xff");
  my $receipt  = accept_item($store, 'retained', $raw);
  my $oid      = body_oid($dbh, $raw);
  my $baseline = counts($dbh);

  # delete_blob unlinks the LO before deleting its mapping. The FK then fails.
  # A real upstream transaction must restore both the row and the LO itself.
  my $unlinked_inside;
  {
    local $dbh->{Callbacks} = {
      do => sub {
        my ($handle, $sql) = @_;
        if ($sql =~ /DELETE FROM .*blossom_blob_data/sm) {
          $unlinked_inside =
            !$handle->selectrow_array('SELECT 1 FROM pg_largeobject_metadata WHERE oid = ?', undef, $oid);
        }
        return;
      }
    };
    like dies {
      $store->_metadata_store->with_transaction(sub { $store->_blob_store->delete_blob($raw->content_sha256) })
    }, qr/database operation failed/, 'mail foreign key rejects upstream deletion after LO unlink';
  }
  ok $unlinked_inside, 'upstream really unlinked the large object before the failing row deletion';
  is body_oid($dbh, $raw), $oid, 'rollback restores the original LO mapping';
  is stream_bytes($store->_blob_store->get_blob($raw->content_sha256)), $raw->raw_bytes,
    'rollback restores readable large-object bytes after unlink';
  like dies {
    $store->_metadata_store->with_transaction(sub { $store->_metadata_store->delete_blob($raw->content_sha256) })
  }, qr/database operation failed/, 'mail foreign key also protects upstream metadata';
  is counts($dbh), $baseline, 'failed external deletion leaves all accepted rows unchanged';

  for my $point (qw(after_prepare after_metadata after_mail after_queue before_commit)) {
    my $new        = submission(raw("rollback $point\0\xff"), ['private@example.test']);
    my $prior_oids = existing_created_oids();
    my $error;
    if ($point eq 'after_prepare') {
      my $insert = mock 'Net::Blossom::Server::Backend::Postgres::MetadataStore' => override =>
        [insert_blob => sub { die "private failure after LO creation\n" }];
      $error = dies { enqueue($store, $new, $point) };
    } else {
      local $dbh->{Callbacks} = $point eq 'before_commit' ? {commit => sub { die "injected commit interruption\n" }} : {
        do => sub {
          my ($handle, $sql) = @_;
          my $target =
              $point eq 'after_metadata' ? qr/INSERT INTO messages/sm
            : $point eq 'after_mail'     ? qr/INSERT INTO recipients/sm
            :                              qr/INSERT INTO deliveries/sm;
          if ($sql =~ $target) {
            if ($point eq 'after_queue') {
              local $handle->{Callbacks} = {};
              $handle->do($sql, @_[2 .. $#_]);
            }
            die "injected write interruption\n";
          }
          return;
        }
      };
      $error = dies { enqueue($store, $new, $point) };
    }
    like $error, qr/blob operation failed|injected (?:write|commit) interruption/,
      "$point fails before acceptance receipt";
    unlike $error, qr/private\@|rollback $point|private failure/, 'errors omit private data';
    is counts($dbh),            $baseline, "$point rolls back every mail, envelope, outbox, mapping, and metadata row";
    is existing_created_oids(), $prior_oids, "$point also rolls back the imported PostgreSQL large object";
    ok !-e $staging_paths[-1], "$point removes the staged upload";
    is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
      $raw->raw_bytes, 'earlier accepted custody survives unrelated rollback';
  }

  {
    my $fault =
      mock 'Overnet::Mail::Store::Postgres' => override => [_blob_bytes => sub { return 'altered prepared bytes' }];
    like dies { accept_item($store, 'bad-readback', raw('new checked content')) }, qr/content integrity/,
      'new LO bytes are verified inside their creating transaction';
  }
  is counts($dbh), $baseline, 'failed in-transaction readback rolls back the complete acceptance';
};

subtest 'postcommit lost acknowledgements recover stable receipts' => sub {
  my $fixture = fixture('lost_ack');
  my $store   = make_store($fixture);
  my $dbh     = $fixture->{dbh};
  my $item    = submission(raw("committed despite lost ack\0\xff"), ['one@example.test', 'two@example.test']);
  {
    local $dbh->{Callbacks} = {
      commit => sub {
        my ($handle) = @_;
        local $handle->{Callbacks} = {};
        $handle->commit;
        die "commit acknowledgement interrupted\n";
      }
    };
    like dies { enqueue($store, $item) }, qr/commit acknowledgement interrupted/,
      'actual COMMIT followed by lost acknowledgement returns no success';
  }
  is counts($dbh), [1, 1, 1, 2, 1, 2],
    'actual committed mail, content, envelope, and queue survive acknowledgement failure';
  ok !-e $staging_paths[-1], 'ambiguous commit still cleans staging';
  my $message_id    = $dbh->selectrow_array('SELECT message_id FROM messages');
  my $submission_id = $dbh->selectrow_array('SELECT submission_id FROM submissions');
  my $delivery_ids  = $dbh->selectcol_arrayref('SELECT delivery_id FROM deliveries ORDER BY position');
  $store->disconnect;
  $store = reopen($fixture);
  my $replay = enqueue($store, $item);
  is $replay,
    {
    message_id     => $message_id,
    submission_id  => $submission_id,
    delivery_ids   => $delivery_ids,
    content_sha256 => $item->message->content_sha256
    },
    'same request key resolves unknown outcome to exact committed identities';
  is counts($fixture->{dbh}), [1, 1, 1, 2, 1, 2], 'receipt recovery creates no duplicate content or delivery';

  my $second = submission(raw('cleanup ack failure'), ['three@example.test']);
  {
    my $fault = mock 'Net::Blossom::Server::Backend::Postgres::BlobStore::_Upload' => override =>
      [commit => sub { die "private cleanup path\n" }];
    like dies { enqueue($store, $second, 'cleanup') }, qr/acceptance committed, retry the original/,
      'postcommit staging failure explicitly reports committed acceptance';
  }
  my $second_replay = enqueue($store, $second, 'cleanup');
  is enqueue($store, $second, 'cleanup'), $second_replay,     'postcommit cleanup failure has stable replay too';
  is counts($fixture->{dbh}),             [2, 2, 2, 3, 2, 3], 'cleanup failure cannot erase committed custody';
};

subtest 'transaction durability, bounded locks, and captured schema' => sub {
  my $fixture = fixture('settings');
  my $store   = make_store($fixture);
  my $dbh     = $fixture->{dbh};
  $dbh->do(q{SET synchronous_commit = 'off'});
  $dbh->do(q{SET search_path = pg_catalog});
  my $settings = $store->_transaction(
    sub {
      return [map { $dbh->selectrow_array("SHOW $_") }
          qw(transaction_isolation synchronous_commit lock_timeout statement_timeout search_path)];
    }
  );
  is $settings->[0], 'read committed', 'mail selects READ COMMITTED within each transaction';
  is $settings->[1], 'on',             'mail commits synchronously despite caller session default';
  is $settings->[2], '2500ms',         'lock wait is bounded';
  is $settings->[3], '10s',            'statement execution is bounded';
  like $settings->[4], qr/\Q$fixture->{schema}\E/, 'captured application schema is reinstated transaction-locally';
  my $receipt = accept_item($store, 'captured', raw('captured schema content'));
  is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
    'captured schema content', 'search-path drift cannot redirect accepted custody';
  $dbh->do('SET search_path = ' . $dbh->quote_identifier($fixture->{schema}) . ', pg_catalog');
  $dbh->begin_work;
  like dies { accept_item($store, 'nested', raw('nested content')) }, qr/transaction is already active/,
    'caller-owned transaction cannot receive a premature receipt';
  ok !$dbh->{AutoCommit}, 'nested rejection leaves caller transaction untouched';
  $dbh->rollback;
  $store->disconnect;
  $store->disconnect;
  like dies { accept_item($store, 'closed', raw('closed content')) }, qr/store is closed/,
    'disconnected stores fail closed';
};

subtest 'temporary table names cannot shadow persistent mail custody' => sub {
  my $fixture  = fixture('temp_shadow');
  my $dbh      = $fixture->{dbh};
  my @shadowed = qw(messages deliveries blossom_blob_data);
  for my $table (@shadowed) {
    my $name = $dbh->quote_identifier($table);
    $dbh->do("CREATE TEMP TABLE $name (sentinel TEXT NOT NULL)");
    my $temporary = $dbh->quote_identifier('pg_temp', $table);
    $dbh->do("INSERT INTO $temporary (sentinel) VALUES (?)", undef, "untouched $table");
  }

  # The session omits pg_temp here, so PostgreSQL would otherwise give the
  # temporary schema implicit first priority for relation name resolution.
  my $store   = make_store($fixture);
  my $raw     = raw("persistent despite temp shadows\0\xff\r\n");
  my $item    = submission($raw, ['private@example.test']);
  my $receipt = enqueue($store, $item);
  is enqueue($store, $item), $receipt, 'temporary names cannot redirect same-key replay';
  is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
    $raw->raw_bytes, 'mail reads persistent large-object mapping despite temporary shadow';
  is stream_bytes($store->_blob_store->get_blob($raw->content_sha256)), $raw->raw_bytes,
    'upstream schema-qualified cloned stream reads the persistent body';
  is $store->_metadata_store->find_blob($raw->content_sha256)->{size}, $raw->size_bytes,
    'upstream qualified metadata still identifies the persistent content';
  my $claim = $store->claim_delivery(mailbox_id => 'box', now => 10);
  is $claim->{delivery_id}, $receipt->{delivery_ids}->[0],          'claim finds the persistent delivery';
  is finish($store, $claim, 11, 'confirmed')->{state}, 'delivered', 'settlement updates only the persistent delivery';
  is $store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})->[0]->{state},
    'delivered', 'status resolves the durable queue with temporary names present';

  for my $table (@shadowed) {
    my $persistent = $dbh->quote_identifier($fixture->{schema}, $table);
    my $temporary  = $dbh->quote_identifier('pg_temp',          $table);
    is $dbh->selectrow_array("SELECT COUNT(*) FROM $persistent"), 1,
      "one durable $table row exists in the application schema";
    is $dbh->selectcol_arrayref("SELECT sentinel FROM $temporary"), ["untouched $table"],
      "temporary $table sentinel remains untouched";
  }
  $store->disconnect;
  $store = reopen($fixture);
  is enqueue($store, $item), $receipt, 'receipt survives disconnect that destroys the temporary tables';
  is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
    $raw->raw_bytes, 'persistent custody survives destruction of every temporary shadow';
};

subtest 'constructor arguments and schema selection are fail-closed' => sub {
  like dies { Overnet::Mail::Store::Postgres->new }, qr/dbh/, 'dbh is required';
  for my $bad (undef, [], {}, 'dbi:Pg:secret', raw('not a database')) {
    like dies { Overnet::Mail::Store::Postgres->new(dbh => $bad) }, qr/idle PostgreSQL DBI handle/,
      'non-DBI constructor input is rejected';
  }
  my $sqlite = DBI->connect('dbi:SQLite:dbname=:memory:', q{}, q{}, {RaiseError => 1, PrintError => 0});
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $sqlite) }, qr/idle PostgreSQL DBI handle/,
    'a real SQLite DBI handle is not PostgreSQL';
  $sqlite->disconnect;
  my $fixture = fixture('arguments');
  my $dbh     = $fixture->{dbh};
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh, path => '/private/mail.sqlite') },
    qr/does not accept a SQLite path/, 'SQLite path is rejected';
  for my $bad (undef, [], 0, -1, '01', '1.5') {
    like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh, max_message_bytes => $bad) }, qr/positive integer/,
      'invalid acceptance limit is rejected';
  }
  $dbh->begin_work;
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/idle PostgreSQL DBI handle/,
    'constructor rejects active caller transaction';
  ok !$dbh->{AutoCommit}, 'constructor leaves rejected caller transaction active';
  $dbh->rollback;
  for my $path (q{''}, 'pg_catalog') {
    $dbh->do("SET search_path = $path");
    like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/requires an application schema/,
      'missing or system current schema is rejected';
  }
  my $mixed = fixture('mixed', provision => 0, mixed_case => 1);
  like dies { make_store($mixed) }, qr/requires an application schema/,
    'unsupported quoted uppercase schema is rejected';

  # Server durability settings are not changed. Inject only their read result on
  # a genuine connected DBI handle to cover both refusal branches safely.
  for my $setting (qw(fsync full_page_writes)) {
    $dbh->do('SET search_path = ' . $dbh->quote_identifier($fixture->{schema}) . ', pg_catalog');
    local $dbh->{Callbacks} = {
      selectrow_array => sub {
        my (undef, $sql) = @_;
        if ($sql eq "SHOW $setting") {
          $_[1] = q{SELECT 'off'};
        }
        return;
      }
    };
    like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/durability settings unavailable/,
      "disabled $setting is refused";
  }
};

my @schema_cases = (
  ['missing', sub { $_[0]->do('DROP TABLE blossom_blob_data') },        qr/unsupported Blossom PostgreSQL schema/],
  ['foreign', sub { $_[0]->do('CREATE TABLE unrelated (id INTEGER)') }, qr/unsupported mail store schema/],
  [
    'unlogged',
    sub { $_[0]->do('ALTER TABLE blossom_blob_data SET UNLOGGED') },
    qr/unsupported Blossom PostgreSQL schema/
  ],
  [
    'nullable',
    sub { $_[0]->do('ALTER TABLE blossom_blobs ALTER COLUMN size DROP NOT NULL') },
    qr/unsupported Blossom PostgreSQL schema/
  ],
  [
    'column_type',
    sub { $_[0]->do('ALTER TABLE blossom_blobs ALTER COLUMN size TYPE INTEGER') },
    qr/unsupported Blossom PostgreSQL schema/
  ],
  [
    'extra_column',
    sub { $_[0]->do('ALTER TABLE blossom_blob_data ADD COLUMN incompatible TEXT NOT NULL') },
    qr/unsupported Blossom PostgreSQL schema/
  ],
  [
    'view',
    sub {
      $_[0]->do('DROP TABLE blossom_blob_data');
      $_[0]->do(q{CREATE VIEW blossom_blob_data AS SELECT ''::text AS storage_key, 0::oid AS body_oid});
    },
    qr/unsupported Blossom PostgreSQL schema/
  ],
  [
    'missing_pk',
    sub { $_[0]->do('ALTER TABLE blossom_blob_data DROP CONSTRAINT blossom_blob_data_pkey') },
    qr/unsupported Blossom PostgreSQL constraints/
  ],
  [
    'wrong_fk',
    sub {
      $_[0]->do('ALTER TABLE blossom_owners DROP CONSTRAINT blossom_owners_sha256_fkey');
      $_[0]->do('ALTER TABLE blossom_owners ADD FOREIGN KEY (sha256) REFERENCES blossom_blobs(sha256)');
    },
    qr/unsupported Blossom PostgreSQL constraints/
  ],
  [
    'extra_constraint',
    sub { $_[0]->do('ALTER TABLE blossom_blobs ADD CHECK (size >= 0)') },
    qr/unsupported Blossom PostgreSQL constraints/
  ],
);
for my $case (@schema_cases) {
  subtest "reject incompatible schema $case->[0]" => sub {
    my $fixture = fixture("reject_$case->[0]");
    $case->[1]->($fixture->{dbh});
    like dies { make_store($fixture) }, $case->[2], 'constructor refuses incompatible preprovisioned schema';
    is $fixture->{dbh}->selectrow_array(
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = ? AND table_name = 'messages'",
      undef, $fixture->{schema}),
      0,
      'schema rejection does not partially deploy mail tables';
    ok $fixture->{dbh}->{AutoCommit}, 'schema rejection rolls back the initialization transaction';
  };
}

subtest 'empty, partial, and unknown mail schema versions are rejected' => sub {
  my $empty = fixture('empty', provision => 0);
  like dies { make_store($empty) }, qr/unsupported Blossom PostgreSQL schema/,
    'adapter never silently provisions an empty database';
  for my $mutation (
    ['partial',       sub { $_[0]->do('DROP TABLE deliveries') }],
    ['mail_unlogged', sub { $_[0]->do('ALTER TABLE overnet_mail_schema SET UNLOGGED') }],
    [
      'mail_view',
      sub {
        $_[0]->do('DROP TABLE overnet_mail_schema');
        $_[0]->do('CREATE VIEW overnet_mail_schema AS SELECT 1 AS version');
      }
    ],
    ['version_empty', sub { $_[0]->do('DELETE FROM overnet_mail_schema') }],
    [
      'version_unknown',
      sub {
        $_[0]->do('ALTER TABLE overnet_mail_schema DROP CONSTRAINT overnet_mail_schema_version_check');
        $_[0]->do('UPDATE overnet_mail_schema SET version = 2');
      }
    ],
    [
      'version_multiple',
      sub {
        $_[0]->do('ALTER TABLE overnet_mail_schema DROP CONSTRAINT overnet_mail_schema_version_check');
        $_[0]->do('INSERT INTO overnet_mail_schema (version) VALUES (2)');
      }
    ],
  ) {
    my $fixture = fixture($mutation->[0]);
    my $store   = make_store($fixture);
    $mutation->[1]->($fixture->{dbh});
    $store->disconnect;
    my $expected = $mutation->[0] eq 'mail_view'
      || $mutation->[0] eq 'mail_unlogged' ? qr/unsupported mail store durability/ : qr/unsupported mail store schema/;
    like dies { reopen($fixture) }, $expected, 'incomplete or unsupported mail schema has no implicit migration';
    if ($mutation->[0] eq 'mail_view') {
      is $fixture->{dbh}->selectrow_array('SELECT version FROM overnet_mail_schema'), 1,
        'rejected marker view retains its original value';
      is $fixture->{dbh}->selectrow_array(
'SELECT c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? AND c.relname = ?',
        undef,
        $fixture->{schema},
        'overnet_mail_schema'
        ),
        'v',
        'constructor does not replace or alter the rejected marker view';
      ok $fixture->{dbh}->{AutoCommit}, 'rejected marker view leaves no initialization transaction active';
    }

  }
};

ok cleanup(), 'cleanup removes only this test process schemas and tracked large objects';
done_testing;

sub connect_db {
  return eval {
    DBI->connect(
      $dsn,
      $ENV{OVERNET_TEST_PG_USER}     // q{},
      $ENV{OVERNET_TEST_PG_PASSWORD} // q{},
      {
        RaiseError     => 1,
        PrintError     => 0,
        AutoCommit     => 1,
        pg_enable_utf8 => 0,
      }
    );
  };
}

sub fixture {
  my ($label, %options) = @_;
  my $schema = 'pgmail_' . $$ . q{_} . ++$serial . q{_} . $label;
  $schema = ucfirst $schema if $options{mixed_case};
  $control->do('CREATE SCHEMA ' . $control->quote_identifier($schema));
  push @schemas, $schema;
  my $dbh = open_schema($schema);
  if (!exists $options{provision} || $options{provision}) {
    Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
    Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
  }
  return {schema => $schema, dbh => $dbh};
}

sub open_schema {
  my ($schema) = @_;
  my $dbh = connect_db();
  die "test connection unavailable\n" if !$dbh;
  push @handles, $dbh;
  $dbh->do('SET search_path = ' . $dbh->quote_identifier($schema) . ', pg_catalog');
  return $dbh;
}

sub make_store {
  my ($fixture, %options) = @_;
  return Overnet::Mail::Store::Postgres->new(dbh => $fixture->{dbh}, %options);
}

sub reopen {
  my ($fixture, %options) = @_;
  $fixture->{dbh} = open_schema($fixture->{schema});
  return make_store($fixture, %options);
}

sub raw {
  return Overnet::Mail::RawMessage->new(raw_bytes => $_[0]);
}

sub submission {
  my ($message, $recipients, $sender) = @_;
  return Overnet::Mail::Submission->new(
    message  => $message,
    envelope => Overnet::Mail::Envelope->new(
      sender     => defined $sender ? $sender : q{},
      recipients => $recipients,
    )
  );
}

sub accept_item {
  my ($store, $key, $item) = @_;
  return $store->accept_item(mailbox_id => 'box', idempotency_key => $key, item => $item);
}

sub enqueue {
  my ($store, $item, $key) = @_;
  return $store->enqueue_submission(
    mailbox_id      => 'box',
    idempotency_key => defined $key ? $key : 'request',
    item            => $item
  );
}

sub finish {
  my ($store, $claim, $now, $outcome, %extra) = @_;
  return $store->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $claim->{delivery_id},
    attempt     => $claim->{attempt},
    now         => $now,
    outcome     => $outcome,
    %extra
  );
}

sub counts {
  my ($dbh) = @_;
  return [map { $dbh->selectrow_array("SELECT COUNT(*) FROM $_") }
      qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries)];
}

sub body_oid {
  my ($dbh, $raw) = @_;
  return $dbh->selectrow_array('SELECT body_oid FROM blossom_blob_data WHERE storage_key = ?', undef,
    $raw->content_sha256);
}

sub stream_bytes {
  my ($stream) = @_;
  die "expected upstream stream\n" if !defined $stream;
  my $bytes = q{};
  my $chunk;
  while ($stream->read($chunk, 113)) {
    $bytes .= $chunk;
  }
  $stream->close;
  return $bytes;
}

sub upstream_upload {
  my ($store, $raw) = @_;
  my $upload = $store->_blob_store->begin_upload;
  $upload->write($raw->raw_bytes);
  $store->_metadata_store->with_transaction(
    sub {
      $store->_metadata_store->lock_blob($raw->content_sha256);
      my %metadata = (
        sha256   => $raw->content_sha256,
        size     => $raw->size_bytes,
        type     => 'application/octet-stream',
        uploaded => time
      );
      my $key = $upload->prepare(%metadata);
      $store->_metadata_store->insert_blob(%metadata, storage_key => $key);
      return 1;
    }
  );
  $upload->commit;
  return;
}

sub remember_transaction_los {
  my ($dbh) = @_;
  my $oids = $dbh->selectcol_arrayref(
    q{SELECT oid FROM pg_largeobject_metadata WHERE xmin::text = (txid_current() % 4294967296)::text});
  $created_oids{$_} = 1 for @{$oids};
  return;
}

sub existing_created_oids {
  return [
    grep { $control->selectrow_array('SELECT 1 FROM pg_largeobject_metadata WHERE oid = ?', undef, $_) }
    sort { $a <=> $b } keys %created_oids
  ];
}

sub transaction_lo_count {
  return scalar @{existing_created_oids()};
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
