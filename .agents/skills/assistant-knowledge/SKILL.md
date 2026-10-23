---
description: Update the Trio Assistant's server-side brain (knowledge, behavior rules, conversation memory) with zero app rebuild — edit the knowledge file on the Mac, live on the next new chat. Also covers recovering chat transcripts from ~/.codex/sessions.
---

# Trio Assistant knowledge & memory updates

## Purpose
The assistant's knowledge lives on the server, not in the app. Teaching it anything = editing one file. No build, no TestFlight, no restart.

## When to use
- Eddie wants the assistant smarter on a topic ("research X and teach it")
- A behavior tweak ("it should always mention pre-bolus timing")
- Preserving/restoring conversation continuity after a chat breaks

## Key paths (Mac mini)
- **Knowledge file (the brain):** `~/.codex-proxy/knowledge/diabetes-coach.md` — injected into the system prompt of every NEW chat by the proxy (`loadKnowledge()` in `codex-proxy/src/server.js`). Read fresh per conversation: edits are live instantly, no proxy restart.
- **Chat transcripts (server-side):** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — every assistant conversation thread. Parse `payload.type == "message"` items; user text follows `"My message: "` or is the last block after context payloads; strip ```nutrition blocks from assistant text.
- **Proxy streaming knobs:** `CHAT_HEARTBEAT_MS` / `CHAT_TIMEOUT_MS` env for `ai.salem.codex-proxy` (restart via `launchctl kickstart -k gui/501/ai.salem.codex-proxy` — proxy restart is fine; it is NOT the OpenClaw gateway, which must never be restarted without authorization).

## Steps
1. **Adding researched knowledge**: run a parallel research workflow (cited, primary sources — this is a medical tool, never write algorithm/clinical "facts" from memory), synthesize to Markdown, append as a new numbered `## section` to the knowledge file. Keep the existing structure: Trio/oref algorithm first, `## Uncertainties` hedging section, diagnostic checklist.
2. **Behavior rules**: add to the `## COACHING BEHAVIOR` section near the top (e.g. "always give pre-bolus timing on meal estimates").
3. **Conversation memory / recovery**: extract the conversation from the session jsonl files, distill (include Eddie-specific facts like his phantom-carb habit and "ask, don't assume" notes), append/update the `## Conversation Memory` section.
4. **Verify**: tell Eddie to start a NEW chat (✎) — existing threads keep their old system prompt; only new conversations pick up edits.

## Expected output
Confirmation of what was added/changed and the one-liner: "live on your next new chat — no app update needed."
