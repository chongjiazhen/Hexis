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
    if not probes_dir.is_dir():
        raise ValueError(f"probes dir not found: {probes_dir}")
    model_dirs = sorted(d for d in probes_dir.iterdir() if d.is_dir())
    models = [d.name for d in model_dirs]

    # cell[persona][model] = scored dict
    cells: dict[str, dict[str, dict]] = {}
    vram: dict[str, str] = {}
    for d in model_dirs:
        vram[d.name] = _read_vram(d)
        for jf in sorted(d.glob("*.json")):
            try:
                data = json.loads(jf.read_text())
            except json.JSONDecodeError:
                print(f"WARN: skipping malformed JSON: {jf}", file=sys.stderr)
                continue
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
    lines.append("| peak board VRAM (MiB) | " + " | ".join(vram[m] for m in models) + " |")
    lines.append("")
    lines.append(f"Failure classes: {', '.join(FAILURE_CLASSES)}.")
    lines.append("")
    lines.append(
        "Floor verdict: the floor model is the largest tier that is clean "
        "fleet-wide AND fits the 8GB Companion budget."
    )
    lines.append("")
    lines.append(
        "VRAM caveat: the sampler records `nvidia-smi memory.used` for the "
        "WHOLE board (desktop + every running model), not the probed tier's "
        "footprint in isolation. On a 16GB dev box with the fleet up, this "
        "number is NOT the 8GB-card answer. To size a tier, probe it on a "
        "clean box, or measure the used-VRAM delta around its serve. Treat "
        "the column as a coarse upper bound until then."
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
