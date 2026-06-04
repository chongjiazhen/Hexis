#!/usr/bin/env bash
# Build full applicable migration by inlining @@INLINE markers in
# migrate-additive.sql. Pulls files from the trial worktree.
#
# Usage:
#   ./migrate-additive-build.sh > migrate-additive.full.sql
#
# Then apply per persona:
#   for p in $personas; do
#     docker exec -i hexis_brain psql -U hexis_user -d hexis_$p \
#       --single-transaction --set ON_ERROR_STOP=on \
#       < migrate-additive.full.sql
#   done

set -euo pipefail

SHELL_FILE="$(dirname "$0")/migrate-additive.sql"
WORKTREE="${TRIAL_WORKTREE:-C:/Users/User/.claude/jobs/f3783d2d/hexis-upstream}"

if [[ ! -d "$WORKTREE/db" ]]; then
    echo "ERROR: trial worktree db/ not found at $WORKTREE/db" >&2
    echo "       set TRIAL_WORKTREE env var or fix path in this script" >&2
    exit 2
fi

while IFS= read -r line; do
    if [[ "$line" =~ ^--\ @@INLINE:\ (.+)$ ]]; then
        rel="${BASH_REMATCH[1]}"
        src="$WORKTREE/$rel"
        if [[ ! -f "$src" ]]; then
            echo "ERROR: inline source missing: $src" >&2
            exit 3
        fi
        echo
        echo "-- ===== BEGIN INLINE: $rel ====="
        cat "$src"
        echo "-- ===== END INLINE: $rel ====="
        echo
    else
        echo "$line"
    fi
done < "$SHELL_FILE"
