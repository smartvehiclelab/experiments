#!/usr/bin/env bash
set -u

CONTAINER="${1:?Usage: $0 <container-name-or-id> [output-directory]}"
LOG_DIR="${2:-.}"

mkdir -p -- "$LOG_DIR" || exit 1
LOG_FILE="$LOG_DIR/docker-check-$(date +%Y%m%d-%H%M%S).log"

{
    printf '=== Docker check: %s ===\n' "$(date -Is)"

    printf '\n=== Docker systemd service status ===\n'
    systemctl status docker.service --no-pager --full

    printf '\n=== Container logs: %s (last 200 lines) ===\n' "$CONTAINER"
    docker logs --timestamps --tail 200 "$CONTAINER"
} > "$LOG_FILE" 2>&1

printf 'Saved to: %s\n' "$LOG_FILE"