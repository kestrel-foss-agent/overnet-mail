#!/usr/bin/env perl
# GPL-3.0-only. Destructive operations are for disposable synthetic tests only.
use strictures 2;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use DBI ();
use JSON ();
use MIME::Base64 qw(decode_base64);
use Overnet::Mail::Store;
use Overnet::Mail::Store::Postgres;
use Overnet::Mail::RawMessage;
use Net::Blossom::Server::Backend::Postgres::BlobStore;
use Net::Blossom::Server::Backend::Postgres::MetadataStore;
use Time::HiRes qw(usleep);

@ARGV == 1 or die "fixture config required\n";
open my $fh, '<:raw', $ARGV[0] or die "fixture config read failed\n";
my $config = JSON->new->decode(do { local $/; <$fh> });
close $fh;
my $request = JSON->new->decode(do { local $/; <STDIN> });
my $action = $request->{action} // q{};
my $pg = ($config->{engine} // q{}) eq 'postgres';
my ($dbh, $store);
if ($pg) {
    # Even the destructive fixture cannot target a normal application schema.
    $config->{schema} =~ /\Aovernet_imap_[0-9a-f]{16}\z/ or die "synthetic schema required\n";
    $config->{dsn} =~ m{\Adbi:Pg:dbname=[A-Za-z0-9_]+;host=(?:127\.0\.0\.1|/[A-Za-z0-9_/.-]+);port=[0-9]{1,5}\z}
        or die "local fixture DSN required\n";
    $dbh = DBI->connect($config->{dsn}, $config->{user}, q{}, {
        RaiseError => 1, PrintError => 0, AutoCommit => 1, pg_enable_utf8 => 0,
    });
    $dbh->do('SET client_min_messages = warning');
    my $schema = $dbh->quote_identifier($config->{schema});
    if ($action eq 'init' || $action eq 'empty_schema' || $action eq 'blossom_only') {
        $dbh->do("CREATE SCHEMA $schema");
    }
    $dbh->do("SET search_path = $schema, pg_catalog");
    if ($action eq 'cleanup') {
        my $exists = $dbh->selectrow_array(q{SELECT to_regclass('blossom_blob_data') IS NOT NULL});
        if ($exists) {
            my $oids = $dbh->selectcol_arrayref('SELECT body_oid FROM blossom_blob_data');
            for my $oid (@{$oids}) {
                my ($present) = $dbh->selectrow_array('SELECT COUNT(*) FROM pg_largeobject_metadata WHERE oid = ?', undef, $oid);
                $dbh->do('SELECT lo_unlink(?)', undef, $oid) if $present;
            }
        }
        $dbh->do("DROP SCHEMA IF EXISTS $schema CASCADE");
        print "{}\n";
        exit 0;
    }
    if ($action eq 'empty_schema') { print "{}\n"; exit 0 }
    if ($action eq 'init' || $action eq 'blossom_only') {
        Net::Blossom::Server::Backend::Postgres::BlobStore->new(dbh => $dbh)->deploy_schema;
        Net::Blossom::Server::Backend::Postgres::MetadataStore->new(dbh => $dbh)->deploy_schema;
    }
    if ($action eq 'blossom_only') { print "{}\n"; exit 0 }
    if ($action eq 'schema_state') {
        my $tables = $dbh->selectcol_arrayref(q{SELECT tablename FROM pg_tables WHERE schemaname = ? ORDER BY tablename}, undef, $config->{schema});
        my $versions = [];
        if (grep { $_ eq 'overnet_mail_schema' } @{$tables}) {
            $versions = $dbh->selectcol_arrayref('SELECT version FROM overnet_mail_schema ORDER BY version');
        }
        print JSON->new->encode({tables => $tables, versions => $versions}); exit 0;
    }
    $store = Overnet::Mail::Store::Postgres->new(dbh => $dbh, max_message_bytes => ($request->{max_bytes} // 10485760));
} else {
    # The Python harness generates this exact basename under a temporary root.
    $config->{engine} eq 'sqlite' && $config->{path} =~ m{\A/[^\x00\r\n;]*/fixture\.sqlite\z}
        or die "synthetic SQLite fixture path required\n";
    $store = Overnet::Mail::Store->new(path => $config->{path}, max_message_bytes => ($request->{max_bytes} // 10485760));
    $dbh = $store->_dbh;
}
my $mailbox = $request->{mailbox} // $config->{mailbox_id};
my $answer = {};
if ($action eq 'init' || $action eq 'ensure') {
    $answer = $store->ensure_mailbox(mailbox_id => $mailbox);
} elsif ($action eq 'receive' || $action eq 'bulk') {
    my $count = $action eq 'receive' ? 1 : $request->{count};
    $count =~ /\A[1-9][0-9]{0,3}\z/ && $count <= 4200 or die "fixture count limit\n";
    my $raw = decode_base64($request->{raw_b64});
    for my $i (1 .. $count) {
        $answer = $store->receive_message(
            mailbox_id => $mailbox,
            idempotency_key => $request->{key} . ($action eq 'bulk' ? "-$i" : q{}),
            received_at => $request->{received_at} // 1700000000,
            message => Overnet::Mail::RawMessage->new(raw_bytes => $raw, max_bytes => ($request->{max_bytes} // 10485760)),
        );
        usleep(($request->{delay_ms} // 0) * 1000) if $request->{delay_ms};
    }
} elsif ($action eq 'state') {
    $answer = $store->mailbox_state(mailbox_id => $mailbox);
} elsif ($action eq 'uidnext') {
    $dbh->do('UPDATE mailboxes SET uidnext = ? WHERE mailbox_id = ?', undef, $request->{value}, $mailbox);
} elsif ($action eq 'old_schema') {
    if ($pg) {
        $dbh->do('DROP TABLE overnet_mail_schema');
        $dbh->do('CREATE TABLE overnet_mail_schema (version INTEGER)');
        $dbh->do('INSERT INTO overnet_mail_schema VALUES (2)');
    } else { $dbh->do('PRAGMA user_version = 4') }
} elsif ($action eq 'corrupt' || $action eq 'missing') {
    my ($key) = $dbh->selectrow_array('SELECT content_sha256 FROM mailbox_entries WHERE mailbox_id = ? AND uid = ?', undef, $mailbox, $request->{uid});
    defined $key or die "fixture UID missing\n";
    if ($pg) {
        my ($oid) = $dbh->selectrow_array('SELECT body_oid FROM blossom_blob_data WHERE storage_key = ?', undef, $key);
        if ($action eq 'missing') { $dbh->do('SELECT lo_unlink(?)', undef, $oid) }
        else { $dbh->do(q{SELECT lo_put(?, 0, decode('58', 'hex'))}, undef, $oid) }
    } elsif ($action eq 'missing') {
        # Deliberately bypass foreign keys only in this corruption fixture.
        $dbh->do('PRAGMA foreign_keys = OFF');
        $dbh->do('DELETE FROM blossom_blob_data WHERE storage_key = ?', undef, $key);
    } else {
        $dbh->do('UPDATE blossom_blob_data SET body = ? WHERE storage_key = ?', undef, 'corrupt-synthetic-body', $key);
    }
} else { die "unknown fixture action\n" }
# DBI may return the same canonical integer with string or numeric scalar flags.
# This fixture's JSON transport deliberately serializes receipt time as a number;
# the Store API and immutable value are unchanged.
$answer->{received_at} = 0 + $answer->{received_at} if $action eq 'receive' || $action eq 'bulk';
$store->disconnect;
print JSON->new->canonical->encode($answer), "\n";
