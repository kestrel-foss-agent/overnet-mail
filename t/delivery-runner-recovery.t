use strictures 2;

use Config;
use File::Temp qw(tempdir);
use IO::Select;
use IO::Socket::INET;
use JSON  ();
use POSIX ();
use Test2::V0;
use Overnet::Mail::DeliveryRunner;
use Overnet::Mail::Store;
use Overnet::Mail::Transport::LoopbackSMTP;

plan skip_all => 'fork unavailable on this platform' if !$Config{d_fork};

my $dir = tempdir(CLEANUP => 1);
local $ENV{TMPDIR} = $dir;
my $counter = 0;
my $raw =
    "From: visible\@example.test\r\nTo: unrelated\@example.test\r\nCc: visible-cc\@example.test\r\n"
  . "Subject: =?UTF-8?B?4pyT?=\r\n\tfolded subject\r\nMIME-Version: 1.0\r\n"
  . "Content-Type: multipart/mixed; boundary=fixture\r\n\r\n"
  . "--fixture\r\nContent-Type: text/plain\r\n\r\n.\r\n..two\r\nbody\r\n"
  . "--fixture\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n"
  . "AP8BAgM=\r\n--fixture--\r\n";

subtest 'finalized enqueue and independent recipient custody' => sub {
  my $store      = new_store('partial');
  my @recipients = ('blind@example.test', 'rejected@example.test', 'unknown@example.test');
  my $submission = submission(@recipients);
  $store->_dbh->do(
q{CREATE TEMP TRIGGER fail_enqueue BEFORE INSERT ON deliveries WHEN NEW.position = 1 BEGIN SELECT RAISE(ABORT, 'private trigger detail'); END}
  );
  like dies { enqueue($store, $submission) }, qr/database operation failed/, 'enqueue fails at the second recipient';
  is counts($store), [0, 0, 0, 0, 0, 0], 'message, private envelope and complete queue roll back atomically';
  $store->_dbh->do('DROP TRIGGER fail_enqueue');
  my $receipt = enqueue($store, $submission);
  is counts($store), [1, 1, 1, 3, 1, 3], 'finalized submission explicitly creates one complete outbox';

  my @cases = (
    [{}, 'confirmed', 'delivered'],
    [{recipient_code => 550}, 'permanent', 'failed'],
    [{drop_final     => 1},   'uncertain', 'uncertain'],
  );
  for my $position (0 .. $#cases) {
    my ($options, $outcome, $state) = @{$cases[$position]};
    my ($result, $peer) = smtp_run($store, 100, %{$options});
    is $result,
      {
      status      => 'recorded',
      delivery_id => $receipt->{delivery_ids}[$position],
      attempt     => 1,
      outcome     => $outcome,
      state       => $state,
      },
      'one runner call settles only its original recipient identity';
    my $commands =
      "EHLO fixture.invalid\r\nMAIL FROM:<> SIZE=" . length($raw) . "\r\nRCPT TO:<$recipients[$position]>\r\n";
    $commands .= "DATA\r\n" if $position != 1;
    is $peer->{commands}, $commands, 'SMTP uses the null reverse-path and precisely one envelope recipient';
    is $peer->{received}, $position == 1 ? q{} : $raw, 'DATA octets retain MIME, folded headers and dot-led lines';
    unlike $peer->{received}, qr/(?:blind|rejected|unknown)\@example[.]test|(?:\A|\r\n)Bcc:/,
      'blind envelope recipients never enter message headers or body';

    if ($position != 1) {
      like $peer->{wire}, qr/\r\n\.\.\r\n\.\.\.two\r\n/, 'SMTP transparency is removed without changing stored bytes';
    }
  }
  my $rows = rows($store);
  is [map { $_->{state} } @{$rows}], ['delivered', 'failed', 'uncertain'],
    'siblings retain independent durable outcomes';
  is $rows->[2]{next_attempt_at},    160, 'uncertain custody receives the explicit retry delay';
  is $rows->[2]{uncertain_attempts}, 1,   'ambiguity stays visible';
  my ($idle, $unused) = smtp_run($store, 159);
  is $idle, {status => 'idle'}, 'no retry before the deadline and no repeat of terminal recipients';
  is $unused->{commands}, q{}, 'idle run never connects to the peer';
  my $path = $store->path;
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $path);
  is rows($store),                 $rows,    'all partial outcomes survive reopening SQLite';
  is enqueue($store, $submission), $receipt, 'idempotent enqueue preserves original submission and delivery IDs';
  is rows($store),                 $rows,    'enqueue replay never resets outcomes or retry deadlines';
  is $store->load(mailbox_id => 'box', message_id => $receipt->{message_id})->{message}->raw_bytes, $raw,
    'exact original bytes survive every handoff and reconnect';
  $store->disconnect;
};

for my $failure (qw(commit lost_ack)) {
  subtest "claim $failure fails before any SMTP handoff" => sub {
    my $store = new_store("claim-$failure");
    enqueue($store, submission('blind@example.test'));
    my $peer = start_peer();
    $store->_dbh->{Callbacks} = {
      commit => sub {
        my ($dbh) = @_;
        if ($failure eq 'lost_ack') {
          local $dbh->{Callbacks} = {};
          $dbh->commit;
        }
        die 'blind@example.test private claim acknowledgement failure';
      },
    };
    my $error = dies {
      runner($store, $peer, sub { return 100 })->run_once(mailbox_id => 'box')
    };
    $store->_dbh->{Callbacks} = {};
    my $unused = finish_peer($peer);
    like $error,   qr/runner could not claim delivery/, 'claim failure is a fixed sanitized exception';
    unlike $error, qr/blind|private|acknowledgement/,   'DB callback diagnostics never escape the claim boundary';
    is $unused->{commands}, q{}, 'a failed claim acknowledgement never opens an SMTP exchange';
    is $unused->{received}, q{}, 'no message bytes leave before an acknowledged claim';
    my $path = $store->path;
    $store->disconnect;
    $store = Overnet::Mail::Store->new(path => $path);
    my $lost = $failure eq 'lost_ack';
    is [@{rows($store)->[0]}{qw(state attempt uncertain_attempts)}],
      [$lost ? 'leased' : 'ready', $lost ? 1 : 0, 0],
      'reopened status distinguishes rolled-back claim from committed lease with lost acknowledgement';

    if ($lost) {
      my ($idle) = smtp_run($store, 109);
      is $idle, {status => 'idle'}, 'lost claim acknowledgement preserves its lease until expiration';
    }
    my ($recovered, $accepted) = smtp_run($store, $lost ? 110 : 100);
    is $recovered,
      {status => 'recorded', delivery_id => 1, attempt => $lost ? 2 : 1, outcome => 'confirmed', state => 'delivered'},
      'next eligible invocation uses only the durable attempt count';
    is rows($store)->[0]{uncertain_attempts}, $lost ? 1 : 0,
      'lost acknowledgement conservatively counts lease-expiry uncertainty even without a prior SMTP send';
    is $accepted->{received}, $raw, 'recovery sends the original immutable bytes';
    $store->disconnect;
  };
}

for my $failure (qw(update commit)) {
  subtest "accepted SMTP custody but failed completion $failure" => sub {
    my $store = new_store("completion-$failure");
    enqueue($store, submission('blind@example.test'));
    my $ticks = 0;
    my $clock = sub {
      ++$ticks;
      if ($failure eq 'commit' && $ticks == 3) {
        $store->_dbh->{Callbacks} = {commit => sub { die 'blind@example.test private commit exception'; }};
      }
      return 100;
    };
    if ($failure eq 'update') {
      $store->_dbh->do(
q{CREATE TEMP TRIGGER fail_finish BEFORE UPDATE ON deliveries WHEN NEW.state = 'delivered' BEGIN SELECT RAISE(ABORT, 'blind@example.test private update exception'); END}
      );
    }
    my ($result, $accepted) = smtp_run($store, 100, clock => $clock);
    $store->_dbh->{Callbacks} = {};
    $store->_dbh->do('DROP TRIGGER fail_finish') if $failure eq 'update';
    is $result,
      {
      status      => 'unrecorded',
      delivery_id => 1,
      attempt     => 1,
      outcome     => 'confirmed',
      error       => 'completion_failed',
      },
      'remote acceptance is not mislabeled as durable success and errors omit private data';
    is $accepted->{accepted}, "250\n", 'peer sent its final custody acknowledgement';
    is $accepted->{received}, $raw,    'peer already has the complete message despite failed DB completion';
    my $path = $store->path;
    $store->disconnect;
    $store = Overnet::Mail::Store->new(path => $path);
    is [@{rows($store)->[0]}{qw(state attempt uncertain_attempts last_outcome lease_until)}],
      ['leased', 1, 0, undef, 110], 'failed completion restores the committed lease, not a terminal outcome';
    my ($idle, $unused) = smtp_run($store, 109);
    is $idle, {status => 'idle'}, 'runner does not retry an unexpired ambiguous lease';
    is $unused->{commands}, q{}, 'completion failure does not trigger an internal resend';
    my ($recovered, $duplicate) = smtp_run($store, 110);
    is $recovered, {status => 'recorded', delivery_id => 1, attempt => 2, outcome => 'confirmed', state => 'delivered'},
      'expired lease is recovered only with a new fenced attempt';
    is rows($store)->[0]{uncertain_attempts}, 1,      'lease-expiry ambiguity remains after later custody confirmation';
    is $duplicate->{received}, $accepted->{received}, 'recovery can duplicate accepted mail; it is not exactly once';
    $store->disconnect;
  };
}

subtest 'lost completion acknowledgement after a real DB commit' => sub {
  my $store      = new_store('lost-completion-ack');
  my $submission = submission('blind@example.test');
  my $receipt    = enqueue($store, $submission);
  my $ticks      = 0;
  my $clock      = sub {
    ++$ticks;
    if ($ticks == 3) {
      $store->_dbh->{Callbacks} = {
        commit => sub {
          my ($dbh) = @_;
          local $dbh->{Callbacks} = {};
          $dbh->commit;
          die 'private acknowledgement lost after commit';
        },
      };
    }
    return 100;
  };
  my ($result, $peer) = smtp_run($store, 100, clock => $clock);
  $store->_dbh->{Callbacks} = {};
  is $result,
    {
    status      => 'unrecorded',
    delivery_id => 1,
    attempt     => 1,
    outcome     => 'confirmed',
    error       => 'completion_failed',
    },
    'lost acknowledgement is reported without claiming whether the DB committed';
  is $peer->{received}, $raw, 'real SMTP custody occurred before the acknowledgement fault';
  my $path = $store->path;
  $store->disconnect;
  $store = Overnet::Mail::Store->new(path => $path);
  is [@{rows($store)->[0]}{qw(state attempt last_outcome)}], ['delivered', 1, 'confirmed'],
    'reopened status proves the completion committed despite its lost acknowledgement';
  is enqueue($store, $submission), $receipt, 'replay resolves the same logical request';
  my ($idle, $unused) = smtp_run($store, 1_000);
  is $idle, {status => 'idle'}, 'a committed terminal recipient is never reclaimed after its former lease expires';
  is $unused->{commands}, q{}, 'status reconciliation avoids a duplicate send';
  $store->disconnect;
};

subtest 'worker process exits after observing final 250 and before completion write' => sub {
  my $store = new_store('crash-after-250');
  enqueue($store, submission('blind@example.test'));
  my $path = $store->path;
  $store->disconnect;
  my $peer = start_peer();
  my $pid  = fork;
  die 'worker fork failed' if !defined $pid;
  if (!$pid) {
    local $SIG{ALRM} = sub { POSIX::_exit(79) };
    alarm 15;
    local *Overnet::Mail::Store::finish_delivery = sub {
      my ($child, %args) = @_;
      POSIX::_exit($args{outcome} eq 'confirmed' ? 71 : 72);
    };
    my $child = Overnet::Mail::Store->new(path => $path);
    runner($child, $peer, sub { return 100 })->run_once(mailbox_id => 'box');
    POSIX::_exit(73);
  }
  waitpid $pid, 0;
  is $? >> 8, 71, 'worker observed final acceptance, then exited at the first completion call without any write';
  my $first = finish_peer($peer);
  is $first->{accepted}, "250\n", 'fixture sent final 250 before the process interruption';
  is $first->{received}, $raw,    'remote fixture has all bytes at the crash point';
  $store = Overnet::Mail::Store->new(path => $path);
  is [@{rows($store)->[0]}{qw(state attempt last_outcome)}], ['leased', 1, undef],
    'crash leaves the original committed claim and no invented durable success';
  my ($idle) = smtp_run($store, 109);
  is $idle, {status => 'idle'}, 'no premature retry before crash lease expires';
  my ($recovered, $second) = smtp_run($store, 110);
  is $recovered, {status => 'recorded', delivery_id => 1, attempt => 2, outcome => 'confirmed', state => 'delivered'},
    'recovery creates a fresh fence and records later custody';
  is rows($store)->[0]{uncertain_attempts}, 1, 'post-250 crash remains historically uncertain';
  is $second->{received}, $first->{received},  'the uncertainty window can cause duplicate SMTP custody';
  $store->disconnect;
};

subtest 'new worker finishes while the expired worker is still in a real send' => sub {
  my $store = new_store('overlapping-workers');
  enqueue($store, submission('blind@example.test'));
  my $path = $store->path;
  $store->disconnect;
  my $old_peer    = start_peer(block_final => 1);
  my $result_path = "$dir/old-worker-result";
  my $pid         = fork;
  die 'stale worker fork failed' if !defined $pid;

  if (!$pid) {
    local $SIG{ALRM} = sub { POSIX::_exit(79) };
    alarm 20;
    my $child  = Overnet::Mail::Store->new(path => $path);
    my $ticks  = 0;
    my $clock  = sub { return ++$ticks == 3 ? 111 : 100 };
    my $result = runner($child, $old_peer, $clock)->run_once(mailbox_id => 'box');
    write_file($result_path, JSON->new->encode($result));
    $child->disconnect;
    POSIX::_exit(0);
  }
  is signal_read($old_peer->{ready}), 'B', 'old SMTP exchange has sent the full DATA body and awaits the final reply';
  $store = Overnet::Mail::Store->new(path => $path);
  is [@{rows($store)->[0]}{qw(state attempt lease_until)}], ['leased', 1, 110],
    'claim was durable before SMTP and no writer transaction spans the blocked send';
  my ($new_result, $new_peer) = smtp_run($store, 110);
  is $new_result, {status => 'recorded', delivery_id => 1, attempt => 2, outcome => 'confirmed', state => 'delivered'},
    'another connection expires the lease and finishes a newer send while old I/O is still blocked';
  my $settled = rows($store);
  is $settled->[0]{uncertain_attempts}, 1, 'reclaim records uncertainty before the old result arrives';
  signal_write($old_peer->{release}, 'F');
  waitpid $pid, 0;
  is $?, 0, 'old worker returned normally after its real SMTP final reply was released';
  my $old_result   = JSON->new->decode(read_file($result_path));
  my $old_observed = finish_peer($old_peer);
  is $old_result,
    {
    status      => 'unrecorded',
    delivery_id => 1,
    attempt     => 1,
    outcome     => 'confirmed',
    error       => 'completion_failed',
    },
    'old remote success retains its original attempt and cannot settle the new lease';
  is rows($store),              $settled,              'late success cannot overwrite any of the newer durable outcome';
  is $old_observed->{received}, $new_peer->{received}, 'fencing protects local state while both peers can accept bytes';
  is $old_observed->{accepted}, "250\n",               'the stale transport really returned final SMTP success';
  $store->disconnect;
};

subtest 'transport exception after real acceptance remains uncertain and bounded' => sub {
  my $store = new_store('exception-after-acceptance');
  enqueue($store, submission('blind@example.test'));
  my $deliver          = \&Overnet::Mail::Transport::LoopbackSMTP::deliver;
  my $saw_confirmation = 0;
  my ($result, $peer);
  {
    local *Overnet::Mail::Transport::LoopbackSMTP::deliver = sub {
      my ($transport, $claim) = @_;
      my $report = $deliver->($transport, $claim);
      die 'fixture failed to reach real acceptance' if $report->{outcome} ne 'confirmed';
      $saw_confirmation = 1;
      die 'blind@example.test private exception after acceptance';
    };
    ($result, $peer) = smtp_run($store, 100);
  }
  is $saw_confirmation, 1,       'actual LoopbackSMTP confirmed custody before the injected exception';
  is $peer->{accepted}, "250\n", 'exception is injected only after the actual adapter saw acceptance';
  is $peer->{received}, $raw,    'exception does not erase bytes already accepted by the peer';
  is $result, {status => 'recorded', delivery_id => 1, attempt => 1, outcome => 'uncertain', state => 'uncertain'},
    'exception becomes a sanitized uncertain result instead of fabricated delivery or non-delivery';
  is [@{rows($store)->[0]}{qw(next_attempt_at uncertain_attempts last_outcome)}], [160, 1, 'uncertain'],
    'explicit retry deadline and uncertainty survive a post-acceptance exception';
  my ($idle) = smtp_run($store, 159);
  is $idle, {status => 'idle'}, 'post-acceptance exception never causes an immediate internal retry';
  $store->disconnect;
};

subtest 'retryable SMTP outcomes exhaust exactly the existing attempt budget' => sub {
  my $store      = new_store('bounded-retries');
  my $submission = submission('blind@example.test');
  my $receipt    = enqueue($store, $submission);
  for my $attempt (1 .. 5) {
    my $now     = 100 + ($attempt - 1) * 60;
    my %options = $attempt == 1 ? (recipient_code => 450) : (drop_final => 1);
    my ($result, $peer) = smtp_run($store, $now, %options);
    my $outcome = $attempt == 1 ? 'transient' : 'uncertain';
    my $state   = $attempt == 5 ? 'exhausted' : $attempt == 1 ? 'deferred' : 'uncertain';
    is $result, {status => 'recorded', delivery_id => 1, attempt => $attempt, outcome => $outcome, state => $state},
      'one explicitly invoked runner call consumes one bounded attempt';
    is $peer->{received}, $attempt == 1 ? q{} : $raw,
      'transient recipient rejection and lost final reply stay distinct';
    is rows($store)->[0]{next_attempt_at}, $now + 60, 'every retryable result records only the explicit delay';
    my ($idle, $unused) = smtp_run($store, $now + 59);
    is $idle, {status => 'idle'}, 'no attempt is available before its recorded retry deadline';
    is $unused->{commands}, q{}, 'waiting is represented as idle, without SMTP I/O or busy retries';
  }
  is [@{rows($store)->[0]}{qw(state attempt uncertain_attempts last_outcome)}], ['exhausted', 5, 4, 'uncertain'],
    'exhaustion retains ambiguous acceptance rather than claiming non-delivery';
  is enqueue($store, $submission), $receipt, 'replay does not create another attempt budget';
  my ($idle, $unused) = smtp_run($store, 1_000);
  is $idle, {status => 'idle'}, 'no sixth attempt after exhaustion';
  is $unused->{commands}, q{}, 'exhausted recipient is not silently resent';
  $store->disconnect;
};

done_testing;

sub new_store {
  my ($name) = @_;
  return Overnet::Mail::Store->new(path => "$dir/$name.db");
}

sub submission {
  my (@recipients) = @_;
  return Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => $raw),
    envelope => Overnet::Mail::Envelope->new(sender => q{}, recipients => \@recipients),
  );
}

sub enqueue {
  my ($store, $submission) = @_;
  return $store->enqueue_submission(mailbox_id => 'box', idempotency_key => 'request', item => $submission);
}

sub counts {
  my ($store) = @_;
  return [map { $store->_dbh->selectrow_array("SELECT COUNT(*) FROM $_") }
      qw(blossom_blob_data blossom_blobs messages recipients submissions deliveries)];
}

sub rows {
  my ($store) = @_;
  return $store->deliveries(mailbox_id => 'box', submission_id => 1);
}

sub runner {
  my ($store, $peer, $clock) = @_;
  return Overnet::Mail::DeliveryRunner->new(
    store         => $store,
    transport     => Overnet::Mail::Transport::LoopbackSMTP->new(port => $peer->{port}, timeout => 10),
    clock         => $clock,
    retry_after   => 60,
    lease_seconds => 10,
  );
}

sub smtp_run {
  my ($store, $now, %options) = @_;
  my $peer   = start_peer(%options);
  my $result = runner($store, $peer, $options{clock} // sub { return $now })->run_once(mailbox_id => 'box');
  return ($result, finish_peer($peer));
}

sub start_peer {
  my (%options) = @_;
  my $listener =
    IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp', Timeout => 10)
    or die 'fixture listener failed';
  my $port = $listener->sockport;
  my $path = "$dir/peer-" . ++$counter;
  pipe my $cancel_read,  my $cancel_write  or die 'fixture cancellation pipe failed';
  pipe my $ready_read,   my $ready_write   or die 'fixture ready pipe failed';
  pipe my $release_read, my $release_write or die 'fixture release pipe failed';
  my $pid = fork;
  die 'fixture fork failed' if !defined $pid;

  if (!$pid) {
    close $cancel_write  or die 'child cancellation close failed';
    close $ready_read    or die 'child readiness close failed';
    close $release_write or die 'child release close failed';
    my $ok = eval { serve($listener, $path, \%options, $cancel_read, $ready_write, $release_read); 1 };
    write_file("$path.error", "$@") if !$ok;
    POSIX::_exit($ok ? 0 : 1);
  }
  close $listener     or die 'parent listener close failed';
  close $cancel_read  or die 'parent cancellation close failed';
  close $ready_write  or die 'parent readiness close failed';
  close $release_read or die 'parent release close failed';
  return {
    port    => $port,
    pid     => $pid,
    path    => $path,
    cancel  => $cancel_write,
    ready   => $ready_read,
    release => $release_write
  };
}

sub finish_peer {
  my ($peer) = @_;
  close $peer->{cancel} or die 'fixture cancellation failed';
  waitpid $peer->{pid}, 0;
  my $status = $?;
  is $status, 0, 'scripted ephemeral loopback-only peer exited cleanly';
  diag read_file("$peer->{path}.error") if $status;
  close $peer->{ready}   or die 'readiness pipe close failed';
  close $peer->{release} or die 'release pipe close failed';
  return {map { $_ => read_file("$peer->{path}.$_") } qw(commands received wire accepted)};
}

sub serve {
  my ($listener, $path, $options, $cancel, $ready, $release) = @_;
  local $SIG{PIPE} = 'IGNORE';
  local $SIG{ALRM} = sub { die 'fixture deadline'; };
  alarm 25;
  my %output;
  for my $kind (qw(commands received wire accepted)) {
    open my $file, '>:raw', "$path.$kind" or die 'fixture output open failed';
    $output{$kind} = $file;
  }
  my @readable = IO::Select->new($listener, $cancel)->can_read(20);
  if (grep { fileno($_) == fileno($listener) } @readable) {
    my $socket = $listener->accept or die 'fixture accept failed';
    $socket->autoflush(1);
    binmode $socket, ':raw' or die 'fixture binary mode failed';
    exchange($socket, \%output, $options, $ready, $release);
    close $socket or die 'fixture socket close failed';
  }
  for my $file (values %output) {
    close $file or die 'fixture output close failed';
  }
  close $listener or die 'fixture listener close failed';
  close $cancel   or die 'fixture cancellation close failed';
  close $ready    or die 'fixture readiness close failed';
  close $release  or die 'fixture release close failed';
  alarm 0;
  return;
}

sub exchange {
  my ($socket, $output, $options, $ready, $release) = @_;
  print {$socket} "220 fixture\r\n" or die 'fixture greeting failed';
  for my $stage (qw(hello mail recipient data)) {
    my $command = <$socket>;
    die 'fixture command missing' if !defined $command;
    print {$output->{commands}} $command or die 'command capture failed';
    my $reply =
        $stage eq 'hello' ? "250-fixture\r\n250 SIZE 10485760\r\n"
      : $stage eq 'data'  ? "354 send bytes\r\n"
      :                     "250 accepted\r\n";
    if ($stage eq 'recipient' && $options->{recipient_code}) {
      print {$socket} "$options->{recipient_code} private server detail\r\n" or die 'fixture rejection failed';
      return;
    }
    print {$socket} $reply or die 'fixture reply failed';
  }
  my $terminated = 0;
  while (defined(my $line = <$socket>)) {
    if ($line eq ".\r\n") {
      $terminated = 1;
      last;
    }
    print {$output->{wire}} $line or die 'wire capture failed';
    $line =~ s/\A\.\././;
    print {$output->{received}} $line or die 'message capture failed';
  }
  die 'fixture DATA terminator missing' if !$terminated;
  if ($options->{block_final}) {
    signal_write($ready, 'B');
    die 'fixture release missing' if signal_read($release) ne 'F';
  }
  if (!$options->{drop_final}) {
    print {$socket} "250 accepted\r\n"  or die 'final acceptance failed';
    print {$output->{accepted}} "250\n" or die 'acceptance capture failed';
  }
  return;
}

sub signal_read {
  my ($pipe) = @_;
  local $SIG{ALRM} = sub { die 'coordination deadline'; };
  alarm 15;
  my $count = sysread $pipe, my $value, 1;
  alarm 0;
  die 'coordination read failed' if !defined $count || $count != 1;
  return $value;
}

sub signal_write {
  my ($pipe, $value) = @_;
  my $count = syswrite $pipe, $value;
  die 'coordination write failed' if !defined $count || $count != 1;
  return;
}

sub read_file {
  my ($path) = @_;
  open my $file, '<:raw', $path or die 'fixture read failed';
  local $/;
  my $value = <$file>;
  close $file or die 'fixture read close failed';
  return $value // q{};
}

sub write_file {
  my ($path, $value) = @_;
  open my $file, '>:raw', $path or die 'fixture write open failed';
  print {$file} $value or die 'fixture write failed';
  close $file          or die 'fixture write close failed';
  return;
}
