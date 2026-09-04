# Archive Organizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build CLI-driven archive organizer inside `hexis` that uses a cloud model for global archive architecture, a local model for subtree batching, and deterministic validation for rename/move operations only under `E:\archive`, with append-only journaling and optional git audit commits.

**Architecture:** New `core/archive_organizer/` package owns archive scanning, cloud taxonomy design, local subtree batching, validation, journal, and execution. `apps/hexis_cli.py` exposes a two-stage planning flow: `assess` for cloud architecture, `batch` for local subtree manifests, plus `apply` and `journal`. Deterministic path validation is the hard gate before any write.

**Tech Stack:** Python 3.10+, existing Hexis CLI, existing local/cloud LLM wiring in `core/llm.py`, `pathlib`/`os`/`shutil`, JSON/JSONL files, optional local git via subprocess.

---

### Task 1: Add archive plan models and artifact formats

**Files:**
- Create: `core/archive_organizer/__init__.py`
- Create: `core/archive_organizer/models.py`
- Create: `tests/core/test_archive_organizer_models.py`

- [ ] **Step 1: Write the failing test**

```python
from core.archive_organizer.models import ArchiveOp, ArchiveBatch, ArchiveTaxonomy, ArchiveAssessment


def test_taxonomy_round_trip():
    taxonomy = ArchiveTaxonomy(
        version=1,
        roots=["Projects", "Reference", "Inbox"],
        rules=["keep source and destination under archive root"],
    )
    data = taxonomy.to_dict()
    restored = ArchiveTaxonomy.from_dict(data)

    assert restored == taxonomy


def test_assessment_contains_summary():
    assessment = ArchiveAssessment(
        batch_id="assess-1",
        root=r"E:\archive",
        sample_paths=[r"E:\archive\a.txt"],
        summary="draft taxonomy",
        taxonomy=ArchiveTaxonomy(version=1, roots=["Projects"], rules=["x"]),
    )
    assert assessment.batch_id == "assess-1"
    assert assessment.root == r"E:\archive"


def test_archive_batch_contains_ops():
    batch = ArchiveBatch(batch_id="batch-1", root=r"E:\archive", ops=[])
    assert batch.batch_id == "batch-1"
    assert batch.root == r"E:\archive"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_archive_organizer_models.py -v`
Expected: FAIL with missing symbols.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class ArchiveTaxonomy:
    version: int
    roots: list[str]
    rules: list[str]

    def to_dict(self) -> dict[str, Any]:
        return {"version": self.version, "roots": self.roots, "rules": self.rules}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ArchiveTaxonomy":
        return cls(
            version=int(data["version"]),
            roots=list(data.get("roots") or []),
            rules=list(data.get("rules") or []),
        )


@dataclass(frozen=True)
class ArchiveAssessment:
    batch_id: str
    root: str
    sample_paths: list[str]
    summary: str
    taxonomy: ArchiveTaxonomy
    metadata: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class ArchiveOp:
    op_id: str
    action: str
    source: str
    destination: str
    reason: str
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "op_id": self.op_id,
            "action": self.action,
            "source": self.source,
            "destination": self.destination,
            "reason": self.reason,
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ArchiveOp":
        return cls(
            op_id=data["op_id"],
            action=data["action"],
            source=data["source"],
            destination=data["destination"],
            reason=data["reason"],
            metadata=dict(data.get("metadata") or {}),
        )


@dataclass
class ArchiveBatch:
    batch_id: str
    root: str
    ops: list[ArchiveOp]
    dry_run: bool = True
    metadata: dict[str, Any] = field(default_factory=dict)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_archive_organizer_models.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/archive_organizer/__init__.py core/archive_organizer/models.py tests/core/test_archive_organizer_models.py
git commit -m "feat(archive): add archive plan models"
```

### Task 2: Implement cloud assessment and local batch planners

**Files:**
- Create: `core/archive_organizer/planner.py`
- Create: `tests/core/test_archive_organizer_planner.py`

- [ ] **Step 1: Write the failing test**

```python
from core.archive_organizer.models import ArchiveTaxonomy
from core.archive_organizer.planner import build_archive_assessment, build_archive_batch


class FakeLLM:
    def __init__(self, response):
        self.response = response
        self.calls = []

    def __call__(self, prompt):
        self.calls.append(prompt)
        return self.response


def test_cloud_assessment_builds_taxonomy():
    llm = FakeLLM({
        "batch_id": "assess-1",
        "summary": "group by project then reference",
        "taxonomy": {"version": 1, "roots": ["Projects", "Reference"], "rules": ["stay under root"]},
    })
    assessment = build_archive_assessment(
        root=r"E:\archive",
        scan_summary={"sample_paths": [r"E:\archive\p\a.txt"]},
        llm_client=llm,
    )

    assert assessment.batch_id == "assess-1"
    assert isinstance(assessment.taxonomy, ArchiveTaxonomy)
    assert assessment.taxonomy.roots == ["Projects", "Reference"]


def test_local_batch_uses_taxonomy_and_subtree():
    llm = FakeLLM({
        "batch_id": "batch-1",
        "ops": [
            {
                "op_id": "op-1",
                "action": "rename",
                "source": r"E:\archive\project\a.txt",
                "destination": r"E:\archive\Projects\project-a.txt",
                "reason": "normalize project file name",
                "metadata": {},
            }
        ],
        "dry_run": True,
    })
    batch = build_archive_batch(
        root=r"E:\archive",
        subtree=r"E:\archive\project",
        taxonomy=ArchiveTaxonomy(version=1, roots=["Projects"], rules=["stay under root"]),
        scan_summary={"files": [r"E:\archive\project\a.txt"]},
        llm_client=llm,
    )

    assert batch.batch_id == "batch-1"
    assert batch.ops[0].destination.endswith("project-a.txt")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_archive_organizer_planner.py -v`
Expected: FAIL with missing planner functions.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

from .models import ArchiveAssessment, ArchiveBatch, ArchiveOp, ArchiveTaxonomy


def build_archive_assessment(*, root: str, scan_summary: dict, llm_client) -> ArchiveAssessment:
    prompt = {
        "mode": "cloud-assess",
        "root": root,
        "scan_summary": scan_summary,
        "goal": "produce ideal archive taxonomy and rules",
    }
    response = llm_client(prompt)
    taxonomy = ArchiveTaxonomy.from_dict(response["taxonomy"])
    return ArchiveAssessment(
        batch_id=response["batch_id"],
        root=root,
        sample_paths=list(scan_summary.get("sample_paths") or []),
        summary=response["summary"],
        taxonomy=taxonomy,
        metadata=dict(response.get("metadata") or {}),
    )


def build_archive_batch(
    *,
    root: str,
    subtree: str,
    taxonomy: ArchiveTaxonomy,
    scan_summary: dict,
    llm_client,
) -> ArchiveBatch:
    prompt = {
        "mode": "local-batch",
        "root": root,
        "subtree": subtree,
        "taxonomy": taxonomy.to_dict(),
        "scan_summary": scan_summary,
        "allowed_actions": ["rename", "move"],
        "hard_rules": ["stay inside root", "no overwrite", "no delete"],
    }
    response = llm_client(prompt)
    ops = [ArchiveOp.from_dict(item) for item in response["ops"]]
    return ArchiveBatch(
        batch_id=response["batch_id"],
        root=root,
        ops=ops,
        dry_run=bool(response.get("dry_run", True)),
        metadata=dict(response.get("metadata") or {}),
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_archive_organizer_planner.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/archive_organizer/planner.py tests/core/test_archive_organizer_planner.py
git commit -m "feat(archive): add cloud and local planners"
```

### Task 3: Implement hard validator and append-only journal

**Files:**
- Create: `core/archive_organizer/validator.py`
- Create: `core/archive_organizer/journal.py`
- Create: `tests/core/test_archive_organizer_validator.py`
- Create: `tests/core/test_archive_organizer_journal.py`

- [ ] **Step 1: Write the failing tests**

```python
import pytest

from core.archive_organizer.validator import ArchiveValidator
from core.archive_organizer.journal import ArchiveJournal


def test_validator_blocks_symlink_escape(tmp_path):
    root = tmp_path / "archive"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    link = root / "link"

    try:
        link.symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks not supported")

    validator = ArchiveValidator(str(root))
    result = validator.validate_op(
        action="move",
        source=str(link / "secret.txt"),
        destination=str(root / "inbox" / "secret.txt"),
    )

    assert result.allowed is False


def test_journal_appends_jsonl(tmp_path):
    journal = ArchiveJournal(str(tmp_path / "archive"))
    journal.append({"batch_id": "b1", "op_id": "op1", "status": "dry-run"})
    journal.append({"batch_id": "b1", "op_id": "op1", "status": "applied"})

    lines = (tmp_path / "archive" / ".archive-organizer" / "actions.jsonl").read_text().splitlines()
    assert len(lines) == 2
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/core/test_archive_organizer_validator.py tests/core/test_archive_organizer_journal.py -v`
Expected: FAIL with missing classes.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ValidationResult:
    allowed: bool
    reason: str = ""


class ArchiveValidator:
    def __init__(self, root: str):
        self.root = Path(root).resolve()

    def _resolve(self, path: str) -> Path:
        return Path(path).resolve()

    def _within_root(self, path: Path) -> bool:
        try:
            return path.is_relative_to(self.root)
        except AttributeError:
            return str(path).startswith(str(self.root))

    def validate_op(self, *, action: str, source: str, destination: str) -> ValidationResult:
        if action not in {"rename", "move"}:
            return ValidationResult(False, "action not allowed")
        src = self._resolve(source)
        dst = self._resolve(destination)
        if not self._within_root(src) or not self._within_root(dst):
            return ValidationResult(False, "path outside archive root")
        if dst.exists():
            return ValidationResult(False, "destination exists")
        return ValidationResult(True, "")


class ArchiveJournal:
    def __init__(self, root: str):
        self.root = Path(root)
        self.base = self.root / ".archive-organizer"
        self.path = self.base / "actions.jsonl"

    def append(self, record: dict[str, Any]) -> None:
        self.base.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/core/test_archive_organizer_validator.py tests/core/test_archive_organizer_journal.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/archive_organizer/validator.py core/archive_organizer/journal.py tests/core/test_archive_organizer_validator.py tests/core/test_archive_organizer_journal.py
git commit -m "feat(archive): add validator and journal"
```

### Task 4: Implement batch executor with exact manifest apply and audit commit

**Files:**
- Create: `core/archive_organizer/executor.py`
- Create: `core/archive_organizer/git_audit.py`
- Create: `tests/core/test_archive_organizer_executor.py`
- Create: `tests/core/test_archive_organizer_git.py`

- [ ] **Step 1: Write the failing tests**

```python
from core.archive_organizer.executor import ArchiveExecutor
from core.archive_organizer.models import ArchiveOp, ArchiveBatch


def test_executor_dry_run_makes_no_changes(tmp_path):
    root = tmp_path / "archive"
    root.mkdir()
    src = root / "a.txt"
    src.write_text("hello")
    batch = ArchiveBatch(
        batch_id="batch-1",
        root=str(root),
        ops=[ArchiveOp(op_id="op-1", action="rename", source=str(src), destination=str(root / "b.txt"), reason="rename")],
        dry_run=True,
    )

    executor = ArchiveExecutor()
    result = executor.run(batch)

    assert result.applied is False
    assert src.exists() is True
    assert not (root / "b.txt").exists()


def test_executor_applies_rename(tmp_path):
    root = tmp_path / "archive"
    root.mkdir()
    src = root / "a.txt"
    src.write_text("hello")
    batch = ArchiveBatch(
        batch_id="batch-2",
        root=str(root),
        ops=[ArchiveOp(op_id="op-1", action="rename", source=str(src), destination=str(root / "b.txt"), reason="rename")],
        dry_run=False,
    )

    executor = ArchiveExecutor()
    result = executor.run(batch)

    assert result.applied is True
    assert not src.exists()
    assert (root / "b.txt").exists()
```

```python
from core.archive_organizer.git_audit import commit_journal_batch


def test_git_commit_message_uses_batch_id(tmp_path, monkeypatch):
    calls = []

    def fake_run(cmd, cwd=None, check=False):
        calls.append((cmd, cwd, check))
        class Result:
            returncode = 0
        return Result()

    monkeypatch.setattr("core.archive_organizer.git_audit.subprocess.run", fake_run)
    commit_journal_batch(str(tmp_path), "batch-9")

    assert calls[0][0][:2] == ["git", "add"]
    assert calls[1][0][:2] == ["git", "commit"]
    assert "batch-9" in calls[1][0]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/core/test_archive_organizer_executor.py tests/core/test_archive_organizer_git.py -v`
Expected: FAIL with missing executor or audit helper.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import subprocess

from .journal import ArchiveJournal
from .models import ArchiveBatch
from .validator import ArchiveValidator


@dataclass
class ExecutionResult:
    applied: bool
    batch_id: str
    status: str


class ArchiveExecutor:
    def run(self, batch: ArchiveBatch) -> ExecutionResult:
        validator = ArchiveValidator(batch.root)
        journal = ArchiveJournal(batch.root)

        for op in batch.ops:
            result = validator.validate_op(action=op.action, source=op.source, destination=op.destination)
            journal.append({**op.to_dict(), "batch_id": batch.batch_id, "status": "validated" if result.allowed else "rejected", "reason": result.reason})
            if not result.allowed:
                return ExecutionResult(False, batch.batch_id, "rejected")

        if batch.dry_run:
            return ExecutionResult(False, batch.batch_id, "dry-run")

        for op in batch.ops:
            src = Path(op.source)
            dst = Path(op.destination)
            os.replace(src, dst)
            journal.append({**op.to_dict(), "batch_id": batch.batch_id, "status": "applied"})

        return ExecutionResult(True, batch.batch_id, "applied")


def commit_journal_batch(repo_root: str, batch_id: str) -> None:
    subprocess.run(["git", "add", ".archive-organizer/actions.jsonl"], cwd=repo_root, check=True)
    subprocess.run(["git", "commit", "-m", f"archive: batch {batch_id}"], cwd=repo_root, check=True)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/core/test_archive_organizer_executor.py tests/core/test_archive_organizer_git.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/archive_organizer/executor.py core/archive_organizer/git_audit.py tests/core/test_archive_organizer_executor.py tests/core/test_archive_organizer_git.py
git commit -m "feat(archive): add executor and git audit"
```

### Task 5: Wire CLI surface for assess, batch, apply, journal

**Files:**
- Modify: `apps/hexis_cli.py`
- Create: `core/archive_organizer/cli.py`
- Create: `core/archive_organizer/runtime.py`
- Create: `tests/cli/test_archive_organizer_cli.py`
- Create: `tests/core/test_archive_organizer_runtime.py`

- [ ] **Step 1: Write the failing tests**

```python
import argparse
import asyncio

from apps.hexis_cli import build_parser
from core.archive_organizer.runtime import resolve_archive_llm_configs


def test_archive_organizer_subcommand_exists():
    parser = build_parser()
    subparsers = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    assert "archive-organizer" in subparsers.choices


def test_archive_organizer_leaf_commands_exist():
    parser = build_parser()
    subparsers = next(a for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    archive_parser = subparsers.choices["archive-organizer"]
    archive_subparsers = next(a for a in archive_parser._actions if isinstance(a, argparse._SubParsersAction))
    assert {"assess", "batch", "apply", "journal"}.issubset(set(archive_subparsers.choices))


def test_runtime_resolves_cloud_and_local_configs(monkeypatch):
    async def fake_resolve(pool, key, fallback_key=None, overrides=None):
        return {"provider": "fake", "model": key, "api_key": "x"}

    monkeypatch.setattr("core.archive_organizer.runtime.resolve_llm_config", fake_resolve)
    cloud_cfg, local_cfg = asyncio.run(resolve_archive_llm_configs(pool=object()))
    assert cloud_cfg["model"] == "llm.archive.cloud"
    assert local_cfg["model"] == "llm.archive.local"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `pytest tests/cli/test_archive_organizer_cli.py -v`
Expected: FAIL with missing subcommand.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

from core.llm_config import resolve_llm_config


async def resolve_archive_llm_configs(*, pool, cloud_overrides: dict | None = None, local_overrides: dict | None = None):
    cloud_cfg = await resolve_llm_config(
        pool,
        "llm.archive.cloud",
        fallback_key="llm.chat",
        overrides=cloud_overrides,
    )
    local_cfg = await resolve_llm_config(
        pool,
        "llm.archive.local",
        fallback_key="llm.heartbeat",
        overrides=local_overrides,
    )
    return cloud_cfg, local_cfg


from .executor import ArchiveExecutor
from .git_audit import commit_journal_batch
from .planner import build_archive_assessment, build_archive_batch


def register_archive_subcommands(sub):
    archive = sub.add_parser("archive-organizer", help="Plan and apply archive reorganizations")
    archive_sub = archive.add_subparsers(dest="archive_command", required=True)

    assess = archive_sub.add_parser("assess", help="Cloud pass: design ideal archive taxonomy")
    assess.set_defaults(func="archive_assess")

    batch = archive_sub.add_parser("batch", help="Local pass: build subtree batch from taxonomy")
    batch.set_defaults(func="archive_batch")

    apply = archive_sub.add_parser("apply", help="Apply exact batch manifest")
    apply.set_defaults(func="archive_apply")

    journal = archive_sub.add_parser("journal", help="Show archive action journal")
    journal.set_defaults(func="archive_journal")

    archive.set_defaults(func="archive-organizer")
    return archive
```

And in `apps/hexis_cli.py`, call `register_archive_subcommands(sub)` where other top-level commands are registered, then route `archive_assess`, `archive_batch`, `archive_apply`, and `archive_journal` in main dispatch the same way existing subcommands are handled.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/cli/test_archive_organizer_cli.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add apps/hexis_cli.py core/archive_organizer/cli.py tests/cli/test_archive_organizer_cli.py
git commit -m "feat(archive): add cli surface"
```

### Task 6: Add end-to-end flow for cloud assess -> local batch -> apply

**Files:**
- Create: `tests/core/test_archive_organizer_integration.py`
- Modify: `core/archive_organizer/executor.py`
- Modify: `core/archive_organizer/planner.py`

- [ ] **Step 1: Write the failing integration test**

```python
from core.archive_organizer.models import ArchiveTaxonomy
from core.archive_organizer.planner import build_archive_assessment, build_archive_batch
from core.archive_organizer.executor import ArchiveExecutor


def test_assess_then_batch_then_apply(tmp_path):
    root = tmp_path / "archive"
    root.mkdir()
    src = root / "project" / "a.txt"
    src.parent.mkdir()
    src.write_text("hello")

    cloud_llm = lambda prompt: {
        "batch_id": "assess-1",
        "summary": "Projects at top level",
        "taxonomy": {"version": 1, "roots": ["Projects"], "rules": ["stay under root"]},
    }
    local_llm = lambda prompt: {
        "batch_id": "batch-1",
        "ops": [
            {
                "op_id": "op-1",
                "action": "rename",
                "source": str(src),
                "destination": str(root / "Projects" / "a.txt"),
                "reason": "place project file under taxonomy root",
                "metadata": {},
            }
        ],
        "dry_run": False,
    }

    assessment = build_archive_assessment(root=str(root), scan_summary={"sample_paths": [str(src)]}, llm_client=cloud_llm)
    batch = build_archive_batch(root=str(root), subtree=str(src.parent), taxonomy=assessment.taxonomy, scan_summary={"files": [str(src)]}, llm_client=local_llm)
    result = ArchiveExecutor().run(batch)

    assert assessment.taxonomy.roots == ["Projects"]
    assert result.applied is True
    assert (root / "Projects" / "a.txt").exists()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/core/test_archive_organizer_integration.py -v`
Expected: FAIL until planner/executor wiring is complete.

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

from .models import ArchiveAssessment, ArchiveBatch, ArchiveOp, ArchiveTaxonomy

# keep existing planner helpers, but ensure they are importable and stable

def build_archive_assessment(*, root: str, scan_summary: dict, llm_client) -> ArchiveAssessment:
    prompt = {"mode": "cloud-assess", "root": root, "scan_summary": scan_summary}
    response = llm_client(prompt)
    taxonomy = ArchiveTaxonomy.from_dict(response["taxonomy"])
    return ArchiveAssessment(
        batch_id=response["batch_id"],
        root=root,
        sample_paths=list(scan_summary.get("sample_paths") or []),
        summary=response["summary"],
        taxonomy=taxonomy,
    )


def build_archive_batch(*, root: str, subtree: str, taxonomy: ArchiveTaxonomy, scan_summary: dict, llm_client) -> ArchiveBatch:
    prompt = {"mode": "local-batch", "root": root, "subtree": subtree, "taxonomy": taxonomy.to_dict(), "scan_summary": scan_summary}
    response = llm_client(prompt)
    ops = [ArchiveOp.from_dict(item) for item in response["ops"]]
    return ArchiveBatch(batch_id=response["batch_id"], root=root, ops=ops, dry_run=bool(response.get("dry_run", True)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/core/test_archive_organizer_integration.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add core/archive_organizer/planner.py core/archive_organizer/executor.py tests/core/test_archive_organizer_integration.py
git commit -m "feat(archive): wire assess batch apply flow"
```

## Coverage Check

Covered:
- standalone package inside `hexis`: Tasks 1-6
- cloud architecture pass: Tasks 2, 6
- local subtree batching: Tasks 2, 6
- deterministic root lock: Task 3
- rename/move only: Tasks 3, 4
- dry-run then apply: Task 4
- append-only journal: Task 3
- optional git audit history: Task 4
- CLI subcommands: Task 5

Gap check:
- if real cloud/local provider selection needs config keys rather than direct CLI arguments, add one tiny config task before Task 5 so planner helpers can load model configs from `core/llm.py` instead of accepting raw callables only.
