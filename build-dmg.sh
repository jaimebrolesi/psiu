#!/bin/bash
# Compiles Psiu, assembles Psiu.app with its icon and builds Psiu.dmg to drag into Applications.
set -euo pipefail
cd "$(dirname "$0")"

version=$(sw_vers -productVersion | cut -d. -f1)
if [ "$version" -lt 14 ]; then
  echo "Psiu needs macOS 14 (Sonoma) or later."; exit 1
fi
if ! command -v swift >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Run: xcode-select --install  and then this script again."; exit 1
fi

app="build/Psiu.app"
# Cleans build/ but keeps the Python environment with dmgbuild between builds.
mkdir -p build
find build -mindepth 1 -maxdepth 1 ! -name venv -exec rm -rf {} +
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# A universal binary for Apple silicon and Intel, both for macOS 14 (the minimum set in Package.swift; without
# it, the compiler would require the macOS of the SDK it builds with).
echo "Compiling for Apple silicon and Intel..."
for arch in arm64 x86_64; do
  swift build -c release --product Psiu --triple "$arch-apple-macosx14.0" --quiet
done
lipo -create .build/arm64-apple-macosx/release/Psiu .build/x86_64-apple-macosx/release/Psiu -output "$app/Contents/MacOS/Psiu"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.jaimebrolesi.psiu</string>
  <key>CFBundleName</key><string>Psiu</string>
  <key>CFBundleDisplayName</key><string>Psiu</string>
  <key>CFBundleExecutable</key><string>Psiu</string>
  <key>CFBundleIconFile</key><string>Psiu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.7.1</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>pt-BR</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Psiu brings the terminal window of the session you click to the front.</string>
</dict>
</plist>
PLIST

# Info.plist texts in Brazilian Portuguese; the English ones live in Info.plist itself.
mkdir -p "$app/Contents/Resources/en.lproj" "$app/Contents/Resources/pt-BR.lproj"
touch "$app/Contents/Resources/en.lproj/InfoPlist.strings"
cat > "$app/Contents/Resources/pt-BR.lproj/InfoPlist.strings" <<'STRINGS'
"NSAppleEventsUsageDescription" = "O Psiu traz para a frente a janela do terminal da sessão que você clicar.";
STRINGS

echo "Drawing the icon..."
mkdir -p build/Psiu.iconset
"$app/Contents/MacOS/Psiu" icon build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icon-1024.png --out "build/Psiu.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" build/icon-1024.png --out "build/Psiu.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/Psiu.iconset -o "$app/Contents/Resources/Psiu.icns"

echo "Signing locally..."
codesign --force --deep --sign - "$app"

echo "Drawing the installer background..."
"$app/Contents/MacOS/Psiu" dmg-background build
tiffutil -cathidpicheck build/background.png build/background@2x.png -out build/background.tiff >/dev/null

# dmgbuild lays out the installer window without Finder (see dmg-settings.py), on a Mac or on a GitHub runner.
# It lives in a virtual environment in build/venv, so the system Python stays untouched.
if [ ! -x build/venv/bin/dmgbuild ]; then
  echo "Installing dmgbuild in build/venv..."
  python3 -m venv build/venv
  build/venv/bin/pip install --quiet --disable-pip-version-check dmgbuild==1.6.7
fi

echo "Assembling the .dmg..."
# If a "Psiu" volume (or "Psiu 1"...) is still mounted from before, detach it.
for v in /Volumes/Psiu*; do [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1 || true; done
rm -f Psiu.dmg
build/venv/bin/dmgbuild -s dmg-settings.py -D app="$app" -D background=build/background.tiff \
  -D icon="$app/Contents/Resources/Psiu.icns" Psiu Psiu.dmg >/dev/null
# Icon of the .dmg file itself. It lives in the file's attributes: it works on this Mac but doesn't survive a download.
osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.setIconForFileOptions($.NSImage.alloc.initWithContentsOfFile("build/Psiu.app/Contents/Resources/Psiu.icns"), "Psiu.dmg", 0)' >/dev/null || true

echo "Done: $(pwd)/Psiu.dmg"
echo "Open the .dmg, drag Psiu into Applications and open Psiu from there."
