# WSL2 standalone-dockerd Migration — PARKED

**Status:** evaluated 2026-05-16, parked. Not started. Current setup (Docker Desktop
+ `start-all.ps1` + Scheduled Task AtStartup/AtLogOn) stays. Resume only if true
pre-login headless boot becomes worth the migration risk.

## Why we're on Docker Desktop at all

Default path, never a decision. `winget install docker` gives: one installer,
auto WSL2 wiring, `host.docker.internal` for free, Windows `docker.exe` on PATH,
automatic firewall/port-proxy, auto-updates. Path of least resistance, not chosen
on merit.

## The trigger question

Goal was: bring all 4 characters (Sam/Baymax/Rocky/Tars) online **at boot, before
login**. Docker Desktop's engine is a per-user GUI app — cannot run with zero user
session. So Docker Desktop can never give true pre-login boot. Standalone `dockerd`
in a WSL2 distro can (WSL VM runs without an interactive session).

## Throughput verdict: neutral

The llama.cpp "native beats WSL" logic does NOT transfer:
- llama.cpp is GPU-bound → native NVIDIA driver beats WSL2 GPU-PV shim ~5-15%. Stays native.
- Hexis containers (Postgres/RabbitMQ/Python workers) are GPU-free and **already run
  in WSL2** — Docker Desktop *is* a WSL2 backend. Standalone dockerd is WSL2→WSL2,
  same substrate. LLM stays on native host llama-server (`:8080/:8081`) either way.
- Headless dockerd is marginally *lighter* (no Docker Desktop GUI/backend ~300-800MB idle).

So migration is throughput-neutral / slightly lighter. The cost is **migration risk
+ Win10 networking friction**, not performance.

## Environment constraints (captured 2026-05-16)

- Windows **10.0.19045** (Win10 22H2). WSL **2.7.3.0**, kernel 6.6.
- WSL *mirrored networking* needs **Win11 22H2+** → NOT available here. Stuck on NAT.
- Distros: `Ubuntu` (default), `docker-desktop`. Docker CLI = Docker Desktop's
  `docker.exe`, context `desktop-linux` (named pipe).

## Footguns, ranked

1. **Postgres data migration — CRITICAL / irreplaceable.** 4 DBs hold agent
   identity, consent, memory. Consent is *final* (project rule) — wiping = killing
   a character. Volume `postgres_data` lives in Docker Desktop's managed storage;
   standalone dockerd = different storage, volume invisible. MUST `pg_dumpall`
   (or volume tar) and verify per-DB row counts BEFORE anything destructive.

2. **`host.docker.internal` disappears — CRITICAL on Win10.** Docker Desktop
   injects it; standalone dockerd does not, and no mirrored mode on Win10.
   Hexis depends on it: DB→embeddings `http://host.docker.internal:8081/v1/embeddings`,
   bootstrap llm endpoint. Must add `extra_hosts: ["host.docker.internal:host-gateway"]`
   to every service in all 4 compose files AND confirm host-gateway under WSL2-NAT
   resolves to the **Windows** host (where native llama-server listens). Wrong →
   embeddings/LLM fail → agents can't recall/remember.

3. **Windows `docker.exe` vanishes — HIGH.** `start-all.ps1`/`start.ps1` call
   `docker compose` via Docker Desktop's CLI/pipe. Removing Desktop breaks them.
   Must rewrite launchers to `wsl -d <distro> -- docker compose ...` (do NOT expose
   dockerd over TCP — security footgun). Partly undoes the current scripts.

4. **Boot-start still needs the Scheduled Task — MEDIUM.** WSL VM doesn't self-start
   headless. Win is the VM *can* run with no session. Need S4U/SYSTEM task running
   `wsl -d <distro> -- <start dockerd>`. systemd in distro (`/etc/wsl.conf
   [boot] systemd=true`) supported by WSL 2.7.3 but enabling restarts the distro.

5. **Repo build location — MEDIUM.** Source compose `build:` from `C:\hexis`
   (NTFS). Building via `/mnt/c` = slow 9p + perm/EOL issues. Clone repo into WSL
   ext4 (divergent checkout) OR use GHCR runtime images
   (`ops/docker-compose.runtime.yml`) to skip build.

6. **Resource double-count + rollback — LOW.** `.wslconfig` caps shared across VM.
   Keep Docker Desktop installed-but-stopped during trial; never run both engines
   at once (port/distro contention). Decommission `docker-desktop` distro only
   after validated green.

## Safe migration order (if resumed)

1. `pg_dumpall` backup of all 4 DBs + verify restore on a scratch engine.
2. Stand up `dockerd` in `Ubuntu` distro **beside** Docker Desktop (don't run both at once).
3. Wire `extra_hosts` host-gateway; test embeddings + LLM reachability from a container.
4. Restore data; verify per-DB row counts (memories/consent/identity).
5. Rewrite `start-all.ps1`/`start.ps1` to drive `wsl -d Ubuntu -- docker compose`.
6. Cut over. Keep Docker Desktop as rollback until N days green.

## Bottom line

Not worth it just for the boot-vs-logon delta (current setup = online a few minutes
after logon screen, zero migration risk). Revisit only if pre-login headless
becomes a hard requirement.
