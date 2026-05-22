# Alert Direct-to-Telegram Fallback — Design

**Date:** 2026-05-22
**Status:** Approved design, pending implementation plan
**Builds on:** `2026-05-22-telegram-alert-persona-design.md`

## Problem

The Telegram alert pipeline routes every alert through the local hexis stack
(`script → hexis_api → worker → outbox → telegram adapter → Telegram`). Hexis
is therefore a single point of failure: if the local box is down, alerts never
reach Telegram at all — not just the persona commentary, the alert itself.

This design adds a fallback so a live alert still reaches the user when hexis is
unavailable, and hexis's memory is backfilled once it recovers.

## Decisions (locked during brainstorming)

| Question | Decision |
|----------|----------|
| Outage-window alerts | **Buffer + replay on recovery.** The script delivers direct-to-Telegram during the outage *and* buffers the alert; on recovery it replays the buffer to hexis as memory-only. The persona's memory has no gap. |
| Reference helper languages | **Python (stdlib `urllib.request`)** for `daily_report.py` and the beta alert scripts; **Bash (`curl`)** for the `canary*.sh` set. Both forms specified below. |
| Replayed-alert reaction | None. A replayed alert is hours old; a reaction would be stale noise. Replay is pure awareness backfill. |

## Architecture

```
                  ┌─ webhook POST ok ──► hexis pipeline (normal) ─► Telegram
script's          │                      then: drain buffer ─► replay (deliver=false)
send_alert()  ────┤
                  └─ webhook POST fails ─┬─► direct-to-Telegram (⚠️ marker)
                                         └─► append to local buffer file
```

Two code surfaces:

1. **Hexis** — one change: a `deliver` flag on the `/api/webhook/alert` payload.
2. **Script-side helper** — a shared `send_alert()` the alert scripts call
   instead of POSTing the webhook (or calling Telegram) directly. Lives in the
   user's script repos, not in hexis; reference implementations are in the
   Appendix.

## Component 1 — Hexis `deliver` flag

`/api/webhook/alert` payload gains one optional field:

```json
{ "text": "...", "priority": "high", "title": "...", "deliver": true }
```

`deliver` — bool, default `true`. Read in `_handle_alert_webhook`
(`services/worker_service.py`).

### `deliver: true` (default — a normal live alert)

Current behavior, unchanged, with one addition: the episodic-memory `context`
dict gains `"delivered_via": "hexis"`.

### `deliver: false` (a replay of an outage-window alert)

The script already delivered this alert direct-to-Telegram during the outage.
Replay must **not** re-send it and must **not** react (the alert is stale). It
is pure memory backfill:

- `text` is still required — raise `ValueError` if missing/empty.
- The `channel.telegram.alert_chat_id` requirement is **skipped** — replay never
  delivers to a chat, so no destination is needed.
- **Skip step 1** (raw outbox publish).
- Record the episodic memory exactly as the live path does (importance keyed to
  priority: `high` → 0.7, `normal` → 0.4), but with `context` carrying
  `"delivered_via": "direct_fallback"` and `"reacted": true` — the latter so the
  heartbeat batch never picks it up for a stale reaction.
- **Skip step 3** (no reaction, immediate or batched).
- Return `{"source": "alert", "priority": priority, "delivered": false, "reacted": true, "mode": "replay"}`.

Memory `content` stays uniform (`f"Alert ({priority}): {text}"`); provenance
lives in the `delivered_via` context key.

### Tests (hexis side)

- `test_alert_webhook_replay_skips_delivery` — `deliver: false`, fake bridge →
  zero publishes; memory created with `delivered_via="direct_fallback"`,
  `reacted=true`, importance matching priority; result `delivered` is `false`.
- `test_alert_webhook_replay_missing_text_raises` — `deliver: false`, no `text`
  → `ValueError`.
- `test_alert_webhook_live_stamps_delivered_via` — a normal `deliver`-absent
  call → memory `context.delivered_via == "hexis"`.

## Component 2 — Script-side `send_alert()` helper

A shared helper the alert scripts call. Behavior, identical across both language
forms:

1. `POST /api/webhook/alert` with `{text, priority, title, deliver: true}`,
   short timeout (~3 s).
2. **Success (2xx)** → hexis owns delivery. Then **drain the buffer** (§Replay).
   Return `"hexis"`.
3. **Failure** (connection refused, timeout, non-2xx) →
   a. Send **direct-to-Telegram** via `api.telegram.org/bot<TOKEN>/sendMessage`,
      text prefixed with the marker `⚠️ ` (signals "hexis did not see this
      live"). 10 s timeout.
   b. Append the alert (without `deliver`) to the local buffer file.
   c. Return `"direct"` if the Telegram send succeeded, else `"lost"`.

The live alert path is never blocked by hexis being down, and a buffer or drain
failure never breaks it.

### Replay / drain

On any successful webhook POST (step 2), drain the buffer:

- Read buffered alerts oldest-first.
- For each, `POST /api/webhook/alert` with the alert plus `deliver: false`.
- On a successful replay, drop that line from the buffer.
- On a replay failure, **stop draining** (hexis flaky again) — keep that line
  and all later lines for the next attempt.
- Cap at 50 replays per call so a long outage backlog never stalls a script.

### Buffer file

- Path: `~/.hexis-alert-buffer.jsonl` (override via `HEXIS_ALERT_BUFFER`).
- Format: append-only, one JSON alert object per line (JSONL).
- Append is atomic enough for short lines under concurrent scripts (POSIX
  `write` ≤ PIPE_BUF). The drain is a read-modify-write and takes an exclusive
  lock (`fcntl.flock` in Python, `flock` in Bash, on a `.lock` sidecar file) so
  two scripts cannot both rewrite the buffer.
- A corrupt line is dropped silently during drain.

### Configuration (env vars the helper reads)

| Var | Purpose | Default |
|-----|---------|---------|
| `HEXIS_ALERT_WEBHOOK_URL` | the alert webhook | `http://localhost:43817/api/webhook/alert` |
| `TELEGRAM_BOT_TOKEN` | bot token for the direct fallback | — (no fallback if unset) |
| `TELEGRAM_ALERT_CHAT_ID` | destination chat for the direct fallback | — (no fallback if unset) |
| `HEXIS_ALERT_BUFFER` | buffer file path | `~/.hexis-alert-buffer.jsonl` |

The token and chat id necessarily duplicate hexis's own `.env` — that
duplication is the point: the fallback must work when hexis (and its config)
is unreachable.

## Out of scope

- No persona reaction on replayed alerts (stale by definition).
- No de-duplication beyond the buffer. If a script crashes between the
  direct-send and the buffer-append, that one alert is not replayed — a memory
  gap, never a double-send. Accepted.
- The helper is **not** committed to the hexis repo. It belongs in the user's
  script repos (`~/trade-recon`, `~/solux/lazyalpha/trading_stack`). The
  Appendix reference implementations are to be copied there.
- POSIX assumed for the lock primitive (`fcntl` / `flock`). The alert scripts
  are Bash with `~/` paths, i.e. POSIX hosts. A Windows-native Python caller
  would need `msvcrt.locking` instead — out of scope unless it arises.

## Appendix A — Python reference helper (stdlib only)

`hexis_alert.py` — no third-party dependencies; `daily_report.py` and the beta
alert scripts `import` it.

```python
"""hexis_alert.py — resilient alert sender with direct-to-Telegram fallback.

Stdlib only (urllib.request) — no requests/httpx/aiohttp. Drop into any script.
"""
from __future__ import annotations

import fcntl
import json
import os
import urllib.error
import urllib.request

WEBHOOK_URL = os.environ.get(
    "HEXIS_ALERT_WEBHOOK_URL", "http://localhost:43817/api/webhook/alert"
)
BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("TELEGRAM_ALERT_CHAT_ID", "")
BUFFER_PATH = os.path.expanduser(
    os.environ.get("HEXIS_ALERT_BUFFER", "~/.hexis-alert-buffer.jsonl")
)
WEBHOOK_TIMEOUT = 3.0
DRAIN_CAP = 50
FALLBACK_MARKER = "⚠️ "  # ⚠️


def _post_json(url: str, body: dict, timeout: float) -> int:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status


def _webhook_post(body: dict) -> bool:
    """POST to the hexis alert webhook. True on 2xx, False on any failure."""
    try:
        return 200 <= _post_json(WEBHOOK_URL, body, WEBHOOK_TIMEOUT) < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _telegram_direct(text: str) -> bool:
    """Send straight to Telegram, bypassing hexis. True on success."""
    if not BOT_TOKEN or not CHAT_ID:
        return False
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    body = {"chat_id": CHAT_ID, "text": FALLBACK_MARKER + text}
    try:
        return 200 <= _post_json(url, body, 10.0) < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _buffer_append(alert: dict) -> None:
    """Append an alert to the buffer. Best-effort — never raises to the caller."""
    try:
        with open(BUFFER_PATH, "a", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            try:
                f.write(json.dumps(alert) + "\n")
            finally:
                fcntl.flock(f, fcntl.LOCK_UN)
    except OSError:
        pass


def _drain_buffer() -> None:
    """Replay buffered alerts to hexis as memory-only (deliver=false)."""
    if not os.path.exists(BUFFER_PATH):
        return
    lock_path = BUFFER_PATH + ".lock"
    try:
        lock = open(lock_path, "w")
    except OSError:
        return
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with open(BUFFER_PATH, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
        remaining: list[str] = []
        drained = 0
        for i, line in enumerate(lines):
            if not line.strip():
                continue
            if drained >= DRAIN_CAP:
                remaining.extend(lines[i:])
                break
            try:
                alert = json.loads(line)
            except ValueError:
                continue  # drop a corrupt line
            if _webhook_post(dict(alert, deliver=False)):
                drained += 1
            else:
                remaining.extend(lines[i:])  # hexis flaky again — stop
                break
        with open(BUFFER_PATH, "w", encoding="utf-8") as f:
            f.write("\n".join(remaining) + ("\n" if remaining else ""))
    except OSError:
        pass
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def send_alert(text: str, priority: str = "normal", title: str | None = None) -> str:
    """Send an alert. Returns 'hexis', 'direct', or 'lost'.

    'hexis'  — delivered via the persona webhook (normal path).
    'direct' — webhook down; delivered straight to Telegram, buffered for replay.
    'lost'   — webhook down AND direct send failed; alert buffered only.
    """
    alert: dict = {"text": text, "priority": priority}
    if title:
        alert["title"] = title

    if _webhook_post(dict(alert, deliver=True)):
        _drain_buffer()
        return "hexis"

    delivered = _telegram_direct(text)
    _buffer_append(alert)
    return "direct" if delivered else "lost"
```

## Appendix B — Bash reference helper

`hexis-alert.sh` — sourced by the `canary*.sh` scripts; depends on `curl`,
`flock`, and `python3` (already present — the stack runs Python). After
sourcing, call `hexis_send_alert "text" [priority] [title]`.

```bash
# hexis-alert.sh — resilient alert sender with direct-to-Telegram fallback.
# Source this file, then call:  hexis_send_alert "text" [priority] [title]
# Echoes one of: hexis | direct | lost

HEXIS_ALERT_WEBHOOK_URL="${HEXIS_ALERT_WEBHOOK_URL:-http://localhost:43817/api/webhook/alert}"
HEXIS_ALERT_BUFFER="${HEXIS_ALERT_BUFFER:-$HOME/.hexis-alert-buffer.jsonl}"
HEXIS_WEBHOOK_TIMEOUT="${HEXIS_WEBHOOK_TIMEOUT:-3}"
HEXIS_DRAIN_CAP="${HEXIS_DRAIN_CAP:-50}"

# JSON-encode a string (produces a quoted JSON string literal).
_hexis_json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

# POST a JSON body. Returns 0 on a 2xx response.
_hexis_post() {  # $1=url  $2=body  $3=timeout
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$3" \
    -H 'Content-Type: application/json' -X POST -d "$2" "$1" 2>/dev/null) || return 1
  [ -n "$code" ] && [ "$code" -ge 200 ] && [ "$code" -lt 300 ]
}

_hexis_webhook_post() { _hexis_post "$HEXIS_ALERT_WEBHOOK_URL" "$1" "$HEXIS_WEBHOOK_TIMEOUT"; }

_hexis_telegram_direct() {  # $1=text
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_ALERT_CHAT_ID" ] || return 1
  local text_json
  text_json=$(_hexis_json "⚠️ $1")
  _hexis_post "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    "{\"chat_id\":\"${TELEGRAM_ALERT_CHAT_ID}\",\"text\":${text_json}}" 10
}

# Replay buffered alerts to hexis as memory-only (deliver=false), oldest-first.
_hexis_drain_buffer() {
  [ -f "$HEXIS_ALERT_BUFFER" ] || return 0
  (
    flock -x 200
    local tmp drained=0 line replay
    tmp=$(mktemp)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if [ "$drained" -ge "$HEXIS_DRAIN_CAP" ]; then
        printf '%s\n' "$line" >> "$tmp"; continue
      fi
      # Each buffered line is a flat JSON object {...}; inject deliver:false.
      replay="${line%\}}, \"deliver\": false}"
      if _hexis_webhook_post "$replay"; then
        drained=$((drained + 1))
      else
        printf '%s\n' "$line" >> "$tmp"   # stop replaying; keep this line
        # keep the remaining lines too:
        while IFS= read -r line; do printf '%s\n' "$line" >> "$tmp"; done
        break
      fi
    done < "$HEXIS_ALERT_BUFFER"
    mv "$tmp" "$HEXIS_ALERT_BUFFER"
  ) 200>"${HEXIS_ALERT_BUFFER}.lock"
}

# hexis_send_alert "text" [priority] [title]
hexis_send_alert() {
  local text="$1" priority="${2:-normal}" title="$3"
  local body text_json
  text_json=$(_hexis_json "$text")
  body="{\"text\":${text_json},\"priority\":\"${priority}\""
  [ -n "$title" ] && body="${body},\"title\":$(_hexis_json "$title")"
  body="${body}}"

  if _hexis_webhook_post "${body%\}}, \"deliver\": true}"; then
    _hexis_drain_buffer
    echo "hexis"; return 0
  fi

  local result="lost"
  _hexis_telegram_direct "$text" && result="direct"
  printf '%s\n' "$body" >> "$HEXIS_ALERT_BUFFER"
  echo "$result"
}
```

Note on the Bash `deliver`-injection (`${line%\}}, ...`): it strips the trailing
`}` and appends `, "deliver": <bool>}`. This is safe because every buffered line
is produced by `hexis_send_alert` itself — a flat, single-line JSON object. It
would break on a pretty-printed or nested object; the buffer format is
controlled, so it holds.
