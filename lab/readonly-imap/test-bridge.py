#!/usr/bin/env python3
"""Adversarial real fork/exec/pipe tests; no IMAP replacement or network."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent


class BridgeIO(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='overnet-bridge-build-')
        cls.probe = Path(cls.build.name) / 'probe'
        subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        str(HERE / 'bridge-io.c'), str(HERE / 'bridge-probe.c'), '-o', str(cls.probe)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='overnet-bridge-case-')
        self.root = Path(self.tmp.name)
        self.helper = self.root / 'helper ; literal path.py'
        self.config = self.root / 'config ; literal path'
        self.config.write_text('synthetic')

    def tearDown(self):
        self.tmp.cleanup()

    def run_helper(self, body, limit=4096):
        self.helper.write_text('#!' + sys.executable + '\nimport os, sys, time\n' + body)
        self.helper.chmod(0o700)
        started = time.monotonic()
        p = subprocess.run([str(self.probe), str(self.helper), str(self.config), str(limit)],
                           capture_output=True, timeout=14)
        self.assertLess(time.monotonic() - started, 12)
        self.assertEqual(p.stderr, b'')
        return p

    def test_01_literal_argv_clean_environment_and_exact_response(self):
        p = self.run_helper("assert sys.argv[1] == " + repr(str(self.config)) + "\n"
                            "assert sys.stdin.buffer.read() == b'SNAPSHOT\\n'\n"
                            "assert not any(x.startswith('OVERNET_') for x in os.environ)\n"
                            "assert 'PYTHONPATH' not in os.environ and 'PERL5OPT' not in os.environ\n"
                            "os.write(1, b'OK 1 1 0\\n')\n")
        self.assertEqual((p.returncode, p.stdout), (0, b'OK 1 1 0\n'))

    def test_02_fragmented_output_is_reassembled(self):
        p = self.run_helper("sys.stdin.buffer.read()\nfor x in b'OK 1 2 1\\n1 1700000000\\n':\n os.write(1, bytes([x])); time.sleep(.001)\n")
        self.assertEqual((p.returncode, p.stdout), (0, b'OK 1 2 1\n1 1700000000\n'))

    def test_03_nonzero_exit_discards_plausible_data(self):
        p = self.run_helper("sys.stdin.buffer.read(); os.write(1, b'OK 1 1 0\\n'); sys.exit(4)\n")
        self.assertEqual((p.returncode, p.stdout), (1, b''))

    def test_04_signal_death_discards_partial_data(self):
        p = self.run_helper("sys.stdin.buffer.read(); os.write(1, b'OK 1'); os.kill(os.getpid(), 9)\n")
        self.assertEqual((p.returncode, p.stdout), (1, b''))

    def test_05_excess_output_and_exact_limit(self):
        for count, expected in [(4096, 0), (4097, 1), (10485761, 1)]:
            with self.subTest(count=count):
                p = self.run_helper("sys.stdin.buffer.read(); os.write(1, b'x' * " + str(count) + ")\n")
                self.assertEqual(p.returncode, expected)
                self.assertEqual(p.stdout, b'x' * count if not expected else b'')

    def test_06_early_exit_does_not_deliver_sigpipe_to_parent(self):
        for _ in range(20):
            p = self.run_helper('sys.exit(7)\n')
            self.assertEqual(p.returncode, 1)

    def test_07_exec_failure_is_checked(self):
        p = subprocess.run([str(self.probe), str(self.helper), str(self.config), '4096'], capture_output=True, timeout=3)
        self.assertEqual((p.returncode, p.stdout, p.stderr), (1, b'', b''))

    def test_08_hung_helper_is_killed_and_reaped(self):
        pidfile = self.root / 'pid'
        p = self.run_helper("open(" + repr(str(pidfile)) + ", 'w').write(str(os.getpid()))\ntime.sleep(30)\n")
        self.assertEqual((p.returncode, p.stdout), (1, b''))
        with self.assertRaises(ProcessLookupError):
            os.kill(int(pidfile.read_text()), 0)

    def test_09_descendant_holding_pipe_is_killed_on_timeout(self):
        pidfile = self.root / 'pid'
        p = self.run_helper("sys.stdin.buffer.read()\npid = os.fork()\nif pid == 0:\n open(" +
                            repr(str(pidfile)) + ", 'w').write(str(os.getpid()))\n time.sleep(30)\nelse:\n os.write(1, b'OK 1 1 0\\n')\n")
        self.assertEqual((p.returncode, p.stdout), (1, b''))
        pid = int(pidfile.read_text())
        status = Path(f'/proc/{pid}/status')
        deadline = time.monotonic() + 1
        while status.exists() and 'State:\tZ' not in status.read_text() and time.monotonic() < deadline:
            time.sleep(.01)
        if status.exists():
            # Orphan reaping belongs to the executor's PID 1. A zombie cannot
            # execute or retain a pipe; the helper group must have no live child.
            self.assertIn('State:\tZ', status.read_text())

    def test_10_inherited_descriptors_are_closed(self):
        fd = os.open(self.config, os.O_RDONLY)
        os.set_inheritable(fd, True)
        try:
            self.helper.write_text('#!' + sys.executable + '\nimport os, sys\n'
                                   'sys.stdin.buffer.read()\n'
                                   'try: os.fstat(' + str(fd) + ')\n'
                                   'except OSError: os.write(1, b"closed")\n'
                                   'else: sys.exit(6)\n')
            self.helper.chmod(0o700)
            p = subprocess.run([str(self.probe), str(self.helper), str(self.config), '4096'],
                               pass_fds=(fd,), capture_output=True, timeout=3)
            self.assertEqual((p.returncode, p.stdout), (0, b'closed'))
        finally:
            os.close(fd)

    def test_11_memory_allocation_is_bounded(self):
        p = self.run_helper('sys.stdin.buffer.read(); data = bytearray(512 * 1024 * 1024)\n')
        self.assertEqual((p.returncode, p.stdout), (1, b''))

    def test_12_invalid_response_limits_fail_closed(self):
        for limit in [0, 10485760 + 65, 2**63]:
            p = self.run_helper('os.write(1, b"unexpected")\n', limit)
            self.assertEqual((p.returncode, p.stdout), (1, b''))


if __name__ == '__main__':
    unittest.main(verbosity=2)
