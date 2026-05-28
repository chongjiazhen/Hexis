# NSFW / Persona System-Prompt Injection

## Config key

`agent.persona_system_prompt` config key (per-persona DB) prepends card's
`data.system_prompt` + `post_history_instructions` to LLM system prompt.
Set via `set_persona_prompt.<P>.sql` (canonical re-seed; keep after DB wipe).

Apply:
```bash
docker exec -i hexis_brain psql -U hexis_user -d hexis_<P> < set_persona_prompt.<P>.sql
```

## Failure mode without it

Without `agent.persona_system_prompt`: `conversation.md` "honor your values/bounds"
→ model infers SFW posture → Qwen3 refuses in thinking → streaming yields ""
→ history poisoned.

## Empty-response guard

`channels/conversation.py` (`stream_channel_message`) contains an empty-response
guard that prevents `""` from being stored. If missing → perpetual silence after
first refusal.

## Full NSFW onboard recipe

`.local-notes/hexis-native-onboard-nsfw.prompt.md`
