use strictures 2;
use Test2::V0;
use File::Temp qw(tempdir);
use JSON       ();
use Overnet::Mail::Store;

# A contract oracle, not a production adapter or an SMTP/LMTP implementation.
# All identities come from this trusted synthetic transcript, never MIME headers.
# queue_id is observational only: it MUST NOT become the Store idempotency key.
my $root    = 't/fixtures/inbound-mta';
my $fixture = JSON->new->decode(slurp("$root/partial-retry.json"));
is $fixture->{version},      2,             'known fixture format';
is $fixture->{message_file}, 'message.eml', 'fixed local fixture, no external input';
is $fixture->{attempts}->[0]->{queue_id}, $fixture->{attempts}->[7]->{queue_id},
  'later byte-identical delivery deliberately reuses the queue ID';
isnt $fixture->{attempts}->[0]->{delivery_token}, $fixture->{attempts}->[7]->{delivery_token},
  'trusted intake supplies a distinct token for the later delivery';
my $bytes = slurp("$root/message.eml");
my $dir   = tempdir(CLEANUP => 1);
my $path  = "$dir/mail.db";
my $store = open_store();

for my $address (sort keys %{$fixture->{routes}}) {
  my $mailbox = $fixture->{routes}->{$address};
  $store->ensure_mailbox(mailbox_id => $mailbox);
  $store->register_recipient(recipient => $address, mailbox_id => $mailbox);
}
my %first_receipts;
for my $attempt (@{$fixture->{attempts}}) {
  subtest $attempt->{name} => sub {
    my $fault = $attempt->{fault};
    ok scalar(grep { $_ eq $fault } qw(normal drop_ack fail_before_store changed_bytes)), 'known test fault';
    my $raw = $bytes . ($fault eq 'changed_bytes' ? "changed\r\n" : q{});
    my $result;
    my $ok = eval {
      die "synthetic failure before Store call\n" if $fault eq 'fail_before_store';
      $result = $store->receive_delivery(
        source_id       => $fixture->{source_id},
        idempotency_key => $attempt->{delivery_token},
        recipient       => $attempt->{recipient},
        message         => Overnet::Mail::RawMessage->new(raw_bytes => $raw),
        received_at     => $attempt->{received_at},
      );

      # Commit returned success, but the upstream peer never receives its ack.
      if ($fault eq 'drop_ack') {
        is $result->{status}, 'received', 'lost-ack injection follows successful custody';
        die "synthetic lost acknowledgement\n";
      }
      1;
    };
    my $observed = $ok ? $result->{status} : 'defer';
    is $observed, $attempt->{expected_result}, 'upstream observation matches transcript';

    # No exception text, raw headers or private address metadata is returned.
    undef $store;
    $store = open_store();
    if (exists $attempt->{expected_mailbox}) {
      is $result->{status}, 'received', 'successful Store result exists even when ack is lost';
      my $entries = $store->mailbox_uid_entries(mailbox_id => $attempt->{expected_mailbox});
      my ($entry) = grep { $_->{uid} == $attempt->{expected_uid} } @{$entries};
      ok $entry, 'expected persisted UID exists';
      if ($entry) {
        my %receipt = %{$entry};
        delete $receipt{uid};
        is $result->{receipt}, \%receipt, 'returned receipt exactly matches durable entry';
      }
    }
    my @boxes = qw(alice bob);
    for my $index (0 .. $#boxes) {
      my $box     = $boxes[$index];
      my $entries = $store->mailbox_uid_entries(mailbox_id => $box);
      is scalar(@{$entries}), $attempt->{expected_counts}->[$index], "$box durable count after reopening";
      is $store->mailbox_state(mailbox_id => $box)->{uidnext}, scalar(@{$entries}) + 1, "$box UIDNEXT";
      for my $entry (@{$entries}) {
        is $store->load_mailbox_uid(mailbox_id => $box, uid => $entry->{uid})->{message}->raw_bytes,
          $bytes, "$box preserves complete MIME octets";
      }
      if (@{$entries}) {
        $first_receipts{$box} //= $entries->[0];
        is $entries->[0], $first_receipts{$box}, "$box retries preserve receipt, UID and original time";
      }
    }
    for my $table (qw(messages recipients submissions deliveries blossom_owners)) {
      is $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $table"), 0, "$table remains empty";
    }
    is $store->_dbh->selectrow_array('SELECT COUNT(*) FROM blossom_blob_data'), 1, 'one authoritative blob';
  };
}
is $store->mailbox_uid_entries(mailbox_id => 'alice')->[0]->{received_at}, 100,
  'lost ack retains original receipt time';
is $store->mailbox_uid_entries(mailbox_id => 'bob')->[0]->{received_at}, 104,
  'pre-custody failure does not create a receipt';
done_testing;

sub open_store {
  return Overnet::Mail::Store->new(path => $path, max_message_bytes => 2048);
}

sub slurp {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "read fixture: $!";
  local $/;
  my $value = <$fh>;
  close $fh or die "close fixture: $!";
  return $value;
}
