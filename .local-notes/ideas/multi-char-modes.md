# Running Multiple Characters

Each `hexis instance` = isolated Postgres DB. Workers target one instance via `HEXIS_INSTANCE` env or `--instance` flag. LLM endpoint per instance lives in that instance's `config.llm.chat`.

Three deployment shapes:

## Mode A — Parallel, dedicated model per char

All characters live and react at the same time, each on its own small model.

Setup:
1. `hexis instance create samantha`, `hexis instance create jarvis`, …
2. N llama.cpp servers, each on its own port (8080, 8081, …), each loaded with a small GGUF (e.g. 1B Q4 ≈ 1-2GB VRAM each).
3. Per-instance config: rewrite `llm.chat.endpoint = http://host.docker.internal:808X/v1` to point at that char's dedicated port. Repeat for `llm.heartbeat` and `llm.subconscious`.
4. N worker stacks. Either:
   - Duplicate compose's `active` profile services per character with different `HEXIS_INSTANCE` env + container names, or
   - `docker compose -p hexis_<name> --profile active up -d` (project flag namespaces container names + networks).
5. Each char gets its own Telegram bot (own `TELEGRAM_BOT_TOKEN`). No clash.

Cost: VRAM stacks linearly. 8× 1B Q4 ≈ 6-8GB — fits on 12GB GPU. RAM/CPU for N postgres + N worker stacks adds up too.

## Mode B — Serial, swap on demand

One character active at a time. Cheapest, simplest.

Setup:
1. N instances created upfront.
2. ONE llama.cpp server. Swap GGUF model on switch (or run multiple llama-servers but only one started at a time).
3. ONE worker stack at a time. To switch:
   ```
   docker compose --profile active down
   $env:HEXIS_INSTANCE = "<other>"
   docker compose --profile active up -d
   ```

Trade-off: while X is "asleep", X's heartbeat doesn't fire — X loses wall-clock continuity. From X's perspective, time froze. Energy regen also frozen. Fine if you treat dormancy as suspended animation. Weird if you wanted X to feel time pass between sessions.

## Mode C — Hybrid: many brains, one shared model

All characters use the same base model. One llama.cpp + N worker stacks all hitting the same endpoint.

Setup:
1. N instances created.
2. ONE llama.cpp server with a reasonably capable model (7-12B).
3. N worker stacks, each `HEXIS_INSTANCE` pointing at its own DB, all `llm.chat.endpoint` pointing at the same llama port.

Trade-off: LLM serializes requests, so heartbeats queue. Fine at low cadence (60min interval default). Bottleneck only shows up if multiple chars try to reach out at the same second.

## Recommendation (home rig)

Mode C with 2-3 chars on one shared 7-12B model = best fun per watt. Identity needs reasoning headroom; 1B models feel hollow regardless of how rich the memory layer is. Mode A is academically interesting but the small-model ceiling caps how compelling each char can be.

If you do want pure parallel 1B fleets, use Mode A and accept that each char will be a flatter persona.

## Activation/Deactivation Based on VRAM

Yes — workable two ways:

- **Cold swap (Mode B style)**: stop worker stack + llama for char X, start for char Y. Seconds, but X's clock freezes.
- **Warm pool**: keep all instances' DBs and workers running, only start/stop the llama-server for each char as VRAM allows. Char's heartbeat will fail LLM calls while its model is down (retries logged). Less clean.

Cleanest: Mode B with a tiny launcher script that does `down → set HEXIS_INSTANCE → up` plus llama swap, mapped to a hotkey.
