#!/bin/bash
# Compila o Psiu, monta o Psiu.app com ícone e gera o Psiu.dmg para arrastar em Aplicativos.
set -euo pipefail
cd "$(dirname "$0")"

versao=$(sw_vers -productVersion | cut -d. -f1)
if [ "$versao" -lt 14 ]; then
  echo "O Psiu precisa do macOS 14 (Sonoma) ou mais novo."; exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Falta o compilador Swift. Rode: xcode-select --install  e depois este script de novo."; exit 1
fi

app="build/Psiu.app"
rm -rf build
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

echo "Compilando..."
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>O Psiu traz para a frente a janela do terminal da sessão que você clicar.</string>
</dict>
</plist>
PLIST

echo "Desenhando o ícone..."
mkdir -p build/Psiu.iconset
"$app/Contents/MacOS/Psiu" icone build/icone-1024.png
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" build/icone-1024.png --out "build/Psiu.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" build/icone-1024.png --out "build/Psiu.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/Psiu.iconset -o "$app/Contents/Resources/Psiu.icns"

echo "Assinando localmente..."
codesign --force --deep --sign - "$app"

echo "Desenhando o fundo do instalador..."
"$app/Contents/MacOS/Psiu" fundo-dmg build
tiffutil -cathidpicheck build/fundo.png build/fundo@2x.png -out build/fundo.tiff >/dev/null

echo "Montando o .dmg..."
mkdir -p build/dmg/.background
cp -R "$app" build/dmg/
ln -s /Applications build/dmg/Aplicativos
cp build/fundo.tiff build/dmg/.background/fundo.tiff

# Se sobrou um volume "Psiu" montado de uma geração anterior, desmonta antes.
if [ -d /Volumes/Psiu ]; then hdiutil detach /Volumes/Psiu -force >/dev/null 2>&1 || true; fi

hdiutil create -srcfolder build/dmg -volname Psiu -fs HFS+ -format UDRW -ov build/rw.dmg >/dev/null
disco=$(hdiutil attach -readwrite -noverify -noautoopen build/rw.dmg | grep -E '^/dev/' | head -1 | awk '{print $1}')

# Arruma a janela: fundo, tamanho, ícones grandes e posições alinhadas à seta do fundo.
# Na primeira vez, o macOS pede para o Terminal (ou o Claude Code) controlar o Finder: aceite.
if ! osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "Psiu"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opcoes to the icon view options of container window
        set arrangement of opcoes to not arranged
        set icon size of opcoes to 112
        set text size of opcoes to 13
        set background picture of opcoes to file ".background:fundo.tiff"
        set position of item "Psiu.app" of container window to {170, 190}
        set position of item "Aplicativos" of container window to {470, 190}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
  echo "Aviso: não consegui arrumar a janela do instalador (permissão para controlar o Finder?). O .dmg sai sem o fundo."
fi

sync
hdiutil detach "$disco" >/dev/null
rm -f Psiu.dmg
hdiutil convert build/rw.dmg -format UDZO -o Psiu.dmg >/dev/null
rm -rf build/dmg build/rw.dmg

echo "Pronto: $(pwd)/Psiu.dmg"
echo "Abra o .dmg, arraste o Psiu para Aplicativos e abra o Psiu de lá."
