#!/bin/bash
# Tests for a built Psiu (bash build-dmg.sh first): the command line, the binary, the images and the unit tests.
# Everything runs in a temporary home, so your real ~/.claude and ~/.psiu stay untouched. Exits with non-zero status on any failure.
set -euo pipefail
cd "$(dirname "$0")"

P="$PWD/build/Psiu.app/Contents/MacOS/Psiu"
[ -x "$P" ] || { echo "Build Psiu first: bash build-dmg.sh"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
failures=0
pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; failures=$((failures + 1)); }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }
# Runs Psiu in the temporary home, in English, so the texts below are predictable.
psiu() { HOME="$T" "$P" "$@" -AppleLanguages "(en-US)"; }
# Python reads the JSON files; $1 is a small expression over `d`, the parsed file.
json() { python3 -c "import json, sys; d = json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$1"; }

echo "Install"
mkdir -p "$T/.claude"
echo '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true other-tool"}]}]}}' > "$T/.claude/settings.json"
cp "$T/.claude/settings.json" "$T/original.json"
psiu install >/dev/null
psiu install >/dev/null   # twice: nothing may be duplicated
S="$T/.claude/settings.json"
events="SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop SubagentStop SessionEnd PreCompact"
for e in $events; do
  check "hook $e present once" json "$S" "sum('Psiu.app/Contents/MacOS/Psiu' in h['command'] for g in d['hooks'].get('$e', []) for h in g['hooks']) == 1"
done
check "other tool's hook kept" json "$S" "any(h['command'] == '/usr/bin/true other-tool' for g in d['hooks']['Stop'] for h in g['hooks'])"
check "status line points to Psiu" json "$S" "d['statusLine']['command'].endswith('Psiu\" statusline')"
check "other settings kept" json "$S" "d['theme'] == 'dark'"

echo "Hooks"
echo '{"session_id":"test","hook_event_name":"UserPromptSubmit","cwd":"/tmp/demo","prompt":"hi"}' | psiu hook
F="$T/.psiu/sessions/test.json"
check "session file written" test -s "$F"
check "session is running" json "$F" "d['state'] == 'running'"
check "project from cwd" json "$F" "d['project'] == 'demo'"
check "summary from prompt" json "$F" "d['resumo'] == 'Prompt: hi'"
echo '{"session_id":"test","hook_event_name":"PreCompact","trigger":"auto"}' | psiu hook
check "compaction counted" json "$F" "d['compactacoes'] == 1"
echo '{"session_id":"test","hook_event_name":"SessionStart","source":"clear"}' | psiu hook
check "/clear resets compactions" json "$F" "d['compactacoes'] == 0"

echo "Status line"
out=$(echo '{"session_id":"test","context_window":{"used_percentage":42},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":9999999999}}}' | psiu statusline)
check "status line output" test "$out" = "context 42% | 5h 30%"
check "context saved" json "$T/.psiu/sessions/test.metrics.json" "d['ctx'] == 42"
check "limits saved" json "$T/.psiu/limits.json" "d['five_hour']['pct'] == 30"

echo "Uninstall"
psiu uninstall >/dev/null
check "settings.json back to the original" python3 -c "import json, sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)" "$S" "$T/original.json"

echo "Invalid settings.json"
printf '{"theme": dark' > "$S"
cp "$S" "$T/broken.json"
check "install refuses it with exit 1" bash -c '! HOME="$1" "$2" install -AppleLanguages "(en-US)" >/dev/null' _ "$T" "$P"
check "install leaves it untouched" cmp -s "$S" "$T/broken.json"

echo "Binary"
check "universal (Apple silicon and Intel)" test "$(lipo -archs "$P" | tr ' ' '\n' | sort | tr '\n' ' ')" = "arm64 x86_64 "
for arch in arm64 x86_64; do
  check "$arch runs on macOS 14" test "$(lipo -thin $arch "$P" -output "$T/$arch" && otool -l "$T/$arch" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')" = "14.0"
done
# The Intel side runs under Rosetta only on GitHub (CI=true): on a Mac with a person at it, macOS 26 warns
# that apps using Rosetta will stop working in a future macOS.
if [ "${CI:-}" = true ] && arch -x86_64 /usr/bin/true 2>/dev/null; then
  out=$(echo '{"session_id":"intel","context_window":{"used_percentage":7}}' | HOME="$T" arch -x86_64 "$P" statusline -AppleLanguages "(en-US)")
  check "Intel build answers the status line" test "$out" = "context 7%"
else
  echo "  skip  Intel build (only on GitHub, or Rosetta not installed)"
fi

echo "Images"
size() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}'; }
check "icon is 1024 x 1024" test "$(size build/icon-1024.png)" = "1024 1024 "
check "installer background 1x is 640 x 400" test "$(size build/background.png)" = "640 400 "
check "installer background 2x is 1280 x 800" test "$(size build/background@2x.png)" = "1280 800 "
check "icon has drawing in it" test "$(stat -f %z build/icon-1024.png)" -gt 20000
check "background has drawing in it" test "$(stat -f %z build/background@2x.png)" -gt 100000

echo "Unit tests"
# With only the Command Line Tools (no Xcode), Swift Testing lives where swift test doesn't look by itself.
extra=()
if [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
  F=/Library/Developer/CommandLineTools/Library/Developer
  extra=(-Xswiftc -F -Xswiftc "$F/Frameworks" -Xlinker -F -Xlinker "$F/Frameworks"
         -Xlinker -rpath -Xlinker "$F/Frameworks" -Xlinker -rpath -Xlinker "$F/usr/lib")
fi
if swift test ${extra[@]+"${extra[@]}"} > "$T/swift-test.log" 2>&1; then
  pass "swift test: $(grep -Eo '[0-9]+ tests in [0-9]+ suites' "$T/swift-test.log" | tail -1)"
else
  grep -E 'error|✘' "$T/swift-test.log" | head -40
  fail "swift test"
fi

if [ "$failures" -gt 0 ]; then echo "$failures test(s) failed."; exit 1; fi
echo "All tests passed."
