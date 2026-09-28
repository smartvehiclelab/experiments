#!/usr/bin/env bash
set -u

CONTAINER="${1:?Usage: $0 <container-name-or-id> [output-directory]}"
LOG_DIR="${2:-.}"

mkdir -p -- "$LOG_DIR" || exit 1
LOG_FILE="$LOG_DIR/docker-check-$(date +%Y%m%d-%H%M%S).log"

{
    printf '=== Docker check started: %s ===\n' "$(date -Is)"

    printf '\n=== Docker systemd service status ===\n'
    systemctl status docker.service --no-pager --full

    printf '\n=== Container inspect: %s ===\n' "$CONTAINER"
    docker inspect "$CONTAINER"

    printf '\n=== Container logs: %s ===\n' "$CONTAINER"
    printf 'Including last 200 lines, then following live output.\n\n'

    docker logs \
        --timestamps \
        --tail 200 \
        --follow \
        "$CONTAINER"

} 2>&1 | tee "$LOG_FILE"

printf '\nSaved to: %s\n' "$LOG_FILE"