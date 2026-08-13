#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
app="$project_dir/dist/JZM5BatteryTray.app"
signing_identity=${CODE_SIGN_IDENTITY:--}

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$project_dir/Info.plist" "$app/Contents/Info.plist"

swiftc "$project_dir/JZM5BatteryTray.swift" \
  -target arm64-apple-macos13.0 \
  -framework AppKit \
  -framework IOKit \
  -framework CoreFoundation \
  -framework MultipeerConnectivity \
  -framework ServiceManagement \
  -o "$app/Contents/MacOS/JZM5BatteryTray"

codesign --force --deep --sign "$signing_identity" "$app"
echo "$app"
