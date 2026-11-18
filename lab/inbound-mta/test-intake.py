#!/usr/bin/env python3
"""Local synthetic tests. Requires real Perl Store and pymilter; never skips them.

Run with the clean-ci Perl environment plus mail-perl5/postgres-perl5, and
PYTHONPATH pointing to the installed pymilter directory. No network is used.
"""
import concurrent.futures
import email.message
import gc
import importlib.util
import io
import json
import os
import select
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location('intake', HERE / 'intake.py')
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)
A, B = 'alice@synthetic.invalid', 'bob@synthetic.invalid'
MESSAGE = (b'From: sender@synthetic.invalid\r\nSubject:\tbytes\r\n'
           b'X-Fold: one\r\n\ttwo\r\nReceived: sender supplied\r\n'
           b'\r\n.dot\r\n\x00\xffbinary\r\n')


def queued(token, message=MESSAGE, queue_id='QUEUE-A'):
    return (b'Received: by synthetic.invalid id ' + queue_id.encode() + b'\r\n' +
            intake.TOKEN_HEADER.encode() + b': ' + token.encode() + b'\r\n' + message)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.path = self.base / 'ledger.sqlite'
        self.ledger = intake.Ledger.initialize(self.path)
        self.config = self.base / 'store.json'
        self.db = self.base / 'store.sqlite'
        self.config.write_text(json.dumps({'engine': 'sqlite', 'path': str(self.db)}))

    def issue(self, recipients=(A,), message=MESSAGE):
        return self.ledger.issue(message, recipients, 1700000000)

    def provision(self, addresses=(A, B)):
        code = '''use Overnet::Mail::Store;
my $s = Overnet::Mail::Store->new(path => shift @ARGV);
for my $r (@ARGV) {
  my ($box) = split /@/, $r;
  $s->ensure_mailbox(mailbox_id => $box);
  $s->register_recipient(recipient => $r, mailbox_id => $box);
}'''
        subprocess.run(['perl', '-I' + str(ROOT / 'lib'), '-e', code, str(self.db),
                        *addresses], check=True, capture_output=True, timeout=15)

    def rows(self):
        with sqlite3.connect(self.db) as db:
            return db.execute('SELECT mailbox_id, uid, idempotency_key, received_at '
                              'FROM mailbox_entries ORDER BY mailbox_id, uid').fetchall()

    def deliver(self, token, address=A, **kwargs):
        return intake.deliver(self.ledger, self.config, address, queued(token), **kwargs)


class LedgerTests(Fixture):
    def test_identical_messages_are_distinct_and_queue_ids_irrelevant(self):
        first, second = self.issue(), self.issue()
        self.assertNotEqual(first, second)
        self.assertEqual(intake.queue_boundary(queued(first, queue_id='Q1')),
                         intake.queue_boundary(queued(first, queue_id='Q2')))
        reopened = intake.Ledger(self.path)
        self.assertEqual(reopened.resolve(first, A, MESSAGE), self.ledger.resolve(first, A, MESSAGE))
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_collision_retry_and_exhaustion_never_overwrite(self):
        first = self.issue()
        with mock.patch.object(intake.secrets, 'token_hex', side_effect=[first, 'a' * 64]):
            self.assertEqual(self.issue(message=b'Subject: other\r\n\r\nbody'), 'a' * 64)
        with mock.patch.object(intake.secrets, 'token_hex', return_value=first) as random:
            with self.assertRaises(intake.Deferred):
                self.issue()
            self.assertEqual(random.call_count, 8)
        self.assertEqual(self.ledger.resolve(first, A, MESSAGE)[1], MESSAGE)

    def test_concurrent_issuance(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            tokens = list(pool.map(lambda _: intake.Ledger(self.path).issue(MESSAGE, [A], 1), range(24)))
        self.assertEqual(len(set(tokens)), 24)
        with self.ledger.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM intake').fetchone()[0], 24)

    def test_issuance_waits_for_write_lock(self):
        db = self.ledger.connect()
        self.addCleanup(db.close)
        db.execute('BEGIN IMMEDIATE')
        started = threading.Event()
        def issue():
            started.set()
            return self.issue()
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(issue)
            self.assertTrue(started.wait(1))
            time.sleep(.1)
            self.assertFalse(future.done())
            db.rollback()
            self.assertRegex(future.result(timeout=3), r'^[0-9a-f]{64}$')

    def test_killed_uncommitted_issue_rolls_back_on_reopen(self):
        # Exercise public issue() with an actual SQLite transaction. The child
        # connection pauses immediately before the real __exit__ commit so the
        # parent can kill only that child. No commit result is mocked.
        child_code = r"""
import importlib.util
import sqlite3
import sys
spec = importlib.util.spec_from_file_location('intake', sys.argv[1])
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)
real_connect = sqlite3.connect
class CommitBarrier(sqlite3.Connection):
    def __exit__(self, kind, value, traceback):
        if kind is None and self.in_transaction:
            token = self.execute('SELECT token FROM intake').fetchone()[0]
            print(token, flush=True)
            sys.stdin.buffer.read(1)
        return super().__exit__(kind, value, traceback)
def connect(*args, **kwargs):
    return real_connect(*args, factory=CommitBarrier, **kwargs)
intake.sqlite3.connect = connect
intake.Ledger(sys.argv[2]).issue(b'Subject: crash\r\n\r\nbody',
                                ['alice@synthetic.invalid'], 1)
"""
        child = subprocess.Popen([sys.executable, '-c', child_code,
                                  str(HERE / 'intake.py'), str(self.path)],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([child.stdout], [], [], 5)
            self.assertTrue(ready, 'child did not reach the pre-commit barrier')
            token = child.stdout.readline().decode('ascii').strip()
            self.assertRegex(token, r'^[0-9a-f]{64}$')
            self.assertIsNone(child.poll())
            self.assertTrue(Path(str(self.path) + '-journal').exists())
            child.kill()
            child.communicate(timeout=5)
            self.assertLess(child.returncode, 0)
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=5)
        reopened = intake.Ledger(self.path)
        with self.assertRaises(intake.Deferred):
            reopened.resolve(token, A, b'Subject: crash\r\n\r\nbody')
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM intake').fetchone()[0], 0)
            self.assertEqual(db.execute('PRAGMA integrity_check').fetchone()[0], 'ok')
        fresh = reopened.issue(MESSAGE, [A], 1)
        self.assertEqual(reopened.resolve(fresh, A, MESSAGE)[1], MESSAGE)

    def test_ledger_descriptors_close_without_cyclic_gc(self):
        # Linux test environment: absence of /proc is an explicit failure, not
        # a skipped resource-lifetime assertion.
        fd_dir = Path('/proc/self/fd')
        self.assertTrue(fd_dir.is_dir())
        gc.collect()
        was_enabled = gc.isenabled()
        gc.disable()
        try:
            before = len(list(fd_dir.iterdir()))
            for _ in range(100):
                token = self.issue()
                self.assertEqual(self.ledger.resolve(token, A, MESSAGE)[1], MESSAGE)
            after = len(list(fd_dir.iterdir()))
            self.assertLessEqual(after, before + 2)
        finally:
            if was_enabled:
                gc.enable()

    def test_invalid_issuance(self):
        for message, addresses, when in [(b'', [A], 1), (b'x' * 65537, [A], 1),
                (MESSAGE, [], 1), (MESSAGE, ['bad'], 1), (MESSAGE, [A], True),
                (MESSAGE, [A], -1), (MESSAGE, [A], 10000000000),
                (MESSAGE, [f'a{i}@synthetic.invalid' for i in range(33)], 1)]:
            with self.subTest(addresses=addresses, when=when, length=len(message)):
                with self.assertRaises(intake.Deferred):
                    self.ledger.issue(message, addresses, when)

    def test_invalid_bindings_never_call_store(self):
        token = self.issue()
        token_line = intake.TOKEN_HEADER.encode() + b': ' + token.encode() + b'\r\n'
        cases = [queued(token, MESSAGE + b'x'), queued(token)[:-1],
                 queued(token).replace(token_line, b''),
                 queued(token).replace(token_line, token_line * 2),
                 queued('0' * 64), queued(token[:-1]),
                 queued(token).replace(token_line, token_line.rstrip() + b'\r\n folded\r\n'),
                 queued(token).replace(b'Received: by', b'Subject: by', 1),
                 queued(token).replace(b'\r\n', b'\n'), b'x' * (intake.MAX_QUEUE_BYTES + 1)]
        for raw in cases:
            with self.subTest(raw=raw[:100]):
                runner = mock.Mock()
                with self.assertRaises(intake.Deferred):
                    intake.deliver(self.ledger, self.config, A, raw, runner=runner)
                runner.assert_not_called()
        runner = mock.Mock()
        with self.assertRaises(intake.Deferred):
            intake.deliver(self.ledger, self.config, B, queued(token), runner=runner)
        runner.assert_not_called()

    def test_malformed_cli_arguments_defer_without_echoing_input(self):
        for args in [[], ['deliver'], ['deliver', str(self.path), str(self.config), '--secret-recipient']]:
            result = subprocess.run([sys.executable, str(HERE / 'intake.py'), *args],
                                    input=b'', capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 75)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'Temporary intake failure\n')

    def test_missing_corrupt_and_wrong_version_ledgers_fail_closed_cli(self):
        token = self.issue()
        bad = self.base / 'bad.sqlite'
        bad.write_bytes(b'not a database')
        wrong = self.base / 'wrong.sqlite'
        intake.Ledger.initialize(wrong)
        with sqlite3.connect(wrong) as db:
            db.execute('PRAGMA user_version=99')
        missing = self.base / 'missing.sqlite'
        for path in (bad, wrong, missing):
            result = subprocess.run([sys.executable, str(HERE / 'intake.py'), 'deliver', str(path),
                                     str(self.config), A], input=queued(token), capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 75)
            self.assertEqual(result.stdout, b'')
            self.assertEqual(result.stderr, b'Temporary intake failure\n')
        self.assertFalse(missing.exists())
        self.assertFalse(self.db.exists(), 'invalid ledger must never invoke Store')


class StoreTests(Fixture):
    def setUp(self):
        super().setUp()
        self.provision()

    def test_valid_binding_unknown_store_route_defers_without_custody(self):
        unknown = 'unprovisioned@synthetic.invalid'
        token = self.issue((unknown,))
        self.assertEqual(self.ledger.resolve(token, unknown, MESSAGE)[1], MESSAGE)
        result = subprocess.run([sys.executable, str(HERE / 'intake.py'), 'deliver',
                                 str(self.path), str(self.config), unknown],
                                input=queued(token), capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 75)
        self.assertEqual(result.stdout, b'')
        self.assertEqual(result.stderr, b'Temporary intake failure\n')
        self.assertEqual(self.rows(), [])
        with sqlite3.connect(self.db) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM blossom_blob_data').fetchone()[0], 0)
            self.assertIsNone(db.execute('SELECT mailbox_id FROM recipient_routes WHERE recipient=?',
                                         (unknown,)).fetchone())

    def test_real_store_exact_bytes_and_reopen_retry(self):
        token = self.issue()
        self.deliver(token)
        before = self.rows()
        self.ledger = intake.Ledger(self.path)
        intake.deliver(self.ledger, self.config, A, queued(token, queue_id='REQUEUED'))
        self.assertEqual(self.rows(), before)
        self.assertEqual(len(before), 1)
        with sqlite3.connect(self.db) as db:
            self.assertEqual(db.execute('SELECT body FROM blossom_blob_data').fetchall(), [(MESSAGE,)])
        self.deliver(self.issue())
        self.assertEqual(len(self.rows()), 2)

    def test_multi_recipient_partial_failure(self):
        token = self.issue((A, B))
        self.deliver(token, A)
        with sqlite3.connect(self.db) as db:
            db.execute("CREATE TRIGGER fail_b BEFORE INSERT ON mailbox_entries WHEN NEW.mailbox_id = '" +
                       B.split("@")[0] + "' BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        with self.assertRaises(intake.Deferred):
            self.deliver(token, B)
        self.assertEqual(len(self.rows()), 1)
        with sqlite3.connect(self.db) as db:
            db.execute('DROP TRIGGER fail_b')
        self.deliver(token, B)
        self.deliver(token, A)
        self.assertEqual([row[0] for row in self.rows()], ['alice', 'bob'])

    def test_committed_store_lost_acknowledgement_retry(self):
        token = self.issue()
        def lost_ack(*args, **kwargs):
            result = subprocess.run(*args, **kwargs)
            self.assertEqual(result.returncode, 0)
            return subprocess.CompletedProcess(result.args, 0, b'')
        with self.assertRaises(intake.Deferred):
            self.deliver(token, runner=lost_ack)
        self.assertEqual(len(self.rows()), 1)
        self.deliver(token)
        self.assertEqual(len(self.rows()), 1)

    def test_concurrent_duplicate_delivery_is_one_receipt(self):
        token = self.issue()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: self.deliver(token), range(8)))
        self.assertEqual(len(self.rows()), 1)

    def test_store_ack_must_be_exact_and_normal_exit(self):
        token = self.issue()
        for status, ack in [(75, b'received\n'), (0, b'received\nextra'), (0, b'received'), (0, b'')]:
            with self.subTest(status=status, ack=ack):
                with self.assertRaises(intake.Deferred):
                    self.deliver(token, runner=mock.Mock(return_value=subprocess.CompletedProcess([], status, ack)))
        with self.assertRaises(subprocess.TimeoutExpired):
            self.deliver(token, runner=mock.Mock(side_effect=subprocess.TimeoutExpired('perl', .01)))
        self.assertEqual(self.rows(), [])


class BoundsTests(unittest.TestCase):
    def test_read_exact_limit_and_over_limit(self):
        for payload, valid in [(b'abcd', True), (b'abcde', False)]:
            with tempfile.TemporaryFile() as stream:
                stream.write(payload)
                stream.seek(0)
                if valid:
                    self.assertEqual(intake.read_bounded(stream.fileno(), 4, 1), payload)
                else:
                    with self.assertRaises(intake.Deferred):
                        intake.read_bounded(stream.fileno(), 4, 1)

    def test_read_timeout_with_open_writer(self):
        read, write = os.pipe()
        try:
            start = time.monotonic()
            with self.assertRaises(intake.Deferred):
                intake.read_bounded(read, 10, .05)
            self.assertLess(time.monotonic() - start, 1)
        finally:
            os.close(read)
            os.close(write)


class MilterTests(Fixture):
    def context(self):
        import Milter
        from Milter.testctx import TestCtx
        with mock.patch.object(Milter, 'runmilter'):
            intake.serve(self.path, [A], 'local:' + str(self.base / 'unused.sock'))
        # Upstream TestCtx aliases and mutates its class-level options list.
        # Supply fresh options, and spy on mutations because its chgheader
        # simplification removes all matching names rather than one index.
        with mock.patch.object(TestCtx, 'default_opts', [Milter.CURR_ACTS, 0x1fffff, 0, 0]):
            ctx = TestCtx()
            self.assertEqual(ctx._connect(ip='127.0.0.1'), Milter.CONTINUE)
        ctx.chgheader = mock.Mock(wraps=ctx.chgheader)
        ctx.addheader = mock.Mock(wraps=ctx.addheader)
        ctx._msg = email.message.Message()
        self.assertEqual(ctx._envfrom('<sender@synthetic.invalid>'), Milter.CONTINUE)
        self.assertEqual(ctx._envrcpt('<' + A + '>'), Milter.CONTINUE)
        return ctx

    def count(self):
        with self.ledger.connect() as db:
            return db.execute('SELECT COUNT(*) FROM intake').fetchone()[0]

    def test_negotiation_requires_actions_and_leading_space(self):
        import Milter
        ctx = self.context()
        for actions, protocol in [(Milter.ADDHDRS, Milter.P_HDR_LEADSPC),
                                  (Milter.CHGHDRS, Milter.P_HDR_LEADSPC),
                                  (Milter.ADDHDRS | Milter.CHGHDRS, 0)]:
            self.assertEqual(ctx._priv.negotiate([actions, protocol, 0, 0]), Milter.REJECT)
            self.assertEqual(ctx._envfrom('<sender@synthetic.invalid>'), Milter.TEMPFAIL)
        self.assertEqual(self.count(), 0)

    def test_new_mail_resets_state_and_missing_eoh_never_commits(self):
        import Milter
        ctx = self.context()
        self.assertEqual(ctx._header('Subject', ' prior'), Milter.CONTINUE)
        self.assertEqual(ctx._eoh(), Milter.CONTINUE)
        self.assertEqual(ctx._envfrom('<new@synthetic.invalid>'), Milter.CONTINUE)
        self.assertEqual(ctx._priv.parts, [])
        self.assertEqual(ctx._priv.addresses, set())
        self.assertEqual(ctx._envrcpt('<' + A + '>'), Milter.CONTINUE)
        self.assertEqual(ctx._header('Subject', ' incomplete'), Milter.CONTINUE)
        self.assertEqual(ctx._eom(), Milter.TEMPFAIL)
        self.assertEqual(self.count(), 0)

    def test_oversize_body_and_stripped_tokens_never_commit(self):
        import Milter
        for kind in ('body', 'token'):
            ctx = self.context()
            if kind == 'body':
                self.assertEqual(ctx._eoh(), Milter.CONTINUE)
                result = ctx._feed_body(io.BytesIO(b'x' * (intake.MAX_BYTES + 1)))
            else:
                result = ctx._header(intake.TOKEN_HEADER, 'x' * (intake.MAX_BYTES + 1))
            self.assertEqual(result, Milter.TEMPFAIL)
            self.assertEqual(ctx._eom(), Milter.TEMPFAIL)
        self.assertEqual(self.count(), 0)

    def test_header_mutation_failure_defers_and_leaves_only_orphan(self):
        import Milter
        for method in ('chgheader', 'addheader'):
            ctx = self.context()
            ctx._msg[intake.TOKEN_HEADER] = 'spoof'
            ctx._header(intake.TOKEN_HEADER, ' spoof')
            ctx._header('Subject', ' test')
            ctx._eoh()
            before = self.count()
            with mock.patch.object(ctx, method, side_effect=OSError('synthetic acknowledgement loss')):
                self.assertEqual(ctx._eom(), Milter.TEMPFAIL)
            self.assertEqual(self.count(), before + 1)
            self.assertFalse(self.db.exists())

    def test_real_pymilter_callbacks_strip_spoofed_tokens_and_preserve_bytes(self):
        import Milter
        ctx = self.context()
        self.assertEqual(ctx._envrcpt('<' + B + '>'), Milter.REJECT)
        ctx._msg = email.message.Message()
        for name, value in [('Subject', ' test'), (intake.TOKEN_HEADER, ' spoof'),
                            (intake.TOKEN_HEADER.lower(), ' ' + '0' * 64), ('X-Fold', '\tone\n two')]:
            ctx._msg[name] = value
            self.assertEqual(ctx._header(name, value), Milter.CONTINUE)
        self.assertEqual(ctx._eoh(), Milter.CONTINUE)
        self.assertEqual(ctx._feed_body(io.BytesIO(b'body\r\n.\x00\xff')), Milter.CONTINUE)
        self.assertEqual(ctx._eom(), Milter.CONTINUE)
        ctx.chgheader.assert_has_calls([mock.call(intake.TOKEN_HEADER, 2, ''),
                                        mock.call(intake.TOKEN_HEADER, 1, '')])
        self.assertEqual(ctx.chgheader.call_count, 2)
        self.assertEqual(ctx.addheader.call_count, 1)
        tokens = ctx._msg.get_all(intake.TOKEN_HEADER)
        self.assertEqual(len(tokens), 1)
        self.assertRegex(tokens[0], r'^ [0-9a-f]{64}$')
        expected = b'Subject: test\r\nX-Fold:\tone\r\n two\r\n\r\nbody\r\n.\x00\xff'
        self.assertEqual(self.ledger.resolve(tokens[0].strip(), A, expected)[1], expected)
        with self.assertRaises(intake.Deferred):
            self.ledger.resolve(tokens[0].strip(), B, expected)


if __name__ == '__main__':
    unittest.main(verbosity=2)
