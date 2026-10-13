#!/usr/bin/env python3
"""Malformed helper frames through the real Dovecot plugin (no real mail)."""
import argparse
import base64
import imaplib
import json
import os
from pathlib import Path
import pwd
import resource
import signal
import subprocess
import sys
import tempfile
import unittest

PARSER = argparse.ArgumentParser()
PARSER.add_argument('--prefix', type=Path, required=True)
PARSER.add_argument('--plugin-dir', type=Path, required=True)
ARGS, UNIT_ARGS = PARSER.parse_known_args()
HERE = Path(__file__).resolve().parent
PREFIX = ARGS.prefix.resolve()
PLUGINS = ARGS.plugin_dir.resolve()


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (512 * 1024 * 1024, 512 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (20, 20))


class PipeClient(imaplib.IMAP4_stream):
    def open(self, host=None, port=None, timeout=None):
        self.host = self.port = self.sock = self.file = None
        self.process = subprocess.Popen(self.command, shell=False, close_fds=True,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, preexec_fn=limits,
                                        env={'PATH': '/usr/bin:/bin', 'USER': 'overnet-synthetic-fixture'})
        self.writefile = self.process.stdin
        self.readfile = self.process.stdout


class Frames(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='overnet-frame-')
        self.root = Path(self.tmp.name)
        for name in ['run', 'state', 'home']:
            (self.root / name).mkdir()
        self.data = self.root / 'response.json'
        self.helper = self.root / 'synthetic-helper.py'
        self.helper.write_text('#!' + sys.executable + '\n'
                               'import sys,json,base64\n'
                               'c=json.load(open(sys.argv[1]))\n'
                               'r=sys.stdin.buffer.read()\n'
                               'key="snapshot" if r == b"SNAPSHOT\\n" else "fetch"\n'
                               'sys.stdout.buffer.write(base64.b64decode(c[key]))\n'
                               'sys.stdout.buffer.flush()\n'
                               'sys.exit(c.get("exit", 0))\n')
        self.helper.chmod(0o700)
        config = (HERE / 'dovecot.conf.in').read_text()
        for key, value in {'TEST_ROOT': self.root, 'PLUGIN_DIR': PLUGINS,
                           'HELPER': self.helper, 'STORE_CONFIG': self.data, 'PERL5LIB': ''}.items():
            config = config.replace('@' + key + '@', str(value))
        user = pwd.getpwuid(os.geteuid()).pw_name
        config += f'\ndefault_internal_user = {user}\ndefault_login_user = {user}\n'
        self.config = self.root / 'dovecot.conf'
        self.config.write_text(config)
        self.command = [str(PREFIX / 'libexec/dovecot/imap'), '-c', str(self.config)]
        self.clients = []
        signal.signal(signal.SIGALRM, self.timeout)
        signal.alarm(60)

    def timeout(self, *_):
        raise TimeoutError('frame test deadline')

    def tearDown(self):
        signal.alarm(0)
        for c in self.clients:
            if c.process.poll() is None:
                c.process.kill()
            c.process.wait(timeout=3)
            c.readfile.close()
            c.writefile.close()
        self.tmp.cleanup()

    def responses(self, snapshot=b'OK 1 2 1\n1 1700000000\n', fetch=b'DATA 24\nSubject: frame\r\n\r\nbody\r\n', code=0):
        self.data.write_text(json.dumps({'snapshot': base64.b64encode(snapshot).decode(),
                                        'fetch': base64.b64encode(fetch).decode(), 'exit': code}))

    def wire(self, command, logout=True):
        p = subprocess.run(self.command, input=command + b'z LOGOUT\r\n', capture_output=True,
                           timeout=15, preexec_fn=limits,
                           env={'PATH': '/usr/bin:/bin', 'USER': 'overnet-synthetic-fixture'})
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertNotRegex(p.stderr, rb'Panic|Fatal|segmentation')
        if logout:
            self.assertIn(b'z OK ', p.stdout)
        return p.stdout

    def test_01_malformed_snapshots_fail_closed(self):
        bad = [b'', b'ERR\n', b'OK 0 1 0\n', b'OK 1 0 0\n', b'OK 1 1 4097\n',
               b'OK 4294967296 1 0\n', b'OK 1 4294967296 0\n',
               b'OK 18446744073709551616 1 0\n', b'OK +1 1 0\n', b'OK 01 1 0\n',
               b'OK 1 1 0\nJUNK', b'OK 1 1 0\x00\n', b'OK 1 2 1\n',
               b'OK 1 2 1\n0 0\n', b'OK 1 2 1\n2 0\n', b'OK 1 3 2\n1 0\n1 0\n',
               b'OK 1 4 2\n2 0\n1 0\n', b'OK 1 2 1\n1 -1\n',
               b'OK 1 2 1\n1 10000000000\n', b'OK 1 2 1\n1 0\n2 0\n',
               b'OK 1 4294967295 1\n4294967295 0\n', b'x' * 100000]
        for frame in bad:
            with self.subTest(frame=frame[:80]):
                self.responses(snapshot=frame)
                out = self.wire(b'a EXAMINE INBOX\r\n')
                self.assertIn(b'a NO ', out)
                self.assertNotIn(b'a OK ', out)

    def test_02_malformed_bodies_never_become_substitute_content(self):
        bad = [b'', b'ERR\n', b'DATA 0\n', b'DATA 1\n', b'DATA 1\nab',
               b'DATA +1\na', b'DATA 01\na', b'DATA 10485761\n',
               b'DATA 18446744073709551616\n', b'DATA 1\x00\na', b'DATA 1\ra']
        for frame in bad:
            with self.subTest(frame=frame):
                self.responses(fetch=frame)
                out = self.wire(b'a EXAMINE INBOX\r\nb UID FETCH 1 (BODY.PEEK[])\r\n', logout=False)
                self.assertIn(b'a OK ', out)
                self.assertIn(b'* BYE FETCH failed: ', out)
                self.assertNotIn(b'BODY[] {', out)

    def test_03_plausible_response_from_failed_child_is_rejected(self):
        self.responses(code=1)
        self.assertIn(b'a NO ', self.wire(b'a EXAMINE INBOX\r\n'))

    def test_04_valid_terminal_identifiers_are_accepted(self):
        self.responses(snapshot=b'OK 4294967295 4294967295 1\n4294967294 9999999999\n')
        out = self.wire(b'a EXAMINE INBOX\r\nb UID SEARCH ALL\r\n')
        self.assertIn(b'UIDVALIDITY 4294967295', out)
        self.assertIn(b'UIDNEXT 4294967295', out)
        self.assertIn(b'* SEARCH 4294967294', out)

    def test_05_selected_prefix_rewrite_and_rollback_are_rejected(self):
        changed = [b'OK 2 2 1\n1 1700000000\n', b'OK 1 1 0\n',
                   b'OK 1 2 1\n1 1700000001\n', b'OK 1 3 1\n2 1700000000\n']
        for frame in changed:
            with self.subTest(frame=frame):
                self.responses()
                c = PipeClient(self.command)
                self.clients.append(c)
                self.assertEqual(c.select('INBOX', readonly=True), ('OK', [b'1']))
                self.responses(snapshot=frame)
                result, _ = c.noop()
                self.assertEqual(result, 'OK')
                self.assertIn(b'Overnet local reader returned invalid data', b' '.join(c.untagged_responses.pop('NO', [])))
                self.responses()
                c.logout()

    def test_06_unknown_uid_does_not_fetch_unselected_data(self):
        self.responses(fetch=b'DATA 6\nsecret')
        out = self.wire(b'a EXAMINE INBOX\r\nb UID FETCH 2 (BODY.PEEK[])\r\n')
        self.assertIn(b'b OK ', out)
        self.assertNotIn(b'secret', out)
        self.assertNotIn(b'BODY[] {', out)


if __name__ == '__main__':
    unittest.main(argv=[__file__] + UNIT_ARGS, verbosity=2)
