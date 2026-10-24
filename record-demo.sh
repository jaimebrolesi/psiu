#!/bin/bash
# Records the Psiu demo hands-free: records the top of the main screen while demo.sh runs
# and converts the video into docs/demo.gif (pt) or docs/demo-en.gif (en). Needs Psiu installed in
# Applications and Screen Recording permission for the app running this script (macOS asks once).
# Usage: bash record-demo.sh [pt|en]
set -euo pipefail
cd "$(dirname "$0")"

lang=${1:-pt}
case "$lang" in
  pt) gif=docs/demo.gif; languages=pt-BR ;;
  en) gif=docs/demo-en.gif; languages=en-US ;;
  *) echo "Usage: bash record-demo.sh [pt|en]"; exit 1 ;;
esac

P="/Applications/Psiu.app/Contents/MacOS/Psiu"
[ -x "$P" ] || { echo "Install Psiu in Applications first."; exit 1; }

# Records with an isolated Psiu in a temporary home: your real sessions, limits and scoreboard
# never show up in the GIF and stay untouched. Your Psiu is closed meanwhile and reopened at the end.
demo_home="$(mktemp -d)"
mkdir -p "$demo_home/.claude"
# Counts as connected to Claude Code, so the isolated Psiu doesn't ask to connect.
printf '{"statusLine":{"type":"command","command":"\\"%s\\" statusline"}}' "$P" > "$demo_home/.claude/settings.json"
pkill -x Psiu || true; sleep 1
# A plain blue backdrop over the main screen, above every window and the menu bar but below Psiu (main menu
# level + 2): your windows, desktop and wallpaper never show up in the GIF, and the GIF stays small.
osascript -l JavaScript >/dev/null 2>&1 <<'JS' &
ObjC.import('AppKit');
$.NSApplication.sharedApplication.setActivationPolicy(1);
var frame = $.NSScreen.screens.objectAtIndex(0).frame;
function rgb(r, g, b) { return $.NSColor.colorWithSRGBRedGreenBlueAlpha(r / 255, g / 255, b / 255, 1); }
var image = $.NSImage.alloc.initWithSize(frame.size);
image.lockFocus;
$.NSGradient.alloc.initWithStartingColorEndingColor(rgb(0x12, 0x1c, 0x2e), rgb(0x1f, 0x33, 0x54))
  .drawInRectAngle($.NSMakeRect(0, 0, frame.size.width, frame.size.height), 90);
image.unlockFocus;
var w = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(frame, 0, 2, false);
w.level = 25;   // main menu level + 1
w.ignoresMouseEvents = true;
w.collectionBehavior = 1 | 16;   // all spaces, stationary
w.backgroundColor = $.NSColor.colorWithPatternImage(image);
w.orderFrontRegardless;
$.NSRunLoop.currentRunLoop.run;
JS
backdrop=$!
HOME="$demo_home" "$P" -AppleLanguages "($languages)" >/dev/null 2>&1 &
demo_psiu=$!
finish() {
  kill "$demo_psiu" "$backdrop" 2>/dev/null || true
  wait "$demo_psiu" "$backdrop" 2>/dev/null || true
  rm -rf "$demo_home"
  sleep 1; open /Applications/Psiu.app
}
trap finish EXIT
sleep 3

# Width of the main screen in points, to center the recording on the notch.
width=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.objectAtIndex(0).frame.size.width')
width=${width%.*}
w=900; h=560
x=$(( (width - w) / 2 ))

mkdir -p build
rm -f build/demo.mov
echo "Recording the ${w}x${h} region at the top of the screen (x=$x) for 75 s..."
screencapture -v -V 75 -R "${x},0,${w},${h}" build/demo.mov &
recorder=$!
sleep 2
HOME="$demo_home" PSIU_DEMO_LANG=$lang PSIU_DEMO_LANGUAGES=$languages bash demo.sh
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
