use strict;
use warnings;

# Deliberately fail closed, before loading optional integration dependencies.
BEGIN {
  die "real-mta.t requires the isolated lab and OVERNET_REAL_MTA_LAB=1\n"
    unless ($ENV{OVERNET_REAL_MTA_LAB} // '') eq '1' && -x '/lab/control';
}

use Test2::V0;
use File::Temp   qw(tempdir);
use JSON::PP     qw(decode_json);
use MIME::Base64 qw(encode_base64);
use Email::MIME;
use Mail::IMAPClient;
use Net::SMTP;
use Time::HiRes qw(time sleep);
use Overnet::Mail::Store;
use Overnet::Mail::DeliveryRunner;
use Overnet::Mail::Transport::LoopbackSMTP;

# Observe the real adapter, never replace its protocol implementation or replies.
{

  package Local::ObservedLoopback;
  use parent 'Overnet::Mail::Transport::LoopbackSMTP';
  our @reports;

  sub deliver {
    my ($self, $claim) = @_;
    my $report = $self->SUPER::deliver($claim);
    push @reports, {%{$report}};
    return $report;
  }
}

my $dir        = tempdir(CLEANUP => 1);
my $path       = "$dir/archive.sqlite";
my $store      = Overnet::Mail::Store->new(path => $path);
my $transport  = Local::ObservedLoopback->new(port => 2525, timeout => 10);
my $now        = 1000;
my $runner     = make_runner();
my $token      = 'real-mta-' . $$;
my $message_id = "<$token\@reference.invalid>";
my $attachment = pack('C*', 0 .. 255) . "\0\xff\r\n.binary\n";
my $text       = "First line\r\n.\r\n..two\r\n.leading dot\r\nLast line\r\n";
my $raw =
    "From: sender\@reference.invalid\r\n"
  . "To: alice\@reference.invalid\r\n"
  . "Date: Thu, 08 Oct 2026 00:00:00 +0000\r\n"
  . "Message-ID: $message_id\r\n"
  . "Subject: real MTA MIME round trip\r\n"
  . "MIME-Version: 1.0\r\n"
  . "Content-Type: multipart/mixed; boundary=reference-lab-boundary\r\n\r\n"
  . "--reference-lab-boundary\r\nContent-Type: text/plain; charset=us-ascii\r\n"
  . "Content-Transfer-Encoding: 7bit\r\n\r\n$text"
  . "--reference-lab-boundary\r\nContent-Type: application/octet-stream\r\n"
  . "Content-Disposition: attachment; filename=octets.bin\r\n"
  . "Content-Transfer-Encoding: base64\r\n\r\n"
  . encode_base64($attachment, "\r\n")
  . "--reference-lab-boundary--\r\n";

is queue_rows(), [], 'isolated Postfix queue begins empty';
for my $user (qw(alice blind)) {
  my $imap = imap_login($user);
  is scalar($imap->message_count('INBOX')), 0, "$user starts with an empty real mailbox";
  $imap->logout or die 'IMAP logout failed';
}

my $receipt = $store->enqueue_submission(
  mailbox_id      => 'lab',
  idempotency_key => $token,
  item            => Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => $raw),
    envelope => Overnet::Mail::Envelope->new(
      sender     => '',
      recipients => ['alice@reference.invalid', 'blind@reference.invalid'],
    ),
  ),
);
is scalar(@{$receipt->{delivery_ids}}), 2, 'one app delivery per private envelope recipient';
control('dovecot-stop');
for my $position (0, 1) {
  my $result = $runner->run_once(mailbox_id => 'lab');
  is $result,
    {
    status      => 'recorded',
    delivery_id => $receipt->{delivery_ids}[$position],
    attempt     => 1,
    outcome     => 'confirmed',
    state       => 'delivered',
    },
    'Postfix accepts custody even with mailbox service unavailable';
  is $Local::ObservedLoopback::reports[-1],
    {outcome => 'confirmed', stage => 'final', smtp_code => 250},
    'real final DATA 250 is the custody boundary';
}
is $runner->run_once(mailbox_id => 'lab'), {status => 'idle'}, 'accepted recipients cannot be resent';
is scalar(@Local::ObservedLoopback::reports), 2, 'exactly two actual SMTP deliveries';
archive_unchanged();

my $queued = await_value(
  'two messages queued while LMTP is down',
  sub {
    my $rows = queue_rows();
    return @$rows == 2 ? $rows : undef;
  }
);
my @queue_ids = sort map { $_->{queue_id} } @$queued;
is [
  sort map {
    map { $_->{address} } @{$_->{recipients}}
  } @$queued
  ],
  ['alice@reference.invalid', 'blind@reference.invalid'], 'Postfix durably retains both exact envelope recipients';
control('postfix-stop');
control('postfix-start');
is [sort map { $_->{queue_id} } @{queue_rows()}], \@queue_ids,
  'same Postfix queue IDs survive a daemon restart with LMTP still down';

# Reopen the application archive too: terminal custody must survive its restart.
$store->disconnect;
$store = Overnet::Mail::Store->new(path => $path);
$now += 86400;
$runner = make_runner();
is $runner->run_once(mailbox_id => 'lab'), {status => 'idle'}, 'reopened app never retries Postfix-owned mail';
is [map { [$_->{state}, $_->{attempt}] }
    @{$store->deliveries(mailbox_id => 'lab', submission_id => $receipt->{submission_id})}],
  [['delivered', 1], ['delivered', 1]], 'durable recipient outcomes remain terminal at one attempt';
archive_unchanged();
control('dovecot-start');
control('postfix-flush');
await_value('Postfix drains its existing queue into recovered Dovecot', sub { return @{queue_rows()} ? undef : 1 });

my %identity;
for my $user (qw(alice blind)) {
  my $imap = imap_login($user);
  my $uids = await_value(
    "$user receives original queued message",
    sub {
      $imap->noop or die 'IMAP NOOP failed';
      my $found = $imap->search('HEADER', 'Message-ID', $message_id);
      die 'IMAP SEARCH failed' unless defined $found;
      return @$found ? $found : undef;
    }
  );
  is scalar(@$uids),                        1, "$user receives exactly one copy";
  is scalar($imap->message_count('INBOX')), 1, "$user has no other unintended deliveries";
  my $uid = $uids->[0];
  like "$uid", qr/\A[1-9][0-9]*\z/, 'IMAP identity is a UID, not a sequence assumption';
  my $received = $imap->message_string($uid);
  die 'IMAP body fetch failed' unless defined $received;

  # SMTP/LMTP legitimately prepend trace fields. The entire original MIME is
  # still required as an exact suffix, and the application copy is byte-exact.
  is substr($received, -length($raw)), $raw, 'full original MIME survives behind delivery trace headers';
  my ($headers) = split /\r\n\r\n/, $received, 2;
  unlike $headers, qr/^(?:Bcc|Resent-Bcc):/mi, 'delivered root headers have no blind-recipient field';
  unlike $headers, qr/blind\@reference\.invalid/i, 'visible recipient cannot see private envelope recipient'
    if $user eq 'alice';
  my @parts = Email::MIME->new($received)->subparts;
  is scalar(@parts),  2,           'multipart structure survives actual SMTP and LMTP';
  is $parts[1]->body, $attachment, 'decoded attachment retains every octet';
  like $parts[0]->body, qr/\r\n\.\r\n\.\.two\r\n\.leading dot\r\n/, 'SMTP dot transparency round trips';
  my $initial_flags = $imap->flags($uid);
  die 'IMAP flag fetch failed' unless defined $initial_flags;
  ok !grep($_ eq '\\Seen', @$initial_flags), 'BODY.PEEK leaves original message unseen';
  $imap->set_flag('Seen',    $uid) or die 'IMAP Seen store failed';
  $imap->set_flag('Flagged', $uid) or die 'IMAP Flagged store failed';
  my $validity = $imap->uidvalidity('INBOX');
  like "$validity", qr/\A[1-9][0-9]*\z/, 'UIDVALIDITY is present';
  $identity{$user} = [$uid, $validity];
  $imap->logout or die 'IMAP logout failed';
}
control('dovecot-stop');
control('dovecot-start');
for my $user (qw(alice blind)) {
  my $imap = imap_login($user);
  is scalar($imap->search('HEADER', 'Message-ID', $message_id)), [$identity{$user}[0]],
    'UID persists after mailbox-service restart';
  is $imap->uidvalidity('INBOX'), $identity{$user}[1], 'UIDVALIDITY persists after mailbox-service restart';
  my $flags = $imap->flags($identity{$user}[0]);
  die 'IMAP flag fetch failed' unless defined $flags;
  ok scalar(grep($_ eq '\\Seen',    @$flags)), 'Seen flag persists on disk';
  ok scalar(grep($_ eq '\\Flagged', @$flags)), 'Flagged flag persists on disk';
  is scalar($imap->message_count('INBOX')), 1, 'restart does not duplicate mailbox delivery';
  $imap->logout or die 'IMAP logout failed';
}
is $runner->run_once(mailbox_id => 'lab'), {status => 'idle'}, 'mailbox recovery requires no app resend';
is scalar(@Local::ObservedLoopback::reports), 2, 'no hidden transport invocation after custody';
archive_unchanged();

# Negative protocol probes use real libnet against the restricted Postfix listener.
for my $recipient ('unknown@reference.invalid', 'nobody@external.invalid') {
  my $smtp = smtp_connect();
  $smtp->mail('') or die 'MAIL probe failed';
  ok !$smtp->to($recipient), 'unknown or external recipient is rejected at RCPT';
  like '' . $smtp->code, qr/\A5[0-9][0-9]\z/, 'recipient denial is permanent';
  $smtp->close;
}
{
  my $smtp = smtp_connect();
  is 0 + $smtp->supports('SIZE'), 65536, 'Postfix advertises the bounded lab size limit';
  ok !$smtp->mail('', Size => 65537), 'oversize declared message rejected before DATA';
  is 0 + $smtp->code, 552, 'oversize rejection has the real SMTP size code';
  $smtp->close;
}
{
  my $smtp = smtp_connect();
  $smtp->mail('')                      or die 'MAIL undeclared-size probe failed';
  $smtp->to('alice@reference.invalid') or die 'RCPT undeclared-size probe failed';
  $smtp->data                          or die 'DATA undeclared-size probe failed';
  my $oversize = "Subject: oversize probe\r\n\r\n" . (('x' x 78) . "\r\n") x 850;
  $smtp->datasend($oversize) or die 'oversize body write failed';
  ok !$smtp->dataend, 'actual oversize DATA is rejected even without a SIZE declaration';
  is 0 + $smtp->code, 552, 'actual body size is enforced by Postfix';
  $smtp->close;
}
{
  my $smtp = smtp_connect();
  $smtp->mail('') or die 'MAIL mixed probe failed';
  ok $smtp->to('alice@reference.invalid'), 'first known recipient accepted';
  for my $recipient ('unknown@reference.invalid', 'nobody@external.invalid') {
    ok !$smtp->to($recipient), 'invalid recipient in mixed transaction is rejected';
    like '' . $smtp->code, qr/\A5[0-9][0-9]\z/, 'mixed-recipient denial is permanent';
  }

  # Do not issue DATA after partial recipient acceptance. RSET aborts it.
  ok $smtp->reset, 'RSET aborts partially accepted transaction';
  $smtp->close;
}
is queue_rows(), [], 'rejected and aborted transactions leave no queued mail';
for my $user (qw(alice blind)) {
  my $imap = imap_login($user);
  is scalar($imap->message_count('INBOX')), 1, 'negative probes deliver no mail';
  $imap->logout or die 'IMAP logout failed';
}
archive_unchanged();
$store->disconnect;
done_testing;

sub make_runner {
  return Overnet::Mail::DeliveryRunner->new(
    store       => $store,
    transport   => $transport,
    clock       => sub {$now},
    retry_after => 60,
  );
}

sub archive_unchanged {
  is $store->load(mailbox_id => 'lab', message_id => $receipt->{message_id})->{message}->raw_bytes,
    $raw, 'immutable local archive is byte-for-byte unchanged';
}

sub control {
  my ($action) = @_;
  system('/lab/control', $action) == 0 or die "lab control failed: $action\n";
}

sub queue_rows {
  open my $fh, '-|', '/lab/control', 'queue-json' or die 'queue inspection failed';
  my @rows;
  while (my $line = <$fh>) {
    next if $line =~ /\A\s*\z/;
    push @rows, decode_json($line);
  }
  close $fh or die 'queue inspection command failed';
  return \@rows;
}

sub await_value {
  my ($description, $probe) = @_;
  my $deadline = time + 45;
  while (time < $deadline) {
    my $value = $probe->();
    return $value if $value;
    sleep 0.25;
  }
  die "timed out: $description\n";
}

sub imap_login {
  my ($user) = @_;
  my $imap = Mail::IMAPClient->new(
    Server        => '127.0.0.1',
    Port          => 1143,
    User          => "$user\@reference.invalid",
    Password      => 'lab-only',
    Uid           => 1,
    Peek          => 1,
    Timeout       => 10,
    Ssl           => 0,
    Starttls      => 0,
    Authmechanism => 'LOGIN',
  ) or die 'IMAP login failed';
  $imap->select('INBOX') or die 'IMAP SELECT failed';
  return $imap;
}

sub smtp_connect {
  my $smtp = Net::SMTP->new(
    '127.0.0.1',
    Port           => 2525,
    Hello          => 'probe.reference.invalid',
    Timeout        => 10,
    ExactAddresses => 1
  ) or die 'SMTP connection failed';
  return $smtp;
}
