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
