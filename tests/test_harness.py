"""Local contract/failure fixtures only; never Raspberry Pi benchmark evidence."""
import csv
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BASH = os.environ.get('BASH_EXE') or shutil.which('bash')
if not BASH and os.name == 'nt':
    candidate = Path('C:/Program Files/Git/bin/bash.exe')
    BASH = str(candidate) if candidate.exists() else None
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


def main():
    if not BASH:
        raise SystemExit('Bash required: set BASH_EXE to a Bash executable')
    with tempfile.TemporaryDirectory(prefix='harness-validation-', dir=ROOT.parent) as temp:
        tmp = Path(temp)
        env = os.environ.copy()
        for key in ('TARGET_BASE_URL', 'SESSION_ID', 'FAIL_SUMMARY', 'CONTAINER_NAME', 'SOURCE_DIR', 'DOCKER_FIXTURE'):
            env.pop(key, None)
        # Use the interpreter running this test without installing or changing the host.
        bindir = tmp / 'bin'
        bindir.mkdir()
        wrapper = bindir / 'python3'
        wrapper.write_text('#!/usr/bin/env bash\n'
                           'if [[ ${FAIL_SUMMARY:-0} == 1 && ${2:-} == */raw.csv ]]; then exit 9; fi\n'
                           'exec "' + posix(sys.executable) + '" "$@"\n', encoding='utf-8')
        wrapper.chmod(0o755)
        # Always isolate Docker too: never inspect the developer's real containers.
        docker = bindir / 'docker'
        docker.write_text(r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_TRACE"
case "$1" in
  info) [[ ${DOCKER_FIXTURE:-} != denied ]] || { echo 'permission denied' >&2; exit 1; }; echo fixture;;
  ps)
    case ${DOCKER_FIXTURE:-} in
      ambiguous) printf 'renamed-app\nsecond-app\n';;
      port) [[ $* != *publish=* ]] || echo renamed-app;;
      *) echo renamed-app;;
    esac;;
  inspect)
    [[ ${*: -1} != missing ]] || exit 1
    case "$*" in
      *RestartCount*) echo 'fixture-id,running,healthy,0,2026-01-01T00:00:00Z,false';;
      *Config.Env*) echo YOLO_MODEL_PATH=fixture.pt;;
      *image_ref*) echo 'fixture-id image_ref=fixture image_id=sha256:fixture';;
      *'{{.Image}}'*) echo sha256:fixture;;
      *) echo '{"Status":"running"}';;
    esac;;
  image) echo '[]';;
  logs) echo 'fixture application log';;
  context) echo fixture-context;;
  --version) echo 'Docker fixture';;
  *) echo 'Unexpected Docker command' >&2; exit 99;;
esac
''', encoding='utf-8', newline='\n')
        docker.chmod(0o755)
        env['DOCKER_TRACE'] = posix(tmp / 'docker-trace.txt')
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
            before = set((tmp / 'results').glob('*'))
            print(f'\nRUN {script} {" ".join(args)} (expected exit {expected})', flush=True)
            output = []
            started = time.monotonic()
            with subprocess.Popen([BASH, '-c', command, 'test', posix(ROOT / script), *args],
                                  env=env, cwd=ROOT.parent, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, text=True, encoding='utf-8',
                                  errors='replace', bufsize=1, start_new_session=os.name != 'nt') as proc:
                def relay():
                    for line in proc.stdout:
                        output.append(line)
                        print(line, end='', flush=True)
                reader = threading.Thread(target=relay, daemon=True)
                reader.start()
                try:
                    proc.wait(timeout=50)
                except subprocess.TimeoutExpired:
                    if os.name == 'nt':
                        subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                                       capture_output=True, check=False)
                    else:
                        os.killpg(proc.pid, signal.SIGTERM)
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        if os.name != 'nt':
                            os.killpg(proc.pid, signal.SIGKILL)
                        else:
                            proc.kill()
                        proc.wait()
                    raise AssertionError(f'{script} timed out after 50s\n' + ''.join(output))
                reader.join(timeout=5)
            assert proc.returncode == expected, (script, proc.returncode, ''.join(output))
            created = set((tmp / 'results').glob('*')) - before
            assert len(created) <= 1, (script, created)
            result = next(iter(created), None)
            if result is not None:
                progress = (result / 'progress.log').read_text()
                assert 'Starting target=' in progress and 'Finished exit_code=' in progress
                assert 'Finalizing:' in progress
                assert 'Finished exit_code=' in ''.join(output), 'Progress must reach the console'
            print(f'PASS {script} ({time.monotonic()-started:.1f}s)', flush=True)
            return result

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
            baseline = run('system_baseline.sh')
            assert len(rows(baseline / 'raw.csv')) == 2
            assert all(r['container_state'] == 'running' for r in rows(baseline / 'raw.csv'))
            metadata = (baseline / 'metadata.txt').read_text()
            assert 'container_name=renamed-app' in metadata
            assert 'harness_repository=' in metadata
            assert 'backend_source_directory=not supplied' in metadata
            assert 'main.py' not in (baseline / 'errors.log').read_text()
            assert 'fixture application log' in (baseline / 'docker.log').read_text()
            source = tmp / 'backend source'
            source.mkdir()
            (source / 'compose.yaml').write_text('services: {}\n')
            explicit = run('system_baseline.sh', '--container', 'custom-app', '--source-dir', posix(source))
            assert 'container_name=custom-app' in (explicit / 'metadata.txt').read_text()
            assert 'compose.yaml' in (explicit / 'backend-source-sha256.txt').read_text()
            for mode in ('denied', 'ambiguous', 'port'):
                env['DOCKER_FIXTURE'] = mode
                result = run('system_baseline.sh')
                expected_state = 'running' if mode == 'port' else 'NA'
                assert all(r['container_state'] == expected_state for r in rows(result / 'raw.csv'))
                if mode == 'denied':
                    assert 'daemon inaccessible' in (result / 'errors.log').read_text()
                elif mode == 'ambiguous':
                    assert 'Cannot uniquely identify' in (result / 'errors.log').read_text()
            env.pop('DOCKER_FIXTURE')
            missing = run('system_baseline.sh', '--container', 'missing')
            assert all(r['container_state'] == 'NA' for r in rows(missing / 'raw.csv'))
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
            endurance = run('endurance_test.sh', '--duration', '3', '--interval', '3')
            progress = (endurance / 'progress.log').read_text()
            assert 'remaining_s=3' in progress and 'remaining_s=0' in progress
            assert 'cpu_pct=' in progress and 'temp_c=' in progress
            session = run('run_all_safe.sh', '--requests', '1')
            assert len(rows(session / 'children.csv')) == 5
            assert posts == [], 'Read-only scripts and safe session must never POST'
            assert all(line.split()[0] in {'info', 'ps', 'inspect', 'image', 'logs', 'context', '--version'}
                       for line in (tmp / 'docker-trace.txt').read_text().splitlines()), 'Docker must remain read-only'
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


if __name__ == '__main__':
    main()
