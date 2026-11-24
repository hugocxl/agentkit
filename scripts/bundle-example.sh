#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/worktree.sh" com.hugocxl.AgentKitExample "AgentKit Example"
if [ "${1:-}" != --skip-build ]; then swift build --product AgentKitExample; fi
BIN="$(swift build --show-bin-path)"
VERSION="$(scripts/changelog.sh version)"
APP="$ROOT/build/AgentKit Example.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/AgentKitExample" "$APP/Contents/MacOS/AgentKitExample"
for bundle in "$BIN"/*.bundle; do
    [ -d "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${WT_BUNDLE_ID}</string>
<key>CFBundleName</key><string>${WT_APP_NAME}</string>
<key>CFBundleExecutable</key><string>AgentKitExample</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${VERSION:-1.0.0}</string>
<key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Dictate a message into the conversation composer.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Turn your dictation into an editable message.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "$APP"
