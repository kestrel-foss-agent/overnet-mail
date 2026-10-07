use strictures 2;

use File::Temp   qw(tempdir);
use Scalar::Util qw(refaddr);
use Test2::V0;
use Overnet::Mail::Store;

my $dir = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my $store = Overnet::Mail::Store->new(path => "$dir/shared.db");
my $raw   = Overnet::Mail::RawMessage->new(raw_bytes => "Subject: shared storage\r\n\r\n\0\xffbytes");
is refaddr($store->_metadata_store->dbh), refaddr($store->_dbh), 'metadata uses the mail database handle';
is refaddr($store->_blob_store->dbh),     refaddr($store->_dbh), 'bytes use the same database handle';
is $store->_dbh->selectrow_array('PRAGMA user_version'), 3,      'shared storage has an explicit schema version';
is $store->_dbh->selectrow_array(q{SELECT COUNT(*) FROM sqlite_master WHERE name = 'contents'}), 0,
  'no duplicate mail byte store remains';

my $begin = Net::Blossom::Server::Backend::SQLite::BlobStore->can('begin_upload');
my @paths;
my $capture = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore' => override => [
  begin_upload => sub {
    my $upload = $begin->(@_);
    push @paths, $upload->path;
    is((stat($upload->path))[2] & 0777, 0600, 'staged message is owner-only');
    return $upload;
  }
];
my $receipt = accept_raw($store, 'one');
is $store->_metadata_store->find_blob($raw->content_sha256)->{size}, $raw->size_bytes,
  'Blossom metadata contains the exact accepted byte length';
is $store->_blob_store->get_blob($raw->content_sha256), $raw->raw_bytes, 'Blossom reads the exact mail content';
ok !-e $paths[-1], 'successful commit removes temporary upload';
is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_owners'), 0,
  'mail membership is not invented as Blossom pubkey ownership';

for my $target (['blossom_blob_data', 'storage_key'], ['blossom_blobs', 'sha256']) {
  like dies {
    $store->_metadata_store->with_transaction(
      sub {
        return $store->_dbh->do("DELETE FROM $target->[0] WHERE $target->[1] = ?", undef, $raw->content_sha256);
      }
    );
  }, qr/database operation failed/, 'mail references protect byte and metadata custody';
}
is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes,
  $raw->raw_bytes, 'failed external deletion cannot remove accepted content';

# New uploads are verified after preparation, before mail records are accepted.
{
  my $get   = Net::Blossom::Server::Backend::SQLite::BlobStore->can('get_blob');
  my $calls = 0;
  my $fault = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore' => override =>
    [get_blob => sub { ++$calls; return $calls == 1 ? undef : 'wrong staged content' }];
  like dies { accept_raw($store, 'changed', 'different new content') }, qr/content integrity/,
    'a newly prepared body is rehashed before acceptance';
}
is row_counts($store), [1, 1, 1], 'failed new content verification rolls back both Blossom tables and mail';
ok !-e $paths[-1], 'rollback removes prepared staging file';

# Exact-byte comparison is still required even if a digest check were fooled.
{
  my $fault = mock 'Overnet::Mail::Store' => override => [_content => sub { return $raw }];
  like dies { accept_raw($store, 'collision', 'different collision bytes') }, qr/content conflicts/,
    'newly prepared content must compare byte-for-byte with the submitted item';
}
is row_counts($store), [1, 1, 1], 'new-content collision rolls back both storage components';

for my $case (
  ['Net::Blossom::Server::Backend::SQLite::BlobStore',          'begin_upload'],
  ['Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload', 'write'],
  ['Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload', 'prepare'],
  ['Net::Blossom::Server::Backend::SQLite::MetadataStore',      'insert_blob'],
) {
  my $fault = mock $case->[0] => override => [$case->[1] => sub { die "private path and message secret\n" }];
  my $error = dies { accept_raw($store, 'broken', "new body $case->[1]") };
  like $error,   qr/blob operation failed/,       "$case->[1] failure is fail-closed";
  unlike $error, qr/private path|message secret/, 'blob diagnostics omit private staging details';
  is row_counts($store), [1, 1, 1], 'upload failure leaves no partial mail or blob rows';
  ok !-e $paths[-1], 'upload failure cleans staging';
}

# A successful SQL commit remains accepted if later staging cleanup fails.
{
  my $fault = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload' => override =>
    [commit => sub { die "private cleanup failure\n" }];
  like dies { accept_raw($store, 'cleanup', 'cleanup content') }, qr/acceptance committed, retry the original/,
    'post-commit cleanup failure reports committed acceptance with replay guidance';
}
my $cleanup = accept_raw($store, 'cleanup', 'cleanup content');
is $cleanup->{message_id}, 2,         'lost receipt replays the committed ID without a second logical message';
is row_counts($store),     [2, 2, 2], 'post-commit cleanup failure never rolls back committed custody';

# A DBI exception can arrive after the actual SQL commit, before its acknowledgement.
{
  my $ack = Overnet::Mail::Store->new(path => "$dir/acknowledgement.db");
  {
    local $ack->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        local $dbh->{Callbacks} = {};
        $dbh->commit;
        die "commit acknowledgement interrupted\n";
      }
    };
    like dies { accept_raw($ack, 'acknowledgement') }, qr/commit acknowledgement interrupted/,
      'actual commit followed by a thrown exception does not return success';
  }
  $ack->_dbh->{Callbacks} = {};
  ok !-e $paths[-1], 'ambiguous SQL commit still cleans temporary upload';
  is row_counts($ack),                                  [1, 1, 1], 'actual committed custody survives the exception';
  is accept_raw($ack, 'acknowledgement')->{message_id}, 1,         'replay resolves an actual-commit exception';
  $ack->disconnect;
}

# Real writer state transitions precede cleanup, so a cleanup error can leave staging.
for my $committed (0, 1) {
  my $cleanup_store = Overnet::Mail::Store->new(path => "$dir/cleanup-state-$committed.db");
  {
    my $fault = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload' => override =>
      [_cleanup => sub { die "private staging cleanup failure\n" }];
    local $cleanup_store->_dbh->{Callbacks} = $committed ? {} : {commit => sub { die "commit interrupted\n" }};
    like dies { accept_raw($cleanup_store, 'cleanup-state') }, qr/upload cleanup failed/,
      'cleanup failure after real commit/abort state transition is reported';
  }
  $cleanup_store->_dbh->{Callbacks} = {};
  ok -f $paths[-1], 'failed cleanup can leave the private staged file';
  is((stat($paths[-1]))[2] & 0777, 0600, 'residual staging remains owner-only');
  is row_counts($cleanup_store), [($committed) x 3], 'cleanup failure preserves the actual transaction outcome';
  is accept_raw($cleanup_store, 'cleanup-state')->{message_id}, 1, 'original-key retry resolves acceptance once';
  $cleanup_store->disconnect;
}

# Cleanup failure must not conceal a failed rollback or leave its handle reusable.
{
  my $fault = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload' => override =>
    [abort => sub { die "private abort failure\n" }];
  local $store->_dbh->{Callbacks} = {
    commit   => sub { die "commit interrupted\n" },
    rollback => sub { die "rollback interrupted\n" },
  };
  like dies { accept_raw($store, 'poisoned', 'poisoned content') }, qr/rollback failed; reopen required/,
    'rollback failure takes precedence over cleanup failure';
}
like dies { accept_raw($store, 'one') }, qr/store is closed/, 'failed rollback poisons the mail handle';
unlink $paths[-1] or die "remove test staging: $!";
$store = Overnet::Mail::Store->new(path => "$dir/shared.db");
is row_counts($store), [2, 2, 2], 'reopen recovers failed commit without changing prior acceptance';

{
  my $fault = mock 'Net::Blossom::Server::Backend::SQLite::BlobStore::_Upload' => override =>
    [abort => sub { die "private abort failure\n" }];
  local $store->_dbh->{Callbacks} = {commit => sub { die "commit interrupted\n" }};
  like dies { accept_raw($store, 'abort', 'abort content') }, qr/upload cleanup failed; retry the original/,
    'rollback cleanup failure is explicit and sanitized';
}
unlink $paths[-1] or die "remove test staging: $!";
is row_counts($store), [2, 2, 2], 'successful rollback is retained despite cleanup error';

$store->_dbh->begin_work;
like dies { accept_raw($store, 'nested') }, qr/transaction is already active/,
  'caller-owned transactions cannot receive premature acceptance receipts';
ok !$store->_dbh->{AutoCommit}, 'nested rejection does not commit or roll back the caller transaction';
$store->_dbh->rollback;

# Stale, unreferenced bytes are never silently adopted or overwritten.
my $orphan = Overnet::Mail::RawMessage->new(raw_bytes => 'orphan content');
$store->_dbh->do('INSERT INTO blossom_blob_data (storage_key, body) VALUES (?, CAST(? AS BLOB))',
  undef, $orphan->content_sha256, $orphan->raw_bytes);
like dies { accept_raw($store, 'orphan', $orphan->raw_bytes) }, qr/content is missing/,
  'metadata-less bytes require explicit repair instead of implicit acceptance';
$store->disconnect;

done_testing;

sub accept_raw {
  my ($storage, $key, $bytes) = @_;
  my $message = defined $bytes ? Overnet::Mail::RawMessage->new(raw_bytes => $bytes) : $raw;
  return $storage->accept_item(mailbox_id => 'box', idempotency_key => $key, item => $message);
}

sub row_counts {
  my ($storage) = @_;
  return [map { $storage->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") }
      qw(blossom_blob_data blossom_blobs messages)];
}
