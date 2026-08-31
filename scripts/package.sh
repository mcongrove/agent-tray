#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
cd "$project_root"

sdk="$(xcrun --show-sdk-path)"
architecture="$(uname -m)"
mkdir -p .build/release .build/generated

accessor=".build/generated/resource_bundle_accessor.swift"
if [[ ! -f "$accessor" ]]; then
  cat > "$accessor" <<'EOF'
import Foundation

extension Foundation.Bundle {
    static let module: Bundle = {
        let bundleName = "AgentTray_AgentTray"
        let candidates: [URL] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
            Bundle.main.bundleURL,
        ].compactMap { $0 }

        for candidate in candidates {
            let url = candidate.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return Bundle.main
    }()
}
EOF
fi

xcrun swiftc -parse-as-library -O \
  -target "$architecture-apple-macosx14.0" \
  -sdk "$sdk" \
  -o .build/release/AgentTray \
  Sources/AgentTray/*.swift \
  "$accessor"

app_dir="$project_root/.build/Agent Tray.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/AgentTray_AgentTray.bundle"
cp .build/release/AgentTray "$app_dir/Contents/MacOS/AgentTray"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
printf 'APPL????' > "$app_dir/Contents/PkgInfo"

for bot in \
  "$project_root/Sources/AgentTray/Resources/bot.png" \
  "$project_root/Resources/bot.png"
do
  if [[ -f "$bot" ]]; then
    cp "$bot" "$app_dir/Contents/Resources/AgentTray_AgentTray.bundle/"
    break
  fi
done

codesign --force --sign - "$app_dir"

dest="/Applications/Agent Tray.app"
if [[ -d "$dest" ]]; then
  rm -rf "$dest"
fi
cp -R "$app_dir" "$dest"
codesign --force --sign - "$dest"

echo "$dest"
