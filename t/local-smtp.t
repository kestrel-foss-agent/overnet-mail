use strictures 2;

use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Select;
use Test2::V0;
use Overnet::Mail::RawMessage;
use Overnet::Mail::Store;
use Overnet::Mail::Transport::LoopbackSMTP;

my $dir     = tempdir(CLEANUP => 1);
my $counter = 0;
my $raw =
    "From: visible\@example.test\r\nTo: unrelated\@example.test\r\nSubject: =?UTF-8?B?4pyT?=\r\n"
  . "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=example\r\n\r\n"
  . "--example\r\nContent-Type: text/plain\r\n\r\n.\r\n..two\r\nthree\r\n"
  . "--example\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n"
  . "AP8BAgM=\r\n--example--\r\n";
my $claim   = claim($raw);
my $adapter = Overnet::Mail::Transport::LoopbackSMTP->new(port => 1_024);
is $adapter->port,    1_024, 'minimum fixture port is accepted';
is $adapter->timeout, 2,     'default per-I/O timeout is bounded';
is +Overnet::Mail::Transport::LoopbackSMTP->new({port => 65_535, timeout => 30})->timeout, 30,
  'hashref construction and upper bounds are supported';

for my $field (qw(port timeout)) {
  for my $bad (undef, [], q{}, 0, -1, '01', '1.5', 'x', 100_000) {
    like dies { Overnet::Mail::Transport::LoopbackSMTP->new(port => 2_525, $field => $bad) }, qr/bounded integer/,
      'configuration rejects noncanonical or out-of-range integers';
  }
}
for my $args ({port => 1_023}, {port => 65_536}, {port => 2_525, timeout => 31}) {
  like dies { Overnet::Mail::Transport::LoopbackSMTP->new($args) }, qr/bounded integer/, 'both exact ranges enforced';
}
for my $option (qw(host username password tls SSL debug Hello SendHello)) {
  like dies { Overnet::Mail::Transport::LoopbackSMTP->new(port => 2_525, $option => 'private-value') },
    qr/\Aunsupported loopback adapter option/, 'unsupported security options fail closed without values';
}
for my $bad (undef, [], {}, {message => {}}, {message => $adapter}) {
  like dies { $adapter->deliver($bad) }, qr/single-recipient claim/, 'invalid claim shape is rejected';
}
for my $field (qw(sender recipient)) {
  like dies { $adapter->deliver({%{$claim}, $field => "private\r\nRCPT TO:other"}) }, qr/printable ASCII/,
    'envelope injection is rejected before connection';
}
like dies { $adapter->deliver(claim("Bcc: private\@example.test\r\n\r\nbody\r\n")) }, qr/Bcc or Resent-Bcc/,
  'transport rechecks finalized root-header privacy';

my @invalid = (
  ["Subject: x\n\nbody\n",                       'message_framing'],
  ["Subject: x\r\n\r\nno final newline",         'message_framing'],
  ["Subject: x\r\n\r\nbare\nnewline\r\n",        'message_framing'],
  ["Subject: x\r\n\r\nbare\rnewline\r\n",        'message_framing'],
  ["Subject: x\r\n\r\nnul\0byte\r\n",            'message_framing'],
  ["Subject: x\r\n\r\n" . ('x' x 999) . "\r\n",  'message_line_length'],
  ["Subject: \xc3\xa9\r\n\r\nbody\r\n",          'smtputf8_unsupported'],
  ["Subject: x\r\n\r\n" . ("x\r\n" x 3_495_254), 'message_size'],
);
for my $case (@invalid) {
  my ($bytes, $stage) = @{$case};
  is $adapter->deliver(claim($bytes)), result('permanent', $stage), 'unsupported wire form is never silently rewritten';
}
my $long = 'x' x 242 . '@example.test';
is length $long, 255, 'overlong path fixture';
for my $field (qw(sender recipient)) {
  is $adapter->deliver({%{$claim}, $field => $long}), result('permanent', 'envelope_path_length'),
    'both SMTP path lengths are bounded';
}

my ($success, $commands, $received, $wire) = peer($claim);
is $success, result('confirmed', 'final', 250), 'only final 250 confirms local custody';
is $commands,
  "EHLO fixture.invalid\r\nMAIL FROM:<> SIZE=" . length($raw) . "\r\nRCPT TO:<blind\@example.test>\r\nDATA\r\n",
  'null sender and only the claimed recipient are sent';
is $received, $raw, 'MIME attachment bytes survive exact round trip';
like $wire, qr/\r\n\.\.\r\n\.\.\.two\r\n/, 'libnet dot-stuffs single and repeated dots';
is $claim->{message}->raw_bytes, $raw, 'stored immutable bytes never change';
ok !exists $success->{recipient}, 'result contains no private recipient';
ok !exists $success->{message},   'result contains no message or server text';

my $quoted =
  {%{$claim}, sender => '"<other@example.test>"@example.test', recipient => '"quoted recipient"@example.test'};
my ($quote_result, $quote_commands) = peer($quoted, hello => "250 fixture\r\n");
is $quote_result->{outcome}, 'confirmed', 'quoted addr-specs work with ordinary SMTP';
like $quote_commands, qr/MAIL FROM:<"<other\@example.test>"\@example.test>\r\n/,
  'ExactAddresses prevents library heuristic address rewriting';
like $quote_commands, qr/RCPT TO:<"quoted recipient"\@example.test>\r\n/,
  'quoted recipient remains an exact envelope path';

for my $code (251, 252) {
  is +(peer($claim, recipient => "$code accepted\r\n"))[0]->{outcome}, 'confirmed', 'ordinary RCPT acceptance codes';
}
for my $stage (qw(hello mail recipient data final)) {
  for my $code (421, 450, 550) {
    my %options = ($stage => "$code private server text\r\n");
    $options{helo} = "$code private server text\r\n" if $stage eq 'hello';
    my ($outcome, $transcript) = peer($claim, %options);
    is $outcome, result($code < 500 ? 'transient' : 'permanent', $stage, $code),
      'complete peer negative reply is classified without exposing its text';
    unlike $transcript, qr/QUIT|RSET/, 'cleanup cannot implicitly finish a failed DATA stream';
  }
  my ($dropped) = peer($claim, drop => $stage);
  is $dropped, result($stage eq 'final' ? 'uncertain' : 'transient', $stage),
    'disconnect uses local zero code, not a fabricated peer 421';
}
for my $reply (
  "250-incomplete\r\n",
  "550-incomplete\r\n",
  "250-first\r\n550 inconsistent\r\n",
  "550-first\r\n250 inconsistent\r\n",
  "invalid private text\r\n",
  "550-first\r\ninvalid private text\r\n",
  "251 unexpected success\r\n",
  "354 unexpected continuation\r\n"
) {
  is +(peer($claim, final => $reply))[0], result('uncertain', 'final'),
    'incomplete malformed inconsistent or unexpected final reply never proves custody or rejection';
}
for my $stage (qw(hello mail recipient data)) {
  my $expected = $stage eq 'data' ? 354 : 250;
  my ($outcome, $transcript) = peer($claim, $stage => "450-inconsistent\r\n$expected misleading success\r\n");
  is $outcome, result('transient', $stage),
    'inconsistent multiline reply cannot advance even when its last code and library boolean imply success';
  unlike $transcript, qr/QUIT|RSET/, 'protocol failure closes without completing a pending stream';
}
for my $stage (qw(hello mail recipient data)) {
  my $unexpected = $stage eq 'data' ? 350 : 299;
  my ($outcome) = peer($claim, $stage => "$unexpected unexpected response\r\n");
  is $outcome, result('transient', $stage), 'unexpected positive code before body fails safely';
}
is +(peer($claim, greeting => "550 unavailable\r\n"))[0], result('transient', 'connect'),
  'unavailable greeting has no retained peer evidence from constructor';
is +(peer($claim, drop => 'greeting'))[0], result('transient', 'connect'), 'greeting disconnect is transient';
for my $greeting (
  "250 unexpected greeting\r\n",
  "220-first\r\n250 inconsistent\r\n",
  "250-first\r\n220 inconsistent\r\n",
  "220-first\r\n"
) {
  my ($outcome, $transcript) = peer($claim, greeting => $greeting);
  is $outcome,    result('transient', 'connect'), 'only complete consistent 220 greeting starts a transaction';
  is $transcript, q{},                            'invalid greeting sends no EHLO or message commands';
}

is +(peer($claim, hello => "500 EHLO unavailable\r\n", helo => "250 fixture\r\n"))[0]->{outcome}, 'confirmed',
  'ordinary HELO-only peer remains compatible for seven-bit MIME';

my $eight = claim("Subject: ascii\r\n\r\n\xff\xc3\xa9\r\n");
my ($eight_result, $eight_commands, $eight_received) = peer($eight);
is $eight_result->{outcome}, 'confirmed', '8BITMIME body is accepted when advertised';
like $eight_commands, qr/BODY=8BITMIME\r\n/, 'library requests negotiated eight-bit body';
is $eight_received, $eight->{message}->raw_bytes, 'eight-bit data preserves octets';
my ($no_eight, $no_eight_commands) = peer($eight, hello => "250 fixture\r\n");
is $no_eight, result('permanent', 'eight_bit_unsupported'), 'unsupported eight-bit body fails locally';
unlike $no_eight_commands, qr/MAIL|RCPT|DATA/, 'unsupported capability is rejected before MAIL';

for my $size (q{}, '0', length($raw), length($raw) + 1) {
  my ($outcome, $transcript) = peer($claim, hello => "250-fixture\r\n250 SIZE $size\r\n");
  is $outcome->{outcome}, 'confirmed', 'empty zero exact and larger SIZE limits are supported';
  like $transcript, qr/ SIZE=@{[length $raw]}\r\n/, 'exact canonical byte length is supplied to library';
}
my ($too_large, $size_commands) = peer($claim, hello => "250-fixture\r\n250 SIZE " . (length($raw) - 1) . "\r\n");
is $too_large, result('permanent', 'peer_size_limit'), 'advertised SIZE excludes oversize message';
unlike $size_commands, qr/MAIL|RCPT|DATA/, 'size mismatch rejected before MAIL';
is +(peer($claim, hello => "250-fixture\r\n250 SIZE junk\r\n"))[0], result('transient', 'invalid_size_capability'),
  'malformed size capability fails closed';
my $boundary = claim("Subject: x\r\n\r\n" . ('x' x 998) . "\r\n");
is +(peer($boundary))[0]->{outcome}, 'confirmed', 'exact 998-octet line boundary succeeds';
my $max_path = 'x' x 241 . '@example.test';
is +(peer({%{$claim}, sender => $max_path, recipient => $max_path}))[0]->{outcome}, 'confirmed',
  'exact 254-octet path boundary succeeds';

# Timeout after peer received terminator is not conclusive non-delivery.
my ($timed_out, undef, $timed_bytes) = peer($claim, delay_final => 2, timeout => 1);
is $timed_out,   result('uncertain', 'final'), 'lost final acknowledgement by timeout remains uncertain';
is $timed_bytes, $raw,                         'timeout may occur after peer has all message bytes';

# Fault injection targets library exceptions and write failures unavailable deterministically over TCP.

{
  my $prefix    = "Subject: x\r\n\r\n";
  my $remaining = 10_485_760 - length $prefix;
  my $bytes =
    $prefix . ((('x' x 998) . "\r\n") x int($remaining / 1_000)) . ('x' x (($remaining % 1_000) - 2)) . "\r\n";
  is length $bytes, 10_485_760, 'exact maximum message fixture';
  local *Overnet::Mail::Transport::SMTPClient::new = sub { return; };
  is $adapter->deliver(claim($bytes)), result('transient', 'connect'),
    'exact maximum wire size passes preflight without rewriting';
}

{
  local *Overnet::Mail::Transport::SMTPClient::new = sub { die 'private exception'; };
  is $adapter->deliver($claim), result('transient', 'connect'), 'connection exception is sanitized';
}
{
  local *Overnet::Mail::Transport::SMTPClient::datasend = sub {
    return 1 if @_ == 1;    # Net::SMTP::data initializes datasend before body.
    die 'private body exception';
  };
  is +(peer($claim))[0], result('uncertain', 'body'), 'body exception is conservatively uncertain';
}
{
  local *Overnet::Mail::Transport::SMTPClient::datasend = sub { return @_ == 1; };
  is +(peer($claim))[0], result('uncertain', 'body'), 'body write failure is uncertain and never auto-finished';
}

{
  no warnings 'once';
  local *Overnet::Mail::Transport::SMTPClient::close = sub { die 'private cleanup exception'; };
  is +(peer($claim))[0], result('confirmed', 'final', 250),
    'cleanup exception cannot erase observed acceptance or expose peer data';
}

# One transport call per recipient preserves the queue's partial outcomes.
my $store      = Overnet::Mail::Store->new(path => "$dir/queue.db");
my $submission = Overnet::Mail::Submission->new(
  message  => $claim->{message},
  envelope => Overnet::Mail::Envelope->new(
    sender     => q{},
    recipients => ['one@example.test', 'blind@example.test', 'last@example.test']
  )
);
my $receipt = $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'one', item => $submission);
for my $case ([{}, 'delivered'], [{recipient => "550 rejected\r\n"}, 'failed'], [{drop => 'final'}, 'uncertain']) {
  my $lease = $store->claim_delivery(mailbox_id => 'box', now => 100);
  my ($outcome) = peer($lease, %{$case->[0]});
  is $store->deliveries(mailbox_id => 'box', submission_id => 1)->[$lease->{position} // ($lease->{delivery_id} - 1)]
    ->{state},
    'leased', 'adapter itself never commits or retries a queue outcome';
  my %retry    = $outcome->{outcome} eq 'uncertain' ? (retry_after => 60) : ();
  my $finished = $store->finish_delivery(
    mailbox_id  => 'box',
    delivery_id => $lease->{delivery_id},
    attempt     => $lease->{attempt},
    now         => 101,
    outcome     => $outcome->{outcome},
    %retry
  );
  is $finished->{state}, $case->[1], 'explicit caller settlement affects only the claimed recipient';
}
is [map { $_->{state} } @{$store->deliveries(mailbox_id => 'box', submission_id => $receipt->{submission_id})}],
  ['delivered', 'failed', 'uncertain'], 'partial outcomes persist without retrying accepted recipients';
ok !defined $store->claim_delivery(mailbox_id => 'box', now => 160), 'uncertain recipient is not immediately retried';
is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes, $raw,
  'local delivery attempt leaves durable original unchanged';
$store->disconnect;

done_testing;

sub claim {
  my ($bytes) = @_;
  return {
    message   => Overnet::Mail::RawMessage->new(raw_bytes => $bytes, max_bytes => 20_971_520),
    sender    => q{},
    recipient => 'blind@example.test'
  };
}

sub result {
  my ($outcome, $stage, $code) = @_;
  return {outcome => $outcome, stage => $stage, smtp_code => $code};
}

sub peer {
  my ($input, %options) = @_;
  my $listener =
    IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp', Timeout => 5)
    or die 'fixture listener failed';
  my $port = $listener->sockport;
  my $path = "$dir/peer-" . ++$counter;
  pipe my $cancel_read, my $cancel_write or die 'fixture cancellation pipe failed';
  my $pid = fork;
  die 'fixture fork failed' if !defined $pid;
  if (!$pid) {
    close $cancel_write or die 'child pipe close failed';
    my $ok = eval { serve($listener, $path, \%options, $cancel_read); 1; };
    exit($ok ? 0 : 1);
  }
  close $cancel_read or die 'parent pipe close failed';
  close $listener    or die 'parent listener close failed';
  my $transport = Overnet::Mail::Transport::LoopbackSMTP->new(port => $port, timeout => $options{timeout} // 1);
  my $outcome   = $transport->deliver($input);
  close $cancel_write or die 'parent cancellation failed';
  waitpid $pid, 0;
  is $?, 0, 'scripted loopback peer exited cleanly';
  return ($outcome, map { read_file("$path.$_") } qw(commands received wire));
}

sub serve {
  my ($listener, $path, $options, $cancel) = @_;
  local $SIG{PIPE} = 'IGNORE';
  local $SIG{ALRM} = sub { die 'fixture deadline'; };
  alarm 8;
  open my $commands, '>:raw', "$path.commands" or die 'commands output failed';
  open my $received, '>:raw', "$path.received" or die 'message output failed';
  open my $wire,     '>:raw', "$path.wire"     or die 'wire output failed';
  my @ready = IO::Select->new($listener, $cancel)->can_read(8);

  if (!grep { fileno($_) == fileno($listener) } @ready) {
    close $listener or die 'unused listener close failed';
    close $cancel   or die 'cancellation pipe close failed';
    close $commands or die 'empty commands close failed';
    close $received or die 'empty message close failed';
    close $wire     or die 'empty wire close failed';
    alarm 0;
    return;
  }
  close $cancel                  or die 'connected pipe close failed';
  my $socket = $listener->accept or die 'fixture accept failed';
  close $listener                or die 'fixture listener close failed';
  $socket->autoflush(1);
  binmode $socket, ':raw' or die 'fixture binary mode failed';

  if (($options->{drop} // q{}) ne 'greeting') {
    print {$socket} $options->{greeting} // "220 fixture\r\n";
    for my $stage (qw(hello mail recipient data final)) {
      if ($stage eq 'final') {
        while (defined(my $line = <$socket>)) {
          last if $line eq ".\r\n";
          print {$wire} $line;
          $line =~ s/\A\.\././;
          print {$received} $line;
        }
        sleep($options->{delay_final}) if $options->{delay_final};
      } else {
        my $command = <$socket>;
        last if !defined $command;
        print {$commands} $command;
      }
      last if ($options->{drop} // q{}) eq $stage;
      my $default =
          $stage eq 'hello' ? "250-fixture\r\n250-SIZE 10485760\r\n250 8BITMIME\r\n"
        : $stage eq 'data'  ? "354 send bytes\r\n"
        :                     "250 accepted\r\n";
      print {$socket} $options->{$stage} // $default;
      if ($stage eq 'hello' && exists $options->{helo}) {
        my $command = <$socket>;
        last if !defined $command;
        print {$commands} $command;
        print {$socket} $options->{helo};
      }
    }
  }
  close $socket   or die 'fixture socket close failed';
  close $commands or die 'commands output close failed';
  close $received or die 'message output close failed';
  close $wire     or die 'wire output close failed';
  alarm 0;
  return;
}

sub read_file {
  my ($path) = @_;
  open my $file, '<:raw', $path or die 'fixture read failed';
  local $/;
  my $bytes = <$file>;
  close $file or die 'fixture read close failed';
  return $bytes // q{};
}
