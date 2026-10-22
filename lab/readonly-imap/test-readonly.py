#!/usr/bin/env python3
"""Real Store/Blossom tests for a local, unauthenticated IMAP storage lab.

Runs only synthetic temporary SQLite databases or uniquely named PostgreSQL
schemas. Uses Dovecot over process pipes, never an IMAP network listener.
"""
import argparse
import base64
import hashlib
import imaplib
import json
import os
from pathlib import Path
import pwd
import re
import resource
import secrets
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import time
import unittest

PARSER = argparse.ArgumentParser()
PARSER.add_argument('--prefix', type=Path, required=True)
PARSER.add_argument('--plugin-dir', type=Path, required=True)
PARSER.add_argument('--engine', choices=['sqlite', 'postgres'], required=True)
ARGS, UNIT_ARGS = PARSER.parse_known_args()
PREFIX, PLUGINS = ARGS.prefix.resolve(), ARGS.plugin_dir.resolve()
HERE = Path(__file__).resolve().parent
PERL = shutil.which('perl')
PERL5LIB = os.environ.get('PERL5LIB', '')
ENV = {'PATH': str(Path(PERL).parent)+':/usr/bin:/bin', 'USER': 'overnet-synthetic-fixture', 'PERL5LIB': PERL5LIB}
if ARGS.engine == 'postgres' and not os.environ.get('OVERNET_TEST_PG_DSN'):
    PARSER.error('--engine postgres requires OVERNET_TEST_PG_DSN; skipping is not allowed')
VERSION = subprocess.check_output([str(PREFIX/'sbin/dovecot'), '--version'], text=True).strip().split()[0]
if VERSION != '2.4.5':
    PARSER.error('This integration requires exactly Dovecot 2.4.5')

HEADER = (b'From: sender@example.invalid\r\nTo: reader@example.invalid\r\n'
          b'Date: Tue, 14 Nov 2023 22:13:20 +0000\r\n'
          b'Message-ID: <synthetic@example.invalid>\r\nMIME-Version: 1.0\r\n')
PLAIN = HEADER + b'Subject: Synthetic plain\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nHello, immutable mail.\r\n'
ENCODED = (HEADER + b'Subject: Binary attachment\r\nContent-Type: application/octet-stream\r\n'
           b'Content-Transfer-Encoding: base64\r\n\r\nAP9CSU5BUlk=\r\n')
MULTIPART = (HEADER + b'Subject: Multipart\r\nContent-Type: multipart/mixed; boundary="fixture-boundary"\r\n\r\n'
             b'Preamble\r\n--fixture-boundary\r\nContent-Type: text/plain; charset=utf-8\r\n'
             b'Content-Transfer-Encoding: quoted-printable\r\n\r\nCaf=C3=A9\r\n'
             b'--fixture-boundary\r\nContent-Type: application/octet-stream\r\n'
             b'Content-Disposition: attachment; filename="synthetic.bin"\r\n'
             b'Content-Transfer-Encoding: base64\r\n\r\nAP9CSU5BUlk=\r\n'
             b'--fixture-boundary--\r\nEpilogue\r\n')
BINARY = HEADER + b'Subject: Nonconforming NUL control\r\n\r\n\x00\xffraw\r\n'
LF = b'From: sender@example.invalid\nSubject: Nonconforming LF control\n\nRaw LF\n'


def process_limits():
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (20, 20))


class PipeClient(imaplib.IMAP4_stream):
    """Standard IMAP client parser, direct argv process spawn, no shell."""
    def __init__(self, argv, env, stderr):
        self.child_env, self.child_stderr = env, stderr
        super().__init__(argv)

    def open(self, host=None, port=None, timeout=None):
        self.host = self.port = self.sock = self.file = None
        self.process = subprocess.Popen(self.command, env=self.child_env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.child_stderr, shell=False, close_fds=True, preexec_fn=process_limits)
        self.writefile, self.readfile = self.process.stdin, self.process.stdout


def deadline(*_):
    raise TimeoutError('real-engine integration case exceeded 90 seconds')


class ReadOnlyIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='overnet-readonly-imap-')
        self.root = Path(self.tmp.name)
        self.clients, self.logs, self.cleanup_configs = [], [], []
        # Pin the exact interpreter used to install this run's CPAN/XS modules.
        # The C bridge executes this trusted local wrapper directly, no shell.
        self.wrapper = self.root/'store-helper'
        helper_hex = str(HERE/'store-helper.pl').encode().hex()
        self.wrapper.write_text('#!'+PERL+'\n' +
                                "my $file = pack('H*', '"+helper_hex+"'); exec {$^X} $^X, $file, @ARGV; die \"helper exec failed\\n\";\n")
        self.wrapper.chmod(0o700)
        self.config = self.new_config()
        self.fixture('init')
        signal.signal(signal.SIGALRM, deadline)
        signal.alarm(90)

    def tearDown(self):
        signal.alarm(0)
        for c in self.clients:
            if c.process.poll() is None:
                c.process.kill()
                c.process.wait(timeout=5)
            for stream in [c.process.stdin, c.process.stdout]:
                if stream and not stream.closed:
                    stream.close()
        for log in self.logs:
            log.close()
        if ARGS.engine == 'postgres':
            for config in self.cleanup_configs:
                p = self.fixture_process('cleanup', config=config)
                if p.returncode:
                    raise AssertionError('synthetic PostgreSQL cleanup failed: '+p.stderr.decode(errors='replace'))
        self.tmp.cleanup()

    def new_config(self, mailbox='synthetic', shared=None):
        directory = self.root/secrets.token_hex(4)
        directory.mkdir()
        if shared is not None:
            config = json.loads(Path(shared).read_text())
            config['mailbox_id'] = mailbox
        elif ARGS.engine == 'sqlite':
            config = {'engine': 'sqlite', 'path': str(directory/'fixture.sqlite'), 'mailbox_id': mailbox}
        else:
            config = {'engine': 'postgres', 'dsn': os.environ['OVERNET_TEST_PG_DSN'],
                      'user': os.environ.get('OVERNET_TEST_PG_USER', 'postgres'),
                      'schema': 'overnet_imap_'+secrets.token_hex(8), 'mailbox_id': mailbox}
        path = directory/'store.json'
        path.write_text(json.dumps(config))
        if ARGS.engine == 'postgres' and shared is None:
            self.cleanup_configs.append(path)
        return path

    def fixture_process(self, action, config=None, **args):
        return subprocess.run([PERL, str(HERE/'fixture.pl'), str(config or self.config)],
                              env=ENV, input=json.dumps({'action': action, **args}).encode(),
                              capture_output=True, timeout=60)

    def fixture(self, action, config=None, **args):
        p = self.fixture_process(action, config=config, **args)
        self.assertEqual(p.returncode, 0, p.stderr.decode(errors='replace'))
        return json.loads(p.stdout)

    def receive(self, raw=PLAIN, key='message', **args):
        return self.fixture('receive', raw_b64=base64.b64encode(raw).decode(), key=key, **args)

    def receive_delivery(self, raw=PLAIN, key='delivery', recipient='Alice@example.test',
                         source_id='local-mta', **args):
        return self.fixture('receive_delivery', raw_b64=base64.b64encode(raw).decode(),
                            key=key, recipient=recipient, source_id=source_id, **args)

    def helper(self, request, config=None):
        return subprocess.run([PERL, str(HERE/'store-helper.pl'), str(config or self.config)],
                              env=ENV, input=request, capture_output=True, timeout=12)

    def helper_body(self, uid, config=None):
        p = self.helper(f'FETCH {uid}\n'.encode(), config)
        self.assertEqual(p.returncode, 0, p.stderr)
        first, body = p.stdout.split(b'\n', 1)
        self.assertEqual(first, f'DATA {len(body)}'.encode())
        return body

    def snapshot(self, config=None):
        p = self.helper(b'SNAPSHOT\n', config)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.splitlines()
        state = re.fullmatch(rb'OK ([1-9][0-9]*) ([1-9][0-9]*) (0|[1-9][0-9]*)', lines[0])
        self.assertIsNotNone(state)
        validity, next_uid, count = map(int, state.groups())
        rows = [tuple(map(int, line.split(b' '))) for line in lines[1:]]
        self.assertEqual(len(rows), count)
        uids = [row[0] for row in rows]
        self.assertEqual(uids, sorted(set(uids)))
        self.assertTrue(all(0 < uid < next_uid for uid in uids))
        return validity, next_uid, rows

    def imap_config(self, config=None):
        path = self.root/('dovecot-'+secrets.token_hex(4))
        path.mkdir()
        for name in ['run', 'state', 'home']:
            (path/name).mkdir()
        settings = (HERE/'dovecot.conf.in').read_text()
        replacements = {'TEST_ROOT': str(path), 'PLUGIN_DIR': str(PLUGINS),
                        'HELPER': str(self.wrapper), 'STORE_CONFIG': str(config or self.config),
                        'PERL5LIB': PERL5LIB, 'PERL_BIN_DIR': str(Path(PERL).parent), 'PERL': PERL}
        for key, value in replacements.items():
            settings = settings.replace('@'+key+'@', value)
        user = pwd.getpwuid(os.geteuid()).pw_name
        settings += f'\ndefault_internal_user = {user}\ndefault_login_user = {user}\n'
        (path/'dovecot.conf').write_text(settings)
        return path/'dovecot.conf'

    def client(self, config=None, expected=None):
        conf = self.imap_config(config)
        log = open(conf.parent/'stderr.log', 'wb')
        self.logs.append(log)
        c = PipeClient([str(PREFIX/'libexec/dovecot/imap'), '-c', str(conf)], ENV, log)
        self.clients.append(c)
        self.assertEqual(c.state, 'AUTH')
        status, data = c.select('INBOX', readonly=True)
        self.assertEqual(status, 'OK', data)
        if expected is not None:
            self.assertEqual(data, [str(expected).encode()])
        return c

    def body(self, c, uid, field='BODY.PEEK[]'):
        status, data = c.uid('FETCH', str(uid), '(UID RFC822.SIZE '+field+')')
        self.assertEqual(status, 'OK', data)
        literals = [x[1] for x in data if isinstance(x, tuple)]
        self.assertEqual(len(literals), 1, data)
        return literals[0]

    def wire(self, commands, config=None):
        conf = self.imap_config(config)
        p = subprocess.run([str(PREFIX/'libexec/dovecot/imap'), '-c', str(conf)],
                           env=ENV, input=commands, capture_output=True, timeout=30, preexec_fn=process_limits)
        self.assertEqual(p.returncode, 0, p.stderr.decode(errors='replace'))
        self.assertNotRegex(p.stderr, rb'Panic|Fatal|Segmentation')
        return p.stdout

    def test_01_empty_mailbox_and_reconnection_ids(self):
        state = self.fixture('state')
        for _ in range(2):
            c = self.client(expected=0)
            self.assertEqual(c.response('UIDVALIDITY')[1], [str(state['uidvalidity']).encode()])
            self.assertEqual(c.response('UIDNEXT')[1], [b'1'])
            self.assertEqual(c.uid('SEARCH', None, 'ALL'), ('OK', [b'']))
            c.logout()
        self.assertEqual(self.fixture('state'), state)

    def test_02_isolation_replay_and_exact_compliant_corpus(self):
        other = self.new_config(mailbox='other', shared=self.config)
        self.fixture('ensure', mailbox='other')
        self.receive(raw=b'PRIVATE OTHER MAILBOX\r\n', key='private', mailbox='other')
        corpus = [PLAIN, ENCODED, MULTIPART]
        for i, raw in enumerate(corpus, 1):
            first = self.receive(raw=raw, key=f'corpus-{i}', received_at='1700000000')
            self.assertEqual(first['received_at'], 1700000000)
            self.assertEqual(self.receive(raw=raw, key=f'corpus-{i}', received_at=1700000999), first)
            self.assertEqual(self.helper_body(i), raw)
        state = self.fixture('state')
        for _ in range(2):
            c = self.client(expected=3)
            self.assertEqual(c.uid('SEARCH', None, 'ALL'), ('OK', [b'1 2 3']))
            for i, raw in enumerate(corpus, 1):
                self.assertEqual(self.body(c, i), raw)
                self.assertEqual(self.body(c, i, 'BODY.PEEK[]<13.27>'), raw[13:40])
            self.assertEqual(c.uid('FETCH', '4', '(UID)'), ('OK', [None]))
            c.logout()
        self.assertEqual(self.fixture('state'), state)
        self.assertEqual(self.helper_body(1, other), b'PRIVATE OTHER MAILBOX\r\n')
        self.assertEqual(self.snapshot(other)[1], 2)

    def test_03_nonconforming_projection_does_not_rewrite_blobs(self):
        self.receive(BINARY, 'binary')
        self.receive(LF, 'lf')
        c = self.client(expected=2)
        self.assertEqual(self.body(c, 1), BINARY.replace(b'\x00', b'\x80'))
        self.assertEqual(self.body(c, 2), LF.replace(b'\n', b'\r\n'))
        c.logout()
        self.assertEqual(self.helper_body(1), BINARY)
        self.assertEqual(self.helper_body(2), LF)

    def test_04_pagination_and_new_arrival_refresh(self):
        self.fixture('bulk', count=260, raw_b64=base64.b64encode(PLAIN).decode(), key='page')
        self.assertEqual(len(self.snapshot()[2]), 260)
        c = self.client(expected=260)
        self.receive(ENCODED, 'new-arrival')
        self.assertEqual(c.noop()[0], 'OK')
        status, data = c.uid('SEARCH', None, 'ALL')
        self.assertEqual(status, 'OK')
        self.assertEqual(list(map(int, data[0].split())), list(range(1, 262)))
        self.assertEqual(self.body(c, 261), ENCODED)
        c.logout()
        c = self.client(expected=261)
        self.assertEqual(c.response('UIDNEXT')[1], [b'262'])
        c.logout()

    def test_05_snapshot_during_concurrent_receipts(self):
        self.fixture('bulk', count=260, raw_b64=base64.b64encode(PLAIN).decode(), key='seed')
        request = {'action': 'bulk', 'count': 30, 'key': 'concurrent', 'delay_ms': 10,
                   'raw_b64': base64.b64encode(ENCODED).decode()}
        writer = subprocess.Popen([PERL, str(HERE/'fixture.pl'), str(self.config)], env=ENV,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        writer.stdin.write(json.dumps(request).encode())
        writer.stdin.close()
        try:
            observed = []
            while writer.poll() is None:
                _, uidnext, rows = self.snapshot()
                self.assertEqual([uid for uid, _ in rows], list(range(1, uidnext)))
                observed.append(uidnext)
            writer.wait(timeout=15)
            self.assertEqual(writer.returncode, 0, writer.stderr.read())
            self.assertTrue(observed)
            self.assertEqual(self.snapshot()[1], 291)
        finally:
            if writer.poll() is None:
                writer.kill()
                writer.wait(timeout=5)
            writer.stdout.close()
            writer.stderr.close()

    def test_06_sparse_terminal_uid(self):
        self.receive(PLAIN, 'first')
        self.fixture('uidnext', value=4294967294)
        self.receive(ENCODED, 'terminal')
        self.assertEqual(self.snapshot()[1], 4294967295)
        c = self.client(expected=2)
        self.assertEqual(c.response('UIDNEXT')[1], [b'4294967295'])
        self.assertEqual(c.uid('SEARCH', None, 'ALL'), ('OK', [b'1 4294967294']))
        self.assertEqual(self.body(c, 4294967294), ENCODED)
        c.logout()
        self.assertEqual(self.helper_body(4294967294), ENCODED)

    def test_07_strict_write_rejection_and_unchanged_authority(self):
        self.receive()
        before = self.fixture('state')
        out = self.wire(b'a SELECT INBOX\r\n'
                        b'b UID STORE 1 +FLAGS (\\Seen \\Deleted)\r\n'
                        b'c EXPUNGE\r\nd UID EXPUNGE 1\r\n'
                        b'e APPEND INBOX {4+}\r\ntest\r\n'
                        b'f UID COPY 1 INBOX\r\ng UID MOVE 1 INBOX\r\n'
                        b'h UID REPLACE 1 INBOX {4+}\r\ntest\r\n'
                        b'i CREATE other\r\nj DELETE INBOX\r\nk RENAME INBOX other\r\n'
                        b'l SUBSCRIBE INBOX\r\nm UNSUBSCRIBE INBOX\r\n'
                        b'n UID FETCH 1 (FLAGS)\r\nz LOGOUT\r\n')
        for tag in b'bcdefghijklm':
            self.assertRegex(out, bytes([tag])+rb' (?:NO|BAD) ')
        self.assertIn(b'z OK ', out)
        self.assertEqual(self.fixture('state'), before)
        self.assertEqual(self.helper_body(1), PLAIN)
        flags = re.search(rb'\* 1 FETCH \(UID 1 FLAGS \(([^)]*)\)', out)
        self.assertIsNotNone(flags)
        self.assertNotIn(b'\\Seen', flags.group(1))
        self.assertNotIn(b'\\Deleted', flags.group(1))

    def test_08_corrupt_content_fails_without_substitute(self):
        self.receive()
        self.fixture('corrupt', uid=1)
        self.assertEqual(self.helper(b'FETCH 1\n').stdout, b'ERR\n')
        out = self.wire(b'a EXAMINE INBOX\r\nb UID FETCH 1 BODY.PEEK[]\r\nz LOGOUT\r\n')
        self.assertNotIn(PLAIN, out)
        self.assertNotIn(b'corrupt-synthetic-body', out)
        self.assertRegex(out, rb'b NO |\* BYE ')

    def test_09_missing_content_fails_without_substitute(self):
        self.receive()
        self.fixture('missing', uid=1)
        p = self.helper(b'FETCH 1\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        out = self.wire(b'a EXAMINE INBOX\r\nb UID FETCH 1 BODY.PEEK[]\r\nz LOGOUT\r\n')
        self.assertNotIn(PLAIN, out)
        self.assertRegex(out, rb'b NO |\* BYE ')

    def test_10_absent_schema_is_not_created(self):
        absent = self.new_config()
        before = json.loads(absent.read_text())
        p = self.helper(b'SNAPSHOT\n', absent)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        if ARGS.engine == 'sqlite':
            self.assertFalse(Path(before['path']).exists())
        else:
            self.assertEqual(self.fixture('schema_state', config=absent), {'tables': [], 'versions': []})

    def test_11_empty_or_old_schema_is_not_initialized_or_migrated(self):
        empty = self.new_config()
        if ARGS.engine == 'sqlite':
            dbpath = Path(json.loads(empty.read_text())['path'])
            sqlite3.connect(dbpath).close()
            before = dbpath.read_bytes()
        else:
            self.fixture('blossom_only', config=empty)
            before = self.fixture('schema_state', config=empty)
        p = self.helper(b'SNAPSHOT\n', empty)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        if ARGS.engine == 'sqlite':
            self.assertEqual(dbpath.read_bytes(), before)
        else:
            self.assertEqual(self.fixture('schema_state', config=empty), before)
        self.fixture('old_schema')
        oldpath = Path(json.loads(self.config.read_text()).get('path', str(self.config)))
        oldbytes = oldpath.read_bytes() if ARGS.engine == 'sqlite' else self.fixture('schema_state')
        p = self.helper(b'SNAPSHOT\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        self.assertEqual(oldpath.read_bytes() if ARGS.engine == 'sqlite' else self.fixture('schema_state'), oldbytes)

    def test_12_only_inbox_and_no_filesystem_authority(self):
        self.receive()
        out = self.wire(b'a LIST "" "*"\r\nb SELECT ../../other\r\nc EXAMINE inbox\r\nz LOGOUT\r\n')
        self.assertIn(b'"/" INBOX\r\n', out)
        self.assertRegex(out, rb'b NO ')
        self.assertIn(b'c OK [READ-ONLY]', out)
        for pattern in ['dovecot.index*', 'dovecot-uidlist', 'Maildir', 'mbox']:
            self.assertEqual(list(self.root.rglob(pattern)), [])
        for directory in self.root.glob('dovecot-*/home'):
            self.assertEqual(list(directory.rglob('*')), [])

    def test_13_close_and_reselect_preserves_memory_index_identity(self):
        self.receive()
        out = self.wire(b'a EXAMINE INBOX\r\nb UID SEARCH ALL\r\n'
                        b'c CLOSE\r\nd EXAMINE INBOX\r\ne UID SEARCH ALL\r\n'
                        b'f EXAMINE INBOX\r\ng UID SEARCH ALL\r\nz LOGOUT\r\n')
        self.assertEqual(out.count(b'* SEARCH 1\r\n'), 3)
        self.assertEqual(out.count(b'[UIDVALIDITY 1]'), 3)
        self.assertEqual(out.count(b'[UIDNEXT 2]'), 3)
        self.assertIn(b'z OK ', out)

    def test_14_absent_mailbox_is_not_provisioned(self):
        absent = self.new_config(mailbox='not-provisioned', shared=self.config)
        before = self.fixture('state')
        self.assertIsNone(self.fixture('state', mailbox='not-provisioned'))
        p = self.helper(b'SNAPSHOT\n', absent)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        self.assertIsNone(self.fixture('state', mailbox='not-provisioned'))
        self.assertEqual(self.fixture('state'), before)

    @unittest.skipUnless(ARGS.engine == 'sqlite', 'SQLite physical-file corruption case')
    def test_15_corrupt_sqlite_file_is_unchanged(self):
        broken = self.new_config()
        path = Path(json.loads(broken.read_text())['path'])
        path.write_bytes(b'Synthetic corrupt SQLite header\x00\xff' * 20)
        before = path.read_bytes()
        p = self.helper(b'SNAPSHOT\n', broken)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        self.assertEqual(path.read_bytes(), before)

    def test_16_mailbox_count_bound(self):
        self.fixture('bulk', count=4096, raw_b64=base64.b64encode(PLAIN).decode(), key='limit')
        validity, uidnext, entries = self.snapshot()
        self.assertEqual((uidnext, len(entries)), (4097, 4096))
        c = self.client(expected=4096)
        self.assertEqual(self.body(c, 4096), PLAIN)
        c.logout()
        self.receive(ENCODED, 'over-limit')
        p = self.helper(b'SNAPSHOT\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        self.assertEqual(self.fixture('state')['message_count'], 4097)
        out = self.wire(b'a EXAMINE INBOX\r\nz LOGOUT\r\n')
        self.assertIn(b'a NO ', out)

    def test_17_body_byte_bound(self):
        limit = 10 * 1024 * 1024
        header = HEADER + b'Subject: Byte limit\r\nContent-Type: text/plain\r\n\r\n'
        q, r = divmod(limit - len(header) - 2, 76)
        raw = header + (b'a' * 74 + b'\r\n') * q + b'a' * r + b'\r\n'
        self.assertEqual(len(raw), limit)
        self.receive(raw, 'at-limit')
        self.assertEqual(hashlib.sha256(self.helper_body(1)).digest(), hashlib.sha256(raw).digest())
        c = self.client(expected=1)
        self.assertEqual(self.body(c, 1), raw)
        c.logout()
        oversized = raw + b'x'
        self.receive(oversized, 'over-limit', max_bytes=limit + 1)
        p = self.helper(b'FETCH 2\n')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'ERR\n')
        out = self.wire(b'a EXAMINE INBOX\r\nb UID FETCH 2 BODY.PEEK[]\r\nz LOGOUT\r\n')
        self.assertNotIn(b'BODY[] {', out)
        self.assertRegex(out, rb'b NO |\* BYE ')


    def test_18_routed_delivery_replay_and_wrong_mailbox_isolation(self):
        other = self.new_config(mailbox='other', shared=self.config)
        self.fixture('ensure', mailbox='other')
        self.fixture('route', recipient='Alice@EXAMPLE.TEST')
        self.fixture('route', recipient='Bob@example.test', mailbox='other')
        first = self.receive_delivery(received_at='1700000000')
        self.assertEqual(first['status'], 'received')
        self.assertEqual(first['receipt']['received_at'], 1700000000)
        self.assertEqual(first['receipt']['content_sha256'], hashlib.sha256(PLAIN).hexdigest())
        private = HEADER + b'Subject: Other routed mailbox\r\n\r\nOnly Bob receives this.\r\n'
        self.assertEqual(self.receive_delivery(raw=private, recipient='Bob@example.test')['status'], 'received')
        before, other_before = self.fixture('state'), self.fixture('state', config=other)
        # Canonical domain spelling resolves the same route and replay identity.
        self.assertEqual(self.receive_delivery(recipient='Alice@Example.Test', received_at=1700000999), first)
        self.assertEqual(self.fixture('state'), before)
        self.assertEqual(self.fixture('state', config=other), other_before)
        alice, bob = self.client(expected=1), self.client(config=other, expected=1)
        self.assertNotEqual(alice.process.pid, bob.process.pid)
        self.assertEqual(self.body(alice, 1), PLAIN)
        self.assertEqual(self.body(bob, 1), private)
        self.assertEqual(alice.uid('SEARCH', None, 'ALL'), ('OK', [b'1']))
        self.assertEqual(bob.uid('SEARCH', None, 'ALL'), ('OK', [b'1']))
        self.assertEqual(alice.uid('FETCH', '2', '(UID)'), ('OK', [None]))
        self.assertEqual(bob.uid('FETCH', '2', '(UID)'), ('OK', [None]))
        alice.logout()
        bob.logout()
        self.assertEqual(self.helper_body(1), PLAIN)
        self.assertEqual(self.helper_body(1, other), private)
        self.assertEqual(self.fixture('state'), before)
        self.assertEqual(self.fixture('state', config=other), other_before)

    def test_19_unknown_recipient_takes_no_custody(self):
        self.fixture('route', recipient='Alice@example.test')
        before, counts = self.fixture('state'), self.fixture('custody_counts')
        never_stored = HEADER + b'Subject: Unknown recipient\r\n\r\nNo custody before a route exists.\r\n'
        # Local-part case is not folded, and visible To headers are not routes.
        for recipient in ['alice@example.test', 'reader@example.invalid', 'unregistered@example.test']:
            self.assertEqual(self.receive_delivery(raw=never_stored, recipient=recipient),
                             {'status': 'unknown_recipient'})
            self.assertEqual(self.fixture('custody_counts'), counts)
            self.assertEqual(self.fixture('state'), before)
        c = self.client(expected=0)
        self.assertEqual(c.uid('SEARCH', None, 'ALL'), ('OK', [b'']))
        c.logout()
        # Reusing the exact previously rejected identity after registration is
        # a first receipt, not a stale acknowledged or partially stored attempt.
        self.fixture('route', recipient='unregistered@example.test')
        accepted = self.receive_delivery(raw=never_stored, recipient='unregistered@example.test',
                                         received_at=1700001234)
        self.assertEqual(accepted['status'], 'received')
        self.assertEqual(accepted['receipt']['received_at'], 1700001234)
        c = self.client(expected=1)
        self.assertEqual(c.response('UIDNEXT')[1], [b'2'])
        self.assertEqual(self.body(c, 1), never_stored)
        c.logout()

    def test_20_independent_clients_refresh_reconnect_and_offline_arrival(self):
        self.fixture('route', recipient='Alice@example.test')
        initial = self.fixture('state')
        first, second = self.client(expected=0), self.client(expected=0)
        self.assertNotEqual(first.process.pid, second.process.pid)
        receipts = [self.receive_delivery(raw=PLAIN, key='online')]
        for client in [first, second]:
            self.assertEqual(client.noop()[0], 'OK')
            self.assertEqual(client.uid('SEARCH', None, 'ALL'), ('OK', [b'1']))
            self.assertEqual(self.body(client, 1), PLAIN)
        first.logout()
        receipts.append(self.receive_delivery(raw=ENCODED, key='one-client-online', received_at=1700000061))
        self.assertEqual(second.noop()[0], 'OK')
        self.assertEqual(second.uid('SEARCH', None, 'ALL'), ('OK', [b'1 2']))
        self.assertEqual(self.body(second, 2), ENCODED)
        second.logout()
        # No IMAP process is connected during this incoming delivery.
        self.assertTrue(all(c.process.poll() is not None for c in [first, second]))
        receipts.append(self.receive_delivery(raw=MULTIPART, key='all-clients-offline', received_at=1700003601))
        before = self.fixture('state')
        self.assertEqual(before['uidvalidity'], initial['uidvalidity'])
        self.assertEqual((before['uidnext'], before['message_count']), (4, 3))
        third, fourth = self.client(expected=3), self.client(expected=3)
        self.assertNotEqual(third.process.pid, fourth.process.pid)
        corpus = [PLAIN, ENCODED, MULTIPART]
        for client in [third, fourth]:
            self.assertEqual(client.response('UIDVALIDITY')[1], [str(initial['uidvalidity']).encode()])
            self.assertEqual(client.response('UIDNEXT')[1], [b'4'])
            self.assertEqual(client.uid('SEARCH', None, 'ALL'), ('OK', [b'1 2 3']))
            for uid, raw in enumerate(corpus, 1):
                self.assertEqual(self.body(client, uid), raw)
                self.assertEqual(self.body(client, uid, 'BODY.PEEK[]<13.27>'), raw[13:40])
                status, dates = client.uid('FETCH', str(uid), '(UID INTERNALDATE)')
                self.assertEqual(status, 'OK', dates)
                received = imaplib.Internaldate2tuple(dates[0])
                self.assertIsNotNone(received)
                self.assertEqual(int(time.mktime(received)), receipts[uid-1]['receipt']['received_at'])
        for raw, key, original in zip(corpus, ['online', 'one-client-online', 'all-clients-offline'], receipts):
            self.assertEqual(self.receive_delivery(raw=raw, key=key, received_at=1700009999), original)
        for client in [third, fourth]:
            self.assertEqual(client.noop()[0], 'OK')
            self.assertEqual(client.uid('SEARCH', None, 'ALL'), ('OK', [b'1 2 3']))
            self.assertEqual(client.uid('FETCH', '4', '(UID)'), ('OK', [None]))
            client.logout()
        self.assertEqual(self.fixture('state'), before)

    def test_21_delivery_namespaces_preserve_distinct_receipt_uids(self):
        self.fixture('route', recipient='Alice@example.test')
        self.fixture('route', recipient='alias@example.test')
        direct = self.receive(key='same-key')
        routed = self.receive_delivery(key='same-key')
        source = self.receive_delivery(key='same-key', source_id='second-local-mta')
        alias = self.receive_delivery(key='same-key', recipient='alias@example.test')
        ids = [direct['entry_id']] + [result['receipt']['entry_id'] for result in [routed, source, alias]]
        self.assertEqual(len(set(ids)), 4)
        self.assertEqual(self.receive(key='same-key'), direct)
        self.assertEqual(self.receive_delivery(key='same-key'), routed)
        self.assertEqual(self.receive_delivery(key='same-key', source_id='second-local-mta'), source)
        self.assertEqual(self.receive_delivery(key='same-key', recipient='alias@example.test'), alias)
        before = self.fixture('state')
        c = self.client(expected=4)
        self.assertEqual(c.response('UIDNEXT')[1], [b'5'])
        self.assertEqual(c.uid('SEARCH', None, 'ALL'), ('OK', [b'1 2 3 4']))
        for uid in range(1, 5):
            self.assertEqual(self.body(c, uid), PLAIN)
        c.logout()
        self.assertEqual(self.fixture('state'), before)


if __name__ == '__main__':
    print(f'Real {ARGS.engine} Store + Blossom + Dovecot {VERSION}; synthetic pipe-only test', flush=True)
    unittest.main(argv=[__file__]+UNIT_ARGS, verbosity=2)
