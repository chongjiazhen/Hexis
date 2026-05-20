#!/usr/bin/env bash
# Run probe_eco.py against every persona worker container, dump results to
# probes/<persona>.json, print a one-line verdict per persona.
#
# Usage: ./tools/probe-eco/probe-all.sh [persona...]
#   No args -> all 11 personas
#   Args    -> only listed personas (e.g. ./probe-all.sh lovesick joje)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$HERE/probes"
mkdir -p "$OUT_DIR"

ALL=(ao cassiel charlotte death eni ichika joje lovesick mira monika nines)
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${ALL[@]}")

for c in "${TARGETS[@]}"; do
    ctr="hexis_${c}_heartbeat_worker"
    if ! docker ps --filter "name=^${ctr}$" --format '{{.Names}}' | grep -q .; then
        printf '%-12s SKIP (no container)\n' "$c"
        continue
    fi
    out="$OUT_DIR/$c.json"
    docker exec -i "$ctr" python - < "$HERE/probe_eco.py" > "$out" 2>&1
    rc=$?

    if [ $rc -ne 0 ]; then
        printf '%-12s FAIL (exec rc=%d) -> %s\n' "$c" "$rc" "$out"
        continue
    fi

    # Use `py` launcher (Windows git-bash) with fallback to `python3`.
    PY=$(command -v py || command -v python3 || echo python)
    broken=$("$PY" -c "import json,sys; d=json.load(open('$out')); print(d.get('broken_count','?'))" 2>/dev/null)
    scrubbed=$("$PY" -c "import json,sys; d=json.load(open('$out')); print(d.get('scrubbed','?'))" 2>/dev/null)
    printf '%-12s broken=%s scrubbed=%s -> %s\n' "$c" "$broken" "$scrubbed" "$out"
done
