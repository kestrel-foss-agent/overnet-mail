#!/usr/bin/env python3
"""Local SQLite tests of the lab fault seam; no Postfix or Milter wire claim."""
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import intake

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader('pipe_delivery', str(HERE / 'pipe-delivery'))
spec = importlib.util.spec_from_loader(loader.name, loader)
pipe = importlib.util.module_from_spec(spec)
loader.exec_module(pipe)
spec = importlib.util.spec_from_file_location('postfix_lab', HERE / 'test-postfix.py')
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)
A, B = lab.A, lab.B


class PipeWrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        (self.base / 'faults').mkdir()
        self.config = self.base / 'store.json'
        self.config.write_text(json.dumps({'engine': 'sqlite', 'path': str(self.base / 'store.sqlite')}))
        subprocess.run(['perl', str(HERE / 'store-fixture.pl'), str(self.config),
                        'provision', A, 'alice'], check=True, capture_output=True, timeout=15)
        self.ledger = intake.Ledger.initialize(self.base / 'ledger.sqlite')
        self.token = self.ledger.issue(lab.CONTENT, [A, B], 1700000000)
        self.raw = (b'Received: by fixture.invalid id SYNTHETIC\r\n' +
                    intake.TOKEN_HEADER.encode() + b': ' + self.token.encode() + b'\r\n' + lab.CONTENT)

    def rows(self):
        with sqlite3.connect(self.base / 'store.sqlite') as db:
            return db.execute('SELECT mailbox_id, uid, idempotency_key, received_at '
                              'FROM mailbox_entries ORDER BY mailbox_id, uid').fetchall()

    def event(self):
        return json.loads((self.base / 'events.jsonl').read_text().splitlines()[-1])

    def test_postfix_sanitized_path_uses_fixed_image_runtime(self):
        with mock.patch.dict(pipe.os.environ, {'PATH': '/usr/bin:/bin'}):
            self.assertEqual(pipe.attempt(self.base, A, self.raw), 0)
            self.assertEqual(pipe.os.environ['PATH'], '/usr/local/bin:/usr/bin:/bin')
        self.assertEqual(len(self.rows()), 1)

    def test_normal_and_replay_acknowledgements(self):
        self.assertEqual(pipe.attempt(self.base, A, self.raw), 0)
        before = self.rows()
        self.assertEqual(pipe.attempt(self.base, A, self.raw), 0)
        self.assertEqual(self.rows(), before)
        self.assertEqual(before, [('alice', 1, self.token, 1700000000)])
        self.assertEqual(self.event()['outcome'], 'acknowledged')
        self.assertEqual(self.event()['message_sha256'], hashlib.sha256(lab.CONTENT).hexdigest())

    def test_lost_pipe_ack_retries_real_store_without_duplicate(self):
        fault = self.base / 'faults' / 'after-alice'
        fault.touch()
        for _ in range(2):
            self.assertEqual(pipe.attempt(self.base, A, self.raw), 75)
            self.assertEqual(self.event()['outcome'], 'committed_ack_lost')
        self.assertEqual(len(self.rows()), 1)
        fault.unlink()
        self.assertEqual(pipe.attempt(self.base, A, self.raw), 0)
        self.assertEqual(len(self.rows()), 1)

    def test_before_and_altered_bytes_cannot_acknowledge(self):
        for mode, outcome in [('before', 'blocked_before_store'), ('alter', 'deferred')]:
            fault = self.base / 'faults' / (mode + '-alice')
            fault.touch()
            self.assertEqual(pipe.attempt(self.base, A, self.raw), 75)
            self.assertEqual(self.event()['outcome'], outcome)
            self.assertEqual(self.rows(), [])
            fault.unlink()

    def test_unknown_route_and_missing_binding_cannot_acknowledge(self):
        self.assertEqual(pipe.attempt(self.base, B, self.raw), 75)
        self.assertEqual(self.event()['outcome'], 'deferred')
        (self.base / 'ledger.sqlite').rename(self.base / 'saved.sqlite')
        self.assertEqual(pipe.attempt(self.base, A, self.raw), 75)
        self.assertEqual(self.rows(), [])
        self.assertFalse((self.base / 'ledger.sqlite').exists())

    def test_invalid_input_and_unlisted_wrapper_recipient_fail_closed(self):
        self.assertEqual(pipe.attempt(self.base, A, b'invalid'), 75)
        self.assertEqual(self.event()['outcome'], 'deferred')
        self.assertEqual(pipe.attempt(self.base, 'no@external.invalid', self.raw), 75)
        self.assertEqual(self.rows(), [])

    def test_pickup_extra_received_cannot_recover_old_binding(self):
        self.assertEqual(pipe.attempt(self.base, A, self.raw), 0)
        before = self.rows()
        requeued = b'Received: by pickup.reference.invalid id REQUEUED\r\n' + self.raw
        self.assertEqual(pipe.attempt(self.base, A, requeued), 75)
        self.assertEqual(self.event()['outcome'], 'deferred')
        self.assertEqual(self.event()['token'], self.token)
        self.assertEqual(self.rows(), before)

    def test_main_without_lab_authorization_fails_closed(self):
        with mock.patch.dict(pipe.os.environ, {}, clear=True):
            self.assertEqual(pipe.main(), 75)


class QueueObservationTests(unittest.TestCase):
    def row(self, identifier='ABC1', size=42):
        return {'queue_id': identifier, 'sender': '', 'arrival_time': 1,
                'message_size': size, 'recipients': [{'address': A}]}

    def observe(self, rows):
        output = b'\n'.join(json.dumps(row).encode() for row in rows)
        with mock.patch.object(lab, 'control', return_value=output):
            return lab.queue_rows()

    def test_duplicate_scan_is_one_identity(self):
        self.assertEqual(len(self.observe([self.row(), self.row()])), 1)

    def test_conflicting_duplicate_fails(self):
        with self.assertRaises(AssertionError):
            self.observe([self.row(), self.row(size=43)])

    def test_different_ids_never_deduplicate(self):
        self.assertEqual(len(self.observe([self.row(), self.row('ABC2')])), 2)

    def test_incomplete_scan_cannot_finish_before_store_receipt(self):
        with mock.patch.object(lab, 'snapshot', return_value={'mailboxes': {}}), \
                mock.patch.object(lab, 'queue_rows', return_value={}):
            self.assertFalse(lab.drained({'alice': 1}))


if __name__ == '__main__':
    unittest.main(verbosity=2)
