#!/bin/bash
# Compiles Psiu, assembles Psiu.app with its icon and builds Psiu.dmg to drag into Applications.
set -euo pipefail
cd "$(dirname "$0")"

version=$(sw_vers -productVersion | cut -d. -f1)
if [ "$version" -lt 14 ]; then
  echo "Psiu needs macOS 14 (Sonoma) or later."; exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "The Swift compiler is missing. Run: xcode-select --install  and then this script again."; exit 1
fi

app="build/Psiu.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "Compiling..."
swiftc -O Psiu.swift -o "$app/Contents/MacOS/Psiu"

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
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>CFBundleVersion</key><string>7</string>
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

echo "Assembling the .dmg..."
mkdir -p build/dmg/.background
cp -R "$app" build/dmg/
# Finder shows the link's name as is, without translating it: it stays in English, like the bilingual background.
ln -s /Applications build/dmg/Applications
cp build/background.tiff build/dmg/.background/background.tiff

# If a "Psiu" volume (or "Psiu 1"...) is still mounted from before, detach it: Finder could arrange the wrong one.
for v in /Volumes/Psiu*; do [ -d "$v" ] && hdiutil detach "$v" -force >/dev/null 2>&1 || true; done

hdiutil create -srcfolder build/dmg -volname Psiu -fs HFS+ -format UDRW -ov build/rw.dmg >/dev/null
mount=$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | grep -E '^/dev/.*/Volumes/' | head -1)
disk=$(echo "$mount" | awk '{print $1}')
volume="/Volumes/${mount#*/Volumes/}"

# Arranges the window: background, size, large icons and positions lined up with the background's arrow.
# The first time, macOS asks to let Terminal (or Claude Code) control Finder: allow it.
if ! osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Psiu"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Psiu.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
  echo "Warning: couldn't arrange the installer window (permission to control Finder?). The .dmg comes out without the background."
fi

# Icon of the mounted volume (desktop, sidebar and window title). After Finder, which would erase it.
cp "$app/Contents/Resources/Psiu.icns" "$volume/.VolumeIcon.icns"
SetFile -c icnC "$volume/.VolumeIcon.icns"
SetFile -a C "$volume"

sync
hdiutil detach "$disk" >/dev/null
rm -f Psiu.dmg
hdiutil convert build/rw.dmg -format UDZO -o Psiu.dmg >/dev/null
# Icon of the .dmg file itself. It lives in the file's attributes: it works on this Mac but doesn't survive a download.
osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.setIconForFileOptions($.NSImage.alloc.initWithContentsOfFile("build/Psiu.app/Contents/Resources/Psiu.icns"), "Psiu.dmg", 0)' >/dev/null
rm -rf build/dmg build/rw.dmg

echo "Done: $(pwd)/Psiu.dmg"
echo "Open the .dmg, drag Psiu into Applications and open Psiu from there."
