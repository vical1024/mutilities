"""Exercise the real helper's IPC without an external monitor or disabling a screen.
Usage: python3 Tools/DisplayGuardSmokeTest.py [path/to/DisplayGuard]
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[1]
helper = Path(sys.argv[1]) if len(sys.argv) > 1 else root / '.build/debug/DisplayGuard'
report = json.loads(subprocess.check_output(['system_profiler', 'SPDisplaysDataType', '-json']))
screens = [d for gpu in report['SPDisplaysDataType'] for d in gpu.get('spdisplays_ndrvs', [])]
assert screens and all(d.get('spdisplays_connection_type') == 'spdisplays_internal' for d in screens), 'Run only with external/virtual displays disconnected'
builtin = screens[0]['_spdisplays_displayID']
children = []


def start():
    process = subprocess.Popen([str(helper), str(builtin)], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    children.append(process)
    return process


def until(process, token, timeout=12):
    data = b''
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline-time.monotonic()))
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            break
        data += chunk
        for line in data.splitlines():
            if line.startswith(b'state ') and line != b'state on 0':
                raise AssertionError('Display topology changed during smoke test: ' + repr(line))
        if token in data:
            return data
    raise AssertionError(f'Missing {token!r}: {data!r}')


try:
    p = start()
    until(p, b'ready\n')
    p.stdin.write(b'p')
    until(p, b'state on 0\n')
    p.stdin.close()
    until(p, b'restored\n')
    assert p.wait(timeout=3) == 0
    print('PASS normal EOF restores and exits')

    p = start()
    until(p, b'ready\n')
    p.send_signal(signal.SIGTERM)
    until(p, b'restored\n')
    assert p.wait(timeout=3) == 0
    print('PASS SIGTERM restores and exits')

    p = start()
    until(p, b'ready\n')
    q = start()
    until(q, b'error ')
    assert q.wait(timeout=3) == 1
    assert p.poll() is None
    p.stdin.close()
    until(p, b'restored\n')
    assert p.wait(timeout=3) == 0
    print('PASS duplicate guard is rejected')

    p = start()
    until(p, b'ready\n')
    p.stdin.write(b'p')
    until(p, b'state on 0\n')
    before = time.monotonic()
    data = until(p, b'restored\n')
    assert b'error ' in data
    assert p.wait(timeout=3) == 1
    assert 7 <= time.monotonic() - before < 11
    print('PASS missed heartbeat restores after about 8 seconds')

    p = start()
    until(p, b'ready\n')
    p.stdin.write(b'bad')
    data = until(p, b'restored\n')
    assert b'error ' in data
    assert p.wait(timeout=3) == 1
    print('PASS malformed heartbeat restores and exits')

    owner_code = '''import subprocess,sys,time
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=sys.stdout, stderr=sys.stderr)
print('child', p.pid, flush=True)
time.sleep(30)
'''
    owner = subprocess.Popen([sys.executable, '-c', owner_code, str(helper), str(builtin)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    children.append(owner)
    until(owner, b'ready\n')
    owner.kill()
    until(owner, b'restored\n')
    owner.wait(timeout=3)
    print('PASS SIGKILL of owner triggers helper EOF restoration')
finally:
    for process in children:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
