# SPEC (for hexis worker): hard-cap recall payload for low-ctx OpenClaw bodies

> Handoff from the OpenClaw-side work. Self-contained. Architecture + full
> history: auto-memory `openclaw-hexis-architecture`; onboard recipe:
> `openclaw-hexis-onboard.prompt.md` (same dir).

## Why

OpenClaw body runs persona on a small local model (q36 IQ3_XXS, llama
n_ctx 24576 → ~20K usable, slow, 1 slot). Ground-truth tested 2026-05-18:
recall result payloads (default 10 memories + partial activations, no
importance floor) × multiple recalls/turn blow the context threshold →
OpenClaw auto-compaction fires mid-turn → strips SOUL/system prompt →
**persona collapses to a generic "I'm a language model" reply, no tool
routing, 120s+ stalls**. SOUL trimming did NOT fix it (SOUL was never the
bloat). The dominant consumer is the recall payload.

The recall `limit` is a per-call arg the MODEL chooses, defaulting in the
MCP server. Instructing the model (SOUL) to ask for a small limit is
unreliable — under compaction the instruction is exactly what gets stripped.
**The cap must be enforced server-side, model-proof.**

## OpenClaw side — ALREADY DONE (do not redo)

`C:\openclaw\data\openclaw.json` agent `ennie` tools.deny tightened: only
`get_identity`, `recall`, `remember` remain allowed (hydrate, recall_recent,
get_worldview, get_goals, sense_memory_availability now denied — below the
recipe's ~8, deliberate for this hardware). Gateway restarted, validated.

## hexis side — TO DO

File: `C:\hexis\apps\hexis_mcp_server.py`, `_dispatch_tool`, `recall` branch
(currently ~lines 112-130).

Current:
```python
if name == "recall":
    query = _require(args, "query", name)
    limit = int(args.get("limit", 10))
    include_partial = bool(args.get("include_partial", True))
    ...
    min_importance=float(args.get("min_importance", 0.0)),
```

Change to hard caps (clamp, ignore larger model-supplied values):
```python
if name == "recall":
    query = _require(args, "query", name)
    # Low-ctx body cap: never return more than 3, partials off, noise floored.
    limit = min(int(args.get("limit", 3)), 3)
    include_partial = False
    ...
    min_importance=max(float(args.get("min_importance", 0.3)), 0.3),
```

Notes:
- `limit`: clamp to **3** (default and ceiling). `min(..., 3)` so a model
  asking for 10 still gets 3.
- `include_partial`: force **False** unconditionally (partial activations are
  pure ctx bloat for a chat persona).
- `min_importance`: floor at **0.3** (drop trivial/noise memories).
- Optional, if memory `content` can be long: truncate each returned memory's
  content to ~500 chars at the serialization boundary (`_jsonable` / wherever
  Memory → dict). Confirm typical content length first; only add if needed.
- Leave `recall_recent`, `hydrate` defaults alone — OpenClaw already denies
  them for `ennie`. If another body re-enables them, give them the same clamp.

## Rebuild (caps are baked into the image)

Per onboard recipe / hexis CLAUDE.md, `hexis_mcp_*` runs the code from the
image — editing the .py on disk does NOT take effect until rebuilt:
```
cd C:\hexis
docker compose -f docker-compose.yml -f docker-compose.mcp.yml up -d --build hexis_mcp_ennie
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8767/sse   # expect 200
```
(Apply to other live bodies' mcp containers too if/when they hit the same
ceiling — currently only `ennie` is the OpenClaw-fronted low-ctx body.)

## Validate (ground truth, not "right answer")

After rebuild + an OpenClaw `ennie` turn (identity + a memory question):
1. `docker logs --since 5m openclaw-openclaw-gateway-1 | grep -i auto-compaction`
   → **expect ZERO** `reason=threshold` events for the turn.
2. `docker logs --since 5m hexis_mcp_ennie | grep -c CallToolRequest` → > 0
   (recall still firing, just smaller).
3. Reply stays **in-persona** (Ennie — novelist-companion), correct name,
   no generic "language model" collapse, no 120s stall.
A correct answer ALONE is not proof — a right reply with a compaction event
still means failure. The pass condition is **no threshold compaction**.

## If it still compacts after A+B

The model is simply too small for persona + brain at all. Escalate to the
hardware track (raise llama n_ctx / bigger model — VRAM-bound on the
RTX 5060 Ti 16GB box). Stop tuning config; it's a capacity wall.
