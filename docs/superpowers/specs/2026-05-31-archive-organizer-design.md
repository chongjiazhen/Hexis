# Archive Organizer Design

## Objective

Add standalone archive-organizer package inside `hexis` that can reorganize files under `E:\archive` by renaming and moving only. It must use a cloud model for global archive structure, a local model for subtree batching, then enforce deterministic safety checks before any filesystem write.

## Scope

In scope:
- scan archive tree under one configured root
- generate proposed archive taxonomy with cloud LLM
- generate proposed rename/move batches with local LLM
- validate every proposed path deterministically
- execute only approved rename/move operations
- record every action in append-only journal
- optionally commit journal updates to local git for history

Out of scope:
- delete operations
- overwrite behavior
- moves outside archive root
- shell-based file manipulation
- cross-root copy/delete semantics
- archive cleanup beyond explicit rename/move

## Package Placement

Implement as standalone package inside `hexis`, not inside `llm-serve`.

Recommended shape:
- `core/archive_organizer/` for orchestration, cloud assessment, local batching, validation, journal, and batch execution
- `apps/hexis_cli.py` subcommand for user entrypoint
- reuse existing local/cloud LLM config and provider wiring

## User Surface

Expose CLI/subcommand, not background service first.

Primary commands:
- `hexis archive-organizer assess`
- `hexis archive-organizer batch`
- `hexis archive-organizer apply`
- `hexis archive-organizer journal`

Planned behavior:
- `assess` indexes current archive tree and asks cloud LLM for ideal taxonomy and rules
- `batch` takes one subtree plus taxonomy and asks local LLM for exact rename/move manifest
- `apply` runs validator, then executes approved operations from that exact manifest
- `journal` inspects recent actions and batch status

## Safety Model

The organizer must treat `E:\archive` as hard root. Every source and destination path must remain inside that root after normalization and real-path resolution.

Hard rules:
- source path and destination path must both resolve under `E:\archive`
- deny if destination exists
- deny if path escapes through symlink, junction, reparse point, or similar indirection
- deny any operation that would require delete semantics
- deny any operation that would require overwrite semantics
- execute sequentially, not in parallel
- stop batch on first failure
- never auto-modify proposed destinations to make them fit

Windows-specific expectations:
- handle case-only renames safely
- reject locked files cleanly
- reject reserved path names and invalid path forms
- respect long-path behavior supported by runtime

## Execution Flow

1. User requests archive organization against `E:\archive`.
2. `assess` collects filesystem inventory and optional heuristics.
3. Cloud LLM drafts ideal taxonomy and rules.
4. `batch` applies taxonomy to one subtree and drafts exact rename/move manifest.
5. Validator checks each operation before any write.
6. Dry-run prints exact plan and decision reasons.
7. `apply` executes approved operations sequentially.
8. Journal appends records for every op and batch outcome.
9. Optional git commit captures journal state after successful batch.

## Journal Format

Store append-only JSONL under archive root, for example:

`E:\archive\.archive-organizer\actions.jsonl`

Each record should include:
- batch id
- op id
- timestamp
- action type
- source path
- destination path
- dry-run or applied
- validation result
- status
- size/hash metadata when available
- human-entered batch reason or prompt summary

Git is history only:
- keep a dedicated local git repo under `E:\archive\.archive-organizer\git`
- commit journal changes after successful apply
- commit message should identify batch id
- do not use git as execution control or rollback mechanism

## Error Handling

On validation failure:
- `apply` rejects entire batch if any op fails validation
- report exact rule violated
- never silently rewrite manifest

On execution failure:
- mark op failed in journal
- stop batch immediately
- keep partial state explicit
- do not guess at recovery steps

Recovery model:
- re-run plan or validator
- resume only from remaining approved operations
- never attempt delete-based rollback

## Testing

Add focused tests for:
- root containment under `E:\archive`
- symlink/junction escape rejection
- overwrite denial
- dry-run no-write guarantee
- sequential batch execution
- partial failure journaling
- case-only rename handling
- git commit only after successful apply

Prefer deterministic filesystem fixtures and mocked LLM output. Do not rely on live model output in unit tests.

## Acceptance Criteria

- CLI subcommand exists and routes to archive-organizer package
- only rename/move operations are allowed
- all operations stay under `E:\archive`
- journal is append-only and captures every attempted action
- optional git commit works as audit trail only
- tests cover validation and execution safety rules
