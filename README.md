# Experimental Validation

## TL;DR

Run these Bash scripts **on the Raspberry Pi host with `sudo`** to measure the running server's resource use, HTTP latency, stream transport, Docker/container state, and reliability. Each execution saves a new UTC timestamped directory under `logs/` beside the scripts.

For publishable repeated measurements, use `run_randomized_repeats.sh`. It executes the experiment set **four times**, independently randomizes experiment order within every repetition, inserts a configurable cooldown between runs, records the exact execution order, and assigns a common session ID to the resulting datasets.

Seven earlier recorded runs from 2026-09-27 are also available under [`logs/`](logs/). They predate the randomized repeated-run methodology and were collected without Docker socket access; their measurements and evidence limitations are documented separately below.

Nothing in the harness installs packages, tunes the Pi, restarts containers, modifies GPIO configuration, or changes production code.

This is a standalone experiments repository that observes an already running Pi backend. It also works when placed inside a backend checkout. No backend source files or Compose project are required beside the scripts.

The historical backend architecture described below was inspected at `2de433043c89cec83909f8e5a59875d78d0594a3`, including `main.py`, README, Dockerfile, Compose, requirements and release workflow. Recheck assumptions if the deployed API changes.

---

## Test Environment

Historical source configuration (not discovery of your current deployment):

- Raspberry Pi 5; README supports 64-bit Raspberry Pi OS Bookworm/Trixie. The container uses Python 3.11 slim Bookworm, aiohttp, Picamera2, OpenCV, Ultralytics and GPIOZero/lgpio.
- Compose service `rpi-server`, container `rpi_stream_server`, image `yoloprojekat/rpi-server:latest`; host networking, privileged hardware access, `/dev` and `/run/udev` mounts, 512 MiB shared memory, `unless-stopped` restart policy. Docker logs rotate at 10 MB × 3. The tag release workflow builds `linux/arm64` images.
- Healthcheck: `curl -f http://localhost:1607/health` every 10 seconds, timeout 3 seconds, 3 retries, 5-second start period. An unhealthy status alone does **not** cause Docker's restart policy to restart a running process.
- Server binds `0.0.0.0:1607`. GET `/health` exposes status, camera/model readiness, model loading, detection/follow flags and server uptime. GET `/video_feed` streams multipart JPEG. POST `/toggle_detection` and `/toggle_follow` accept `{"enable": boolean}`. POST `/control` drives motors.
- Camera source requests 640×480 BGR888; JPEG quality 80, camera-loop sleep 0.033 seconds. Annotation may reuse images for three capture iterations. These are settings, **not measured FPS**. The code supports fallback images when camera initialization fails.
- Detection uses `YOLO_MODEL_PATH`, default `yolo26n.pt`, confidence 0.35; inference runs off-thread with a 0.05-second loop sleep. With both toggles off the inference loop idles. Detection on includes inference **and** visual annotation; follow alone also runs inference.
- Follow calls `execute_move()` directly. GPIO18 supplies PWM, direction pins are 17/27, 22/23, 24/25, 5/6; initialization probes gpiochip4/0. Mock GPIO is an automatic failure fallback, with no explicit safe-mode switch or API attestation.

An IMX219 camera, OS Lite installation, and `pametno-vozilo.local` hostname are deployment expectations rather than facts automatically established by this repository for every run.

For publishable datasets, record physical camera, RAM variant, cooling configuration, power supply, ambient temperature, scene/lighting, other active clients, case configuration, and motor-power condition in an `operator-notes.md` associated with the experimental session. These operator observations must not be presented as automatically measured values.

Metadata automatically records local/UTC start/end, host, OS/kernel/architecture, Pi device-tree model when readable, Git remote/SHA/branch/dirty state, source checksums, Docker version/context/container identity/image ID/digests, YOLO environment and run settings.

Health JSON records live flags. Camera settings and actual model file hash are not exposed by the HTTP API.

Git metadata identifies the harness checkout, discovered from the script directory. Harness checksums are saved in `source-sha256.txt`.

Optional `--source-dir PATH` records available backend configuration/source entry-point checksums in `backend-source-sha256.txt`; missing legacy filenames are skipped. This does not prove the running image was built from those sources; compare image identity and deployment records.

---

## Methodology

### Measurement model

The sampler reads host `/proc` and sysfs and inspects the selected Docker container. It does not run inside the application container.

Remote `--url` changes **only HTTP measurements**: host metrics and Docker still describe the collector's host/context. For a combined Pi dataset, run on the Pi and normally use localhost.

- CPU busy percentage: differences between aggregate `/proc/stat` counters (user through steal; guest counters excluded from the sum), treating idle+iowait as idle; normalized to 0–100% across all cores. First sample of each phase is `NA` because no previous sample exists. RAM used = `MemTotal - MemAvailable`, in KiB.
- Temperature: `thermal_zone0/temp` divided by 1000, °C; frequency: CPU0 `scaling_cur_freq`, kHz. Load averages and uptime come from `/proc`; throttling is the unmodified hexadecimal `vcgencmd get_throttled` bitmask, including historical flags. `system.log` preserves disk usage (`df -Pk`), uptime and a process snapshot (ps CPU is lifetime average, not instantaneous).
- Each sample serially performs host reads, bounded HTTP check and Docker inspection. `INTERVAL` is a pause **after** collection, not an exact sampling frequency. Sample timestamp is completion time. Collection continues until the Bash elapsed-time budget expires; slow commands and final log capture can extend wall-clock duration. Baseline always takes two samples separated by a one-second pause; API runs by request count; detection uses the requested duration **per phase**.
- Health success requires curl exit 0, HTTP 200 and valid expected health JSON. This means the endpoint works, not that camera or YOLO is ready; those flags are recorded separately. Failed latency values are `NA`, with curl exit, HTTP code (`000` = no HTTP response), transfer elapsed time and response body retained. Each request uses a fresh curl process, no retry and no redirect following; curl `time_total` includes connection/network/server/body transfer, excluding process startup. Proxy bypass is explicit.
- Detection preflight requires camera/model ready and follow off. It writes detection=false, verifies it, samples, writes true, verifies it, samples, then restores the original detection flag even on ordinary interruption/error. Each sample verifies phase state/readiness. The first CPU sample of each phase is `NA`; startup/transient behavior is included. No stream consumer is added during detection phases.
- The stream consumer discards video bytes; curl records bytes, HTTP code, transfer time and exit status **per attempt**. It tries again after early closure, failure or low-speed timeout, with a one-second pause. Attempt numbers beyond 1 identify reconnect attempts, not necessarily successful reconnections. `STALL_TIMEOUT` detects transfers below 1 byte/s. A final curl timeout (28) can mean deadline **or stall**, so it is explicitly labeled `deadline_or_stall_timeout`, not counted as a successful continuous stream. stderr is retained to help distinguish them. Bytes from HTTP error responses are still transport bytes. A 200 response and nonzero bytes do not prove valid camera frames. Interrupted attempts may retain only their attempt file and stderr.
- Reliability is sampled in baseline/idle/stream/endurance: container ID, state, health, restart count, start time, OOM flag, HTTP status and server uptime. Changed ID/restart count/start time is logged. Inspect raw rows for HTTP failures and service uptime resets. No artificial restarts occur. Polling can miss short outages, and container replacement can reset restart counters. Docker logs are fetched at exit, bounded to 10 seconds and the run start time; rotation/deletion/timeout can make them incomplete, explicitly logged.

Missing measurements use `NA`, never an invented zero. Legitimate zero counts/bytes remain zero.

Optional-command errors are preserved in `errors.log`, including repeated unavailable sensors. An inaccessible Docker daemon does not stop host/HTTP collection.

A failed health check does not stop endurance, stream or API collection; idle/detection stop if their controlled phase cannot be verified.

Exit code 0 means collection completed, **not** that the system passed a benchmark. Always inspect raw failures and errors.

### Docker/container discovery

Every experiment calls the common initialization code before measurement.

The harness first checks whether the Docker CLI and daemon are accessible. When available, it saves the current deployment snapshot using:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

The result is retained as `docker-ps.txt`.

If `--container` was not supplied, automatic discovery proceeds in this order:

1. Compose service label `com.docker.compose.service=rpi-server`.
2. Historical container name `rpi_stream_server`.
3. Container publishing the effective HTTP target port.
4. If and only if exactly one container is running, that unambiguous container is selected.

If several possible containers remain, the harness does not guess. Supply `--container NAME`.

The selected container is verified with `docker inspect` and must be running before Docker measurements are enabled.

The run retains explicit container evidence including `container-selected.txt`, `container-discovery.json`, `container-start.json`, `container-end.json`, Docker metadata and `docker.log` when accessible.

### Randomized repeated-run protocol

The preferred protocol for new comparative measurements is `run_randomized_repeats.sh`.

The default design performs **four repetitions of the experiment set**. Before every repetition, the experiment order is independently randomized using `shuf`.

Conceptually:

```text
Repetition 1: random permutation of experiments
Repetition 2: new random permutation
Repetition 3: new random permutation
Repetition 4: new random permutation
```

The same fixed ordering is therefore not deliberately repeated four times.

With seven configured experiment scripts, the default protocol produces **28 individual experiment executions**.

A cooldown is inserted between executions. The default is 60 seconds and can be changed with `COOLDOWN`.

Randomization helps reduce systematic ordering effects—for example, always running a high-load workload immediately before another particular experiment. The cooldown reduces, but does not eliminate, carryover from temperature, caches, model state, operating-system activity or previous workloads.

Randomization does **not** make consecutive measurements fully statistically independent. Environmental conditions and the physical device remain shared. Results must therefore be interpreted as repeated measurements of the same deployed system under controlled but imperfectly independent conditions.

The runner records:

- session ID;
- number of repetitions;
- cooldown;
- experiment set;
- generated order for every repetition;
- global execution sequence;
- repetition and position;
- start/end UTC timestamps;
- child exit codes;
- failed-run count.

Individual experiments receive the common `SESSION_ID`, allowing their normal metadata to be associated with the randomized session.

Failed runs are retained rather than silently discarded. The runner continues to later experiments and reports failures at the end.

For analysis, report individual observations alongside appropriate aggregate statistics. Depending on the variable and sample size, useful summaries include arithmetic mean, median, standard deviation, interquartile range and observed range. Do not hide failed or invalid runs merely because they worsen a summary.

### Experimental controls

Keep scene, ambient conditions, case/cooling configuration, power conditions and other client activity as comparable as practical across repetitions.

For detection testing, motor power must remain isolated and follow must remain off.

The detection experiment itself still uses a fixed internal **off → on** phase order. Randomizing the order of experiment scripts does not randomize those two internal phases. Any interpretation of the detection comparison must retain that limitation.

Record relevant environmental conditions in `operator-notes.md`.

---

## Experiments

| Experiment | Script | Purpose | Main outputs |
|---|---|---|---|
| Baseline | `system_baseline.sh` | Two host/service/container samples plus environment/process/disk snapshots | `raw.csv`, metadata, system/Docker logs |
| Idle | `idle_stability.sh` | Observe verified detection/follow off; default 300 s | samples and health responses |
| Stream | `stream_stability.sh` | One real MJPEG consumer; default 60 s | `stream.csv`, attempt records, resource samples |
| Detection | `detection_benchmark.sh` | Off/on workload, default 60 s per phase | labeled samples, transition responses/log, restoration record |
| Follow observation | `follow_benchmark.sh` | Read-only current-state observations; default 60 s | samples/flags; **no controlled follow comparison** |
| API latency | `api_latency.sh` | 100 health requests, 1 s pauses by default | individual `raw.csv`, health bodies, `summary.txt` |
| Endurance/reliability | `endurance_test.sh` | Continuous resource/service/container observation; default 600 s | samples, health responses, Docker logs/errors |
| Safe session | `run_all_safe.sh` | Baseline, latency, idle, stream, endurance in sequence | parent metadata, `children.csv`, separate child directories |
| Randomized repetitions | `run_randomized_repeats.sh` | Four independently randomized repetitions with cooldown and session tracking | individual experiment directories plus session order/metadata |

`common.sh` is shared infrastructure and is **not** an experiment.

`run_all_safe.sh` is an aggregate runner and should not itself be included as a child of `run_randomized_repeats.sh`, because doing so would duplicate nested measurements.

The safe runner defaults to 60 s for each duration-based child (explicitly propagated), 5 s pauses and 100 latency requests; use short commands first when validating the harness.

Failed children remain in the session and later children still run. Detection and follow are deliberately excluded from the safe runner.

Endurance is resource+health monitoring; it does not add a stream or change application toggles.

---

## Existing Results: 2026-09-27

> **Important:** the following results are historical single-run measurements. They predate the four-repetition randomized methodology described above and must not be represented as results produced by that protocol.

The available historical datasets cover seven runs on **2026-09-27, 12:34:25–12:53:18 UTC** (14:34:25–14:53:18 local, UTC+02:00).

Metadata identifies a **Raspberry Pi 5 Model B Rev 1.0**, hostname `pametno-vozilo`, Debian GNU/Linux 13.7 (trixie), kernel `6.18.50+rpt-rpi-2712`, and `aarch64`.

Recorded host RAM totals 8,255,824 KiB (7.87 GiB); this is OS-visible memory, not confirmation of the physical RAM variant.

All HTTP measurements target `http://localhost:1607`.

### Resource measurements

These summaries are calculated from each linked `raw.csv`. CPU is the arithmetic mean of valid host-wide samples, excluding the initial `NA` in each phase; it is not time-weighted.

RAM ranges use KiB / 1024 to obtain MiB. Temperature and RAM ranges include all rows. Durations come from `metadata.txt`; sampling pauses were 5 seconds. Values are rounded to two decimal places.

| Experiment / phase | Recorded duration | Rows / valid CPU samples | Mean CPU (%) | RAM range (MiB) | Temperature range (°C) | Raw data |
|---|---|---|---|---|---|---|
| Baseline | 1 s | 2 / 1 | 7.01 | 895.13–914.86 | 51.25–52.35 | [CSV](logs/2026-09-27T12-34-25_system-baseline_sh9csT/raw.csv) |
| Stream | 30 s | 6 / 5 | 4.51 | 888.70–911.23 | 51.80–53.45 | [CSV](logs/2026-09-27T12-35-07_stream-stability_ypnEvM/raw.csv) |
| Idle | 30 s | 6 / 5 | 4.05 | 890.16–905.47 | 51.80–54.00 | [CSV](logs/2026-09-27T12-36-44_idle-stability_oT3wmx/raw.csv) |
| Endurance | 600 s | 118 / 117 | 4.14 | 879.28–906.58 | 52.90–58.95 | [CSV](logs/2026-09-27T12-38-24_endurance_uzFir9/raw.csv) |
| Detection off | 60 s phase | 12 / 11 | 4.08 | 882.39–914.38 | 55.65–59.50 | [CSV](logs/2026-09-27T12-49-56_detection-benchmark_j0ghsR/raw.csv) |
| Detection on | 60 s phase | 12 / 11 | 54.91 | 890.95–1063.44 | 59.50–73.80 | [CSV](logs/2026-09-27T12-49-56_detection-benchmark_j0ghsR/raw.csv) |
| Follow observation (follow off) | 60 s | 12 / 11 | 4.01 | 977.39–992.91 | 60.05–65.55 | [CSV](logs/2026-09-27T12-52-18_follow-observation_54EaI9/raw.csv) |

The detection run lasted 120 seconds overall.

Its [transition log](logs/2026-09-27T12-49-56_detection-benchmark_j0ghsR/transitions.log) records off, on, then restoration to the original off state; the final [health verification](logs/2026-09-27T12-49-56_detection-benchmark_j0ghsR/health-verify-3-false.json) records the restored state.

In this single sequential comparison, mean host CPU increased by 50.83 percentage points with detection enabled.

The fixed phase order, short duration and missing scene/cooling notes limit generalization.

Follow remained off in every resource sample, including the follow-observation run, so these data do not measure autonomous-follow performance.

### API latency and stream transport

The [API latency run](logs/2026-09-27T12-34-36_api-latency_x4KdUA/raw.csv) recorded **20 successful requests, zero failures**, with one-second pauses and 21 seconds total elapsed time.

Its [saved summary](logs/2026-09-27T12-34-36_api-latency_x4KdUA/summary.txt), converted from seconds to milliseconds, reports:

| Minimum | Mean | Median | p95 (nearest rank) | Maximum |
|---|---|---|---|---|
| 0.804 ms | 1.03545 ms | 1.038 ms | 1.175 ms | 1.336 ms |

These are loopback `/health` latencies, not Wi-Fi or inference latencies.

The [stream attempt](logs/2026-09-27T12-35-07_stream-stability_ypnEvM/stream.csv) received **15,500,462 bytes** with HTTP 200 over 30.000228 seconds, using one attempt and no reconnect attempts.

Curl exited with code 28 and outcome `deadline_or_stall_timeout`; [stderr](logs/2026-09-27T12-35-07_stream-stability_ypnEvM/errors.log) reports a timeout after 30,000 ms, consistent with the configured 30-second budget.

This establishes transport activity, not frame validity, FPS or uninterrupted frame delivery.

### Reliability and evidence gaps of the historical runs

- All 168 resource sample rows and all 20 API request rows recorded curl exit 0, HTTP 200 and valid health JSON. Camera and YOLO readiness were true in all resource sample rows. All seven run metadata files report collection exit code 0; this is not a benchmark pass criterion.
- The endurance run collected 118 samples over 600 seconds. Recorded service uptime increased from 525.8 to 1120.6 seconds without a sampled reset. Polling cannot exclude outages between samples, and ten minutes does not establish long-term stability or absence of memory leaks.
- `throttled_bits` was `0x0` through the detection-off phase, changed to `0x50000` at 12:51:01 UTC during detection-on, and remained `0x50000` throughout follow observation. Preserve this nonzero diagnostic in comparisons; the samples alone do not establish when an underlying event occurred or its cause.
- Docker socket access was denied in every historical run. Container identity, image digest, runtime YOLO environment, restart counts, container health and OOM state are therefore unavailable; Docker logs could not be collected. These runs cannot substantiate a claim of zero container restarts.
- Git metadata is `NA`: collection tried to inspect `/home/pi`, which was not a Git checkout. Backend source checksum attempts also failed because the expected files were absent there. The source revision cited in the architecture description does not identify the deployed image for these runs.
- No `operator-notes.md` accompanies these historical datasets. Camera model, power supply, cooling, ambient temperature, scene/lighting, other clients and physical motor-power isolation remain undocumented.
- These datasets are individual executions (`session_id=NA`) and were not randomized repeated measurements.

Retain the raw files and error logs when sharing these results. Source comments about 30 FPS, startup speed or memory stability are not measured results.

---

## Reproduction

### Prerequisites

Prerequisites:

- Bash 4+
- standard Linux utilities (`awk`, coreutils including `timeout`, procps)
- curl
- Python 3 standard library
- `shuf` for randomized repeated runs
- Docker CLI/daemon for container evidence
- `vcgencmd` for Raspberry Pi throttling diagnostics

The harness itself does not install missing utilities, alter Docker permissions, restart containers or change the application.

Run against an already deployed service.

For the Raspberry Pi deployment, **use `sudo` when running experiments** so the harness can inspect the Docker daemon and preserve container identity, restart state, health, OOM information and Docker logs.

Stop other controlling clients before controlled workload measurements.

Physically disconnect or otherwise isolate motor power before experiments that can change inference/control-related state.

### Verify the deployment first

From the standalone experiments checkout on the Pi:

```bash
cd ~/experiments

sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

The expected application container should be visible.

The harness performs the same container-table capture automatically and stores it with each run.

### Manual experiment runs

Run individual experiments with `sudo`:

```bash
cd ~/experiments

sudo bash system_baseline.sh

sudo bash api_latency.sh --requests 20 --interval 1

sudo bash idle_stability.sh --duration 30 --interval 5

sudo bash stream_stability.sh --duration 30 --interval 5

sudo bash endurance_test.sh --duration 600 --interval 5
```

If automatic discovery is ambiguous:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

sudo bash system_baseline.sh \
    --container YOUR_RUNNING_CONTAINER
```

Optional backend source checksums:

```bash
sudo bash system_baseline.sh \
    --container YOUR_RUNNING_CONTAINER \
    --source-dir ~/rpi-server
```

Docker running does not guarantee an unprivileged user can access its socket. For the intended Pi reproduction procedure, `sudo` is therefore used consistently.

A failed daemon check is reported separately from a missing or ambiguous container, and host/HTTP measurements can still continue with Docker fields marked `NA`.

Details are saved in `errors.log`; the harness itself never changes permissions.

Docker discovery always concerns the collector's Docker context, even with a remote HTTP URL, so verify the selected container in the startup output and retained metadata.

### Preferred four-repetition randomized session

Make the runner executable once:

```bash
chmod +x run_randomized_repeats.sh
```

Then run:

```bash
sudo ./run_randomized_repeats.sh
```

Default methodology:

```text
4 repetitions
×
7 experiment scripts
=
28 experiment executions
```

Each repetition receives a newly randomized experiment order.

The default cooldown is 60 seconds between experiment executions.

For a longer cooldown:

```bash
sudo COOLDOWN=120 ./run_randomized_repeats.sh
```

To explicitly select another repetition count:

```bash
sudo REPEATS=5 COOLDOWN=120 ./run_randomized_repeats.sh
```

For the standard reported protocol, retain `REPEATS=4`.

Do not manually rearrange or selectively repeat only favorable runs after observing their results. If a run fails or is invalidated by an external event, preserve it and document the reason.

The randomized runner stores session-level metadata and execution order under:

```text
logs/sessions/<SESSION_ID>/
```

Individual experiment outputs remain in the normal timestamped `logs/` directories and carry the shared session ID in their metadata.

### Safe grouped session

The existing safe grouped runner remains useful for short validation before a full repeated experiment:

```bash
sudo bash run_all_safe.sh \
    --duration 30 \
    --interval 1 \
    --requests 10
```

This runner intentionally excludes detection/follow state-changing experiments.

It is a harness/deployment check, not a substitute for the four-repetition randomized protocol.

### Detection experiment

Idle refuses to run unless detection and follow are already off; set those through the normal operator interface first.

Read-only scripts do not stop a vehicle already following or being remotely controlled.

For the controlled detection comparison, isolate motor power and other controlling clients first:

```bash
sudo bash detection_benchmark.sh \
    --duration 60 \
    --interval 5
```

The experiment verifies and restores detection state, but restoration is best effort and cannot survive SIGKILL, power loss or an unreachable API.

### Follow observation

The follow script is read-only and never enables autonomous following:

```bash
sudo bash follow_benchmark.sh \
    --duration 60 \
    --interval 5
```

This is an observation of current state, not a controlled follow-performance experiment.

### Longer endurance runs

After reviewing short-run evidence:

```bash
sudo DURATION=3600 INTERVAL=10 bash endurance_test.sh

sudo DURATION=14400 INTERVAL=30 bash endurance_test.sh
```

### Optional network latency test

Run on the Pi to retain Pi host metrics while changing the HTTP path:

```bash
sudo TARGET_HOST=pametno-vozilo.local \
    TARGET_PORT=1607 \
    bash api_latency.sh --requests 20
```

Loopback and network measurements must be reported separately.

### Environment settings

Supported settings include:

- `TARGET_HOST=localhost`
- `TARGET_PORT=1607`
- `TARGET_BASE_URL`
- `CONTAINER_NAME`
- `DURATION`
- `INTERVAL`
- `REQUESTS=100`
- `REQUEST_TIMEOUT=3`
- `STALL_TIMEOUT=15`
- `LOG_ROOT`
- `SESSION_ID`
- `SOURCE_DIR`
- randomized runner `REPEATS`
- randomized runner `COOLDOWN`

`TARGET_BASE_URL` overrides host/port.

CLI `--duration`, `--interval`, `--requests`, `--url`, `--container`, and `--source-dir` override corresponding experiment environment settings.

`--help` lists experiment options.

URL metadata is authoritative when host/port settings are overridden.

Avoid credentials in URLs because metadata records them verbatim.

---

## Output and Git handling

Every experiment prints timestamped live progress to stderr and saves it in `progress.log`.

This includes health/readiness flags, sampled CPU/RAM/temperature, throttling, container state, stream attempts, detection changes, warnings and final exit status.

Stdout continues to report result directories.

Raw application Docker logs are collected at exit in `docker.log` when Docker access is available.

Docker-aware runs can additionally contain:

```text
docker-info.txt
docker-ps.txt
container-selected.txt
container-discovery.json
container-start.json
container-end.json
docker.log
```

Duration-based phases show `remaining_s` once per second, including while probes are running.

Detection has a separate countdown for each phase.

This is the remaining collection budget; an in-flight probe, state restoration and final log capture can extend actual completion.

API tests display request progress and an estimated upper remaining time based on request timeouts and pauses; process overhead is excluded.

Baseline reports its fixed two-sample plan.

The safe session reports each child and its countdown rather than claiming an exact overall finish time.

The randomized runner additionally reports repetition, randomized position, global execution sequence, cooldowns and failures.

Names use UTC plus a random suffix to prevent collisions, including concurrent starts.

Runs never overwrite/delete previous data.

Outputs include `metadata.txt`, `raw.csv`, `system.log`, `errors.log`, `docker.log`, start/end container state JSON, health response files, Git status and source checksums.

Stream and detection add their own records; API latency generates its own statistical summary.

Disk space and log growth are the operator's responsibility. No binary video is stored.

`logs/.gitkeep` is tracked and logs are intentionally **not ignored**.

Review identifying hostnames, network details and server logs before publishing.

Commit selected **complete** datasets explicitly, for example:

```bash
git add logs/<run-directory>
```

For a randomized session, retain both the individual run directories and the associated session metadata/order records.

Document exclusions or invalid runs in research analysis rather than automatically selecting only successful runs.

`git_state=dirty` can include newly generated/untracked experiment logs; consult `git-status.txt` and source checksums.

Git SHA does not include uncommitted harness changes, so commit the harness before collecting publishable data.

---

## Evidence model

1. **Raw experimental evidence:** timestamped sample rows, health response bodies, curl attempt records, Docker/system/error logs, container identity/state records and randomized execution-order records. These contain observations and measurement errors, not interpretive conclusions. CPU percentage, used RAM and unit conversions are defined transformations of OS counters; the sampler does not preserve every kernel counter.

2. **Automatically calculated summaries:** API count/success/failure and min/max/arithmetic mean/median/p95 over valid responses only, in seconds. p95 uses nearest rank `ceil(0.95*n)`; an empty successful set produces `NA`. Summary errors leave raw data intact. Request failure counts must accompany latency statistics to avoid survivorship bias.

3. **Repeated-run analysis:** aggregate repeated measurements only after retaining individual observations and failed/invalid runs. State the number of repetitions and valid observations. Appropriate descriptive statistics can include mean, median, standard deviation, IQR and range depending on the metric. Four repetitions improve repeatability evidence over a single run but remain a small sample and do not justify population-level certainty.

4. **Interpretation/conclusions:** explain engineering/scientific significance in a results discussion, separate analysis document or paper. Link the raw dataset, session/order records and environmental notes, and disclose conditions/failed runs. Never insert conclusions into raw logs.

---

## Limitations

- Four repeated measurements provide substantially more information about run-to-run variability than one execution, but four remains a small sample.
- Randomizing experiment order reduces systematic ordering effects; it does not guarantee statistical independence.
- A fixed cooldown reduces but cannot guarantee elimination of thermal or state carryover.
- Environmental variables such as ambient temperature, case configuration, cooling, lighting and power conditions are not automatically measured unless explicitly instrumented.
- Detection still uses a fixed internal off→on comparison. Randomizing script order does not remove this within-experiment ordering limitation.
- No measured FPS, inference throughput, unique-frame count or frame freshness. Multipart bytes cannot establish FPS; annotated images may repeat. Loop sleeps are not achieved rates.
- `/health` can return 200 with camera/model unavailable. Camera readiness reflects initialization, not a guarantee every capture succeeded. Fallback imagery can still stream.
- Host-wide CPU/RAM include Docker, operating system, other clients and the harness itself. No per-container CPU/RAM or inference timing instrumentation is added. Sensor availability and permissions vary.
- Latency includes the chosen network path. Loopback latency does not represent Wi-Fi latency.
- Temperature depends on ambient conditions, cooling and previous workload.
- Follow cannot be safely enabled unattended with this API. Automatic GPIO failure fallback is neither a controllable dry-run facility nor proof that motors are disabled. No follow-on comparison or substitute benchmark is fabricated.
- Detection state can be changed by other clients between checks; restoration is best effort and cannot survive SIGKILL, power loss or an unreachable API. These are not atomic experimental controls. Record such runs as interrupted/invalid.
- Docker logs are bounded by the service's rotation, and sampled state cannot prove zero downtime.
- Container restart counters alone are not sufficient evidence of total service availability.
- This harness does not tune, restart or repair the system during measurement.
- `sudo` enables access needed for Docker evidence on the intended Pi deployment, but running the harness as root does not make the measurements intrinsically more accurate; its purpose here is consistent access to the local Docker context and required system interfaces.

---

## Safety

Baseline, idle, stream, API, endurance, follow observation and the safe runner issue only GETs and read-only local commands.

They cannot initiate motor motion but also cannot stop pre-existing motion.

They are suitable for unattended collection only after the operator has secured the vehicle and excluded other controllers.

Detection is an explicit API state-changing experiment.

Follow must be verified off, other controllers disconnected and motor power isolated before running it.

No experiment script calls `/control` or `/toggle_follow`, manipulates GPIO, or modifies the service.

Follow observation only records current software state and does not exercise autonomous steering.

Because `run_randomized_repeats.sh` can include `detection_benchmark.sh`, **secure the vehicle and isolate motor power before starting the entire randomized session**, not merely when the detection run happens. Its position is deliberately unpredictable.

---

## Harness validation (not benchmark evidence)

Check every shell script before a publishable session:

```bash
for script in *.sh; do
    bash -n "$script" || exit 1
done
```

If ShellCheck is installed:

```bash
shellcheck -x *.sh
```

Run the harness tests:

```bash
python3 tests/test_harness.py
```

The Python harness streams subprocess output immediately, labels each case and its elapsed time, checks console/persisted progress and countdown output, and identifies results by newly created directories.

It can be imported without starting tests.

Set `BASH_EXE` if Bash is not on PATH; the standard Git for Windows installation is also detected.

Cases time out after 50 seconds and terminate their process tree.

Temporary fixture results are created inside the workspace and removed after the run.

`python3 tests/test_harness.py` runs local HTTP and Docker **test fixtures** and failure-path checks in a temporary directory outside `logs/`.

Fixture data are never experimental evidence.

It does not launch production `main.py`, initialize GPIO, or require Pi hardware.

Before a real randomized session, also verify Docker access:

```bash
sudo docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Then perform a short baseline:

```bash
sudo bash system_baseline.sh
```

Inspect the resulting metadata, `docker-ps.txt`, `container-selected.txt`, raw samples and `errors.log` before committing to the full repeated protocol.

---

## Copyright and License

Copyright © 2026 Danilo Stoletović.

This experimental validation harness is licensed under the MIT License. See the repository's [`LICENSE`](LICENSE) file for the full license text.