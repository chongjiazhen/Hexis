# Model-Tier Probe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the ECO probe so it brackets multiple model sizes and produces a scored persona × model matrix (with measured peak VRAM) that confirms or moves the 8GB Companion-SKU floor.

**Architecture:** `probe_eco.py` runs inside each persona worker container (piped via `docker exec`), so it stays self-contained — it only gains a model-label stamp and a higher reply cap. All scoring moves host-side into a new importable `probe_score.py` (shared by the aggregator and its tests). `probe-all.sh` gains a `--model <label>` arg, writes per-model output dirs, and samples peak GPU VRAM host-side during the sweep. A new `aggregate.py` reads every per-model/per-persona JSON dump and emits a markdown matrix.

**Tech Stack:** Python 3.10 (repo venv), asyncpg, bash (git-bash on Windows), `docker exec`, `nvidia-smi`, pytest.

**Serving note (operator, not automated):** the probe does NOT manage the LLM server. Per CLAUDE.md, `:8080` is owned by `set-power-mode.ps1`. To probe model tier X the operator re-arms `ActiveBig` to a tier-X key (`power-profiles.psd1` → `set-power-mode.ps1 eco` → `prime`) and confirms with `hexis-status.ps1`, THEN runs `probe-all.sh --model <label>`. Auto-serving is an explicit YAGNI cut.

---

## File Structure

- Create: `tools/probe-eco/probe_score.py` — failure-class markers + `classify()`. No heavy imports; host-side only; importable.
- Modify: `tools/probe-eco/probe_eco.py` — stamp `model_label` from env; raise reply cap 800 → 4000.
- Modify: `tools/probe-eco/probe-all.sh` — `--model <label>` arg; per-model output dir; background `nvidia-smi` peak sampler.
- Create: `tools/probe-eco/aggregate.py` — read `probes/<label>/*.json`, emit markdown matrix.
- Create: `tests/probe_eco/test_probe_score.py` — unit tests for `classify()`.

---

## Task 1: Host-side scoring module

**Files:**
- Create: `tools/probe-eco/probe_score.py`

- [ ] **Step 1: Write the failing test**

Create `tests/probe_eco/test_probe_score.py`:

```python
import sys
from pathlib import Path

# probe-eco dir has a hyphen -> not a package; add it to sys.path to import.
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "probe-eco"))

from probe_score import FAILURE_CLASSES, classify


def test_clean_reply_has_no_failure_classes():
    assert classify("Hey, my day's been good. Quiet morning, lots of tea.") == {}


def test_prompt_template_leak_flagged_as_leak():
    reply = "[USER MESSAGE] tell me about yourself\n## Identity\ntrust: 0.8"
    result = classify(reply)
    assert "leak" in result
    assert "[USER MESSAGE]" in result["leak"]


def test_repl_confusion_flagged_as_repl():
    result = classify("Repl> print(context variable)")
    assert "repl" in result


def test_generic_assistant_drift_flagged_as_generic():
    result = classify("As an AI, I'm not a human AI assistant.")
    assert "generic" in result


def test_failure_classes_is_the_canonical_list():
    assert FAILURE_CLASSES == ["leak", "echo", "repl", "generic"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\venv\Scripts\Activate.ps1; pytest tests/probe_eco/test_probe_score.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'probe_score'`

- [ ] **Step 3: Write minimal implementation**

Create `tools/probe-eco/probe_score.py`:

```python
# probe_score.py - host-side reply scoring for the model-tier probe.
#
# Pure functions, no heavy imports. Imported by aggregate.py and the unit
# tests. NOT importable from probe_eco.py (that file is piped into a container
# via `docker exec python - < probe_eco.py` and has no filesystem siblings).

FAILURE_CLASSES = ["leak", "echo", "repl", "generic"]

# Markers grouped by failure class. Substring match against the reply text.
# Refine as new failure modes are observed across tiers.
MARKERS: dict[str, list[str]] = {
    # Prompt-context leakage (model regurgitating its structured prompt).
    "leak": [
        "[USER MESSAGE]",
        "[ASSISTANT MESSAGE]",
        "(score:",
        "## Identity",
        "## Memory",
        "trust: 0.",
        "source: conversation_turn",
        "source: internal",
    ],
    # Echo loops.
    "echo": [
        'echo "',
    ],
    # Role confusion - model thinks it is a code REPL or shell.
    "repl": [
        "Repl>",
        "REPL)",
        "(REPL",
        "print(context",
        "Print(context",
        "context variable",
    ],
    # Generic-assistant tells (off-persona drift).
    "generic": [
        "I'm an AI",
        "I am an AI",
        "I'm not a human AI",
        "Based on context, it appears",
        "Without additional information",
        "As an AI",
    ],
}


def classify(reply: str) -> dict[str, list[str]]:
    """Return {failure_class: [matched markers]} for each class with >=1 hit.

    A reply with no hits returns {} (clean).
    """
    result: dict[str, list[str]] = {}
    for cls in FAILURE_CLASSES:
        hits = [m for m in MARKERS[cls] if m in reply]
        if hits:
            result[cls] = hits
    return result
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.\venv\Scripts\Activate.ps1; pytest tests/probe_eco/test_probe_score.py -q`
Expected: PASS — 5 passed

- [ ] **Step 5: Commit**

```bash
git add tools/probe-eco/probe_score.py tests/probe_eco/test_probe_score.py
git commit -m "feat(probe): add host-side failure-class scoring module"
```

---

## Task 2: Stamp model label into probe_eco.py

**Files:**
- Modify: `tools/probe-eco/probe_eco.py:80` (persona derivation area) and `:120-126` (output dict) and `:140-146` (result dict)

- [ ] **Step 1: Add model-label read after persona derivation**

In `probe_eco.py`, find:

```python
    dsn = build_dsn()
    persona = os.environ["POSTGRES_DB"].replace("hexis_", "", 1)
```

Replace with:

```python
    dsn = build_dsn()
    persona = os.environ["POSTGRES_DB"].replace("hexis_", "", 1)
    # Operator-supplied tier label, passed via `docker exec -e PROBE_MODEL_LABEL`.
    # Identifies which model tier was served for this sweep (e.g. "1b", "4b").
    model_label = os.environ.get("PROBE_MODEL_LABEL", "unlabeled")
```

- [ ] **Step 2: Raise the reply cap so late markers are not truncated away**

In `probe_eco.py`, find:

```python
                "reply": reply[:800],
```

Replace with:

```python
                "reply": reply[:4000],
```

- [ ] **Step 3: Add model_label to the result dict**

In `probe_eco.py`, find:

```python
    result = {
        "persona": persona,
        "snap_ts": str(snap_ts),
        "scrubbed": deleted,
        "broken_count": broken_count,
        "probe": out,
    }
```

Replace with:

```python
    result = {
        "persona": persona,
        "model_label": model_label,
        "snap_ts": str(snap_ts),
        "scrubbed": deleted,
        "broken_count": broken_count,
        "probe": out,
    }
```

- [ ] **Step 4: Verify the file still parses**

Run: `.\venv\Scripts\Activate.ps1; python -c "import ast; ast.parse(open('tools/probe-eco/probe_eco.py').read()); print('OK')"`
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add tools/probe-eco/probe_eco.py
git commit -m "feat(probe): stamp model-tier label, raise reply cap to 4000"
```

---

## Task 3: probe-all.sh — per-model dir + VRAM sampler

**Files:**
- Modify: `tools/probe-eco/probe-all.sh` (full rewrite — small file)

- [ ] **Step 1: Rewrite probe-all.sh**

Replace the entire contents of `tools/probe-eco/probe-all.sh` with:

```bash
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

kill "$SAMPLER_PID" 2>/dev/null
trap - EXIT
echo "peak VRAM (MiB): $(cat "$VRAM_FILE")  [$MODEL_LABEL]"
```

- [ ] **Step 2: Verify the script parses**

Run: `bash -n tools/probe-eco/probe-all.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the required-arg guard**

Run: `bash tools/probe-eco/probe-all.sh; echo "exit=$?"`
Expected: `ERROR: --model <label> is required ...` then `exit=1`

- [ ] **Step 4: Commit**

```bash
git add tools/probe-eco/probe-all.sh
git commit -m "feat(probe): per-model output dir + host-side peak VRAM sampler"
```

---

## Task 4: Aggregator — emit the matrix

**Files:**
- Create: `tools/probe-eco/aggregate.py`
- Test: `tests/probe_eco/test_aggregate.py`

- [ ] **Step 1: Write the failing test**

Create `tests/probe_eco/test_aggregate.py`:

```python
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools" / "probe-eco"))

from aggregate import build_matrix


def _write_probe(probes_dir: Path, label: str, persona: str, replies: list[str], vram: int):
    d = probes_dir / label
    d.mkdir(parents=True, exist_ok=True)
    (d / "_vram.txt").write_text(str(vram))
    (d / f"{persona}.json").write_text(json.dumps({
        "persona": persona,
        "model_label": label,
        "probe": [{"prompt": "p", "reply": r} for r in replies],
    }))


def test_build_matrix_scores_clean_and_broken(tmp_path):
    probes = tmp_path / "probes"
    _write_probe(probes, "4b", "mira", ["good reply", "another good one"], 4200)
    _write_probe(probes, "1b", "mira", ["[USER MESSAGE] leak", "Repl> oops"], 1100)

    md = build_matrix(probes)

    assert "| mira |" in md
    assert "4b" in md and "1b" in md
    # 4b clean -> 2/2 ok; 1b fully broken -> 0/2 ok
    assert "2/2" in md
    assert "0/2" in md
    # peak VRAM surfaced
    assert "4200" in md
    assert "1100" in md


def test_build_matrix_handles_missing_vram(tmp_path):
    probes = tmp_path / "probes"
    d = probes / "7b"
    d.mkdir(parents=True)
    (d / "ao.json").write_text(json.dumps({
        "persona": "ao", "model_label": "7b",
        "probe": [{"prompt": "p", "reply": "fine"}],
    }))
    md = build_matrix(probes)
    assert "n/a" in md  # no _vram.txt -> reported as n/a
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.\venv\Scripts\Activate.ps1; pytest tests/probe_eco/test_aggregate.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'aggregate'`

- [ ] **Step 3: Write minimal implementation**

Create `tools/probe-eco/aggregate.py`:

```python
# aggregate.py - merge per-model/per-persona probe dumps into a markdown matrix.
#
# Reads probes/<label>/<persona>.json (+ optional probes/<label>/_vram.txt),
# scores every reply via probe_score.classify, and writes a persona x model
# matrix to .local-notes/probe-tier-matrix.md.
#
# Usage (from repo root, repo venv active):
#   python tools/probe-eco/aggregate.py

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from probe_score import FAILURE_CLASSES, classify

REPO_ROOT = HERE.parents[1]
DEFAULT_PROBES = HERE / "probes"
DEFAULT_OUT = REPO_ROOT / ".local-notes" / "probe-tier-matrix.md"


def _read_vram(model_dir: Path) -> str:
    f = model_dir / "_vram.txt"
    if not f.exists():
        return "n/a"
    txt = f.read_text().strip()
    return txt if txt else "n/a"


def _score_persona(probe_json: dict) -> dict:
    """Return {ok, total, classes} for one persona's probe run."""
    replies = [entry.get("reply", "") for entry in probe_json.get("probe", [])]
    total = len(replies)
    classes: set[str] = set()
    ok = 0
    for reply in replies:
        hits = classify(reply)
        if hits:
            classes.update(hits.keys())
        else:
            ok += 1
    return {"ok": ok, "total": total, "classes": sorted(classes)}


def build_matrix(probes_dir: Path) -> str:
    """Build the markdown matrix from a probes/ directory tree."""
    model_dirs = sorted(d for d in probes_dir.iterdir() if d.is_dir())
    models = [d.name for d in model_dirs]

    # cell[persona][model] = scored dict
    cells: dict[str, dict[str, dict]] = {}
    vram: dict[str, str] = {}
    for d in model_dirs:
        vram[d.name] = _read_vram(d)
        for jf in sorted(d.glob("*.json")):
            data = json.loads(jf.read_text())
            persona = data.get("persona", jf.stem)
            cells.setdefault(persona, {})[d.name] = _score_persona(data)

    lines = ["# Model-tier probe matrix", ""]
    lines.append("Cell = clean replies / total. Failure classes flagged below the count.")
    lines.append("")
    lines.append("| persona | " + " | ".join(models) + " |")
    lines.append("|" + "---|" * (len(models) + 1))
    for persona in sorted(cells):
        row = [persona]
        for m in models:
            c = cells[persona].get(m)
            if c is None:
                row.append("-")
                continue
            tag = f"{c['ok']}/{c['total']}"
            if c["classes"]:
                tag += " (" + ",".join(c["classes"]) + ")"
            row.append(tag)
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append("| metric | " + " | ".join(models) + " |")
    lines.append("|" + "---|" * (len(models) + 1))
    lines.append("| peak VRAM (MiB) | " + " | ".join(vram[m] for m in models) + " |")
    lines.append("")
    lines.append(f"Failure classes: {', '.join(FAILURE_CLASSES)}.")
    lines.append("")
    lines.append(
        "Floor verdict: the floor model is the largest tier that is clean "
        "fleet-wide AND has peak VRAM <= ~5500 MiB."
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    if not DEFAULT_PROBES.exists():
        print(f"no probes dir at {DEFAULT_PROBES}", file=sys.stderr)
        sys.exit(1)
    md = build_matrix(DEFAULT_PROBES)
    DEFAULT_OUT.parent.mkdir(parents=True, exist_ok=True)
    DEFAULT_OUT.write_text(md, encoding="utf-8")
    print(f"wrote {DEFAULT_OUT}")
    print(md)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.\venv\Scripts\Activate.ps1; pytest tests/probe_eco/test_aggregate.py -q`
Expected: PASS — 2 passed

- [ ] **Step 5: Commit**

```bash
git add tools/probe-eco/aggregate.py tests/probe_eco/test_aggregate.py
git commit -m "feat(probe): aggregate per-tier dumps into persona x model matrix"
```

---

## Task 5: End-to-end smoke + docs

**Files:**
- Modify: `tools/probe-eco/probe-all.sh` (header comment already covers usage — no code change; this task is verification + a usage note)
- Create: `tools/probe-eco/README.md`

- [ ] **Step 1: Run the full test suite for the probe**

Run: `.\venv\Scripts\Activate.ps1; pytest tests/probe_eco -q`
Expected: PASS — all probe_eco tests green.

- [ ] **Step 2: Write the README**

Create `tools/probe-eco/README.md`:

```markdown
# probe-eco — persona reply-quality probe

Brackets model tiers to confirm the Companion-SKU VRAM floor.
See `.local-notes/strategy-local-llm-positioning.md` §4.

## One-tier run

1. Re-arm `ActiveBig` to the tier under test: edit `power-profiles.psd1`,
   then `set-power-mode.ps1 eco` then `set-power-mode.ps1 prime`.
2. Confirm with `hexis-status.ps1` (server alias == char DB `llm.chat`).
3. Run: `./probe-all.sh --model <label>`  (label e.g. 1b | 3b | 4b | 7b)
   Output: `probes/<label>/<persona>.json` + `probes/<label>/_vram.txt`.

## Aggregate after all tiers are run

`python aggregate.py`  ->  writes `.local-notes/probe-tier-matrix.md`.

## Floor verdict

The floor model is the largest tier that is clean fleet-wide AND whose
measured peak VRAM is <= ~5500 MiB. If only 7b clears quality but busts
VRAM, the Companion floor moves from 8GB to 12GB — revisit the SKU market %.
```

- [ ] **Step 3: Dry-run the aggregator against an empty tree to confirm the guard**

Run: `.\venv\Scripts\Activate.ps1; python tools/probe-eco/aggregate.py`
Expected: if no `probes/` subdirs exist yet, either `no probes dir` on stderr (exit 1) or an empty matrix — both acceptable; no traceback.

- [ ] **Step 4: Commit**

```bash
git add tools/probe-eco/README.md
git commit -m "docs(probe): add probe-eco usage README"
```

---

## Operator runbook (post-implementation, not a code task)

1. For each tier in {1b, 3b, 4b, 7b}: re-arm `ActiveBig`, then `./probe-all.sh --model <tier>`.
2. `python tools/probe-eco/aggregate.py` → read `.local-notes/probe-tier-matrix.md`.
3. Apply the floor verdict. Feed the result back into `strategy-local-llm-positioning.md` §2/§3.
