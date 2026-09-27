#!/usr/bin/env bash
# Shared collection helpers. Source from an experiment entry point.
set -Eeuo pipefail
export LC_ALL=C
EXP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$EXP_DIR/.." && pwd)

utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() {
    local line
    line="$(utc) [$NAME] $*"
    printf '%s\n' "$line" >> "$RUN_DIR/progress.log"
    printf '%s\n' "$line" >&2
}
error() { printf '%s %s\n' "$(utc)" "$*" >> "$RUN_DIR/errors.log"; log "WARNING $*"; }

# The countdown is a collection budget, not a promise about cleanup time.
start_timer() {
    stop_timer
    local label=$1 budget=$2
    log "$label remaining_s=$budget (collection budget; cleanup follows)"
    (
        trap 'exit 0' TERM INT
        local deadline=$((SECONDS+budget)) remaining
        while ((SECONDS < deadline)); do
            sleep 1
            remaining=$((deadline-SECONDS))
            ((remaining >= 0)) || remaining=0
            log "$label remaining_s=$remaining"
        done
    ) &
    TIMER_PID=$!
}
stop_timer() {
    if [[ -n ${TIMER_PID:-} ]]; then
        kill "$TIMER_PID" 2>/dev/null || true
        wait "$TIMER_PID" 2>/dev/null || true
        TIMER_PID=''
    fi
}
capture() {
    local value
    if value=$("$@" 2>> "$RUN_DIR/errors.log") && [[ -n $value ]]; then
        printf '%s\n' "$value"
    else
        error "unavailable: $*"
        printf 'NA\n'
    fi
}
positive() { [[ $2 =~ ^[1-9][0-9]*$ ]] || { printf '%s must be a positive integer\n' "$1" >&2; exit 2; }; }

init() {
    NAME=$1; shift
    DURATION=${DURATION:-60}; INTERVAL=${INTERVAL:-5}
    TARGET_HOST=${TARGET_HOST:-localhost}; TARGET_PORT=${TARGET_PORT:-1607}
    CONTAINER_NAME=${CONTAINER_NAME:-rpi_stream_server}
    REQUEST_TIMEOUT=${REQUEST_TIMEOUT:-3}; REQUESTS=${REQUESTS:-100}
    STALL_TIMEOUT=${STALL_TIMEOUT:-15}
    while (($#)); do
        case $1 in
            --duration|--interval|--url|--container|--requests)
                (($# >= 2)) || { echo "Missing value for $1" >&2; exit 2; }
                case $1 in
                    --duration) DURATION=$2;; --interval) INTERVAL=$2;;
                    --url) TARGET_BASE_URL=$2;; --container) CONTAINER_NAME=$2;;
                    --requests) REQUESTS=$2;;
                esac; shift 2;;
            --help)
                echo 'Options: --duration SECONDS --interval SECONDS --url URL --container NAME --requests COUNT'
                echo 'Environment: TARGET_HOST TARGET_PORT TARGET_BASE_URL DURATION INTERVAL CONTAINER_NAME REQUEST_TIMEOUT REQUESTS STALL_TIMEOUT LOG_ROOT SESSION_ID'
                exit 0;;
            *) echo "Unknown option: $1" >&2; exit 2;;
        esac
    done
    positive DURATION "$DURATION"; positive INTERVAL "$INTERVAL"
    positive REQUEST_TIMEOUT "$REQUEST_TIMEOUT"; positive REQUESTS "$REQUESTS"
    positive STALL_TIMEOUT "$STALL_TIMEOUT"
    TARGET_BASE_URL=${TARGET_BASE_URL:-http://$TARGET_HOST:$TARGET_PORT}
    TARGET_BASE_URL=${TARGET_BASE_URL%/}
    [[ $TARGET_BASE_URL =~ ^https?://[^[:space:]]+$ ]] || { echo 'Invalid HTTP URL' >&2; exit 2; }
    for cmd in curl python3 awk date mktemp timeout; do
        command -v "$cmd" >/dev/null || { echo "Required command missing: $cmd" >&2; exit 2; }
    done
    mkdir -p -- "${LOG_ROOT:-$EXP_DIR/logs}"
    RUN_DIR=$(mktemp -d "${LOG_ROOT:-$EXP_DIR/logs}/$(date -u +%Y-%m-%dT%H-%M-%S)_${NAME}_XXXXXX")
    export RUN_DIR
    : > "$RUN_DIR/errors.log"
    : > "$RUN_DIR/progress.log"
    START_UTC=$(utc); START_SECONDS=$SECONDS
    STREAM_PID=''; CHILD_PID=''; RESTORE_DETECTION=''; TRANSITION=0
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    log "Starting target=$TARGET_BASE_URL results=$RUN_DIR; collecting metadata"
    metadata
    printf '%s\n' "$RUN_DIR"
}

metadata() {
    local dirty
    dirty=NA
    if git -C "$REPO_DIR" status --porcelain --untracked-files=normal > "$RUN_DIR/git-status.txt" 2>> "$RUN_DIR/errors.log"; then
        dirty=clean; [[ ! -s $RUN_DIR/git-status.txt ]] || dirty=dirty
    fi
    {
        printf 'experiment=%s\nstart_utc=%s\nstart_local=%s\nsession_id=%s\n' "$NAME" "$START_UTC" "$(date -Iseconds)" "${SESSION_ID:-NA}"
        printf 'duration_requested_s=%s\ninterval_s=%s\nrequests=%s\nrequest_timeout_s=%s\nstall_timeout_s=%s\n' "$DURATION" "$INTERVAL" "$REQUESTS" "$REQUEST_TIMEOUT" "$STALL_TIMEOUT"
        printf 'target_host_setting=%s\ntarget_port_setting=%s\ntarget_base_url=%s\ncontainer_name=%s\n' "$TARGET_HOST" "$TARGET_PORT" "$TARGET_BASE_URL" "$CONTAINER_NAME"
        printf 'metrics_scope=local collector host and local Docker context; HTTP target may differ\n'
        printf 'hostname=%s\nkernel=%s\narchitecture=%s\n' "$(capture hostname)" "$(capture uname -sr)" "$(capture uname -m)"
        printf 'os=%s\n' "$(capture cat /etc/os-release)"
        printf 'pi_model=%s\n' "$(capture sh -c 'tr -d "\000" < /proc/device-tree/model')"
        printf 'git_remote=%s\ngit_commit=%s\ngit_branch=%s\ngit_state=%s\n' "$(capture git -C "$REPO_DIR" remote get-url origin)" "$(capture git -C "$REPO_DIR" rev-parse HEAD)" "$(capture git -C "$REPO_DIR" branch --show-current)" "$dirty"
        printf 'docker_version=%s\ndocker_context=%s\n' "$(capture timeout 5 docker --version)" "$(capture timeout 5 docker context show)"
        printf 'container_identity=%s\n' "$(capture timeout 5 docker inspect --format '{{.Id}} image_ref={{.Config.Image}} image_id={{.Image}}' "$CONTAINER_NAME")"
        printf 'image_digests=%s\n' "$(capture timeout 5 docker image inspect --format '{{json .RepoDigests}}' "$(capture timeout 5 docker inspect --format '{{.Image}}' "$CONTAINER_NAME")")"
        printf 'runtime_yolo_env=%s\n' "$(capture sh -c 'timeout 5 docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$1" | grep "^YOLO_"' sh "$CONTAINER_NAME")"
        printf 'camera_runtime_configuration=NA (not exposed by API)\n'
    } > "$RUN_DIR/metadata.txt"
    for file in main.py Dockerfile docker-compose.yml requirements.txt; do
        capture sha256sum "$REPO_DIR/$file" >> "$RUN_DIR/source-sha256.txt"
    done
    capture sha256sum "$EXP_DIR"/*.sh >> "$RUN_DIR/source-sha256.txt"
    {
        capture uptime
        capture df -Pk "$REPO_DIR"
        capture ps -eo pid,ppid,comm,pcpu,pmem
    } > "$RUN_DIR/system.log"
    capture timeout 5 docker inspect --format '{{json .State}}' "$CONTAINER_NAME" > "$RUN_DIR/container-start.json"
}

# Every response is retained, including error responses and invalid JSON.
health() {
    local tag=$1 result rc=0
    result=$(curl --silent --show-error --noproxy '*' --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
        --output "$RUN_DIR/health-$tag.json" --write-out '%{http_code},%{time_total}' \
        "$TARGET_BASE_URL/health" 2>> "$RUN_DIR/errors.log") || rc=$?
    HTTP_RC=$rc; HTTP_CODE=${result%%,*}; HTTP_TIME=${result#*,}
    HTTP_TRANSFER_TIME=${HTTP_TIME:-NA}
    HEALTH_FIELDS=NA,NA,NA,NA,NA,NA
    HTTP_OK=false
    if [[ $rc == 0 && $HTTP_CODE == 200 ]]; then
        if HEALTH_FIELDS=$(python3 - "$RUN_DIR/health-$tag.json" 2>> "$RUN_DIR/errors.log" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
keys = ['camera_active','yolo_active','yolo_loading','detection_enabled','follow_enabled']
assert d.get('status') == 'ok'
assert all(type(d.get(k)) is bool for k in keys)
assert type(d.get('uptime_seconds')) in (int, float)
print(','.join(str(d[k]).lower() for k in keys) + ',' + str(d['uptime_seconds']))
PY
        ); then HTTP_OK=true
        else HEALTH_FIELDS=NA,NA,NA,NA,NA,NA; error "health $tag invalid schema"; fi
    fi
    if [[ $HTTP_OK != true ]]; then error "health $tag curl_exit=$rc http=$HTTP_CODE"; fi
    [[ -n $HTTP_CODE ]] || HTTP_CODE=NA
    [[ $HTTP_OK == true ]] || HTTP_TIME=NA
    IFS=, read -r CAMERA YOLO LOADING DETECTION FOLLOW SERVICE_UPTIME <<< "$HEALTH_FIELDS"
    log "health=$tag http=$HTTP_CODE valid=$HTTP_OK latency_s=$HTTP_TIME camera=$CAMERA yolo=$YOLO detection=$DETECTION follow=$FOLLOW"
}

init_samples() {
    printf '%s\n' 'utc,elapsed_s,phase,cpu_busy_pct,ram_used_kib,ram_total_kib,temp_c,cpu_freq_khz,load1,load5,load15,uptime_s,throttled_bits,curl_exit,http_code,health_valid,health_latency_s,camera_active,yolo_active,yolo_loading,detection_enabled,follow_enabled,service_uptime_s,container_id,container_state,container_health,restart_count,container_started_at,oom_killed' > "$RUN_DIR/raw.csv"
    PREV_TOTAL=''; PREV_IDLE=''; SAMPLE=0
    PREV_CONTAINER=''; PREV_RESTART=''; PREV_STARTED=''
}

sample() {
    local phase=$1 cpu=NA total idle mem=NA,NA temp freq load up throttle docker_fields
    SAMPLE=$((SAMPLE + 1))
    if [[ -r /proc/stat ]]; then
        read -r total idle < <(awk '/^cpu / {s=0; for(i=2;i<=9;i++)s+=$i; print s,$5+$6; exit}' /proc/stat)
        if [[ -n $PREV_TOTAL ]] && ((total > PREV_TOTAL)); then
            cpu=$(awk -v t="$((total-PREV_TOTAL))" -v i="$((idle-PREV_IDLE))" 'BEGIN {printf "%.3f",100*(t-i)/t}')
        fi
        PREV_TOTAL=$total; PREV_IDLE=$idle
    else error '/proc/stat unavailable'; fi
    if [[ -r /proc/meminfo ]]; then
        mem=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2; found=1} END {if(t && found) print t-a "," t; else print "NA,NA"}' /proc/meminfo)
    else error '/proc/meminfo unavailable'; fi
    temp=$(capture cat /sys/class/thermal/thermal_zone0/temp)
    [[ $temp == NA ]] || temp=$(awk -v t="$temp" 'BEGIN {print t/1000}')
    freq=$(capture cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)
    load=$(capture awk '{print $1 "," $2 "," $3}' /proc/loadavg)
    [[ $load != NA ]] || load=NA,NA,NA
    up=$(capture awk '{print $1}' /proc/uptime)
    throttle=$(capture vcgencmd get_throttled)
    throttle=${throttle#throttled=}
    health "$SAMPLE"
    docker_fields=$(capture timeout 5 docker inspect --format '{{.Id}},{{.State.Status}},{{if .State.Health}}{{.State.Health.Status}}{{else}}NA{{end}},{{.RestartCount}},{{.State.StartedAt}},{{.State.OOMKilled}}' "$CONTAINER_NAME")
    [[ $docker_fields != NA ]] || docker_fields=NA,NA,NA,NA,NA,NA
    local cid cstate chealth restarts started oom
    IFS=, read -r cid cstate chealth restarts started oom <<< "$docker_fields"
    if [[ -n $PREV_CONTAINER && $cid != NA && $PREV_CONTAINER != NA ]] && \
       [[ $cid != "$PREV_CONTAINER" || $restarts != "$PREV_RESTART" || $started != "$PREV_STARTED" ]]; then
        error "container transition old=$PREV_CONTAINER/$PREV_RESTART/$PREV_STARTED new=$cid/$restarts/$started"
    fi
    PREV_CONTAINER=$cid; PREV_RESTART=$restarts; PREV_STARTED=$started
    [[ $cstate == running && ( $chealth == healthy || $chealth == NA ) ]] || error "container state=$cstate health=$chealth"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(utc)" "$((SECONDS-START_SECONDS))" "$phase" "$cpu" "$mem" "$temp" "$freq" "$load" "$up" "$throttle" \
        "$HTTP_RC" "$HTTP_CODE" "$HTTP_OK" "$HTTP_TIME" "$HEALTH_FIELDS,$docker_fields" >> "$RUN_DIR/raw.csv"
    log "phase=$phase sample=$SAMPLE cpu_pct=$cpu ram_used_total_kib=$mem temp_c=$temp throttled=$throttle container=$cstate restarts=$restarts"
}

collect() {
    local phase=$1 end=$((SECONDS+DURATION)) remaining
    start_timer "phase=$phase" "$DURATION"
    while ((SECONDS < end)); do
        sample "$phase"
        if [[ $NAME == idle-stability ]] && [[ $HTTP_OK != true || $FOLLOW != false || $DETECTION != false ]]; then
            error 'Idle phase invalidated by failed health or changed toggles'; return 1
        fi
        if [[ $NAME == detection-benchmark ]] && \
           [[ $HTTP_OK != true || $FOLLOW != false || $CAMERA != true || $YOLO != true || $DETECTION != "$EXPECTED_DETECTION" ]]; then
            error "phase $phase invalidated by service/state change"; return 1
        fi
        remaining=$((end-SECONDS))
        ((remaining > 0)) || break
        ((remaining <= INTERVAL)) || remaining=$INTERVAL
        sleep "$remaining"
    done
    stop_timer
    log "phase=$phase remaining_s=0 collection complete"
}

set_detection() {
    local enabled=$1 rc=0 code
    log "Setting detection=$enabled"
    TRANSITION=$((TRANSITION+1))
    code=$(curl --silent --show-error --noproxy '*' --connect-timeout "$REQUEST_TIMEOUT" --max-time "$REQUEST_TIMEOUT" \
        -H 'Content-Type: application/json' --data "{\"enable\":$enabled}" \
        -o "$RUN_DIR/detection-$TRANSITION-$enabled.json" -w '%{http_code}' \
        "$TARGET_BASE_URL/toggle_detection" 2>> "$RUN_DIR/errors.log") || rc=$?
    printf '%s detection_requested=%s curl_exit=%s http=%s\n' "$(utc)" "$enabled" "$rc" "$code" >> "$RUN_DIR/transitions.log"
    [[ $rc == 0 && $code == 200 ]] || { error 'detection write failed'; return 1; }
    health "verify-$TRANSITION-$enabled"
    [[ $HTTP_OK == true && $DETECTION == "$enabled" ]] || { error 'detection read-back failed'; return 1; }
}

stream() {
    local end=$((SECONDS+DURATION)) attempt=0 remaining rc result outcome
    trap '[[ -z ${CURL_PID:-} ]] || kill "$CURL_PID" 2>/dev/null; wait 2>/dev/null || true; exit 143' TERM INT
    printf 'utc,attempt,budget_s,curl_exit,http_code,elapsed_s,bytes_received,outcome\n' > "$RUN_DIR/stream.csv"
    while ((SECONDS < end)); do
        attempt=$((attempt+1)); remaining=$((end-SECONDS)); rc=0
        log "stream attempt=$attempt started budget_s=$remaining"
        curl --silent --show-error --noproxy '*' --connect-timeout "$REQUEST_TIMEOUT" --max-time "$remaining" \
            --speed-limit 1 --speed-time "$STALL_TIMEOUT" --output /dev/null \
            --write-out '%{http_code},%{time_total},%{size_download}' \
            "$TARGET_BASE_URL/video_feed" > "$RUN_DIR/stream-attempt-$attempt.txt" 2>> "$RUN_DIR/errors.log" &
        CURL_PID=$!
        wait "$CURL_PID" || rc=$?
        CURL_PID=''
        result=$(cat "$RUN_DIR/stream-attempt-$attempt.txt")
        [[ -n $result ]] || result=NA,NA,NA
        outcome=interrupted_or_closed
        # Timeout code 28 also denotes a low-speed timeout. Do not equate it with success.
        if ((SECONDS >= end)) && [[ $rc == 28 ]]; then outcome=deadline_or_stall_timeout; fi
        printf '%s,%s,%s,%s,%s,%s\n' "$(utc)" "$attempt" "$remaining" "$rc" "$result" "$outcome" >> "$RUN_DIR/stream.csv"
        log "stream attempt=$attempt curl_exit=$rc http_elapsed_bytes=$result outcome=$outcome"
        [[ $outcome != interrupted_or_closed ]] || error "stream attempt=$attempt curl_exit=$rc result=$result"
        ((SECONDS >= end)) || sleep 1
    done
}

finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    stop_timer
    log 'Finalizing: stopping workers, restoring state and collecting Docker logs'
    if [[ -n $CHILD_PID ]]; then kill "$CHILD_PID" 2>/dev/null; wait "$CHILD_PID"; fi
    if [[ -n $STREAM_PID ]]; then kill "$STREAM_PID" 2>/dev/null; wait "$STREAM_PID"; fi
    if [[ -n $RESTORE_DETECTION ]]; then
        set_detection "$RESTORE_DETECTION" || { error 'RESTORATION FAILED: inspect detection state manually'; rc=1; }
    fi
    timeout 10 docker logs --timestamps --since "$START_UTC" "$CONTAINER_NAME" > "$RUN_DIR/docker.log" 2>> "$RUN_DIR/errors.log"
    [[ $? == 0 ]] || error 'Docker logs unavailable or incomplete (timeout/permissions/container missing)'
    capture timeout 5 docker inspect --format '{{json .State}}' "$CONTAINER_NAME" > "$RUN_DIR/container-end.json"
    printf 'end_utc=%s\nend_local=%s\nelapsed_s=%s\nexit_code=%s\n' "$(utc)" "$(date -Iseconds)" "$((SECONDS-START_SECONDS))" "$rc" >> "$RUN_DIR/metadata.txt"
    [[ $rc == 0 ]] || error "experiment exited with code $rc; partial evidence retained"
    log "Finished exit_code=$rc elapsed_s=$((SECONDS-START_SECONDS)) results=$RUN_DIR"
    exit "$rc"
}
