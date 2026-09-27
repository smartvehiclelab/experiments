# Experimental Validation

## TL;DR

Run these Bash scripts **on the Raspberry Pi host** to measure the running server's resource use, HTTP latency, stream transport, and reliability. Each execution saves a new UTC timestamped directory under `experiments/logs/`. No benchmark datasets or performance claims are supplied. Nothing installs packages, tunes the Pi, restarts containers, or changes production code.

This harness belongs in [smartvehiclelab/rpi-server](https://github.com/smartvehiclelab/rpi-server), the active Pi backend, rather than the archived `rpi-server-legacy`, clients, dashboard, landing page, or separate model export pipeline. Architecture was inspected at `2de433043c89cec83909f8e5a59875d78d0594a3`, including `main.py`, README, Dockerfile, Compose, requirements and release workflow. Recheck assumptions if the deployed API changes.

## Test Environment

Source configuration (not measurements of your deployment):

- Raspberry Pi 5; README supports 64-bit Raspberry Pi OS Bookworm/Trixie. The container uses Python 3.11 slim Bookworm, aiohttp, Picamera2, OpenCV, Ultralytics and GPIOZero/lgpio.
- Compose service `rpi-server`, container `rpi_stream_server`, image `yoloprojekat/rpi-server:latest`; host networking, privileged hardware access, `/dev` and `/run/udev` mounts, 512 MiB shared memory, `unless-stopped` restart policy. Docker logs rotate at 10 MB × 3. The tag release workflow builds `linux/arm64` images.
- Healthcheck: `curl -f http://localhost:1607/health` every 10 seconds, timeout 3 seconds, 3 retries, 5-second start period. An unhealthy status alone does **not** cause Docker's restart policy to restart a running process.
- Server binds `0.0.0.0:1607`. GET `/health` exposes status, camera/model readiness, model loading, detection/follow flags and server uptime. GET `/video_feed` streams multipart JPEG. POST `/toggle_detection` and `/toggle_follow` accept `{"enable": boolean}`. POST `/control` drives motors.
- Camera source requests 640×480 BGR888; JPEG quality 80, camera-loop sleep 0.033 seconds. Annotation may reuse images for three capture iterations. These are settings, **not measured FPS**. The code supports fallback images when camera initialization fails.
- Detection uses `YOLO_MODEL_PATH`, default `yolo26n.pt`, confidence 0.35; inference runs off-thread with a 0.05-second loop sleep. With both toggles off the inference loop idles. Detection on includes inference **and** visual annotation; follow alone also runs inference.
- Follow calls `execute_move()` directly. GPIO18 supplies PWM, direction pins are 17/27, 22/23, 24/25, 5/6; initialization probes gpiochip4/0. Mock GPIO is an automatic failure fallback, with no explicit safe-mode switch or API attestation.

An IMX219 camera, OS Lite installation, and `pametno-vozilo.local` hostname are user-supplied deployment expectations; this repository does not establish those for a live run. Record the physical camera, RAM variant, cooling, power supply, ambient temperature, scene/lighting, other clients and motor-power condition in a separate `operator-notes.md` beside each dataset. Do not present those notes as automatic measurements.

Metadata automatically records local/UTC start/end, host, OS/kernel/architecture, Pi device-tree model when readable, Git remote/SHA/branch/dirty state, source checksums, Docker version/context/container identity/image ID/digests, YOLO environment and run settings. Health JSON records live flags. Camera settings and actual model file hash are not exposed by the HTTP API. Source checkout identity does not prove an already running image was built from it; compare image identity and deployment records.

## Methodology

The sampler reads host `/proc` and sysfs and inspects the selected Docker container. It does not run inside the application container. Remote `--url` changes **only HTTP measurements**: host metrics and Docker still describe the collector's host/context. For a combined Pi dataset, run on the Pi and normally use localhost.

- CPU busy percentage: differences between aggregate `/proc/stat` counters (user through steal; guest counters excluded from the sum), treating idle+iowait as idle; normalized to 0–100% across all cores. First sample of each phase is `NA` because no previous sample exists. RAM used = `MemTotal - MemAvailable`, in KiB.
- Temperature: `thermal_zone0/temp` divided by 1000, °C; frequency: CPU0 `scaling_cur_freq`, kHz. Load averages and uptime come from `/proc`; throttling is the unmodified hexadecimal `vcgencmd get_throttled` bitmask, including historical flags. `system.log` preserves disk usage (`df -Pk`), uptime and a process snapshot (ps CPU is lifetime average, not instantaneous).
- Each sample serially performs host reads, bounded HTTP check and Docker inspection. `INTERVAL` is a pause **after** collection, not an exact sampling frequency. Sample timestamp is completion time. Collection continues until the Bash elapsed-time budget expires; slow commands and final log capture can extend wall-clock duration. Baseline always takes two samples separated by a one-second pause; API runs by request count; detection uses the requested duration **per phase**.
- Health success requires curl exit 0, HTTP 200 and valid expected health JSON. This means the endpoint works, not that camera or YOLO is ready; those flags are recorded separately. Failed latency values are `NA`, with curl exit, HTTP code (`000` = no HTTP response), transfer elapsed time and response body retained. Each request uses a fresh curl process, no retry and no redirect following; curl `time_total` includes connection/network/server/body transfer, excluding process startup. Proxy bypass is explicit.
- Detection preflight requires camera/model ready and follow off. It writes detection=false, verifies it, samples, writes true, verifies it, samples, then restores the original detection flag even on ordinary interruption/error. Each sample verifies phase state/readiness. The first CPU sample of each phase is `NA`; startup/transient behavior is included. No stream consumer is added during detection phases. Keep the scene, temperature conditions and other client activity comparable; the fixed off→on order is not randomized.
- The stream consumer discards video bytes; curl records bytes, HTTP code, transfer time and exit status **per attempt**. It tries again after early closure, failure or low-speed timeout, with a one-second pause. Attempt numbers beyond 1 identify reconnect attempts, not necessarily successful reconnections. `STALL_TIMEOUT` detects transfers below 1 byte/s. A final curl timeout (28) can mean deadline **or stall**, so it is explicitly labeled `deadline_or_stall_timeout`, not counted as a successful continuous stream. stderr is retained to help distinguish them. Bytes from HTTP error responses are still transport bytes. A 200 response and nonzero bytes do not prove valid camera frames. Interrupted attempts may retain only their attempt file and stderr.
- Reliability is sampled in baseline/idle/stream/endurance: container ID, state, health, restart count, start time, OOM flag, HTTP status and server uptime. Changed ID/restart count/start time is logged. Inspect raw rows for HTTP failures and service uptime resets. No artificial restarts occur. Polling can miss short outages, and container replacement can reset restart counters. Docker logs are fetched at exit, bounded to 10 seconds and the run start time; rotation/deletion/timeout can make them incomplete, explicitly logged.

Missing measurements use `NA`, never an invented zero. Legitimate zero counts/bytes remain zero. Optional-command errors are preserved in `errors.log` (including repeated unavailable sensors). An inaccessible Docker daemon does not stop host/HTTP collection. A failed health check does not stop endurance, stream or API collection; idle/detection stop if their controlled phase cannot be verified. Exit code 0 means collection completed, **not** that the system passed a benchmark. Always inspect raw failures and errors.

## Experiments

| Experiment | Script | Purpose | Main outputs |
|---|---|---|---|
| Baseline | `system_baseline.sh` | Two host/service samples plus environment/process/disk snapshots | `raw.csv`, metadata, system/Docker logs |
| Idle | `idle_stability.sh` | Observe verified detection/follow off; default 300 s | samples and health responses |
| Stream | `stream_stability.sh` | One real MJPEG consumer; default 60 s | `stream.csv`, attempt records, resource samples |
| Detection | `detection_benchmark.sh` | Off/on workload, default 60 s per phase | labeled samples, transition responses/log, restoration record |
| Follow observation | `follow_benchmark.sh` | Read-only current-state observations; default 60 s | samples/flags; **no controlled follow comparison** |
| API latency | `api_latency.sh` | 100 health requests, 1 s pauses by default | individual `raw.csv`, health bodies, `summary.txt` |
| Endurance/reliability | `endurance_test.sh` | Continuous resource/service/container observation; default 600 s | samples, health responses, Docker logs/errors |
| Safe session | `run_all_safe.sh` | Baseline, latency, idle, stream, endurance in sequence | parent metadata, `children.csv`, separate child directories |

The safe runner defaults to 60 s for each duration-based child (explicitly propagated), 5 s pauses and 100 latency requests; use the short commands below first. Failed children remain in the session and later children still run. Detection and follow are deliberately excluded. Endurance is resource+health monitoring; it does not add a stream or change application toggles.

## Results

No physical-device experiments have been run as part of creating this harness. Add links to committed run directories after execution, retaining unsuccessful runs when reporting reliability. Suggested results table:

| Experiment | Git commit / image ID | Actual duration | Key measurements | Raw data |
|---|---|---|---|---|

Do not copy source comments about 30 FPS, startup speed, or memory stability into measured results.

## Reproduction

Prerequisites: Bash 4+, standard Linux utilities (awk, coreutils including `timeout`, procps), curl, Python 3 standard library (strict JSON parsing and latency summary). Docker CLI/daemon access and `vcgencmd` are optional. No root is required by the harness. It never installs missing utilities or alters permissions; Docker permission errors become evidence. Run against your already deployed service. Stop other controlling clients and physically disconnect motor power for controlled workload testing.

After copying/committing these files into your Pi checkout:

```bash
cd ~/rpi-server/experiments   # use your actual checkout location
bash system_baseline.sh
bash api_latency.sh --requests 20 --interval 1
bash idle_stability.sh --duration 30 --interval 5
bash stream_stability.sh --duration 30 --interval 5
bash endurance_test.sh --duration 600 --interval 5
```

Idle refuses to run unless detection and follow are already off; set those through your normal operator interface first. Read-only scripts do not stop a vehicle already following or being remotely controlled.

```bash
# One grouped short session; no detection/follow/control POSTs:
bash run_all_safe.sh --duration 30 --interval 1 --requests 10

# Controlled detection comparison, only after isolating motor power/other clients:
bash detection_benchmark.sh --duration 60 --interval 5

# Read-only observation; this never enables follow:
bash follow_benchmark.sh --duration 60 --interval 5

# Later, after reviewing short-run evidence:
DURATION=3600 INTERVAL=10 bash endurance_test.sh
DURATION=14400 INTERVAL=30 bash endurance_test.sh

# Optional network test (run on the Pi to retain Pi host metrics):
TARGET_HOST=pametno-vozilo.local TARGET_PORT=1607 bash api_latency.sh --requests 20
```

Environment settings: `TARGET_HOST=localhost`, `TARGET_PORT=1607`, `TARGET_BASE_URL` (overrides host/port), `CONTAINER_NAME=rpi_stream_server`, `DURATION`, `INTERVAL`, `REQUESTS=100`, `REQUEST_TIMEOUT=3`, `STALL_TIMEOUT=15`, `LOG_ROOT=experiments/logs`, optional `SESSION_ID`. All numeric settings must be positive integer seconds/counts. CLI `--duration`, `--interval`, `--requests`, `--url`, `--container` override corresponding environment settings. `--help` lists options. URL metadata is authoritative when host/port settings are overridden. Avoid credentials in URLs; metadata records them verbatim.

## Output and Git handling

Names use UTC plus a random suffix to prevent collisions, including concurrent starts. Runs never overwrite/delete previous data. Outputs include `metadata.txt`, `raw.csv`, `system.log`, `errors.log`, `docker.log`, start/end container state JSON, health response files, Git status and source checksums. Stream and detection add their own records; only API latency currently generates a statistical summary. Disk space and log growth are the operator's responsibility; no binary video is stored.

`logs/.gitkeep` is tracked and logs are intentionally **not ignored**. Review identifying hostnames, network details and server logs before publishing. Commit selected complete datasets explicitly, for example `git add experiments/logs/<run-directory>`. Document exclusions in research analysis rather than automatically selecting only successful runs. `git_state=dirty` can include newly generated/untracked experiment logs; consult `git-status.txt` and source checksums. Git SHA does not include uncommitted harness changes, so commit the harness before collecting publishable data.

## Evidence model

1. **Raw experimental evidence:** timestamped sample rows, health response bodies, curl attempt records, Docker/system/error logs. These contain observations and measurement errors, no interpretive conclusions. CPU percentage, used RAM and unit conversions are defined transformations of OS counters; the sampler does not preserve every kernel counter.
2. **Automatically calculated summaries:** API count/success/failure and min/max/arithmetic mean/median/p95 over valid responses only, in seconds. p95 uses nearest rank `ceil(0.95*n)`; an empty successful set produces `NA`. Summary errors leave raw data intact. Request failure counts must accompany latency statistics to avoid survivorship bias.
3. **Interpretation/conclusions:** explain engineering/scientific significance in a results discussion, separate analysis document or paper. Link the raw dataset and disclose conditions/failed runs. Never insert these conclusions into raw logs.

## Limitations

- No measured FPS, inference throughput, unique-frame count or frame freshness. Multipart bytes cannot establish FPS; annotated images may repeat. Loop sleeps are not achieved rates.
- `/health` can return 200 with camera/model unavailable. Camera readiness reflects initialization, not a guarantee every capture succeeded. Fallback imagery can still stream.
- Host-wide CPU/RAM include Docker, operating system, other clients and the harness itself. No per-container CPU/RAM or inference timing instrumentation is added. Sensor availability and permissions vary.
- Latency includes the chosen network path. Loopback latency does not represent Wi-Fi latency. Temperature depends on ambient conditions, cooling and previous workload.
- Follow cannot be safely enabled unattended with this API. Automatic GPIO failure fallback is neither a controllable dry-run facility nor proof that motors are disabled. No follow-on comparison or substitute benchmark is fabricated.
- Detection state can be changed by other clients between checks; restoration is best effort and cannot survive SIGKILL, power loss or an unreachable API. These are not atomic experimental controls. Record such runs as interrupted/invalid.
- Docker logs are bounded by the service's rotation, and sampled state cannot prove zero downtime. This harness does not tune, restart or repair the system during measurement.

## Safety

Baseline, idle, stream, API, endurance, follow observation and the safe runner issue only GETs and read-only local commands. They cannot initiate motor motion but also cannot stop pre-existing motion. They are suitable for unattended collection once the operator has secured the vehicle and excluded other controllers.

Detection is an explicit API state-changing experiment, excluded from `run_all_safe.sh`. Follow must be verified off, other controllers disconnected and motor power isolated before running it. No script calls `/control` or `/toggle_follow`, manipulates GPIO, or modifies the service. Follow observation only records current software state and does not exercise autonomous steering.

## Harness validation (not benchmark evidence)

`bash -n experiments/*.sh` must be run in a loop (Bash only parses its first file argument). If already installed, run `shellcheck -x experiments/*.sh`. `python3 experiments/tests/test_harness.py` runs local HTTP **test fixtures** and failure-path checks in a temporary directory outside `logs/`; fixture data are never experimental evidence. It does not launch production `main.py`, initialize GPIO, or require Pi hardware.
