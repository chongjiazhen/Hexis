# DROPPED — agent.tools seed correction

**Status: NOT for upstream.** Source `ec9e1ec`. Demoted in `00-engagement-strategy.md`:
the seed correction is entangled with fleet-driven `agent.tools` values (our registry
names / persona allowlists), and `ec9e1ec` also carries sender_id pollution. The "clean
log on fresh init" benefit is real but fleet-specific — upstream's registry differs. Keep
local. Retained here only so the decision is documented.

---

(original draft — do not ship)

The default seed for `agent.tools` in `db/00_tables.sql` lists tool names that no longer
exist in `core/tools/registry.py`. On fresh `hexis init`, seed values are silently dropped
at runtime (registry filters unknown names) but cause spurious "configured tool not found"
warnings in worker startup logs. The local fix realigns the seed to our registry output —
but "our registry output" is the fleet's, not upstream's, so it doesn't port.
