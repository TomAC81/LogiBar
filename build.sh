#!/bin/zsh
# Builds LogiBar.app and (with --install) installs it to /Applications.
# The bundle is assembled outside this folder because synced folders add
# extended attributes that break code signing.
set -e
cd "$(dirname "$0")"
STAGE=$(mktemp -d)/LogiBar.app
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
clang -c -O2 -Wall -mmacosx-version-min=14.0 Sources/uvc.c -o "${STAGE:h}/uvc.o"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -import-objc-header Sources/uvc.h Sources/*.swift "${STAGE:h}/uvc.o" \
  -framework IOKit -framework CoreFoundation -framework CoreMediaIO -o "$STAGE/Contents/MacOS/LogiBar"
cp Info.plist "$STAGE/Contents/"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/"
xattr -cr "$STAGE"
# Stable identity so macOS privacy permissions survive rebuilds (falls back to ad-hoc).
ID=$(security find-identity -p codesigning | awk '/"LogiBar Local Signing"/ {print $2; exit}')
codesign --force --sign "${ID:--}" --identifier com.local.logibar "$STAGE"
echo "Built $STAGE"
if [[ "$1" == "--install" ]]; then
  pkill -x LogiBar 2>/dev/null && sleep 1 || true
  rm -rf /Applications/LogiBar.app && ditto "$STAGE" /Applications/LogiBar.app
  open /Applications/LogiBar.app
  echo "Installed to /Applications/LogiBar.app"
fi
