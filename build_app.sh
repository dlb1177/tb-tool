#!/bin/zsh
# Builds "TB Tool.app" in this folder — a universal (Apple silicon + Intel), ad-hoc-signed
# macOS app bundle. Put the app anywhere: in Applications, or in a client's folder, where it
# opens the trial balance JSON that sits beside it.
set -euo pipefail
cd "$(dirname "$0")"

echo "▸ Running tests…"
swift test 2>&1 | grep -E "Executed|error|failed" || true

echo "▸ Building universal release binaries…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -vE "^\[|x86_64 architecture is deprecated" || true

APP="TB Tool.app"
PRODUCTS="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path 2>/dev/null)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/TBTool" "$APP/Contents/MacOS/TBTool"
cp "$PRODUCTS/tbcli" "$APP/Contents/MacOS/tbcli"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)…"
codesign --force --deep --sign - --timestamp=none "$APP"

echo "▸ Verifying…"
codesign --verify --deep --verbose=2 "$APP"
echo "✅ Done: $APP"
