#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
init follow-observation "$@"
printf 'mode=read-only observation; no follow comparison or motor writes\n' >> "$RUN_DIR/metadata.txt"
init_samples
collect observed_state
