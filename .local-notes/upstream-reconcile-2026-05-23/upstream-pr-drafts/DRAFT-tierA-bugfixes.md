# DRAFT — Tier-A bug fixes (one PR each, ship after a flagship lands)

Generic, low-risk, obviously-correct. Bodies read 2026-06-04. None ship a test —
**add a minimal test per fix before pushing.** Ship one-at-a-time, security first.
Order/risk verdicts: `../pr-suitability-2026-06-04.md`.

---

## A1. httpx token-leak (security) — `036e840` — HIGH
- **Title:** `fix(channels): silence httpx INFO logs so Telegram bot tokens don't leak`
- **Bug:** httpx logs request URLs at INFO; Telegram bot API embeds the token in the URL path → tokens written to worker logs.
- **Fix:** raise httpx logger to WARNING. `services/channel_worker.py`, +4.
- **Scrub:** none.

## A2. gateway timedelta — `7897c72` — HIGH
- **Title:** `fix(gateway): pass timedelta to gateway_reclaim instead of str`
- **Bug:** asyncpg serializes INTERVAL from `datetime.timedelta`; passing `'10 minutes'` raised `'str' object has no attribute 'days'` → stale-event reclaim silently no-opped on every worker startup.
- **Fix:** `core/gateway.py`.
- **Scrub:** none.

## A3. JSONB `#>>` card init — `a95c654` — HIGH
- **Title:** `fix(init): use #>> for JSONB string extraction in card init`
- **Bug:** `btrim(entry::text,'"')` to unwrap JSON scalars in `init_from_character_card` (values/worldview/boundaries/interests/goals + embed-text) — `::text` gives serialized JSON, so btrim doesn't JSON-unescape and eats legit quote chars. Worldview/values with escaped quotes came through mangled. 8 sites.
- **Fix:** replace all 8 with `entry #>> '{}'`. `db/10_functions_initialization.sql`.
- **Scrub:** none.

## A4. goal priority enum — `54253d9` — HIGH
- **Title:** `fix(db): coerce free-text goal priority to enum in reprioritize`
- **Bug:** small models emit `'highest'`/`'urgent'` — not valid `goal_priority` enum; cast crashed and aborted the heartbeat.
- **Fix:** map common synonyms to nearest enum, fall back `'queued'`. `db/17_functions_subconscious_observations.sql`.
- **Scrub:** none.

## A5. Telegram updates survive restart — `b987e32` — HIGH
- **Title:** `fix(channels): keep queued Telegram updates across worker restarts`
- **Bug:** `drop_pending_updates=True` → every channel-worker restart (deploys) silently discarded Telegram messages that arrived during downtime.
- **Fix:** set False. `channels/telegram_adapter.py`.
- **Scrub:** drop the "power-mode flips" fleet example from the message; keep "deploys/restarts".

## A6. Telegram not-modified no-op — `dc4766c` — HIGH
- **Title:** `fix(channels): treat Telegram "Message is not modified" as edit no-op`
- **Bug:** streaming final `edit_message_text` with identical content → Telegram BadRequest "Message is not modified"; generic `except` retried without parse_mode, replacing MarkdownV2 render with raw text (literal backticks/escapes visible).
- **Fix:** catch that specific error, return success without fallback. `channels/telegram_adapter.py`.
- **Scrub:** none.

## A7. init --endpoint — `48d8d99` — MED
- **Title:** `fix(init): --endpoint arg for noninteractive hexis init`
- **Bug:** noninteractive init hardcoded `endpoint=""` → fresh DBs seeded a blank endpoint, breaking heartbeat/subconscious loop.
- **Fix:** `--endpoint` flag, omitted = unchanged (backward compatible). `apps/hexis_init.py`.
- **Scrub:** "hexis_mira" per-persona DB example → generic.

## A9. conftest tenacity coroutine bug — (home-rig fix, upstream-present) — HIGH
- **Title:** `fix(tests): await fetchval inside AsyncRetrying in embedding-health fixture`
- **Bug:** `ensure_embedding_service` did `ok = await retrying(conn.fetchval, "SELECT check_embedding_service_health()")` — `AsyncRetrying` doesn't await the bare `fetchval` method, so `ok` is an un-awaited coroutine; `assert ok is True` errors. Shared fixture → errors every test that uses it (8+ in `test_cognitive_memory_extra.py`).
- **Confirmed present upstream:** `origin/main:tests/conftest.py:338` (identical).
- **Fix:** wrap in a coroutine fn — `async def _check_health(): return await conn.fetchval(...)` then `await retrying(_check_health)`. **Committed on `home-rig-local` as `e3bf69b`** (2026-06-04); 8 errors → 8 passed. For upstream: cherry-pick `e3bf69b` onto `origin/main` (clean — conftest:338 identical upstream).
- **Scrub:** none. Has implicit proof (suite goes green). Clean test-infra PR — fixes his own harness, good seriousness signal.

## A8. warn misplaced card extensions — `a13e7c8` — MED
- **Title:** `fix(init): warn when character card extensions are misplaced`
- **Bug:** `extensions` at top level instead of nested under `data` → persona block parses empty, agent silently boots default identity.
- **Fix:** log a warning. `core/init_api.py`.
- **Scrub:** none.

---

## Mixed-split mining (2026-06-04) — INSPECTED, all 3 ruled out

Inspected the three that looked extract-worthy from subjects. None upstreamable:
- `7e30ee2` repl-episodic — **RULED OUT.** Fixes `chat_repl.py`, which does NOT exist in `origin/main` (local dev REPL). Correct + useful locally; nothing to PR.
- `ecfbd06` RLM loop — **RULED OUT.** The `core/llm.py` hunk only *removes* `frequency_penalty=0.4` (itself a local addition `e02cb49`, Tier D) → revert matters locally only. Real fix is in `set-power-mode.ps1` (ops) + RP-merge-specific `hexis_rlm.py` caps.
- `4ae2891` outbox isolation — **RULED OUT (fleet-only).** Bug (N persona workers racing one shared RabbitMQ queue) only exists with multiple personas on one broker = our fleet topology. Single-instance upstream lacks it; agent-stamp defense is over-fit. Park unless Eric signals multi-instance interest.

Lesson re-confirmed: subject-level optimism ≠ upstream-fit. Inspect the diff + check the target exists upstream before promoting. Mixed-split bucket = effectively a dead end (local files / reverts / fleet-topology).

Already-tracked Tier-B mixed (own files / strategy doc): `1684d8c` jitter, `aef9652` night-mode (split embed-to-CPU), `4661566` history-cap (`TIERB-`), `944b23a` agent-profile name field (Tier-A hunk) + db/99 (never). Rest of mixed = reach-out cluster (Tier C) + persona/eco (Tier D).

## PR-2 (sequenced behind PR #19) — strip leading divider — `4ff607e`
- **Title:** `fix(llm): strip leading markdown divider from model output`
- **Depends on `0b3beb2`** (PR #19) — it's a sibling that calls `strip_reasoning`. Ship only after #19 lands.
- **Bug:** abliterated Gemma 4 merges sometimes open a reply with a lone `---` rule (markdown-structure leakage).
- **Fix:** `strip_leading_divider()` drops leading `---`/`***`/`___` + whitespace; touches only the start, internal rules survive. Applied at both chat-completion return sites after `strip_reasoning`. `core/llm.py`.
- **Scrub:** "Eudora's onboarding" → generic; frame on the general case, not the specific model.
