use strictures 2;

use Digest::SHA qw(sha256_hex);
use Test2::V0;
use Overnet::Mail::RawMessage;

my $original = "From: sender\@example.test\r\nSubject: Bytes\r\n\r\nbody\0\xff\r\n";
my $input    = $original;
my $message  = Overnet::Mail::RawMessage->new(raw_bytes => $input);
is $message->raw_bytes,      $original,             'exact binary octets and trailing newline preserved';
is $message->size_bytes,     length($original),     'byte size matches original';
is $message->content_sha256, sha256_hex($original), 'content identity hashes original bytes';
is $message->max_bytes,      10_485_760,            'default total byte limit';
$input = 'changed';
is $message->raw_bytes, $original, 'caller input scalar cannot mutate stored bytes';
my $returned = $message->raw_bytes;
$returned =~ s/body/changed/;
is $message->raw_bytes, $original, 'returned scalar cannot mutate stored bytes';
like dies { $message->raw_bytes('replacement') }, qr/read-only/, 'raw accessor is read-only';
like dies { $message->max_bytes(999) },           qr/read-only/, 'limit accessor is read-only';

my $hashref = Overnet::Mail::RawMessage->new({raw_bytes => $original, max_bytes => length($original)});
is $hashref->raw_bytes, $original, 'hashref constructor and exact size boundary accepted';
like dies { Overnet::Mail::RawMessage->new(raw_bytes => $original, max_bytes => length($original) - 1) },
  qr/exceeds max_bytes/, 'one byte over configured limit rejected';
for my $bad (undef, [], 0, -1, '1.5', q{}) {
  like dies { Overnet::Mail::RawMessage->new(raw_bytes => $original, max_bytes => $bad) },
    qr/max_bytes must be a positive integer/, 'invalid byte limit rejected';
}
for my $bad (undef, [], q{}) {
  like dies { Overnet::Mail::RawMessage->new(raw_bytes => $bad) },
    qr/nonempty octet string/, 'non-octet value rejected';
}
my $characters = "\x{100}";
like dies { Overnet::Mail::RawMessage->new(raw_bytes => $characters) }, qr/encoded octets/, 'wide characters rejected';
my $flagged_ascii = $original;
utf8::upgrade($flagged_ascii);
like dies { Overnet::Mail::RawMessage->new(raw_bytes => $flagged_ascii) }, qr/encoded octets/,
  'flagged text requires explicit encoding';
like dies { Overnet::Mail::RawMessage->new }, qr/raw_bytes/, 'missing raw bytes rejected';

my $opaque = Overnet::Mail::RawMessage->new(raw_bytes => 'opaque malformed MIME');
is $opaque->raw_bytes, 'opaque malformed MIME', 'raw storage does not claim MIME validation';
my $no_id = Overnet::Mail::RawMessage->new(raw_bytes => "Subject: no id\n\nbody");
ok $no_id->content_sha256, 'Message-ID is not required';
my $first  = Overnet::Mail::RawMessage->new(raw_bytes => "Message-ID: <same\@example.test>\n\nfirst");
my $second = Overnet::Mail::RawMessage->new(raw_bytes => "Message-ID: <same\@example.test>\n\nsecond");
ok $first->content_sha256 ne $second->content_sha256, 'duplicate RFC Message-ID does not merge different content';
my $identical = Overnet::Mail::RawMessage->new(raw_bytes => $original);
is $identical->content_sha256, $message->content_sha256,
  'identical content has identical content hash without implying delivery deduplication';

done_testing;
