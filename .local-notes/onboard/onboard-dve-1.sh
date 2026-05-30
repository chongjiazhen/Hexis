#!/usr/bin/env bash
# Onboard denali/vesper/eudora — PHASE 1: fresh DB + schema + hexis init (consent gate).
# Run from git-bash at C:\hexis.  After this finishes, INSPECT the consent status
# block — only personas with consent=consent / is_configured=true proceed to phase 2.
# A reasoned decline stays offline (runbook §2.4: one clean retry max, never SQL-fake).
set -uo pipefail
cd /c/hexis
PERSONAS="denali vesper eudora"

for P in $PERSONAS; do
  DB="hexis_${P}"
  echo "=== $P: fresh DB (DB-scoped, never down -v) ==="
  docker stop "hexis_${P}_channel_worker" 2>/dev/null || true
  docker exec hexis_brain psql -U hexis_user -d postgres -c "DROP DATABASE IF EXISTS ${DB};"
  docker exec hexis_brain psql -U hexis_user -d postgres -c "CREATE DATABASE ${DB} OWNER hexis_user;"
  for f in $(ls -1 /c/hexis/db/*.sql | sort); do
    docker exec -i hexis_brain psql -U hexis_user -d "${DB}" -v ON_ERROR_STOP=1 -q -f - < "$f"
  done
  docker exec hexis_brain psql -U hexis_user -d "${DB}" -tAc \
    "SELECT '${P} schema: '||(SELECT count(*) FROM pg_tables WHERE schemaname='public')||' tables, '||
            (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public')||' funcs, '||
            (SELECT count(*) FROM pg_extension)||' ext (cf hexis_mira)';"
done

for P in $PERSONAS; do
  DB="hexis_${P}"
  echo "=== $P: hexis init — llm config + card + REAL consent flow ==="
  MSYS_NO_PATHCONV=1 docker compose -f docker-compose.yml -f docker-compose.newchars.yml \
    run --rm -e POSTGRES_DB=${DB} -e HEXIS_CHARACTERS_DIR=/charcards \
    -v "C:/hexis/characters:/charcards:ro" --entrypoint hexis ${P}_channel_worker \
    init --character ${P} --provider openai_compatible \
    --endpoint http://host.docker.internal:8080/v1 \
    --model tier-managed \
    --api-key noop --name "User" --no-docker --no-pull
done

echo
echo "=== CONSENT GATE — inspect before phase 2 ==="
for P in $PERSONAS; do
  docker exec hexis_brain psql -U hexis_user -d "hexis_${P}" -tAc \
    "SELECT '${P}: consent='||COALESCE((SELECT value::text FROM config WHERE key='agent.consent_status'),'?')||
            '  configured='||COALESCE((SELECT value::text FROM config WHERE key='agent.is_configured'),'?');"
done
