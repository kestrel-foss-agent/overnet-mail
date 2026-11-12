#!/usr/bin/env python3
"""Synthetic SQLite intake delivery and standalone Dovecot IMAP readback.

Uses the existing read-only lab harness and the actual intake delivery command.
No network listener or mail daemon is started. Tokens are issued directly by the
ledger: this does not exercise Postfix, its queue, or Milter wire callbacks.
Run with the repository's Perl dependencies available in PATH and PERL5LIB.
"""
import argparse
import importlib.util
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True,
                        help='installed official Dovecot 2.4.5 prefix')
    parser.add_argument('--plugin-dir', type=Path, required=True,
                        help='directory containing the built read-only plugin')
    args = parser.parse_args()
    # The existing harness parses its arguments at import time. Supply only
    # its documented SQLite options and restore this program's arguments.
    original_argv = sys.argv
    try:
        sys.argv = [str(HERE / 'test-readback.py'),
                    '--prefix', str(args.prefix.resolve()),
                    '--plugin-dir', str(args.plugin_dir.resolve()),
                    '--engine', 'sqlite']
        harness = load_module('readonly_intake_readback',
                              HERE.parent / 'readonly-imap' / 'test-readonly.py')
    finally:
        sys.argv = original_argv
    intake = load_module('intake_readback', HERE / 'intake.py')
    case = harness.ReadOnlyIntegration()
    case.setUp()
    try:
        alice, bob = 'alice@example.test', 'bob@example.test'
        case.fixture('route', recipient=alice)
        bob_config = case.new_config(mailbox='bob', shared=case.config)
        case.fixture('ensure', config=bob_config)
        case.fixture('route', config=bob_config, recipient=bob)
        ledger = intake.Ledger.initialize(case.root / 'intake.sqlite')
        raw = harness.MULTIPART
        token = ledger.issue(raw, [alice, bob], 1700000000)
        queued = (b'Received: by synthetic.invalid id FIRST\r\n' +
                  intake.TOKEN_HEADER.encode('ascii') + b': ' +
                  token.encode('ascii') + b'\r\n' + raw)

        intake.deliver(ledger, case.config, alice, queued)
        client = case.client(expected=1)
        case.assertEqual(case.body(client, 1), raw)
        before = case.snapshot()
        # Treat the first successful acknowledgement as lost. Changing only
        # the excluded synthetic queue trace must not allocate another UID.
        intake.deliver(ledger, case.config, alice,
                       queued.replace(b'id FIRST', b'id RETRY', 1))
        case.assertEqual(case.snapshot(), before)

        intake.deliver(ledger, case.config, bob, queued)
        bob_client = case.client(config=bob_config, expected=1)
        case.assertEqual(case.body(bob_client, 1), raw)
        case.assertEqual(case.snapshot(config=bob_config)[1], 2)
        case.assertEqual(case.snapshot(), before)

        # A separate, byte-identical intake is a distinct delivery. Read it
        # through a fresh standalone IMAP session against the same Store.
        new_token = ledger.issue(raw, [alice], 1700000001)
        new_queued = queued.replace(token.encode('ascii'),
                                    new_token.encode('ascii'), 1)
        intake.deliver(ledger, case.config, alice, new_queued)
        reconnected = case.client(expected=2)
        case.assertEqual(case.body(reconnected, 1), raw)
        case.assertEqual(case.body(reconnected, 2), raw)
        after = case.snapshot()
        case.assertEqual(after[0], before[0])
        case.assertEqual(after[1], 3)
        case.assertEqual(after[2], [(1, 1700000000), (2, 1700000001)])
        case.assertEqual(case.snapshot(config=bob_config)[1], 2)
    finally:
        case.tearDown()
    print('PASS: intake.deliver -> SQLite Store -> Dovecot 2.4.5 standalone IMAP; '
          'exact multipart bytes, replay UID stability, separate recipients, '
          'new identical intake UID 2, reconnect and original timestamps. '
          'No full Postfix integration claim.')


if __name__ == '__main__':
    main()
