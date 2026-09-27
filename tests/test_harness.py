"""Local contract/failure fixtures only; never Raspberry Pi benchmark evidence."""
import csv
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_EXE') or shutil.which('bash')
assert BASH, 'Bash required'
state = dict(detection=False, follow=False, malformed=False)
posts = []


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/health':
            payload = b'not json' if state['malformed'] else json.dumps(dict(
                status='ok', camera_active=True, yolo_active=True,
                yolo_loading=False, detection_enabled=state['detection'],
                follow_enabled=state['follow'], uptime_seconds=10.0)).encode()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(payload)
        elif self.path == '/video_feed':
            self.send_response(200)
            self.end_headers()
            # Deliberately a transport fixture, not real JPEG/video.
            try:
                for _ in range(50):
                    self.wfile.write(b'fixture transport bytes\n')
                    self.wfile.flush()
                    time.sleep(.1)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass
        else:
            self.send_error(404)

    def do_POST(self):
        posts.append(self.path)
        assert self.path == '/toggle_detection', 'Forbidden motor/follow write'
        state['detection'] = json.loads(self.rfile.read(int(self.headers['Content-Length'])))['enable']
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"status":"success"}')


def posix(path):
    return str(path).replace('\\', '/')


with tempfile.TemporaryDirectory(prefix='harness-validation-', dir=ROOT.parent.parent) as temp:
    tmp = Path(temp)
    env = os.environ.copy()
    # Use the interpreter running this test without installing or changing the host.
    bindir = tmp / 'bin'
    bindir.mkdir()
    wrapper = bindir / 'python3'
    wrapper.write_text('#!/usr/bin/env bash\n'
                       'if [[ ${FAIL_SUMMARY:-0} == 1 && ${2:-} == */raw.csv ]]; then exit 9; fi\n'
                       'exec "' + posix(sys.executable) + '" "$@"\n', encoding='utf-8')
    wrapper.chmod(0o755)
    logpath = posix(tmp / 'results')
    if os.name == 'nt':
        logpath = '/' + logpath[0].lower() + logpath[2:]
    env.update(LOG_ROOT=logpath, DURATION='1', INTERVAL='1',
               REQUESTS='2', REQUEST_TIMEOUT='1', STALL_TIMEOUT='1')
    # Git Bash translates Windows PATH at startup; prepend the wrapper in Bash itself.
    binpath = posix(bindir)
    if os.name == 'nt':
        binpath = '/' + binpath[0].lower() + binpath[2:]
    command_prefix = 'export PATH="' + binpath + ':$PATH"; '

    def run(script, *args, expected=0):
        command = command_prefix + 'exec bash "$@"'
        proc = subprocess.run([BASH, '-c', command, 'test', posix(ROOT / script), *args],
                              env=env, cwd=ROOT.parent, capture_output=True, text=True, timeout=50)
        assert proc.returncode == expected, (script, proc.returncode, proc.stdout, proc.stderr)
        directories = sorted((tmp / 'results').glob('*'), key=lambda p: p.stat().st_mtime_ns)
        return directories[-1] if directories else None

    def rows(path):
        with path.open(newline='') as f:
            data = list(csv.DictReader(f))
        assert all(None not in r and None not in r.values() for r in data), path
        return data

    for script in ROOT.glob('*.sh'):
        subprocess.run([BASH, '-n', posix(script)], check=True)
    run('api_latency.sh', '--duration', '0', expected=2)
    run('api_latency.sh', '--unknown', expected=2)
    assert not (tmp / 'results').exists(), 'Invalid CLI must not start an experiment'

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env['TARGET_BASE_URL'] = f'http://127.0.0.1:{server.server_port}'
    try:
        first = run('api_latency.sh')
        assert all(r['health_valid'] == 'true' for r in rows(first / 'raw.csv'))
        assert 'successful=2' in (first / 'summary.txt').read_text()
        assert 'end_utc=' in (first / 'metadata.txt').read_text()
        env['FAIL_SUMMARY'] = '1'
        summary_failure = run('api_latency.sh', expected=1)
        assert len(rows(summary_failure / 'raw.csv')) == 2
        assert 'Summary generation failed' in (summary_failure / 'errors.log').read_text()
        env.pop('FAIL_SUMMARY')
        second = run('api_latency.sh')
        assert first != second and first.exists(), 'Old runs must be preserved'
        state['malformed'] = True
        invalid = run('api_latency.sh')
        assert all(r['latency_s'] == 'NA' for r in rows(invalid / 'raw.csv'))
        assert 'failed=2' in (invalid / 'summary.txt').read_text()
        assert 'invalid schema' in (invalid / 'errors.log').read_text()
        state['malformed'] = False
        state['follow'] = True
        run('detection_benchmark.sh', expected=1)
        run('idle_stability.sh', expected=1)
        assert posts == [], 'Preflight refusal must not mutate anything'
        state['follow'] = False
        detection = run('detection_benchmark.sh')
        assert state['detection'] is False, 'Restore original state'
        assert len(list(detection.glob('detection-*.json'))) == 3
        assert {r['phase'] for r in rows(detection / 'raw.csv')} == {'detection_false', 'detection_true'}
        posts.clear()
        run('system_baseline.sh')
        run('idle_stability.sh')
        run('follow_benchmark.sh')
        stream = run('stream_stability.sh', '--duration', '2')
        assert float(rows(stream / 'stream.csv')[0]['bytes_received']) > 0
        run('endurance_test.sh')
        session = run('run_all_safe.sh', '--requests', '1')
        assert len(rows(session / 'children.csv')) == 5
        assert posts == [], 'Read-only scripts and safe session must never POST'
    finally:
        server.shutdown()
        server.server_close()
    env['TARGET_BASE_URL'] = f'http://127.0.0.1:{server.server_port}'
    failed = run('api_latency.sh', '--requests', '1')
    assert rows(failed / 'raw.csv')[0]['latency_s'] == 'NA'
    assert 'failed=1' in (failed / 'summary.txt').read_text()
    assert 'curl_exit=' in (failed / 'errors.log').read_text()
    print('PASS: syntax, CLI validation, unique directories, metadata, latency success/failure,')
    print('invalid JSON, detection phases/restoration/refusal, read-only safety, stream bytes, session grouping.')
    print('All data were temporary test fixtures, not experimental evidence.')
