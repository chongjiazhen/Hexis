# Pending: sync Output Style rule to atelier/setup.sh

`~/.claude/rules/code-modification.md` was updated on this box (home-rig-local)
with a new `## Output Style` section. Needs to be mirrored to `~/atelier` on
whichever box has that repo.

## If rules/ are symlinked from ~/atelier/rules/

Edit `~/atelier/rules/code-modification.md` directly — append the block below.

## If setup.sh writes the file via heredoc

Add this idempotent guard to `~/atelier/setup.sh`, immediately after the block
that writes/symlinks `code-modification.md`:

```bash
# Output Style rule — no trailing footnote meta-commentary
if ! grep -q '## Output Style' ~/.claude/rules/code-modification.md 2>/dev/null; then
cat >> ~/.claude/rules/code-modification.md << 'EOF'

## Output Style

**Do the work. Don't narrate the work.**

No trailing footnotes, bracketed asides, or parenthetical meta-commentary explaining decisions not made, scope skipped, or issues noticed-but-not-addressed. Examples of banned patterns:

- `(Runbook §6 flags X — separate issue; not touching here.)`
- `Excluded from re-apply: Y — declined card, no operational worker.`
- `Note: did not modify Z as it was out of scope.`

If something warrants attention → surface it as a direct statement or question before or after the work, not buried in a trailing caveat. If it doesn't warrant surfacing → don't mention it at all.
EOF
fi
```

## Section content (for manual paste)

```markdown
## Output Style

**Do the work. Don't narrate the work.**

No trailing footnotes, bracketed asides, or parenthetical meta-commentary explaining decisions not made, scope skipped, or issues noticed-but-not-addressed. Examples of banned patterns:

- `(Runbook §6 flags X — separate issue; not touching here.)`
- `Excluded from re-apply: Y — declined card, no operational worker.`
- `Note: did not modify Z as it was out of scope.`

If something warrants attention → surface it as a direct statement or question before or after the work, not buried in a trailing caveat. If it doesn't warrant surfacing → don't mention it at all.
```
