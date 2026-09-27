#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
INTERVAL=${INTERVAL:-1}
init api-latency "$@"
printf 'duration_scope=request count; DURATION unused\n' >> "$RUN_DIR/metadata.txt"
printf 'utc,request,curl_exit,http_code,health_valid,latency_s,transfer_elapsed_s\n' > "$RUN_DIR/raw.csv"
for ((i=1; i<=REQUESTS; i++)); do
    health "$i"
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$(utc)" "$i" "$HTTP_RC" "$HTTP_CODE" "$HTTP_OK" "$HTTP_TIME" "$HTTP_TRANSFER_TIME" >> "$RUN_DIR/raw.csv"
    ((i == REQUESTS)) || sleep "$INTERVAL"
done
# Summary failure must never destroy or rewrite raw evidence.
if ! python3 - "$RUN_DIR/raw.csv" > "$RUN_DIR/summary.txt" 2>> "$RUN_DIR/errors.log" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1], newline='')))
values = sorted(float(r['latency_s']) for r in rows if r['health_valid'] == 'true')
print('Derived statistics; valid HTTP 200 health JSON responses only; units: seconds')
print(f'requests={len(rows)}\nsuccessful={len(values)}\nfailed={len(rows)-len(values)}')
for k, v in [('min', min(values) if values else 'NA'), ('max', max(values) if values else 'NA'),
             ('mean', statistics.mean(values) if values else 'NA'),
             ('median', statistics.median(values) if values else 'NA'),
             ('p95_nearest_rank', values[math.ceil(.95*len(values))-1] if values else 'NA')]:
    print(f'{k}_s={v}')
PY
then error 'Summary generation failed; raw.csv retained'; exit 1; fi
