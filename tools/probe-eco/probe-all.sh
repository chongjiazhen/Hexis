#!/usr/bin/env bash
# Run probe_eco.py against every persona worker container for ONE model tier.
# Dumps results to probes/<label>/<persona>.json and records peak GPU VRAM
# (host-side, sampled during the sweep) to probes/<label>/_vram.txt.
#
# Usage: ./tools/probe-eco/probe-all.sh --model <label> [persona...]
#   --model <label>  REQUIRED. Tier label, e.g. 1b | 3b | 4b | 7b.
#   No persona args -> all 11 personas.
#
# Serving is NOT managed here. Re-arm ActiveBig to the tier you want
# (set-power-mode.ps1 eco -> prime), confirm with hexis-status.ps1, THEN run.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"

MODEL_LABEL=""
if [ "${1:-}" = "--model" ]; then
    MODEL_LABEL="${2:-}"
    shift 2
fi
if [ -z "$MODEL_LABEL" ]; then
    echo "ERROR: --model <label> is required (e.g. --model 4b)" >&2
    exit 1
fi
if ! printf '%s' "$MODEL_LABEL" | grep -Eq '^[A-Za-z0-9_.-]+$'; then
    echo "ERROR: --model label must match [A-Za-z0-9_.-]+ (got: '$MODEL_LABEL')" >&2
    exit 1
fi

OUT_DIR="$HERE/probes/$MODEL_LABEL"
mkdir -p "$OUT_DIR"
VRAM_FILE="$OUT_DIR/_vram.txt"

ALL=(ao cassiel charlotte death eni ichika joje lovesick mira monika nines)
TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${ALL[@]}")

# Background peak-VRAM sampler (MiB). Writes the running max every 2s.
echo 0 > "$VRAM_FILE"
(
    peak=0
    while :; do
        u=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        if [ -n "$u" ] && [ "$u" -gt "$peak" ] 2>/dev/null; then
            peak=$u
            echo "$peak" > "$VRAM_FILE"
        fi
        sleep 2
    done
) &
SAMPLER_PID=$!
trap 'kill "$SAMPLER_PID" 2>/dev/null' EXIT

for c in "${TARGETS[@]}"; do
    ctr="hexis_${c}_heartbeat_worker"
    if ! docker ps --filter "name=^${ctr}$" --format '{{.Names}}' | grep -q .; then
        printf '%-12s SKIP (no container)\n' "$c"
        continue
    fi
    out="$OUT_DIR/$c.json"
    docker exec -e "PROBE_MODEL_LABEL=$MODEL_LABEL" -i "$ctr" python - < "$HERE/probe_eco.py" > "$out" 2>&1
    rc=$?

    if [ $rc -ne 0 ]; then
        printf '%-12s FAIL (exec rc=%d) -> %s\n' "$c" "$rc" "$out"
        continue
    fi

    PY=$(command -v py || command -v python3 || echo python)
    broken=$("$PY" -c "import json,sys; d=json.load(open('$out')); print(d.get('broken_count','?'))" 2>/dev/null)
    scrubbed=$("$PY" -c "import json,sys; d=json.load(open('$out')); print(d.get('scrubbed','?'))" 2>/dev/null)
    printf '%-12s broken=%s scrubbed=%s -> %s\n' "$c" "$broken" "$scrubbed" "$out"
done

trap - EXIT
kill "$SAMPLER_PID" 2>/dev/null
echo "peak VRAM (MiB): $(cat "$VRAM_FILE")  [$MODEL_LABEL]"
