#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"
mkdir -p .build/checks

xcrun swiftc -parse-as-library \
  Sources/AgentTray/Models.swift \
  Sources/AgentTray/ProfileCatalog.swift \
  Sources/AgentTray/ProcessRunner.swift \
  Sources/AgentTray/CodexStatsProvider.swift \
  Sources/AgentTray/GrokStatsProvider.swift \
  Tests/AgentTrayTests/AgentTrayTests.swift \
  -o .build/checks/AgentTrayTests

.build/checks/AgentTrayTests "$@"
