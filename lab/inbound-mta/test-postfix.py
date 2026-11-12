#!/usr/bin/env python3
"""Fail-closed real inbound assertions, ONLY in the disposable Docker lab.

No protocol replies are mocked. smtplib speaks SMTP, Postfix owns the queue and
pipe process, libmilter invokes the intake, and the actual Perl Store commits.
The pipe wrapper's explicit before/after/alter fault switches are test seams,
not actual power failure or lost SMTP-250 simulation.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import smtplib
import sqlite3
import subprocess
import sys
import time

BASE = Path('/lab/intake')
CONFIG = BASE / 'store.json'
A, B = 'alice@reference.invalid', 'bob@reference.invalid'
TOKEN_HEADER = b'X-Overnet-Intake-Token'
# Fixed headers and body make separate SMTP submissions byte-identical at the
# explicitly supported callback boundary. Includes folding, binary MIME and dots.
CONTENT = (b'From: sender@reference.invalid\r\nTo: header-only@reference.invalid\r\n'
           b'Date: Wed, 11 Nov 2026 00:00:00 +0000\r\n'
           b'Message-ID: <inbound-lab@reference.invalid>\r\n'
           b'Subject:\tfixed inbound fixture\r\nX-Fold: first\r\n\tsecond\r\n'
           b'Received: sender supplied and not transport metadata\r\n'
           b'MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=lab\r\n\r\n'
           b'--lab\r\nContent-Type: text/plain\r\n\r\n.dot\r\n.\r\n..two\r\n'
           b'--lab\r\nContent-Type: application/octet-stream\r\n'
           b'Content-Transfer-Encoding: base64\r\n\r\n' +
           base64.b64encode(bytes(range(256))) + b'\r\n--lab--\r\n')
WIRE = (TOKEN_HEADER + b': ' + b'0' * 64 + b'\r\n' +
        TOKEN_HEADER.lower() + b': sender-forgery\r\n' + CONTENT)


def run(*args, timeout=20):
    return subprocess.run(args, check=True, capture_output=True, timeout=timeout).stdout


def control(*args):
    return run('/lab/control', *args, timeout=65)


def fixture(command, *args):
    data = run('runuser', '-u', 'intake', '--', 'perl',
               '/src/lab/inbound-mta/store-fixture.pl', str(CONFIG), command, *args)
    return json.loads(data)


def check(condition, message):
    if not condition:
        raise AssertionError(message)
    print('PASS:', message, flush=True)


def await_value(label, fn, timeout=35):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.2)
    raise AssertionError('Timed out: ' + label)


def queue_rows():
    # postqueue -j is not an atomic snapshot. Duplicate exact IDs may appear;
    # reject conflicting stable fields, never merge distinct queue IDs.
    rows = {}
    for line in control('queue-json').splitlines():
        row = json.loads(line)
        key = row['queue_id']
        if key in rows:
            for field in ('sender', 'arrival_time', 'message_size'):
                check(rows[key][field] == row[field], 'duplicate scan identity is stable')
        else:
            rows[key] = row
    return rows


def queued_as(identifier, recipients):
    rows = queue_rows()
    if set(rows) - {identifier}:
        raise AssertionError('Unexpected distinct queue ID: ' + str(set(rows)))
    if identifier not in rows:
        return False
    return sorted(r['address'] for r in rows[identifier]['recipients']) == sorted(recipients)


def empty_queue():
    return not queue_rows()


def events():
    path = BASE / 'events.jsonl'
    if not path.exists():
        return []
    # Read only whole records. The append lock protects other writers, while a
    # reader can transiently observe the final incomplete record during flush.
    data = path.read_bytes()
    return [json.loads(line) for line in data[:data.rfind(b'\n') + 1].splitlines()]


def event_after(start, recipient, outcome):
    return [e for e in events()[start:] if e['recipient'] == recipient and e['outcome'] == outcome]


def fault(name, enabled=True):
    path = BASE / 'faults' / name
    if enabled:
        path.touch()
    else:
        path.unlink(missing_ok=True)


def smtp_submit(raw, addresses=(A, B)):
    with smtplib.SMTP('127.0.0.1', 2525, timeout=15) as smtp:
        smtp.ehlo('fixture.reference.invalid')
        code, _ = smtp.mail('')
        check(code == 250, 'MAIL accepted by real Postfix')
        for address in addresses:
            code, _ = smtp.rcpt(address)
            check(code == 250, 'configured envelope recipient accepted')
        code, reply = smtp.data(raw)
        check(code == 250, 'real final SMTP 250 transfers queue custody')
    match = re.search(rb'queued as ([A-F0-9]+)', reply)
    check(match is not None, 'Postfix reports an observable queue ID')
    return match[1].decode('ascii')


def ledger_rows():
    with sqlite3.connect('file:' + str(BASE / 'ledger.sqlite') + '?mode=ro', uri=True) as db:
        return db.execute('SELECT token, message, recipients, received_at FROM intake ORDER BY rowid').fetchall()


def snapshot():
    return fixture('snapshot')


def entry_list(state, mailbox):
    return state['mailboxes'].get(mailbox, {}).get('entries', [])


def drained(counts):
    state = snapshot()
    for mailbox, count in counts.items():
        actual = len(entry_list(state, mailbox))
        if actual > count:
            raise AssertionError('Unexpected extra Store delivery for ' + mailbox)
        if actual != count:
            return False
    return empty_queue()


def check_entries(state, counts, expected):
    for mailbox, count in counts.items():
        entries = entry_list(state, mailbox)
        check(len(entries) == count, mailbox + ' has exact delivery count ' + str(count))
        check([int(row['uid']) for row in entries] == list(range(1, count + 1)),
              mailbox + ' UIDs have no duplicate/replay gap')
        for row, message in zip(entries, expected[mailbox]):
            check(base64.b64decode(row['raw_b64']) == message, 'Store has exact callback-boundary MIME bytes')
            check(row['content_sha256'] == hashlib.sha256(message).hexdigest(), 'Store content hash matches octets')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', choices=('sqlite', 'postgres'), required=True)
    args = parser.parse_args()
    if (os.environ.get('OVERNET_INBOUND_MTA_LAB') != '1' or os.geteuid() != 0
            or not Path('/.dockerenv').is_file() or not Path('/lab/versions.txt').is_file()):
        raise SystemExit('Requires isolated inbound Docker lab; no host service operations permitted')
    check(json.loads(CONFIG.read_text())['engine'] == args.engine, 'explicit Store engine matches isolated setup')
    fixture('provision', A, 'alice')  # Bob is accepted by Postfix but absent in Store.
    fault('after-alice')
    control('milter-start')
    control('postfix-start')
    check(empty_queue(), 'fresh synthetic queue is empty')
    qid = smtp_submit(WIRE)
    await_value('Alice commit but lost pipe acknowledgement', lambda: event_after(0, A, 'committed_ack_lost'))
    await_value('Bob unknown Store recipient defers', lambda: event_after(0, B, 'deferred'))
    await_value('both recipients remain in Postfix', lambda: queued_as(qid, [A, B]))
    original = snapshot()
    check_entries(original, {'alice': 1, 'bob': 0}, {'alice': [CONTENT], 'bob': []})
    ledger = ledger_rows()
    check(len(ledger) == 1 and ledger[0][1] == CONTENT, 'real Milter strips every spoofed token and preserves the boundary')
    token, _, addresses, received_at = ledger[0]
    check(sorted(json.loads(addresses)) == [A, B], 'ledger uses envelope recipients only')
    first = entry_list(original, 'alice')[0]
    check(first['idempotency_key'] == token and int(first['received_at']) == received_at,
          'Store receipt retains trusted token and original intake timestamp')
    control('postfix-stop')
    control('milter-stop')
    # Quiescence precedes the cursor: an old child finishing during shutdown
    # must not satisfy the assertion that a new retry ran after restart.
    before_restart = len(events())
    control('milter-start')
    control('postfix-start')
    control('postfix-flush')
    await_value('same queue ID after restart', lambda: queued_as(qid, [A, B]))
    await_value('actual pipe retry after restart', lambda: event_after(before_restart, A, 'committed_ack_lost'))
    check(snapshot() == original, 'real retry after lost acknowledgement consumes no new UID or timestamp')
    check(ledger_rows() == ledger, 'restarted Milter does not regenerate the token')
    fixture('route', B, 'bob')
    fault('after-alice', False)
    control('postfix-flush')
    await_value('partial-recipient queue drains after recovery', lambda: drained({'alice': 1, 'bob': 1}))
    partial = snapshot()
    check_entries(partial, {'alice': 1, 'bob': 1}, {'alice': [CONTENT], 'bob': [CONTENT]})
    check(entry_list(partial, 'alice') == entry_list(original, 'alice'), 'Bob recovery cannot change Alice custody')
    check(entry_list(partial, 'bob')[0]['idempotency_key'] == token, 'both recipients retain same intake identity')

    smtp_submit(WIRE, (A,))
    await_value('new identical submission drains', lambda: drained({'alice': 2, 'bob': 1}))
    second = snapshot()
    check_entries(second, {'alice': 2, 'bob': 1}, {'alice': [CONTENT, CONTENT], 'bob': [CONTENT]})
    check(ledger_rows()[1][0] != token, 'byte-identical new intake gets a new token')

    # Reinject a real previously valid token at SMTP. It must be treated as
    # sender-controlled, removed, and replaced, never recovered from the header.
    smtp_submit(TOKEN_HEADER + b': ' + token.encode() + b'\r\n' + CONTENT, (A,))
    await_value('reinjection drains', lambda: drained({'alice': 3, 'bob': 1}))
    check(len(ledger_rows()) == 3 and ledger_rows()[2][0] not in {r[0] for r in ledger_rows()[:2]},
          'SMTP reinjection of an old valid token is a distinct intake')
    check_entries(snapshot(), {'alice': 3, 'bob': 1}, {'alice': [CONTENT] * 3, 'bob': [CONTENT]})

    fault('before-alice')
    start = len(events())
    qid = smtp_submit(WIRE, (A,))
    await_value('hold before missing-ledger failure', lambda: event_after(start, A, 'blocked_before_store'))
    control('milter-stop')
    (BASE / 'ledger.sqlite').rename(BASE / 'ledger.saved')
    old = snapshot()
    start = len(events())
    fault('before-alice', False)
    control('postfix-flush')
    await_value('missing ledger fails actual pipe', lambda: event_after(start, A, 'deferred'))
    await_value('Postfix retains missing-ledger delivery', lambda: queued_as(qid, [A]))
    check(snapshot() == old, 'missing binding cannot call Store successfully')
    check(not (BASE / 'ledger.sqlite').exists(), 'delivery never recreates missing ledger')
    (BASE / 'ledger.saved').rename(BASE / 'ledger.sqlite')
    control('milter-start')
    control('postfix-flush')
    await_value('restored binding drains original queue', lambda: drained({'alice': 4, 'bob': 1}))
    check_entries(snapshot(), {'alice': 4, 'bob': 1}, {'alice': [CONTENT] * 4, 'bob': [CONTENT]})

    fault('alter-alice')
    start = len(events())
    qid = smtp_submit(WIRE, (A,))
    old = snapshot()
    await_value('changed pipe bytes fail binding', lambda: event_after(start, A, 'deferred'))
    await_value('changed-byte attempt remains queued', lambda: queued_as(qid, [A]))
    check(snapshot() == old, 'changed pipe bytes do not overwrite or create custody')
    fault('alter-alice', False)
    control('postfix-flush')
    await_value('original unaltered queue bytes recover', lambda: drained({'alice': 5, 'bob': 1}))
    check_entries(snapshot(), {'alice': 5, 'bob': 1}, {'alice': [CONTENT] * 5, 'bob': [CONTENT]})

    if args.engine == 'postgres':
        fault('before-alice')
        start = len(events())
        qid = smtp_submit(WIRE, (A,))
        await_value('hold before PostgreSQL outage', lambda: event_after(start, A, 'blocked_before_store'))
        old = snapshot()
        control('postgres-stop')
        start = len(events())
        fault('before-alice', False)
        control('postfix-flush')
        await_value('real PostgreSQL outage defers pipe', lambda: event_after(start, A, 'deferred'))
        await_value('Postfix retains PostgreSQL outage delivery', lambda: queued_as(qid, [A]))
        # Keep delivery held while inspecting persistence after DB restart.
        fault('before-alice')
        control('postgres-start')
        check(snapshot() == old, 'PostgreSQL service restart preserves previous receipts')
        fault('before-alice', False)
        control('postfix-flush')
        await_value('PostgreSQL recovery drains', lambda: drained({'alice': 6, 'bob': 1}))
        check_entries(snapshot(), {'alice': 6, 'bob': 1}, {'alice': [CONTENT] * 6, 'bob': [CONTENT]})

    before = snapshot()
    with smtplib.SMTP('127.0.0.1', 2525, timeout=15) as smtp:
        smtp.ehlo('fixture.reference.invalid')
        check(smtp.mail('')[0] == 250, 'negative recipient probe MAIL accepted')
        for address in ('unknown@reference.invalid', 'nobody@external.invalid'):
            check(500 <= smtp.rcpt(address)[0] < 600, 'unknown or external recipient refused at RCPT')
        smtp.rset()
        check(smtp.mail('', options=['SIZE=65537'])[0] == 552, 'oversize declared message refused before DATA')
    control('milter-stop')
    with smtplib.SMTP('127.0.0.1', 2525, timeout=15) as smtp:
        smtp.ehlo('fixture.reference.invalid')
        code, _ = smtp.mail('')
        if code == 250:
            code, _ = smtp.rcpt(A)
        if code == 250:
            try:
                code, _ = smtp.data(CONTENT)
            except smtplib.SMTPDataError as error:
                code = error.smtp_code
        check(400 <= code < 500, 'unavailable Milter cannot accept SMTP custody')
    check(empty_queue(), 'rejected SMTP probes create no deliverable queue entry')
    check(snapshot() == before, 'rejected SMTP probes leave Store unchanged')
    # Administrative pickup adds another Received field. This topology does
    # not authorize guessing which transport headers may be removed. Require
    # safe deferral rather than treating requeue as successful integration.
    control('milter-start')
    fault('before-alice')
    start = len(events())
    qid = smtp_submit(WIRE, (A,))
    await_value('pre-Store hold before administrative requeue', lambda: event_after(start, A, 'blocked_before_store'))
    await_value('one held queue entry', lambda: queued_as(qid, [A]))
    held_ledger = ledger_rows()
    before_requeue = snapshot()
    control('postfix-stop')
    control('queue-requeue', qid)
    control('postfix-start')
    def requeued():
        rows = queue_rows()
        if len(rows) > 1:
            raise AssertionError('Requeue created unexpected extra queue IDs')
        return rows if len(rows) == 1 and qid not in rows else None
    replacement = await_value('administrative requeue changes queue ID', requeued)
    replacement_id = next(iter(replacement))
    check(ledger_rows() == held_ledger, 'administrative requeue does not mint another intake identity')
    start = len(events())
    fault('before-alice', False)
    control('postfix-flush')
    rejected = await_value('unsupported administrative requeue safely defers',
                           lambda: event_after(start, A, 'deferred'))
    check(all(row.get('token') == held_ledger[-1][0] for row in rejected),
          'requeue still carries original token, not a synthesized identity')
    check(all(row.get('message_sha256') != hashlib.sha256(CONTENT).hexdigest() for row in rejected),
          'extra pickup trace changes the strict callback boundary')
    await_value('unsupported requeue remains in Postfix custody', lambda: queued_as(replacement_id, [A]))
    check(snapshot() == before_requeue, 'unsupported requeue cannot create or overwrite Store custody')
    # Its only remaining queue item is deliberately retained, not acknowledged.
    # The outer controller removes this synthetic state when disposing the lab.
    print('PASS: real inbound Postfix/Milter/pipe integration for ' + args.engine, flush=True)


if __name__ == '__main__':
    main()
