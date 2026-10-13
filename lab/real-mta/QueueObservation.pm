package QueueObservation;

use strictures 2;
use JSON ();

# postqueue -j can observe one queue file in more than one queue directory
# during a scan. Only the exact ID identifies that file in this isolated lab.
sub unique_rows {
  my ($rows, %options) = @_;
  die "invalid Postfix queue rows\n" if ref($rows) ne 'ARRAY';
  my (%seen, %identity, @unique);
  my $json = JSON->new->canonical;
  for my $row (@{$rows}) {
    die "invalid Postfix queue row\n" if ref($row) ne 'HASH';
    my $id = $row->{queue_id};
    die "invalid Postfix queue ID\n" if !defined($id) || ref($id) || $id !~ /\A[A-Za-z0-9]+\z/smx;

    # Queue name and delivery delay details may change while a file moves.
    my @identity = map { $row->{$_} } qw(sender arrival_time message_size);

    # Recipient membership is stable only while downstream LMTP is stopped.
    if ($options{stable_recipients}) {
      push @identity, [sort map { $_->{address} } @{$row->{recipients}}];
    }
    my $identity = $json->encode(\@identity);
    if ($seen{$id}++) {
      die "conflicting Postfix queue identity: $id\n" if $identity{$id} ne $identity;
      next;
    }
    $identity{$id} = $identity;
    push @unique, $row;
  }
  return \@unique;
}

# A missed expected file is retryable; an observed extra file is not. Never
# accumulate IDs across scans or wait for an unexpected ID to disappear.
sub matching_ids {
  my ($rows, $expected) = @_;
  my $unique   = unique_rows($rows, stable_recipients => 1);
  my %expected = map { $_ => 1 } @{$expected};
  for my $row (@{$unique}) {
    die "unexpected Postfix queue ID: $row->{queue_id}\n" if !$expected{$row->{queue_id}};
  }
  return @{$unique} == keys(%expected) ? $unique : undef;
}

1;
