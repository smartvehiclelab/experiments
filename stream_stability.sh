#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
init stream-stability "$@"
init_samples
stream &
STREAM_PID=$!
collect streaming
wait "$STREAM_PID"
STREAM_PID=''
