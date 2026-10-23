#!/bin/bash
# Grava a demonstração do Psiu sem intervenção: grava o topo da tela principal enquanto o demo.sh roda
# e converte o vídeo em docs/demo.gif (pt) ou docs/demo-en.gif (en). Precisa do Psiu aberto e da
# permissão de Gravação de Tela para o app que roda este script (o macOS pede uma vez).
# Uso: bash gravar-demo.sh [pt|en]
set -euo pipefail
cd "$(dirname "$0")"

idioma=${1:-pt}
case "$idioma" in
  pt) gif=docs/demo.gif; linguas=pt-BR ;;
  en) gif=docs/demo-en.gif; linguas=en-US ;;
  *) echo "Uso: bash gravar-demo.sh [pt|en]"; exit 1 ;;
esac

pgrep -qx Psiu || { echo "Abra o Psiu antes (open -a Psiu)."; exit 1; }

# Fixa o idioma do Psiu só durante a gravação e depois devolve as preferências como estavam.
dominio=io.github.jaimebrolesi.psiu
prefs="$(mktemp)"
if defaults read "$dominio" >/dev/null 2>&1; then defaults export "$dominio" "$prefs"; else rm -f "$prefs"; fi
reabrir() { pkill -x Psiu || true; sleep 1; open /Applications/Psiu.app; sleep 3; }
restaurar_idioma() {
  if [ -f "$prefs" ]; then defaults import "$dominio" "$prefs"; rm -f "$prefs"; else defaults delete "$dominio" 2>/dev/null || true; fi
  reabrir
}
trap restaurar_idioma EXIT
defaults write "$dominio" AppleLanguages -array "$linguas"
reabrir

# Largura da tela principal em pontos, para centralizar a gravação no notch.
largura=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.objectAtIndex(0).frame.size.width')
largura=${largura%.*}
w=900; h=560
x=$(( (largura - w) / 2 ))

mkdir -p build
rm -f build/demo.mov
echo "Gravando a região ${w}x${h} no topo da tela (x=$x) por 60 s..."
screencapture -v -V 60 -R "${x},0,${w},${h}" build/demo.mov &
grav=$!
sleep 2
PSIU_DEMO_IDIOMA=$idioma bash demo.sh
wait "$grav"

[ -s build/demo.mov ] || { echo "A gravação não foi criada. Verifique a permissão de Gravação de Tela."; exit 1; }

if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install ffmpeg; else echo "Falta o ffmpeg e o Homebrew."; exit 1; fi
fi

echo "Convertendo para $gif..."
ffmpeg -y -loglevel error -i build/demo.mov \
  -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  -loop 0 "$gif"
tamanho=$(du -m "$gif" | cut -f1)
echo "Pronto: $gif (${tamanho} MB)"
if [ "$tamanho" -gt 9 ]; then
  echo "Ficou grande; gerando versão mais leve (12 fps, 800 px)..."
  ffmpeg -y -loglevel error -i build/demo.mov \
    -vf "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
    -loop 0 "$gif"
  echo "Novo tamanho: $(du -m "$gif" | cut -f1) MB"
fi
