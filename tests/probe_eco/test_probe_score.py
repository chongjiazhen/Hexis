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
