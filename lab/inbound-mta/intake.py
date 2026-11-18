#!/usr/bin/env python3
"""Bounded synthetic Postfix intake. Not a deployed or general mail service.

Milter owns token issuance; only its ledger can authorize local delivery. SMTP
and Milter framing belong to Postfix and libmilter, not this module.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import re
import secrets
import select
import sqlite3
import subprocess
import sys
import time

TOKEN_HEADER = 'X-Overnet-Intake-Token'
TOKEN_RE = re.compile(r'[0-9a-f]{64}\Z')
MAX_BYTES = 65536
MAX_QUEUE_BYTES = MAX_BYTES + 16384
MAX_RECIPIENTS = 32


class Deferred(Exception):
    """A categorical, non-custody outcome. Never expose underlying exceptions."""


def recipient(value):
    # The lab deliberately permits only simple ASCII dot-atom synthetic routes.
    # It is not an Internet mailbox parser or an account mapping service.
    if not isinstance(value, str) or not re.fullmatch(
            r'[A-Za-z0-9][A-Za-z0-9._+-]{0,63}@[A-Za-z0-9.-]{1,190}', value):
        raise Deferred('recipient')
    local, domain = value.rsplit('@', 1)
    return local + '@' + domain.lower()


def read_bounded(fd, limit, timeout):
    deadline = time.monotonic() + timeout
    chunks = []
    size = 0
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
            raise Deferred('deadline')
        chunk = os.read(fd, min(8192, limit + 1 - size))
        if not chunk:
            return b''.join(chunks)
        size += len(chunk)
        if size > limit:
            raise Deferred('size')
        chunks.append(chunk)


class Ledger:
    """Append-only bindings in a dedicated, operator-owned SQLite database.

    There is no queue-ID index, token recovery from headers at intake, automatic
    recreation, pruning, or mutation of existing bindings.
    """
    def __init__(self, path):
        self.path = Path(path).resolve()

    @classmethod
    def initialize(cls, path):
        path = Path(path).resolve()
        # Explicit provisioning only. Never create a replacement on delivery.
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        obj = cls(path)
        with closing(obj.connect()) as db, db:
            db.executescript('''
                CREATE TABLE identity (source TEXT NOT NULL);
                CREATE TABLE intake (
                    token TEXT PRIMARY KEY, message BLOB NOT NULL,
                    recipients TEXT NOT NULL, received_at INTEGER NOT NULL
                );
                PRAGMA user_version = 1;
            ''')
            db.execute('INSERT INTO identity VALUES (?)',
                       ('intake-' + secrets.token_hex(16),))
        # Include creation of the directory entry in the durability boundary.
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return obj

    def connect(self):
        db = sqlite3.connect(self.path.as_uri() + '?mode=rw', uri=True, timeout=2)
        try:
            db.execute('PRAGMA synchronous = FULL')
            db.execute('PRAGMA journal_mode = DELETE')
            return db
        except BaseException:
            db.close()
            raise

    @staticmethod
    def source(db):
        if db.execute('PRAGMA user_version').fetchone()[0] != 1:
            raise Deferred('ledger')
        rows = db.execute('SELECT source FROM identity').fetchall()
        if len(rows) != 1 or not re.fullmatch(r'intake-[0-9a-f]{32}', rows[0][0]):
            raise Deferred('ledger')
        return rows[0][0]

    def issue(self, message, recipients, received_at):
        if not isinstance(message, bytes) or not 0 < len(message) <= MAX_BYTES:
            raise Deferred('size')
        recipients = sorted(set(recipient(r) for r in recipients))
        if not 1 <= len(recipients) <= MAX_RECIPIENTS:
            raise Deferred('recipient')
        if type(received_at) is not int or not 0 <= received_at <= 9999999999:
            raise Deferred('time')
        with closing(self.connect()) as db, db:
            db.execute('BEGIN IMMEDIATE')
            self.source(db)
            for _ in range(8):
                token = secrets.token_hex(32)
                try:
                    db.execute('INSERT INTO intake VALUES (?, ?, ?, ?)',
                               (token, message, json.dumps(recipients), received_at))
                    return token  # context manager commits before return
                except sqlite3.IntegrityError:
                    pass
            raise Deferred('collision')

    def resolve(self, token, address, message):
        if not TOKEN_RE.fullmatch(token):
            raise Deferred('token')
        address = recipient(address)
        with closing(self.connect()) as db, db:
            source = self.source(db)
            row = db.execute('SELECT message, recipients, received_at FROM intake WHERE token = ?',
                             (token,)).fetchone()
        if row is None or address not in json.loads(row[1]) or message != row[0]:
            raise Deferred('binding')
        return {'source_id': source, 'idempotency_key': token, 'recipient': address,
                'received_at': row[2]}, row[0]


def queue_boundary(raw):
    """Extract bounded local metadata, preserving all other header/body octets.

    This is not a MIME parser. Only root header field spans are inspected. The
    first header MUST be Postfix's own Received, hidden from Milter callbacks.
    Exactly this one transport header and our one token header are excluded.
    """
    if not 0 < len(raw) <= MAX_QUEUE_BYTES:
        raise Deferred('size')
    head, separator, body = raw.partition(b'\r\n\r\n')
    if not separator:
        raise Deferred('framing')
    fields = []
    for line in head.split(b'\r\n'):
        if b'\r' in line or b'\n' in line:
            raise Deferred('framing')
        if line.startswith((b' ', b'\t')):
            if not fields:
                raise Deferred('framing')
            fields[-1] += b'\r\n' + line
        else:
            name, colon, _ = line.partition(b':')
            if not colon or not re.fullmatch(rb'[!-9;-~]+', name):
                raise Deferred('framing')
            fields.append(line)
    if not fields or fields[0].partition(b':')[0].lower() != b'received':
        raise Deferred('trace')
    content = []
    tokens = []
    for field in fields[1:]:
        name, _, value = field.partition(b':')
        if name.lower() == TOKEN_HEADER.lower().encode('ascii'):
            # Intake explicitly inserts one SP with negotiated HDR_LEADSPC.
            if not re.fullmatch(rb' [0-9a-f]{64}', value):
                raise Deferred('token')
            tokens.append(value[1:].decode('ascii'))
        else:
            content.append(field)
    if len(tokens) != 1:
        raise Deferred('token')
    message = b'\r\n'.join(content) + b'\r\n\r\n' + body
    if len(message) > MAX_BYTES:
        raise Deferred('size')
    return tokens[0], message


def deliver(ledger, config, address, raw, timeout=15, runner=subprocess.run):
    token, message = queue_boundary(raw)
    metadata, message = ledger.resolve(token, address, message)
    helper = Path(__file__).with_name('store-delivery.pl')
    result = runner(['perl', str(helper), str(Path(config).resolve()),
                     json.dumps(metadata, separators=(',', ':'))], input=message,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                    timeout=timeout, check=False)
    # A normal process return plus an exact bounded success marker is required.
    if result.returncode != 0 or result.stdout != b'received\n':
        raise Deferred('store')


def serve(path, routes, connection):
    import Milter

    routes = frozenset(recipient(r) for r in routes)
    if not routes or len(routes) > MAX_RECIPIENTS:
        raise Deferred('routes')
    ledger = Ledger(path)
    # Verify provisioning before accepting any connection.
    with closing(ledger.connect()) as db, db:
        ledger.source(db)

    @Milter.header_leading_space
    class Intake(Milter.Base):
        def negotiate(self, opts):
            needed = Milter.ADDHDRS | Milter.CHGHDRS
            self.negotiated = bool(opts[1] & Milter.P_HDR_LEADSPC) and (opts[0] & needed) == needed
            if not self.negotiated:
                return Milter.REJECT
            return super().negotiate(opts)

        def envfrom(self, sender, *args):
            self.parts = []
            self.size = 0
            self.addresses = set()
            self.token_count = 0
            self.headers = 0
            self.failed = not getattr(self, 'negotiated', False)
            self.headers_done = False
            return Milter.TEMPFAIL if self.failed else Milter.CONTINUE

        def envrcpt(self, address, *args):
            try:
                address = recipient(address.removeprefix('<').removesuffix('>'))
                if address not in routes:
                    self.setreply('550', '5.1.1', 'Unknown synthetic recipient')
                    return Milter.REJECT
                if len(self.addresses) >= MAX_RECIPIENTS and address not in self.addresses:
                    return Milter.TEMPFAIL
                self.addresses.add(address)
                return Milter.CONTINUE
            except (Deferred, UnicodeError):
                return Milter.REJECT

        def append(self, block):
            self.size += len(block)
            if self.size > MAX_BYTES:
                self.failed = True
                return Milter.TEMPFAIL
            self.parts.append(block)
            return Milter.CONTINUE

        @Milter.decode('bytes')
        def header(self, field, value):
            self.headers += 1
            if self.headers > 512:
                self.failed = True
                return Milter.TEMPFAIL
            if field.lower() == TOKEN_HEADER.lower():
                self.size += len(field) + len(value) + 3
                if self.size > MAX_BYTES:
                    self.failed = True
                    return Milter.TEMPFAIL
                self.token_count += 1
                return Milter.CONTINUE
            try:
                # Postfix sends folded header LF; body callbacks already CRLF.
                value = value.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
                if b'\r' in value.replace(b'\r\n', b''):
                    raise Deferred('header')
                return self.append(field.encode('ascii') + b':' + value + b'\r\n')
            except (UnicodeError, Deferred):
                self.failed = True
                return Milter.TEMPFAIL

        def eoh(self):
            self.headers_done = True
            return self.append(b'\r\n')

        def body(self, block):
            return self.append(block)

        def eom(self):
            if self.failed or not self.headers_done or not self.addresses:
                return Milter.TEMPFAIL
            try:
                token = ledger.issue(b''.join(self.parts), self.addresses, int(time.time()))
                for index in range(self.token_count, 0, -1):
                    self.chgheader(TOKEN_HEADER, index, '')
                self.addheader(TOKEN_HEADER, ' ' + token)
                return Milter.CONTINUE
            except Exception:
                # Commit/response ambiguity leaves an orphan, never success.
                return Milter.TEMPFAIL

    Milter.factory = Intake
    Milter.set_flags(Milter.ADDHDRS | Milter.CHGHDRS)
    Milter.set_exception_policy(Milter.TEMPFAIL)
    Milter.runmilter('overnet-intake', connection, 15)


class Parser(argparse.ArgumentParser):
    def error(self, message):
        # Do not echo malformed recipients or configuration into MTA replies.
        raise Deferred('arguments')


def main():
    parser = Parser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init')
    init.add_argument('ledger')
    service = commands.add_parser('serve')
    service.add_argument('ledger')
    service.add_argument('socket', help='local Unix socket path, in trusted lab directory')
    service.add_argument('routes', nargs='+')
    delivery = commands.add_parser('deliver')
    delivery.add_argument('ledger')
    delivery.add_argument('config')
    delivery.add_argument('recipient')
    try:
        args = parser.parse_args()
        if args.command == 'init':
            Ledger.initialize(args.ledger)
        elif args.command == 'serve':
            # No TCP listener or caller-selected database operations.
            serve(args.ledger, args.routes, 'local:' + str(Path(args.socket).resolve()))
        else:
            raw = read_bounded(sys.stdin.fileno(), MAX_QUEUE_BYTES, 15)
            deliver(Ledger(args.ledger), args.config, args.recipient, raw)
        return 0
    except Exception:
        print('Temporary intake failure', file=sys.stderr)
        return 75


if __name__ == '__main__':
    sys.exit(main())
