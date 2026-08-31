#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$project_root/.build/Agent Tray.app"
contents_dir="$app_dir/Contents"

if [[ -d "$app_dir" ]]; then
  rm -r "$app_dir"
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_dir/AgentTray" "$contents_dir/MacOS/AgentTray"
cp "$project_root/Resources/Info.plist" "$contents_dir/Info.plist"
if [[ -d "$binary_dir/AgentTray_AgentTray.bundle" ]]; then
  cp -R "$binary_dir/AgentTray_AgentTray.bundle" "$contents_dir/Resources/"
fi
codesign --force --sign - "$app_dir"

echo "$app_dir"
