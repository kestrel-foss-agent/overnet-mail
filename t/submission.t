use strictures 2;

use Email::MIME ();
use Test2::V0;
use Overnet::Mail::Envelope;
use Overnet::Mail::RawMessage;
use Overnet::Mail::Submission;

my $envelope = Overnet::Mail::Envelope->new(
  sender     => 'sender@example.test',
  recipients => ['visible@example.test', 'blind@example.test']
);
my $raw =
"From: sender\@example.test\r\nTo: visible\@example.test\r\nSubject: Folded\r\n subject\r\n\r\nBcc: body text\0\xff\r\n";
my $message    = Overnet::Mail::RawMessage->new(raw_bytes => $raw);
my $submission = Overnet::Mail::Submission->new({message => $message, envelope => $envelope});
is $submission->message,            $message,  'raw message identity retained';
is $submission->envelope,           $envelope, 'envelope remains separate';
is $submission->message->raw_bytes, $raw,      'submission neither strips nor reserializes bytes';
is $submission->max_header_bytes,   65_536,    'default header byte limit';
is $submission->max_header_fields,  200,       'default header field limit';
unlike $raw, qr/blind\@example[.]test/, 'blind recipient is absent from MIME';
is $submission->envelope->recipients->[1], 'blind@example.test', 'blind recipient stays in envelope';
like dies { $submission->message($message) },   qr/read-only/, 'message accessor read-only';
like dies { $submission->envelope($envelope) }, qr/read-only/, 'envelope accessor read-only';

for my $headers (
  "Subject: no id\n",
  "Subject: \xc3\xa9\n",
  "X-Test: one\nX-Test: two\n",
  "Subject: folded\n\tcontinuation\n"
) {
  ok make_submission($headers . "\nbody"), 'supported LF, UTF8 value, duplicate ordinary field or fold accepted';
}
for my $field ('Bcc', 'bCc', 'BCC', 'Resent-Bcc', 'rEsEnT-bCc') {
  for my $value (q{}, 'blind@example.test', "\r\n blind\@example.test") {
    my $bytes    = "Subject: test\r\n$field: $value\r\n\r\nbody";
    my $incoming = Overnet::Mail::RawMessage->new(raw_bytes => $bytes);
    is $incoming->raw_bytes, $bytes, 'incoming Bcc octets remain unchanged';
    my $error = dies { Overnet::Mail::Submission->new(message => $incoming, envelope => $envelope) };
    like $error, qr/must not contain Bcc or Resent-Bcc/, 'outbound field presence rejected regardless of value or case';
    unlike $error, qr/blind\@example[.]test/,            'Bcc error omits recipient';
    is $incoming->raw_bytes, $bytes, 'failed submission leaves original bytes untouched';
  }
}
like dies { make_submission("Bcc:\nBcc: blind\@example.test\n\nbody") }, qr/must not contain/,
  'duplicate Bcc cannot hide behind empty first value';

my @unsupported = (
  "Subject: header only",
  "\n\nbody",
  "Subject: x\nBcc : blind\@example.test\n\nbody",
  "Subject: x\nBcc\t: blind\@example.test\n\nbody",
  "bad line\nBcc: blind\@example.test\n\nbody",
  " orphan continuation\nSubject: x\n\nbody",
  "Subject: x\rBcc: blind\@example.test\r\rbody",
  "Subject: x\n\rBcc: blind\@example.test\n\r\n\rbody",
  "Subject: x\r\nX-Test: y\n\nbody",
  "Subject: x\nX-Test: y\r\n\r\nbody",
  "Subject: x\r\n\nbody",
  "Sub\xffject: x\n\nbody",
);
for my $bytes (@unsupported) {
  my $error = dies { make_submission($bytes) };
  ok $error, 'unsupported physical header framing fails closed';
  unlike $error, qr/blind\@example[.]test/, 'framing error omits blind address';
}
for my $control ("\0", "\x01", "\x08", "\x0b", "\x0c", "\x0e", "\x1f", "\x7f") {
  like dies { make_submission("Subject: x${control}y\n\nbody") }, qr/control byte/, 'control header byte rejected';
}

for my $name (qw(max_header_bytes max_header_fields)) {
  for my $bad (undef, [], 0, -1, '1.5', q{}) {
    like dies { make_submission("Subject: x\n\nbody", $name => $bad) }, qr/positive integer/,
      'invalid header limit rejected';
  }
}
my $header = 'Subject: x';
ok make_submission("$header\n\nbody", max_header_bytes => length($header), max_header_fields => 1),
  'exact header limits accepted';
like dies { make_submission("$header\n\nbody", max_header_bytes => length($header) - 1) }, qr/exceed max_header_bytes/,
  'header byte bound enforced';
like dies { make_submission("$header\nX-Test: y\n\nbody", max_header_fields => 1) }, qr/count exceeds/,
  'header field bound enforced';
for my $bad (undef, {}, $envelope) {
  like dies { Overnet::Mail::Submission->new(message => $bad, envelope => $envelope) }, qr/message must be/,
    'wrong message object rejected';
}
for my $bad (undef, {}, $message) {
  like dies { Overnet::Mail::Submission->new(message => $message, envelope => $bad) }, qr/envelope must be/,
    'wrong envelope object rejected';
}

my $binary = "\0\x01\xff\r\nBcc: inside attachment\n";
my $mime   = Email::MIME->create(
  header_str => [From => 'sender@example.test', To => 'visible@example.test', Subject => 'Attachment fixture'],
  parts      => [
    Email::MIME->create(
      attributes => {content_type => 'text/plain', charset => 'UTF-8', encoding => 'quoted-printable'},
      body_str   => 'Body Bcc: is content'
    ),
    Email::MIME->create(
      attributes => {
        content_type => 'application/octet-stream',
        disposition  => 'attachment',
        filename     => 'sample.bin',
        encoding     => 'base64'
      },
      body => $binary
    ),
  ],
);
my $wire            = $mime->as_string;
my $with_attachment = make_submission($wire);
is $with_attachment->message->raw_bytes, $wire, 'CPAN-generated multipart bytes preserved exactly';
my @parts = Email::MIME->new($with_attachment->message->raw_bytes)->subparts;
is $parts[1]->body, $binary, 'binary attachment decodes unchanged through CPAN';

like dies { make_submission('Subject: ' . ('x' x 100_000), max_header_bytes => 32) },
  qr/headers exceed max_header_bytes/, 'separator search is bounded before scanning an oversized header';
ok make_submission("Subject: x\r\n\r\nbody", max_header_bytes => length('Subject: x')),
  'exact CRLF header limit includes separator slack';

my $forwarded = Email::MIME->create(
  header_str => [From => 'sender@example.test', Subject => 'Forwarded message'],
  parts      => [
    Email::MIME->create(
      attributes => {content_type => 'message/rfc822'},
      body       => "From: old\@example.test\r\nBcc: old-blind\@example.test\r\n\r\nforwarded body",
    )
  ],
);
my $forwarded_wire = $forwarded->as_string;
like $forwarded_wire, qr{Content-Type: message/rfc822}, 'fixture is a real attached message';
like $forwarded_wire, qr/Bcc: old-blind/,               'attached message retains its own Bcc header';
is make_submission($forwarded_wire)->message->raw_bytes, $forwarded_wire,
  'root-only privacy boundary accepts embedded message headers without rewriting';

done_testing;

sub make_submission {
  my ($bytes, @extra) = @_;
  return Overnet::Mail::Submission->new(
    message  => Overnet::Mail::RawMessage->new(raw_bytes => $bytes),
    envelope => $envelope,
    @extra,
  );
}
