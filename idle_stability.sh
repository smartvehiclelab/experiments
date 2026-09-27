#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
DURATION=${DURATION:-300}
init idle-stability "$@"
init_samples
health preflight
[[ $HTTP_OK == true && $FOLLOW == false && $DETECTION == false ]] || { error 'Idle requires verified detection=false and follow=false; no state changed'; exit 1; }
collect observed_idle
