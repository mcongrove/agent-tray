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
```

`package.sh` builds an ad-hoc signed app and installs it to `/Applications/Agent Tray.app`. Launch from there once; login launch registers automatically.

## Data access

- Codex quota and account usage come from the local `codex app-server` protocol.
- Codex profile activity comes from session metadata under `$CODEX_HOME` or `~/.codex`.
- Grok quota and activity are estimates derived from metadata in `~/.grok/logs/unified.jsonl`.
- Cursor plan limits come from the signed-in Cursor dashboard session. Local activity comes from `~/.cursor/ai-tracking` suggestion metadata, not conversation content.

Agent Tray does not read or persist prompts, responses, or credential values. Azure-backed Codex profiles show local activity when their existing process environment cannot provide authenticated quota data.
