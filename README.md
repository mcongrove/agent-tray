# Agent Tray

Agent Tray is a native macOS menu-bar utility for monitoring local Grok and Codex profiles. It shows available quota windows, reset times, recent token activity, session activity, and provider health without storing prompts or credentials.

## Requirements

- macOS 14 or later
- Swift 5.10 or later
- Grok and/or Codex installed locally

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

Agent Tray does not read or persist prompts, responses, or credential values. Azure-backed Codex profiles show local activity when their existing process environment cannot provide authenticated quota data.
