# Message and envelope boundary

This milestone adds three in-memory value objects. It implements no server,
delivery, outbox, authentication, storage, composing or header rewriting.

## RawMessage

`Overnet::Mail::RawMessage` accepts a nonempty octet scalar, copies its value and
exposes read-only scalar access. It preserves every byte, including body NULs,
trailing newlines, MIME encodings and malformed opaque inbound content. Perl
UTF-8-flagged character strings must be explicitly encoded before construction.
The default total limit is 10 MiB, configurable with `max_bytes`.

`content_sha256` identifies content bytes, independently of RFC Message-ID.
Message-ID may be absent or duplicated. The digest is not a delivery key,
authorization token or exactly-once guarantee. No parser serialization is used.

## Envelope

`Overnet::Mail::Envelope` requires an explicit sender and nonempty recipient
array. The empty sender string is the SMTP null reverse-path. Empty recipients,
display-name/address-list inputs, control bytes and non-ASCII envelope addresses
are rejected. `Email::Address::XS` parses bare addr-specs and supplies formatted
addresses; local-part case, recipient order and duplicate recipients are retained.
Header comments accepted by that parser are not replayed as SMTP envelope syntax.
Arrays are defensively copied on input and output. Errors omit all address data.

Defaults are 1000 recipients (`max_recipients`) and 1024 bytes per address input
(`max_address_bytes`). These are resource limits, not full SMTP path or domain
validation. SMTPUTF8 envelope addresses remain explicitly unsupported; transport
capability, domain, path-length and deliverability validation belong at the future
mature-MTA boundary. Unicode body encodings and SMTP 8BITMIME are separate matters.

## Submission

`Overnet::Mail::Submission` combines a RawMessage and Envelope without deriving
routing recipients from To/Cc/Bcc. It first accepts only an unambiguous root
header subset: consistent CRLF or LF, a blank header/body separator, ASCII field
names immediately followed by a colon, and continuations after a field.
It rejects control bytes, mixed newlines, orphan continuations and unsupported
field framing before `Email::Simple` inspects field names. Any Bcc or Resent-Bcc
field is rejected, including empty, folded, mixed-case and duplicate instances.
The bytes are never rewritten, even when construction fails.

Defaults are 64 KiB excluding the separator (`max_header_bytes`) and 200 fields
(`max_header_fields`). Continuations count toward bytes, not field count. These
limits are configurable independently of the total RawMessage limit.

This is deliberately narrower than all valid RFC 5322 forms: header-only messages
and obsolete whitespace before a colon are unsupported outbound inputs here.
Inbound RawMessage storage remains opaque and does not impose these restrictions.
This framing guard is not a MIME validator or complete RFC implementation.

The privacy guarantee concerns root Bcc header metadata. It does not remove
arbitrary recipient text from bodies or forwarded attachments. Non-ASCII header
values are retained as bytes; future transport code must validate their encoding
and required SMTPUTF8 capabilities separately from body 8BITMIME requirements.

As with normal Perl objects, these public read-only interfaces are not a security
boundary against arbitrary code that directly changes private object internals.

## CPAN choices and evidence

- [Moo](https://metacpan.org/pod/Moo) owns construction and read-only accessors
- [Email::Simple](https://metacpan.org/pod/Email::Simple) inspects only bounded root
  headers; its serialization reconstructs headers and is never used for storage
- [Email::Address::XS](https://metacpan.org/pod/Email::Address::XS) supplies addr-spec
  parsing/formatting; this is distinct from full RFC 5321 SMTP Mailbox validation
- [Email::MIME](https://metacpan.org/pod/Email::MIME) builds and decodes multipart
  attachment test fixtures; application code does not reinvent MIME processing
- Digest::SHA supplies the content hash

Tests cover privacy failures, parser-framing ambiguities, binary attachments,
exact size boundaries, null senders, quoted addresses, local-part case,
constructor hashrefs, mutable caller inputs and invalid input types. No test sends
real email. The existing compatibility matrix remains unimplemented until real
MTA/mailbox adapters are introduced and tested end to end.
