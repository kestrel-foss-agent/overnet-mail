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
  plan skip_all => 'set OVERNET_TEST_PG_DSN to run real PostgreSQL mailbox tests';
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
my $message = Overnet::Mail::RawMessage->new(
  raw_bytes => "Message-ID: <mailbox\@example.test>\r\nSubject: PostgreSQL receipt\r\n\r\n"
    . (pack('C*', 0 .. 255) x 400));

subtest 'shared authoritative content, recipient privacy, pagination, and offline reopen' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  is $store->_dbh->selectrow_array('SELECT version FROM overnet_mail_schema'), 4,
    'PostgreSQL mailbox schema marker is explicit';
  my $first = receive($store);
  is [sort keys %{$first}], [qw(content_sha256 entry_id received_at)], 'receipt contains only recipient metadata';
  is receive($store, received_at => 999), $first,                      'same key keeps original timestamp and receipt';
  my $second = receive($store, idempotency_key => 'second-delivery', received_at => 1);
  my $other  = receive($store, mailbox_id => 'other-recipient');
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$first}, uid => 1}, {%{$second}, uid => 2}],
    'two distinct keys for shared bytes receive distinct local UIDs';
  is $store->mailbox_uid_entries(mailbox_id => 'other-recipient'), [{%{$other}, uid => 1}],
    'other recipient independently starts at UID one despite a different global entry ID';
  is $store->mailbox_state(mailbox_id => 'other-recipient'),
    {uidvalidity => 2, uidnext => 2, message_count => 1}, 'other mailbox owns a different validity';
  isnt $second->{entry_id}, $first->{entry_id}, 'different key creates distinct membership for the same bytes';
  isnt $other->{entry_id},  $first->{entry_id}, 'same key in another mailbox creates distinct membership';
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$first, $second],
    'listing is entry-ordered rather than timestamp-ordered and excludes other mailboxes';
  is $store->mailbox_entries(mailbox_id => 'recipient-box', limit => 1), [$first], 'bounded first page';
  is $store->mailbox_entries(mailbox_id => 'recipient-box', after_entry_id => $first->{entry_id}, limit => 1),
    [$second], 'cursor excludes the preceding entry';
  is $store->mailbox_entries(mailbox_id => 'absent'), [], 'unknown mailbox returns empty metadata';
  is $store->load_mailbox_entry(mailbox_id => 'other-recipient', entry_id => $first->{entry_id}), undef,
    'entry identifiers do not bypass mailbox scope';
  my $loaded = $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $first->{entry_id});
  is [sort keys %{$loaded}], [qw(content_sha256 entry_id message received_at)],
    'fetch has no envelope or archive fields';
  isa_ok $loaded->{message}, ['Overnet::Mail::RawMessage'];
  is $loaded->{message}->raw_bytes, $message->raw_bytes, 'all octets survive the authoritative PostgreSQL LO';
  ok !utf8::is_utf8($loaded->{message}->raw_bytes), 'opaque bytes are not decoded as text';
  is counts($store), [1, 1, 0, 3, 0, 0, 0, 0], 'three memberships share one LO and no sender records or Blossom owners';

  my $item = Overnet::Mail::Submission->new(
    message  => $message,
    envelope => Overnet::Mail::Envelope->new(
      sender     => 'sender@example.test',
      recipients => ['visible@example.test', 'blind@example.test']
    )
  );
  my $before_oid = body_oid($store, $message);
  my $outbox =
    $store->enqueue_submission(mailbox_id => 'recipient-box', idempotency_key => 'delivery-key', item => $item);
  is body_oid($store, $message), $before_oid, 'sender submission reuses recipient LO without creating a second copy';
  is counts($store), [1, 1, 0, 3, 1, 2, 1, 2], 'independent outbound custody does not create recipient membership';
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$first, $second],
    'sender archive key does not replace receipt';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $first->{entry_id}), $loaded,
    'private sender envelope never appears in a recipient projection';
  is $store->deliveries(mailbox_id => 'recipient-box', submission_id => $outbox->{submission_id})->[0]->{state},
    'ready',
    'receiving bytes does not settle or claim the independent outbox';
  $store->disconnect;
  $store = open_store($schema);
  is receive($store, received_at => 0), $first, 'exact receipt survives a new offline database connection';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $first->{entry_id})->{message}->raw_bytes,
    $message->raw_bytes, 'recipient retrieval requires only reopened authoritative storage';
  like dies { receive($store, received_at => '01') }, qr/bounded canonical integer/,
    'replay still validates its ignored later timestamp';
  like dies { receive($store, message => $item) }, qr/requires a RawMessage/,
    'private submission is not a recipient receipt';
  like dies { receive($store, message => Overnet::Mail::RawMessage->new(raw_bytes => 'different private bytes')) },
    qr/idempotency key conflicts/, 'same-key different content is refused';
  $store->disconnect;
};

subtest 'receipt-only custody protects mapping, metadata, and LO rollback' => sub {
  my $schema  = provision();
  my $store   = open_store($schema);
  my $receipt = receive($store);
  my $oid     = body_oid($store, $message);
  my $unlinked;
  {
    local $store->_dbh->{Callbacks} = {
      do => sub {
        my ($dbh, $sql) = @_;
        if ($sql =~ /DELETE FROM .*blossom_blob_data/sm) {
          $unlinked = !existing_oids($dbh, $oid);
        }
        return;
      }
    };
    like dies {
      $store->_metadata_store->with_transaction(sub { $store->_blob_store->delete_blob($message->content_sha256) });
    }, qr/database operation failed/, 'membership foreign key rejects mapping deletion after upstream LO unlink';
  }
  ok $unlinked, 'upstream genuinely unlinked the LO inside the failed transaction';
  is existing_oids($store->_dbh, $oid), 1, 'failed deletion restores the LO itself';
  like dies {
    $store->_metadata_store->with_transaction(sub { $store->_metadata_store->delete_blob($message->content_sha256) });
  }, qr/database operation failed/, 'membership directly retains Blossom metadata';
  is counts($store),  [1, 1, 0, 1, 0, 0, 0, 0], 'only recipient custody is needed to retain shared content';
  is receive($store), $receipt,                 'retention errors leave exact receipt replay intact';
  $store->disconnect;
};

for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries)) {
  subtest "$stage failure rolls back new content and retains earlier shared content" => sub {
    my $schema       = provision();
    my $store        = open_store($schema);
    my $original     = receive($store);
    my $original_oid = body_oid($store, $message);
    $store->_dbh->do(
q{CREATE FUNCTION fail_receipt() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'blind@example.test private body'; END $$}
    );
    $store->_dbh->do("CREATE TRIGGER fail_receipt AFTER INSERT ON $stage FOR EACH ROW EXECUTE FUNCTION fail_receipt()");
    my $new = Overnet::Mail::RawMessage->new(raw_bytes => "new private body $stage\0\xff");
    my @imports;
    my $error;
    {
      local $store->_dbh->{Callbacks} = {
        do => sub {
          my ($dbh, $sql, $attrs, @bind) = @_;
          push @imports, $bind[1] if is_insert($sql, 'blossom_blob_data');
          return;
        }
      };
      $error = dies { receive($store, idempotency_key => 'failing', message => $new) };
    }
    $known_oids{$_} = 1 for @imports;
    like $error,   qr/(?:blob|database) operation failed/, 'real PostgreSQL insertion failure yields no receipt';
    unlike $error, qr/blind\@|private body|INSERT|RAISE/,  'database diagnostics omit content and trigger SQL';
    is scalar @imports,                       1, 'a real PostgreSQL large object had been imported before failure';
    is existing_oids($store->_dbh, @imports), 0, 'rollback removes newly imported large object';
    is body_oid($store, $message), $original_oid,            'rollback retains previous shared mapping';
    is counts($store),             [1, 1, 0, 1, 0, 0, 0, 0], 'rollback retains only the earlier receipt and content';
    is $store->mailbox_state(mailbox_id => 'recipient-box'),
      {uidvalidity => 1, uidnext => 2, message_count => 1}, 'rollback consumes no additional UID';
    is allocator($store), 2, 'failed receipt does not consume global validity';

    if ($stage eq 'mailbox_entries') {
      like dies { receive($store, mailbox_id => 'another-recipient') }, qr/database operation failed/,
        'late failure also rejects adding a reference to existing content';
      is $store->mailbox_entries(mailbox_id => 'another-recipient'), [],
        'failed shared reference creates no phantom membership';
      is $store->mailbox_state(mailbox_id => 'another-recipient'), undef,
        'late failure rolls back implicit mailbox initialization';
      is allocator($store),                          2, 'late failure returns UIDVALIDITY allocation too';
      is existing_oids($store->_dbh, $original_oid), 1, 'failed shared reference never unlinks pre-existing bytes';
    }
    $store->_dbh->do("DROP TRIGGER fail_receipt ON $stage");
    is receive($store), $original, 'previous receipt remains replayable after failure';
    ok receive($store, idempotency_key => 'failing', message => $new), 'same request key can retry after rollback';
    is counts($store), [2, 2, 0, 2, 0, 0, 0, 0], 'successful retry commits only one additional receipt and content';
    is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1, 2],
      'retry commits consecutive UIDs despite the failed identity insert';
    $store->disconnect;
  };
}

subtest 'commit error and lost acknowledgement preserve the correct custody boundary' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
    like dies { receive($store) }, qr/commit interrupted/, 'precommit failure returns no receipt';
  }
  $store->_dbh->{Callbacks} = {};
  is counts($store), [(0) x @tables],                             'commit error rolls back membership and content';
  is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'commit error rolls back implicit mailbox';
  is allocator($store),                                    1, 'commit error rolls back global UIDVALIDITY allocation';
  {
    local $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "commit acknowledgement interrupted\n";
      }
    };
    like dies { receive($store) }, qr/commit acknowledgement interrupted/,
      'committed lost acknowledgement returns no success';
  }
  $store->disconnect;
  $store = open_store($schema);
  my $receipt = receive($store, received_at => 999);
  is $receipt->{received_at}, 123,                      'replayed receipt retains original committed timestamp';
  is counts($store),          [1, 1, 0, 1, 0, 0, 0, 0], 'acknowledgement loss never duplicates membership or bytes';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1},
    'lost acknowledgement replay leaves committed counters intact';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
    'lost acknowledgement replay preserves the original UID';
  $store->disconnect;
};

for my $damage (qw(changed_bytes metadata_size metadata_type unlinked_lo missing_both)) {
  subtest "corrupt $damage fails closed without repairing authoritative receipt content" => sub {
    my $schema  = provision();
    my $store   = open_store($schema);
    my $receipt = receive($store);
    my $oid     = body_oid($store, $message);
    $known_oids{$oid} = 1;
    if ($damage eq 'changed_bytes') {
      $store->_dbh->selectrow_array(q{SELECT lo_put(?, 0, decode(repeat('00', ?), 'hex'))},
        undef, $oid, $message->size_bytes);
    } elsif ($damage eq 'metadata_size') {
      $store->_dbh->do('UPDATE blossom_blobs SET size = 1');
    } elsif ($damage eq 'metadata_type') {
      $store->_dbh->do(q{UPDATE blossom_blobs SET type = 'blind@example.test private'});
    } elsif ($damage eq 'unlinked_lo') {
      $store->_dbh->selectrow_array('SELECT lo_unlink(?)', undef, $oid);
    } else {
      my $constraints = $store->_dbh->selectcol_arrayref(
        q{SELECT conname FROM pg_constraint WHERE conrelid = 'mailbox_entries'::regclass AND contype = 'f'});
      $store->_dbh->do('ALTER TABLE mailbox_entries DROP CONSTRAINT ' . $store->_dbh->quote_identifier($_))
        for @{$constraints};
      $store->_dbh->do('DELETE FROM blossom_blob_data');
      $store->_dbh->do('DELETE FROM blossom_blobs');
    }
    my $baseline = counts($store);
    my $error    = dies { $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id}) };
    like $error, qr/content (?:integrity|is missing)|database operation failed/,
      'corrupt retrieval is never successful';
    unlike $error, qr/blind\@|private|PostgreSQL receipt/, 'corruption error does not expose private stored values';
    like dies { $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1) },
      qr/content (?:integrity|is missing)|database operation failed/, 'UID fetch also refuses corrupt content';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'metadata-only UID listing does not read or repair the damaged body';
    like dies { receive($store) }, qr/content (?:integrity|is missing)|database operation failed/,
      'same-key replay verifies persisted content';
    like dies { receive($store, idempotency_key => 'new-key') },
      qr/content (?:integrity|is missing)|database operation failed/,
      'new membership cannot heal corruption behind existing custody';
    is counts($store), $baseline, 'failed retrieval and replay do not change corrupt data';
    $store->disconnect;
  };
}

subtest 'version-one sender storage is rejected without modifying any rows or LO bytes' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  my $item   = Overnet::Mail::Submission->new(
    message  => $message,
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => ['blind@example.test'])
  );
  $store->enqueue_submission(mailbox_id => 'sender-box', idempotency_key => 'old-outbox', item => $item);
  my $dbh = $store->_dbh;
  $dbh->do('DROP TABLE mailbox_entries');
  $dbh->do('ALTER TABLE overnet_mail_schema DROP CONSTRAINT overnet_mail_schema_version_check');
  $dbh->do('UPDATE overnet_mail_schema SET version = 1');
  $dbh->do('ALTER TABLE overnet_mail_schema ADD CHECK (version = 1)');
  my %rows = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY 1") }
    qw(blossom_blob_data blossom_blobs blossom_owners messages recipients submissions deliveries overnet_mail_schema);
  my $before_schema = $dbh->selectall_arrayref(
q{SELECT c.relname, c.relkind, c.relpersistence FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? ORDER BY c.relname},
    undef, $schema
  );
  my $oid = body_oid($store, $message);
  $store->disconnect;
  $dbh = connect_db($schema);
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/unsupported mail store schema/,
    'PostgreSQL schema one is not implicitly migrated';
  is $dbh->selectall_arrayref(
q{SELECT c.relname, c.relkind, c.relpersistence FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ? ORDER BY c.relname},
    undef,
    $schema
    ),
    $before_schema, 'rejected schema keeps all prior relations, sequences, and indexes';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY 1"), $rows{$table}, "old $table rows remain unchanged";
  }
  is $dbh->selectrow_array('SELECT lo_get(?)', undef, $oid), $message->raw_bytes,
    'rejection retains every prior large-object byte';
  ok $dbh->{AutoCommit}, 'rejection leaves no transaction active';
  $dbh->disconnect;
};

subtest 'temporary mailbox table cannot shadow authoritative recipient custody' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  for my $table (qw(mailbox_entries mailboxes mailbox_uidvalidity)) {
    $store->_dbh->do("CREATE TEMP TABLE $table (sentinel TEXT NOT NULL)");
    $store->_dbh->do("INSERT INTO pg_temp.$table VALUES ('untouched')");
  }
  my $receipt = receive($store);
  is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt],
    'receipt and listing resolve the persistent mailbox';
  is $store->load_mailbox_entry(mailbox_id => 'recipient-box', entry_id => $receipt->{entry_id})->{message}->raw_bytes,
    $message->raw_bytes, 'fetch resolves authoritative persistent membership';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1}, 'UID state resolves the persistent mailbox';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1}, 'ensure resolves the persistent mailbox and allocator';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
    'UID listing resolves persistent membership';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes,
    $message->raw_bytes, 'UID fetch resolves persistent membership';

  for my $table (qw(mailbox_entries mailboxes mailbox_uidvalidity)) {
    is $store->_dbh->selectcol_arrayref("SELECT sentinel FROM pg_temp.$table"), ['untouched'],
      "temporary $table sentinel remains untouched";
  }
  $store->disconnect;
  $store = open_store($schema);
  is receive($store), $receipt, 'membership survives destruction of the temporary table';
  $store->disconnect;
};

subtest 'real PostgreSQL concurrent replay and hard interruption recovery' => sub {
  if (!$Config{d_fork}) {
    bail_out 'required PostgreSQL mailbox recovery tests need fork' if $required;
    plan skip_all => 'fork is unavailable';
  }
  for my $conflicting (0, 1) {
    my $schema = provision();
    my @jobs;
    for my $index (0 .. 5) {
      my $raw =
        $conflicting && $index % 2 ? Overnet::Mail::RawMessage->new(raw_bytes => 'different private bytes') : $message;
      push @jobs, spawn_job(
        $schema,
        sub {
          my ($store) = @_;
          my $receipt = eval { receive($store, message => $raw, received_at => 100 + $index) };
          return {receipt => $receipt, error => $@};
        }
      );
    }
    start_jobs(@jobs);
    my @results   = map  { collect_job($_) } @jobs;
    my @successes = grep { defined $_->{receipt} } @results;
    my @failures  = grep { length $_->{error} } @results;
    is scalar @successes, $conflicting ? 3 : 6, 'only matching concurrent messages share the winning receipt';
    is scalar @failures,  $conflicting ? 3 : 0, 'conflicting same-key messages are rejected';
    my $receipt = $successes[0]->{receipt};
    is $_->{receipt}, $receipt, 'successful waiter observes identical original entry, digest, and timestamp'
      for @successes;

    for my $failure (@failures) {
      like $failure->{error},   qr/idempotency key conflicts/, 'different bytes cannot reuse the committed receipt';
      unlike $failure->{error}, qr/different|private|PostgreSQL receipt/, 'conflict errors omit content';
    }
    my $store = open_store($schema);
    is $store->mailbox_entries(mailbox_id => 'recipient-box'), [$receipt], 'concurrent writers commit one membership';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'concurrent losers leave no content or sender-side rows';
    is $store->mailbox_state(mailbox_id => 'recipient-box'),
      {uidvalidity => 1, uidnext => 2, message_count => 1}, 'replay and conflict races consume only one UID';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'all successful concurrent replays refer to the same durable UID';
    $store->disconnect;
  }

  for my $stage (qw(blossom_blob_data blossom_blobs mailbox_entries commit)) {
    my $schema = provision();
    my $job    = spawn_job(
      $schema,
      sub {
        my ($store, $task) = @_;
        my @imports;
        my $pause = sub {
          write_event($task, 'interrupted',
            {oids => \@imports, counts => counts($store), visible_oids => existing_oids($store->_dbh, @imports)});
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
    is scalar @{$checkpoint->{oids}}, 1, "$stage interruption occurs after real LO import";
    is $checkpoint->{visible_oids},   1, 'uncommitted LO exists in the worker transaction';
    my $expected =
        $stage eq 'blossom_blob_data' ? [1, 0, 0, 0, 0, 0, 0, 0]
      : $stage eq 'blossom_blobs'     ? [1, 1, 0, 0, 0, 0, 0, 0]
      :                                 [1, 1, 0, 1, 0, 0, 0, 0];
    is $checkpoint->{counts}, $expected, "$stage mutation really completed before hard interruption";
    terminate_job($job);
    my $store = open_store($schema);
    is counts($store),                                      [(0) x @tables], 'SIGKILL rolls back every uncommitted row';
    is existing_oids($store->_dbh, @{$checkpoint->{oids}}), 0,               'SIGKILL also rolls back uncommitted LO';
    is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'SIGKILL removes uncommitted mailbox state';
    is allocator($store),                                    1,     'SIGKILL consumes no UIDVALIDITY';
    ok receive($store), 'original receipt request safely retries';
    is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'retry commits exactly one recipient membership';
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box')->[0]->{uid}, 1,
      'retry after killed writer uses the first uncommitted UID';
    is $store->mailbox_state(mailbox_id => 'recipient-box'),
      {uidvalidity => 1, uidnext => 2, message_count => 1}, 'retry restores exactly one allocation';
    $store->disconnect;
  }

  my $schema = provision();
  my $job    = spawn_job(
    $schema,
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
  is $checkpoint->{autocommit}, 1, 'receipt committed before acknowledgement loss';
  terminate_job($job);
  my $store = open_store($schema);
  is receive($store, received_at => 999), $checkpoint->{receipt},
    'lost acknowledgement recovers the exact full receipt';
  is counts($store), [1, 1, 0, 1, 0, 0, 0, 0], 'committed receipt survives SIGKILL without a duplicate';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1}, 'committed counters survive SIGKILL and replay';
  receive($store, idempotency_key => 'after-recovery');
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1, 2],
    'new receipt does not reuse the UID committed before process death';
  $store->disconnect;
};

subtest 'durable empty mailboxes and bounded UID snapshots use the authoritative database' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  my $empty  = {uidvalidity => 1, uidnext => 1, message_count => 0};
  is $store->mailbox_state(mailbox_id => 'recipient-box'),              undef, 'unknown mailbox state is absent';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'),        [],    'unknown mailbox has no UID metadata';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1), undef, 'unknown mailbox has no UID body';
  is allocator($store),                                     1,      'read-only methods allocate no UIDVALIDITY';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $empty, 'empty mailbox allocates durable validity';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $empty, 'repeated initialization leaves state unchanged';
  is allocator($store),                                     2,      'only one validity was allocated';
  is counts($store), [(0) x @tables],                               'empty mailbox creates no content or receipt';
  $store->disconnect;
  $store = open_store($schema);
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $empty, 'empty state survives reconnect';
  my $first    = receive($store);
  my $second   = receive($store, idempotency_key => 'second', received_at => 1);
  my $snapshot = $store->mailbox_state(mailbox_id => 'recipient-box');
  my $page     = $store->mailbox_uid_entries(mailbox_id => 'recipient-box', limit => 1);
  is $page, [{%{$first}, uid => 1}], 'UID listing exposes only receipt metadata and UID';
  my $writer = open_store($schema);
  receive($writer, idempotency_key => 'later', received_at => 0);
  $writer->disconnect;
  my $later = $store->mailbox_uid_entries(mailbox_id => 'recipient-box', after_uid => 1);
  is [map { $_->{uid} } @{$later}], [2, 3], 'later page sees newly committed membership';
  is [grep { $_->{uid} < $snapshot->{uidnext} } (@{$page}, @{$later})],
    [{%{$first}, uid => 1}, {%{$second}, uid => 2}], 'captured UIDNEXT bounds a coherent earlier adapter snapshot';
  is $snapshot->{message_count}, 2, 'captured count agrees with bounded UID listing';
  my $loaded = $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1);
  is [sort keys %{$loaded}], [qw(content_sha256 entry_id message received_at uid)], 'UID fetch exposes no sender data';
  is $loaded->{message}->raw_bytes, $message->raw_bytes, 'UID fetch preserves every authoritative LO octet';
  is $store->load_mailbox_uid(mailbox_id => 'another-recipient', uid => 1), undef, 'UID lookup remains mailbox scoped';
  is $store->ensure_mailbox(mailbox_id => 'another-recipient'),
    {uidvalidity => 2, uidnext => 1, message_count => 0}, 'another mailbox has separate stable validity';
  $store->disconnect;
  $store = open_store($schema);
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 4, message_count => 3}, 'receipt state survives a second reconnect';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 1)->{message}->raw_bytes,
    $message->raw_bytes, 'UID to LO mapping survives reconnect';
  $store->disconnect;
};

subtest 'failed mailbox state and allocator updates do not consume durable identifiers' => sub {
  for my $table (qw(mailbox_uidvalidity mailboxes)) {
    my $schema = provision();
    my $store  = open_store($schema);
    $store->_dbh->do(
q{CREATE FUNCTION fail_state() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private state failure'; END $$}
    );
    $store->_dbh->do(
      "CREATE TRIGGER fail_state AFTER INSERT OR UPDATE ON $table FOR EACH ROW EXECUTE FUNCTION fail_state()");
    like dies { $store->ensure_mailbox(mailbox_id => 'recipient-box') }, qr/database operation failed/,
      "$table failure rejects empty mailbox initialization";
    like dies { receive($store) }, qr/database operation failed/, "$table failure rejects implicit initialization";
    is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'failure leaves no mailbox';
    is allocator($store), 1,               'failed initialization returns its validity allocation';
    is counts($store),    [(0) x @tables], 'failed initialization retains no message data';
    $store->_dbh->do("DROP TRIGGER fail_state ON $table");
    my $receipt = receive($store);
    is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 1}],
      'retry uses original first UID';
    is $store->mailbox_state(mailbox_id => 'recipient-box'),
      {uidvalidity => 1, uidnext => 2, message_count => 1}, 'retry uses original first UIDVALIDITY';
    $store->disconnect;
  }
  my $schema = provision();
  my $store  = open_store($schema);
  {
    local $store->_dbh->{Callbacks} = {commit => sub { die "initialize commit interrupted\n" }};
    like dies { $store->ensure_mailbox(mailbox_id => 'recipient-box') }, qr/initialize commit interrupted/,
      'empty mailbox commit failure is not acknowledged';
  }
  $store->_dbh->{Callbacks} = {};
  is allocator($store),                                    1,     'empty mailbox commit failure rolls allocator back';
  is $store->mailbox_state(mailbox_id => 'recipient-box'), undef, 'empty mailbox commit failure removes row';
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  $store->_dbh->do(
q{CREATE FUNCTION fail_advance() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'private UID failure'; END $$}
  );
  $store->_dbh->do(
    q{CREATE TRIGGER fail_advance AFTER UPDATE ON mailboxes FOR EACH ROW EXECUTE FUNCTION fail_advance()});
  like dies { receive($store) }, qr/database operation failed/, 'UIDNEXT update failure rejects receipt';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 1, message_count => 0}, 'failed UIDNEXT update leaves empty mailbox intact';
  is counts($store), [(0) x @tables], 'failed UIDNEXT update retains no content';
  $store->_dbh->do('DROP TRIGGER fail_advance ON mailboxes');
  receive($store);
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box')->[0]->{uid}, 1, 'retry receives first UID';
  $store->disconnect;
};

subtest 'terminal UIDNEXT and global UIDVALIDITY exhaustion fail closed' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  $store->ensure_mailbox(mailbox_id => 'recipient-box');
  $store->_dbh->do(q{UPDATE mailboxes SET uidnext = 4294967294 WHERE mailbox_id = 'recipient-box'});
  my $receipt  = receive($store);
  my $terminal = {uidvalidity => 1, uidnext => 4_294_967_295, message_count => 1};
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $terminal, 'last UID advances to terminal UIDNEXT';
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), [{%{$receipt}, uid => 4_294_967_294}],
    'reserved terminal marker is never assigned';
  my $before = counts($store);
  like dies {
    receive($store, idempotency_key => 'overflow', message => Overnet::Mail::RawMessage->new(raw_bytes => 'overflow'));
  }, qr/(?:UID|uid).*exhaust/, 'new receipt fails when mailbox UID space is exhausted';
  is counts($store),                                        $before,   'failed exhausted receipt stores no data';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),  $terminal, 'exhausted UIDNEXT does not advance or wrap';
  is receive($store, received_at => 999),                   $receipt,  'exact replay works at terminal UIDNEXT';
  is $store->ensure_mailbox(mailbox_id => 'recipient-box'), $terminal, 'existing exhausted mailbox remains usable';
  $store->disconnect;
  $store = open_store($schema);
  is $store->mailbox_state(mailbox_id => 'recipient-box'), $terminal, 'terminal state survives reconnect';
  is $store->load_mailbox_uid(mailbox_id => 'recipient-box', uid => 4_294_967_294)->{message}->raw_bytes,
    $message->raw_bytes, 'last valid UID remains readable after reconnect';
  $store->_dbh->do('UPDATE mailbox_uidvalidity SET next_value = 4294967295 WHERE singleton = 1');
  is $store->ensure_mailbox(mailbox_id => 'last-mailbox'),
    {uidvalidity => 4_294_967_295, uidnext => 1, message_count => 0}, 'last legal validity remains allocatable';
  is allocator($store), 4_294_967_296, 'global allocator persists exhausted sentinel';
  like dies { $store->ensure_mailbox(mailbox_id => 'overflow-mailbox') }, qr/(?:UID|uid).*exhaust/,
    'new mailbox cannot wrap exhausted validity';
  like dies { receive($store, mailbox_id => 'overflow-mailbox') }, qr/(?:UID|uid).*exhaust/,
    'implicit mailbox creation cannot bypass exhaustion';
  is $store->mailbox_state(mailbox_id => 'overflow-mailbox'), undef, 'failed validity allocation leaves no mailbox';
  is allocator($store), 4_294_967_296, 'failed allocation preserves exhausted sentinel';
  is counts($store),    $before,       'failed validity allocation changes no content or receipt';
  my $last = receive($store, mailbox_id => 'last-mailbox');
  is receive($store, mailbox_id => 'last-mailbox'), $last,
    'existing mailbox accepts and replays after global exhaustion';
  is $store->mailbox_state(mailbox_id => 'last-mailbox'),
    {uidvalidity => 4_294_967_295, uidnext => 2, message_count => 1}, 'new UID allocation preserves maximal validity';
  $store->disconnect;
};

subtest 'PostgreSQL schema enforces UID bounds, uniqueness, and mailbox custody directly' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  receive($store);
  receive($store, idempotency_key => 'second');
  receive($store, mailbox_id      => 'another-recipient');
  my $dbh   = $store->_dbh;
  my @cases = (
    ['zero UID', q{UPDATE mailbox_entries SET uid = 0 WHERE mailbox_id = 'recipient-box' AND uid = 2}],
    [
      'reserved terminal UID',
      q{UPDATE mailbox_entries SET uid = 4294967295 WHERE mailbox_id = 'recipient-box' AND uid = 2}
    ],
    [
      'UID beyond uint32',
      q{UPDATE mailbox_entries SET uid = 4294967296 WHERE mailbox_id = 'recipient-box' AND uid = 2}
    ],
    ['duplicate mailbox UID',     q{UPDATE mailbox_entries SET uid = 1 WHERE mailbox_id = 'recipient-box' AND uid = 2}],
    ['zero UIDNEXT',              q{UPDATE mailboxes SET uidnext = 0 WHERE mailbox_id = 'recipient-box'}],
    ['UIDNEXT beyond uint32',     q{UPDATE mailboxes SET uidnext = 4294967296 WHERE mailbox_id = 'recipient-box'}],
    ['zero UIDVALIDITY',          q{UPDATE mailboxes SET uidvalidity = 0 WHERE mailbox_id = 'recipient-box'}],
    ['UIDVALIDITY beyond uint32', q{UPDATE mailboxes SET uidvalidity = 4294967296 WHERE mailbox_id = 'recipient-box'}],
    ['duplicate UIDVALIDITY',     q{UPDATE mailboxes SET uidvalidity = 1 WHERE mailbox_id = 'another-recipient'}],
    [
      'orphan membership',
      q{UPDATE mailbox_entries SET mailbox_id = 'missing-mailbox' WHERE mailbox_id = 'recipient-box'}
    ],
    ['deleting mailbox custody', q{DELETE FROM mailboxes WHERE mailbox_id = 'recipient-box'}],
    ['zero allocator',           q{UPDATE mailbox_uidvalidity SET next_value = 0 WHERE singleton = 1}],
    [
      'allocator beyond exhausted sentinel',
      q{UPDATE mailbox_uidvalidity SET next_value = 4294967297 WHERE singleton = 1}
    ],
    ['second allocator singleton', q{INSERT INTO mailbox_uidvalidity (singleton, next_value) VALUES (2, 1)}],
  );
  my $entries = $store->mailbox_uid_entries(mailbox_id => 'recipient-box');

  for my $case (@cases) {

    # Roll back even a mistakenly accepted mutation so later assertions remain independent.
    $dbh->begin_work;
    my $error = dies { $dbh->do($case->[1]) };
    $dbh->rollback;
    like $error, qr/database operation failed/, "$case->[0] is rejected by PostgreSQL itself";
  }
  is $store->mailbox_uid_entries(mailbox_id => 'recipient-box'), $entries,
    'failed constraints preserve all UID mappings';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 3, message_count => 2}, 'failed constraints preserve mailbox state';
  is allocator($store), 3, 'failed constraints preserve the durable global allocator';
  $store->disconnect;
};

subtest 'version-two receipt history is rejected without changing rows, schema, or LO bytes' => sub {
  my $schema = provision();
  my $store  = open_store($schema);
  receive($store);
  my $oid         = body_oid($store, $message);
  my $dbh         = $store->_dbh;
  my $constraints = $dbh->selectcol_arrayref(
q{SELECT conname FROM pg_constraint WHERE conrelid = 'mailbox_entries'::regclass AND confrelid = 'mailboxes'::regclass}
  );
  $dbh->do('ALTER TABLE mailbox_entries DROP CONSTRAINT ' . $dbh->quote_identifier($_)) for @{$constraints};
  $dbh->do('ALTER TABLE mailbox_entries DROP COLUMN uid');
  $dbh->do('ALTER TABLE mailbox_entries DROP COLUMN receipt_namespace');
  $dbh->do('ALTER TABLE mailbox_entries ADD UNIQUE(mailbox_id, idempotency_key)');
  $dbh->do('DROP TABLE recipient_routes');
  $dbh->do('DROP TABLE mailboxes');
  $dbh->do('DROP TABLE mailbox_uidvalidity');
  $dbh->do('ALTER TABLE overnet_mail_schema DROP CONSTRAINT overnet_mail_schema_version_check');
  $dbh->do('UPDATE overnet_mail_schema SET version = 2');
  $dbh->do('ALTER TABLE overnet_mail_schema ADD CHECK (version = 2)');
  my %rows = map { $_ => $dbh->selectall_arrayref("SELECT * FROM $_ ORDER BY 1") } (@tables, 'overnet_mail_schema');
  my $schema_sql = q{SELECT c.relname, c.relkind, c.relpersistence, a.attnum, a.attname,
    format_type(a.atttypid, a.atttypmod), a.attnotnull, a.attidentity
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
    WHERE n.nspname = ? ORDER BY c.relname, a.attnum};
  my $before_schema  = $dbh->selectall_arrayref($schema_sql, undef, $schema);
  my $constraint_sql = q{SELECT c.conname, pg_get_constraintdef(c.oid) FROM pg_constraint c
    JOIN pg_namespace n ON n.oid = c.connamespace WHERE n.nspname = ? ORDER BY c.conname};
  my $before_constraints = $dbh->selectall_arrayref($constraint_sql, undef, $schema);
  $store->disconnect;
  $dbh = connect_db($schema);
  like dies { Overnet::Mail::Store::Postgres->new(dbh => $dbh) }, qr/unsupported mail store schema/,
    'legacy recipient schema is not silently upgraded';
  is $dbh->selectall_arrayref($schema_sql, undef, $schema), $before_schema,
    'old relations and columns remain unchanged';
  is $dbh->selectall_arrayref($constraint_sql, undef, $schema), $before_constraints, 'old constraints remain unchanged';

  for my $table (sort keys %rows) {
    is $dbh->selectall_arrayref("SELECT * FROM $table ORDER BY 1"), $rows{$table}, "rejection preserves $table rows";
  }
  is $dbh->selectrow_array('SELECT lo_get(?)', undef, $oid), $message->raw_bytes,
    'rejection preserves every old LO octet';
  ok $dbh->{AutoCommit}, 'legacy rejection leaves no transaction open';
  $dbh->disconnect;
};

subtest 'real PostgreSQL concurrent initialization and distinct receipts allocate unique monotonic identifiers' => sub {
  if (!$Config{d_fork}) {
    bail_out 'required PostgreSQL UID concurrency tests need fork' if $required;
    plan skip_all => 'fork is unavailable';
  }
  my $schema = provision();
  my @jobs   = map {
    spawn_job($schema, sub { return $_[0]->ensure_mailbox(mailbox_id => 'recipient-box') })
  } 1 .. 6;
  start_jobs(@jobs);
  is collect_job($_), {uidvalidity => 1, uidnext => 1, message_count => 0},
    'concurrent empty initializers return the same state'
    for @jobs;
  my $store = open_store($schema);
  is allocator($store), 2, 'concurrent same-mailbox initialization consumes one validity';
  $store->disconnect;
  @jobs = map {
    my $index = $_;
    spawn_job($schema, sub { return $_[0]->ensure_mailbox(mailbox_id => "another-$index") });
  } 1 .. 6;
  start_jobs(@jobs);
  my @states = map { collect_job($_) } @jobs;
  is [sort { $a <=> $b } map { $_->{uidvalidity} } @states], [2 .. 7],
    'concurrent different mailboxes receive globally unique consecutive validity values';
  @jobs = map {
    my $index = $_;
    spawn_job($schema,
      sub { return receive($_[0], idempotency_key => "distinct-$index", received_at => 100 - $index) });
  } 1 .. 6;
  start_jobs(@jobs);
  my @receipts = map { collect_job($_) } @jobs;
  $store = open_store($schema);
  my $entries = $store->mailbox_uid_entries(mailbox_id => 'recipient-box');
  is [map { $_->{uid} } @{$entries}], [1 .. 6], 'concurrent distinct receipts receive consecutive non-reused UIDs';
  is [sort { $a <=> $b } map { $_->{entry_id} } @{$entries}],
    [sort { $a <=> $b } map { $_->{entry_id} } @receipts], 'one UID belongs to every acknowledged receipt';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 7, message_count => 6}, 'state tracks all six committed receipts';
  $store->disconnect;

  $schema = provision();
  @jobs   = map {
    my $index = $_;
    spawn_job(
      $schema,
      sub {
        my ($child) = @_;
        return $index % 2 ? $child->ensure_mailbox(mailbox_id => 'recipient-box') : receive($child);
      }
    );
  } 1 .. 6;
  start_jobs(@jobs);
  collect_job($_) for @jobs;
  $store = open_store($schema);
  is allocator($store), 2, 'ensure-versus-receive race allocates one validity';
  is $store->mailbox_state(mailbox_id => 'recipient-box'),
    {uidvalidity => 1, uidnext => 2, message_count => 1},
    'ensure-versus-receive race commits one stable mailbox and UID';
  is [map { $_->{uid} } @{$store->mailbox_uid_entries(mailbox_id => 'recipient-box')}], [1],
    'replay racing initialization consumes no extra UIDs';
  $store->disconnect;
};

cleanup();
done_testing;

sub receive {
  my ($store, %extra) = @_;
  return $store->receive_message(
    mailbox_id      => 'recipient-box',
    idempotency_key => 'delivery-key',
    message         => $message,
    received_at     => 123,
    %extra
  );
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
  my $schema = 'om_mailbox_' . $$ . '_' . ++$sequence . '_' . int(rand(1_000_000));
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
