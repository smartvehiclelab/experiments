#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
DURATION=${DURATION:-1}
init system-baseline "$@"
printf 'duration_scope=fixed two samples with one-second pause; DURATION unused\n' >> "$RUN_DIR/metadata.txt"
init_samples
log 'Baseline: two samples with a one-second pause; completion depends on probe time'
sample baseline
sleep 1
sample baseline
