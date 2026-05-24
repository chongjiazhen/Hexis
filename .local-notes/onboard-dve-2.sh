#!/usr/bin/env bash
# Onboard denali/vesper/eudora — PHASE 2: supplementary config + consent-noise purge
# + persona system-prompt anchor + start channel workers.
# Run from git-bash at C:\hexis, ONLY for personas that GRANTED consent in phase 1.
# Edit PERSONAS below to drop any that declined.
set -uo pipefail
cd /c/hexis
PERSONAS="denali vesper eudora"

for P in $PERSONAS; do
  DB="hexis_${P}"
  U=$(echo "$P" | tr '[:lower:]' '[:upper:]')

  echo "=== $P: §2.5 token + DM allowlist + emotion bootstrap ==="
  docker exec hexis_brain psql -U hexis_user -d "${DB}" -c \
    "SELECT set_config('channel.telegram.bot_token','\"${U}_TELEGRAM_BOT_TOKEN\"'::jsonb);
     SELECT set_config('channel.telegram.allowed_users','[\"593307304\"]'::jsonb);
     SELECT ensure_emotion_bootstrap();"

  echo "=== $P: §2.5b purge consent-flow noise ==="
  ids=$(docker exec hexis_brain psql -U hexis_user -d "${DB}" -tAc \
    "SELECT string_agg(quote_literal(x),',') FROM jsonb_array_elements_text(
     (SELECT value FROM config WHERE key='agent.consent_memory_ids')) x;")
  if [ -n "$ids" ]; then
    docker exec hexis_brain psql -U hexis_user -d "${DB}" -tAc \
      "DELETE FROM memories WHERE id IN ($ids) RETURNING id,type;"
  else
    echo "  (no consent_memory_ids — skip)"
  fi

  echo "=== $P: §2.5c apply persona system-prompt cold-start anchor ==="
  docker exec -i hexis_brain psql -U hexis_user -d "${DB}" -v ON_ERROR_STOP=1 \
    -f - < /c/hexis/characters/set_persona_prompt.${P}.sql
  docker exec hexis_brain psql -U hexis_user -d "${DB}" -tAc \
    "SELECT '${P}: persona_system_prompt len='||
     COALESCE(length((SELECT value::text FROM config WHERE key='agent.persona_system_prompt')),0);"
done

echo
echo "=== build + start channel workers (--no-deps: do NOT recreate hexis_brain) ==="
docker compose -f docker-compose.yml -f docker-compose.newchars.yml \
  up -d --build --no-deps \
  denali_channel_worker vesper_channel_worker eudora_channel_worker

echo
echo "=== §2.8 parity vs hexis_mira (expect empty diff) ==="
for P in $PERSONAS; do
  echo "--- $P ---"
  diff <(docker exec hexis_brain psql -U hexis_user -d hexis_mira -tAc "SELECT key FROM config ORDER BY 1") \
       <(docker exec hexis_brain psql -U hexis_user -d "hexis_${P}" -tAc "SELECT key FROM config ORDER BY 1") \
    && echo "  parity OK"
done

echo
echo "=== Telegram connect check (look for 'Telegram connected as @<bot>', no Conflict/409) ==="
for P in $PERSONAS; do
  echo "--- $P ---"
  docker logs --tail 15 "hexis_${P}_channel_worker" 2>&1 | grep -iE 'telegram|conflict|error' || echo "  (no match)"
done
