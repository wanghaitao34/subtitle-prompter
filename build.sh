#!/bin/zsh
# 编译成 字幕提词器.app（只需要 Command Line Tools，不需要 Xcode）
set -e
cd "$(dirname "$0")"
APP="字幕提词器.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  SubtitlePrompter.swift -o "$APP/Contents/MacOS/SubtitlePrompter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>SubtitlePrompter</string>
  <key>CFBundleIdentifier</key><string>local.hector.subtitle-prompter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>字幕提词器</string>
  <key>CFBundleDisplayName</key><string>字幕提词器</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "已生成 $(pwd)/$APP"
