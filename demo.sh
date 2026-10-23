#!/bin/bash
# Simulates two made-up Claude Code sessions to record the Psiu demo.
# Uses invented names (api, site). Saves and restores your plan limits at the end.
# Run on its own, it adds about a minute to today's scoreboard; record-demo.sh runs it in an isolated home.
set -euo pipefail

P="/Applications/Psiu.app/Contents/MacOS/Psiu"
[ -x "$P" ] || { echo "Install Psiu in Applications before running the demo."; exit 1; }

D="$HOME/.psiu"
backup="$(mktemp -d)"
[ -f "$D/limits.json" ] && cp "$D/limits.json" "$backup/"
restore() {
  rm -f "$D/demo-panel"
  for s in demo-api demo-site; do
    printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$s" | "$P" hook
  done
  if [ -f "$backup/limits.json" ]; then cp "$backup/limits.json" "$D/limits.json"; else rm -f "$D/limits.json"; fi
  rm -rf "$backup"
}
trap restore EXIT

# Made-up texts in the recording's language (record-demo.sh passes PSIU_DEMO_LANG and PSIU_DEMO_LANGUAGES).
if [ "${PSIU_DEMO_LANG:-pt}" = en ]; then
  api_prompt="Update the install guide"; api_reply="Guide updated and tests passing."
  site_prompt="Review the checkout"; site_reply="Review done; the long test is still running."
  site_done="Checkout reviewed and the long test passed."
else
  api_prompt="Atualize o guia de instalação"; api_reply="Guia atualizado e testes passando."
  site_prompt="Revise o checkout"; site_reply="Revisão pronta; o teste longo segue rodando."
  site_done="Checkout revisado e o teste longo passou."
fi

# Hooks run in the recording's language, like the Psiu record-demo.sh opens.
lang_args=(-AppleLanguages "(${PSIU_DEMO_LANGUAGES:-pt-BR})")
ev() { printf '%s' "$1" | "$P" hook "${lang_args[@]}"; }
st() { printf '%s' "$1" | "$P" statusline "${lang_args[@]}" >/dev/null; }
step() { echo; echo "▸ $1"; sleep "$2"; }
# Simulates a long wait: moves the session's "since" back by $2 seconds (the file uses the on-disk names).
age() {
  local t; t=$(date +%s)
  sed -i '' -E "s/\"since\":[0-9.e+]+/\"since\":$((t - $2))/; s/\"updated\":[0-9.e+]+/\"updated\":$t/" "$D/sessions/$1.json"
}

now=$(date +%s)
five_hour=$((now + 3 * 3600))
week=$((now + 4 * 86400))
limits="\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":$five_hour},\"seven_day\":{\"used_percentage\":22,\"resets_at\":$week}}"

echo "Psiu demo."
step "No sessions: Psiu is asleep." 4

ev '{"session_id":"demo-api","hook_event_name":"SessionStart","cwd":"/tmp/api"}'
ev '{"session_id":"demo-api","hook_event_name":"UserPromptSubmit","cwd":"/tmp/api","prompt":"'"$api_prompt"'"}'
st "{\"session_id\":\"demo-api\",\"workspace\":{\"project_dir\":\"/tmp/api\"},\"context_window\":{\"used_percentage\":41},$limits}"
step "Session api working: blue, eyes scanning." 5

ev '{"session_id":"demo-api","hook_event_name":"PermissionRequest","cwd":"/tmp/api","tool_name":"Bash","tool_input":{"command":"npm install"}}'
step "Permission request: yellow, with a sound." 3
touch "$D/demo-panel"
step "The notch stretches and shows the request summary." 5
rm -f "$D/demo-panel"
sleep 1

age demo-api 660
step "Waiting for over 10 minutes: Psiu panics, eyes on fire and a red edge around the notch." 6
age demo-api 1900
step "Waiting for over 30 minutes: burnt, X eyes and smoke." 6

ev '{"session_id":"demo-api","hook_event_name":"PostToolUse","cwd":"/tmp/api"}'
step "Permission granted (simulated): Psiu shakes off the soot and goes back to blue." 4

ev '{"session_id":"demo-api","hook_event_name":"Stop","cwd":"/tmp/api","last_assistant_message":"'"$api_reply"'","background_tasks":[]}'
step "Done: green and smiling, with a sound." 6

ev '{"session_id":"demo-site","hook_event_name":"SessionStart","cwd":"/tmp/site"}'
ev '{"session_id":"demo-site","hook_event_name":"UserPromptSubmit","cwd":"/tmp/site","prompt":"'"$site_prompt"'"}'
st "{\"session_id\":\"demo-site\",\"workspace\":{\"project_dir\":\"/tmp/site\"},\"context_window\":{\"used_percentage\":86},$limits}"
step "Second session working above 80% of its context: Psiu turns purple and tired. The green dot is api, which you haven't seen." 5

ev '{"session_id":"demo-site","hook_event_name":"Stop","cwd":"/tmp/site","last_assistant_message":"'"$site_reply"'","background_tasks":[{"type":"shell","status":"running"}]}'
step "The turn ended, but a shell is running in the background: Psiu sinks into the notch and peeks, still purple." 6

ev '{"session_id":"demo-site","hook_event_name":"PreCompact","trigger":"auto"}'
ev '{"session_id":"demo-site","hook_event_name":"Stop","cwd":"/tmp/site","last_assistant_message":"'"$site_done"'","background_tasks":[]}'
step "Finished after a compaction: green with a purple headband." 5

touch "$D/demo-panel"
step "The panel: both sessions, the \"compacted 1x\" tag and the tip to clear the session." 5
rm -f "$D/demo-panel"
sleep 2

echo
echo "End. Closing the made-up sessions and restoring your limits."
