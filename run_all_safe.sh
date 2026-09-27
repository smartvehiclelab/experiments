#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
init safe-session "$@"
export SESSION_ID=${SESSION_ID:-$(basename -- "$RUN_DIR")}
export LOG_ROOT="$RUN_DIR" TARGET_BASE_URL CONTAINER_NAME DURATION INTERVAL REQUEST_TIMEOUT REQUESTS STALL_TIMEOUT
printf 'session_id_assigned=%s\n' "$SESSION_ID" >> "$RUN_DIR/metadata.txt"
printf 'utc,script,exit_code\n' > "$RUN_DIR/children.csv"
failed=0
for script in system_baseline api_latency idle_stability stream_stability endurance_test; do
    rc=0
    log "Starting child=$script"
    bash "$EXP_DIR/$script.sh" &
    CHILD_PID=$!
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=''
    log "Completed child=$script exit_code=$rc"
    printf '%s,%s,%s\n' "$(utc)" "$script" "$rc" >> "$RUN_DIR/children.csv"
    if ((rc != 0)); then failed=1; fi
done
exit "$failed"
