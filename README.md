# Agent Tray

Agent Tray is a native macOS edge-notch utility for monitoring local Grok, Cursor, and Codex profiles. It shows quota rings on the display edge and usage windows on hover, without storing prompts or credentials.

## Requirements

- macOS 14 or later
- Swift 5.10 or later
- Grok, Cursor, and/or Codex installed locally

## Build and test

```sh
./scripts/test.sh
./scripts/package.sh
open ".build/Agent Tray.app"
```

The packaging script creates an ad-hoc signed local app bundle. Move it to `/Applications` before enabling Launch at Login.

## Data access

- Codex quota and account usage come from the local `codex app-server` protocol.
- Codex profile activity comes from session metadata under `$CODEX_HOME` or `~/.codex`.
- Grok quota and activity are estimates derived from metadata in `~/.grok/logs/unified.jsonl`.
- Cursor plan limits come from the signed-in Cursor dashboard session. Local activity comes from `~/.cursor/ai-tracking` suggestion metadata, not conversation content.

Agent Tray does not read or persist prompts, responses, or credential values. Azure-backed Codex profiles show local activity when their existing process environment cannot provide authenticated quota data.
