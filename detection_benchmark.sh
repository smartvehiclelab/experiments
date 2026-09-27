#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
init detection-benchmark "$@"
init_samples
health preflight
[[ $HTTP_OK == true && $FOLLOW == false && $CAMERA == true && $YOLO == true && $LOADING == false ]] || { error 'Requires ready camera/model and follow=false; no state changed'; exit 1; }
RESTORE_DETECTION=$DETECTION
printf 'duration_scope=per phase\noriginal_detection=%s\n' "$RESTORE_DETECTION" >> "$RUN_DIR/metadata.txt"
for enabled in false true; do
    set_detection "$enabled"
    EXPECTED_DETECTION=$enabled
    # Reset counters so no CPU sample spans a phase boundary.
    PREV_TOTAL=''; PREV_IDLE=''
    collect "detection_$enabled"
done
