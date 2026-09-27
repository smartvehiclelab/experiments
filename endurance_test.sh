#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
DURATION=${DURATION:-600}
init endurance "$@"
init_samples
collect observed_state
