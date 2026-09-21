#!/usr/bin/env python3
"""Opt-in native SSH resource churn on an authorized Linux host.
Uses a fresh namespace and stops only its own daemon after verification.
The SSH spec and system-ssh target must address the same host/user.
"""
import argparse
import json
import os
import pathlib
import select
import socket
import struct
import subprocess
import tempfile
import time
import uuid
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', required=True, type=pathlib.Path)
parser.add_argument('--assets', required=True, type=pathlib.Path)
parser.add_argument('--spec', required=True, type=pathlib.Path)
parser.add_argument('--ssh-target', required=True)
parser.add_argument('--rounds', type=int, default=30)
args = parser.parse_args()
assert 5 <= args.rounds <= 1000
helper = str(args.helper.resolve())
assets = str(args.assets.resolve())
spec = json.loads(args.spec.read_text())
gateways = []
namespace = 'kero-resource-' + uuid.uuid4().hex[:10]
state = None
print('namespace', namespace, flush=True)

class Gateway:

    def __init__(self):
        gateways.append(self)
        self.closed = False
        self.directory = tempfile.TemporaryDirectory(prefix='kero-resource-', dir='/tmp')
        os.chmod(self.directory.name, 0o700)
        self.path = self.directory.name + '/ssh.sock'
        self.events = []
        self.p = subprocess.Popen([helper, '--ssh-gateway'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.p.stdin.write(json.dumps({'spec': spec, 'assets': assets, 'socket': self.path, 'namespace': namespace}) + '\n')
        self.p.stdin.flush()
        start = time.monotonic()
        buffered = b''
        while True:
            while b'\n' not in buffered:
                remaining = 90 - (time.monotonic() - start)
                if remaining <= 0 or not select.select([self.p.stdout], [], [], remaining)[0]:
                    raise TimeoutError('gateway ready')
                chunk = os.read(self.p.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError('gateway exited before ready')
                buffered += chunk
            line, buffered = buffered.split(b'\n', 1)
            event = json.loads(line)
            self.events.append(event['event'])
            assert event['event'] not in ['failed', 'auth'], event
            if event['event'] == 'ready':
                self.home = event['home']
                break
        self.elapsed = time.monotonic() - start

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.p.stdin.close()
        self.p.wait(timeout=5)
        assert self.p.returncode == 0, self.p.stderr.read()
        self.p.stdout.close()
        self.p.stderr.close()
        self.directory.cleanup()

class Wire:

    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(20)
        self.s.connect(path)
        self.send({'op': 'hello', 'version': 1})
        self.hello = self.event()
        assert self.hello['event'] == 'hello'

    def send(self, v):
        self.data(1, json.dumps(v).encode())

    def data(self, k, d):
        self.s.sendall(struct.pack('<I', len(d)) + bytes([k]) + d)

    def exact(self, n):
        r = b''
        while len(r) < n:
            d = self.s.recv(n - len(r))
            if not d:
                raise EOFError()
            r += d
        return r

    def event(self):
        while True:
            n = struct.unpack('<I', self.exact(4))[0]
            k = self.exact(1)[0]
            d = self.exact(n)
            if k == 1:
                return json.loads(d)

    def request(self, v):
        self.send(v)
        return self.event()

    def close(self):
        self.s.close()

def metrics():
    code = "import json,pathlib\ns=pathlib.Path(%r);p=int((s/'daemon.pid').read_text());d=pathlib.Path('/proc')/str(p)\na=dict(x.split(':',1) for x in (d/'status').read_text().splitlines() if ':' in x)\nprint(json.dumps({'pid':p,'fds':len(list((d/'fd').iterdir())),'threads':int(a['Threads']),'rss_kib':int(a['VmRSS'].split()[0]),'images':len(list((s/'images').glob('*/*.png')))}))\n" % state
    return json.loads(subprocess.check_output(
        ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', args.ssh_target, 'python3 -'],
        input=code.encode(), timeout=20))

def create(w, program, args):
    v = w.request({'op': 'create', 'launch': {'session': str(uuid.uuid4()), 'directory': '/tmp', 'program': program, 'arguments': args, 'environment': {}, 'colors': {}, 'size': {'columns': 80, 'rows': 24}}})
    assert v['event'] == 'created', v
    return v['session']
try:
    g = Gateway()
    state = g.home + '/.local/state/' + namespace + '/daemon-v1'
    w = Wire(g.path)
    assert w.request({'op': 'list'})['sessions'] == []
    keep = create(w, '/bin/sh', ['-i'])
    identity = w.hello
    w.close()
    g.close()
    time.sleep(3)
    baseline = metrics()
    print('baseline', baseline, flush=True)
    samples = []
    for i in range(args.rounds):
        g = Gateway()
        assert 'installing' not in g.events, g.events
        w = Wire(g.path)
        assert w.hello['instance'] == identity['instance']
        assert w.request({'op': 'attach', 'key': keep['key']})['session']['pid'] == keep['pid']
        w.request({'op': 'detach'})
        w.close()
        watch = Wire(g.path)
        assert watch.request({'op': 'watch', 'paths': [{'host': identity['host'], 'path': '/tmp'}]})['event'] == 'watching'
        watch.close()
        w = Wire(g.path)
        for j in range(5):
            create(w, '/bin/sh', ['-c', 'exit 0'])
        w.close()
        g.close()
        time.sleep(2.2)
        if (i + 1) % 5 == 0:
            m = metrics()
            assert m['pid'] == baseline['pid']
            samples.append(m)
            print('round', i + 1, 'connect_ms', round(g.elapsed * 1000), 'resources', m, flush=True)
    g = Gateway()
    w = Wire(g.path)
    listed = w.request({'op': 'list'})['sessions']
    assert [s['key'] for s in listed] == [keep['key']], listed
    assert w.request({'op': 'terminate', 'key': keep['key']})['event'] == 'terminated'
    w.close()
    g.close()
    time.sleep(3)
    end = metrics()
    print('end', end, flush=True)
    assert end['fds'] <= baseline['fds'] and end['threads'] <= baseline['threads'], (baseline, end)
    assert samples[-1]['rss_kib'] < samples[0]['rss_kib'] + 8192, (samples[0], samples[-1])
    print(f'PASS {args.rounds} native reconnects, {args.rounds * 5} natural exits, {args.rounds} watchers; zero reconnect installs; daemon and persistent shell identities unchanged; all gateway processes reaped', flush=True)
finally:
    for gateway in gateways:
        try:
            gateway.close()
        except Exception:
            gateway.p.kill()
            gateway.p.wait()
            gateway.directory.cleanup()
    if state:
        # Verify the PID belongs to this namespace before removing test state.
        cleanup = "import os,pathlib,shutil,signal,time\ns=pathlib.Path(%r);p=int((s/'daemon.pid').read_text());d=pathlib.Path('/proc')/str(p)\nassert s.name=='daemon-v1' and s.parent.name.startswith('kero-resource-')\nassert str(s).encode() in (d/'cmdline').read_bytes().split(b'\\x00')\nos.kill(p,signal.SIGTERM)\nfor _ in range(100):\n if not d.exists():break\n time.sleep(.05)\nshutil.rmtree(s.parent)\n" % state
        subprocess.run(['ssh', '-o', 'BatchMode=yes', args.ssh_target, 'python3 -'], input=cleanup.encode(), check=True)
