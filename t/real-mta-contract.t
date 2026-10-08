use strictures 2;
use Test2::V0;

my $wrapper = slurp('scripts/real-mta-lab.sh');
like $wrapper, qr/--network none/, 'runtime has no external network';
like $wrapper, qr/--pids-limit 128 --memory 1g --cpus 2/, 'runtime resources bounded';
unlike $wrapper, qr/--privileged|--network host|--publish|--volume/, 'no host connectivity or mounts';
like $wrapper, qr/trap cleanup EXIT/, 'cleanup on every exit';
my $control = slurp('lab/real-mta/control');
like $control, qr/timeout --kill-after=10s 180s prove/, 'entire real suite bounded';
like $control, qr/ss -ltnH/, 'actual runtime listeners verified';
like $control, qr/ip route show/, 'runtime routes verified';
my $main = slurp('lab/real-mta/main.cf');
like $main, qr/^inet_interfaces = 127\.0\.0\.1$/m, 'SMTP binds private loopback';
like $main, qr/^smtpd_relay_restrictions = reject_unauth_destination$/m, 'loopback is not a relay bypass';
like $main, qr/^smtpd_recipient_restrictions = reject_unlisted_recipient$/m, 'unknown recipients rejected';
like $main, qr/^default_transport = error:/m, 'default Internet transport disabled';
like $main, qr/^relay_transport = error:/m, 'relay transport disabled';
like $main, qr/^message_size_limit = 65536$/m, 'size bound explicit';
like $main, qr/^virtual_transport = lmtp:inet:127\.0\.0\.1:2424$/m, 'only reference LMTP next hop';
my $master = slurp('lab/real-mta/master.cf');
unlike $master, qr/^smtp\s+unix/m, 'Internet SMTP client service absent';
like slurp('lab/real-mta/dovecot.conf'), qr/^listen = 127\.0\.0\.1$/m, 'IMAP and LMTP private loopback';
is slurp('lab/real-mta/recipients'), "alice\@reference.invalid allowed\nblind\@reference.invalid allowed\n",
  'only synthetic envelope destinations permitted';
my $workflow = slurp('.github/workflows/perl-tests.yml');
like $workflow, qr/^  real-mta:/m, 'real engine CI job present';
like $workflow, qr/run: bash scripts\/real-mta-lab.sh check/, 'CI invokes real engines';
my ($lab_job) = $workflow =~ /(^  real-mta:.*)\z/ms;
unlike $lab_job, qr/continue-on-error|if:/, 'real engine job cannot silently skip or tolerate failure';
for my $path ('scripts/real-mta-lab.sh', 'lab/real-mta/control') {
  is system('bash', '-n', $path), 0, "$path shell syntax";
}
done_testing;

sub slurp {
  my ($path) = @_;
  open my $fh, '<', $path or die "read $path: $!";
  local $/;
  my $content = <$fh>;
  close $fh or die "close $path: $!";
  return $content;
}
