#!/bin/bash
# Simula duas sessões fictícias do Claude Code para gravar a demonstração do Psiu.
# Usa nomes inventados (api, site). Guarda e restaura os seus limites do plano no fim.
# O placar de hoje ganha cerca de um minuto da demonstração.
set -euo pipefail

P="/Applications/Psiu.app/Contents/MacOS/Psiu"
[ -x "$P" ] || { echo "Instale o Psiu em Aplicativos antes de rodar a demonstração."; exit 1; }

D="$HOME/.psiu"
copia="$(mktemp -d)"
[ -f "$D/limits.json" ] && cp "$D/limits.json" "$copia/"
restaurar() {
  rm -f "$D/demo-painel"
  for s in demo-api demo-site; do
    printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$s" | "$P" hook
  done
  if [ -f "$copia/limits.json" ]; then cp "$copia/limits.json" "$D/limits.json"; else rm -f "$D/limits.json"; fi
  rm -rf "$copia"
}
trap restaurar EXIT

ev() { printf '%s' "$1" | "$P" hook; }
st() { printf '%s' "$1" | "$P" statusline >/dev/null; }
passo() { echo; echo "▸ $1"; sleep "$2"; }

agora=$(date +%s)
cinco=$((agora + 3 * 3600))
semana=$((agora + 4 * 86400))
limites="\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":$cinco},\"seven_day\":{\"used_percentage\":22,\"resets_at\":$semana}}"

echo "Demonstração do Psiu."
passo "Nenhuma sessão: o Psiu está dormindo." 4

ev '{"session_id":"demo-api","hook_event_name":"SessionStart","cwd":"/tmp/api"}'
ev '{"session_id":"demo-api","hook_event_name":"UserPromptSubmit","cwd":"/tmp/api","prompt":"Atualize o guia de instalação"}'
st "{\"session_id\":\"demo-api\",\"workspace\":{\"project_dir\":\"/tmp/api\"},\"context_window\":{\"used_percentage\":41},$limites}"
passo "Sessão api trabalhando: azul, olhos varrendo." 5

ev '{"session_id":"demo-api","hook_event_name":"PermissionRequest","cwd":"/tmp/api","tool_name":"Bash","tool_input":{"command":"npm install"}}'
passo "Pedido de permissão: amarelo, com som." 3
touch "$D/demo-painel"
passo "O notch se estica e mostra o resumo do pedido." 5
rm -f "$D/demo-painel"
sleep 1

ev '{"session_id":"demo-api","hook_event_name":"PostToolUse","cwd":"/tmp/api"}'
passo "Permissão dada (simulada): volta ao azul." 4

ev '{"session_id":"demo-api","hook_event_name":"Stop","cwd":"/tmp/api","last_assistant_message":"Guia atualizado e testes passando.","background_tasks":[]}'
passo "Terminou: verde sorrindo, com som." 6

ev '{"session_id":"demo-site","hook_event_name":"SessionStart","cwd":"/tmp/site"}'
ev '{"session_id":"demo-site","hook_event_name":"UserPromptSubmit","cwd":"/tmp/site","prompt":"Revise o checkout"}'
st "{\"session_id\":\"demo-site\",\"workspace\":{\"project_dir\":\"/tmp/site\"},\"context_window\":{\"used_percentage\":86},$limites}"
passo "Segunda sessão com contexto alto: robô cansado, ponto vermelho, e o ponto verde da api que você não viu." 7

ev '{"session_id":"demo-site","hook_event_name":"Stop","cwd":"/tmp/site","last_assistant_message":"Revisão pronta; o teste longo segue rodando.","background_tasks":[{"type":"shell","status":"running"}]}'
passo "Turno acabou, mas há um shell em segundo plano: azul lento." 6

touch "$D/demo-painel"
passo "O painel com as duas sessões, a previsão e o placar do dia." 7
rm -f "$D/demo-painel"
sleep 2

echo
echo "Fim. Encerrando as sessões fictícias e restaurando seus limites."
