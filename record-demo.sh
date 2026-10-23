#!/bin/bash
# Records the Psiu demo hands-free: records the top of the main screen while demo.sh runs
# and converts the video into docs/demo.gif (pt) or docs/demo-en.gif (en). Needs Psiu open and
# Screen Recording permission for the app running this script (macOS asks once).
# Usage: bash record-demo.sh [pt|en]
set -euo pipefail
cd "$(dirname "$0")"

lang=${1:-pt}
case "$lang" in
  pt) gif=docs/demo.gif; languages=pt-BR ;;
  en) gif=docs/demo-en.gif; languages=en-US ;;
  *) echo "Usage: bash record-demo.sh [pt|en]"; exit 1 ;;
esac

pgrep -qx Psiu || { echo "Open Psiu first (open -a Psiu)."; exit 1; }

# Sets Psiu's language only while recording, then puts the preferences back as they were.
domain=io.github.jaimebrolesi.psiu
prefs="$(mktemp)"
if defaults read "$domain" >/dev/null 2>&1; then defaults export "$domain" "$prefs"; else rm -f "$prefs"; fi
reopen() { pkill -x Psiu || true; sleep 1; open /Applications/Psiu.app; sleep 3; }
restore_language() {
  if [ -f "$prefs" ]; then defaults import "$domain" "$prefs"; rm -f "$prefs"; else defaults delete "$domain" 2>/dev/null || true; fi
  reopen
}
trap restore_language EXIT
defaults write "$domain" AppleLanguages -array "$languages"
reopen

# Width of the main screen in points, to center the recording on the notch.
width=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.objectAtIndex(0).frame.size.width')
width=${width%.*}
w=900; h=560
x=$(( (width - w) / 2 ))

mkdir -p build
rm -f build/demo.mov
echo "Recording the ${w}x${h} region at the top of the screen (x=$x) for 60 s..."
screencapture -v -V 60 -R "${x},0,${w},${h}" build/demo.mov &
recorder=$!
sleep 2
PSIU_DEMO_LANG=$lang bash demo.sh
wait "$recorder"

[ -s build/demo.mov ] || { echo "The recording wasn't created. Check the Screen Recording permission."; exit 1; }

if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install ffmpeg; else echo "ffmpeg and Homebrew are missing."; exit 1; fi
fi

echo "Converting to $gif..."
ffmpeg -y -loglevel error -i build/demo.mov \
  -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  -loop 0 "$gif"
size=$(du -m "$gif" | cut -f1)
echo "Done: $gif (${size} MB)"
if [ "$size" -gt 9 ]; then
  echo "Too big; making a lighter version (12 fps, 800 px)..."
  ffmpeg -y -loglevel error -i build/demo.mov \
    -vf "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
    -loop 0 "$gif"
  echo "New size: $(du -m "$gif" | cut -f1) MB"
fi
