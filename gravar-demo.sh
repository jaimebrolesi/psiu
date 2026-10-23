#!/bin/bash
# Grava a demonstração do Psiu sem intervenção: grava o topo da tela principal enquanto o demo.sh roda
# e converte o vídeo em docs/demo.gif. Precisa do Psiu aberto e da permissão de Gravação de Tela
# para o app que roda este script (o macOS pede uma vez).
set -euo pipefail
cd "$(dirname "$0")"

pgrep -qx Psiu || { echo "Abra o Psiu antes (open -a Psiu)."; exit 1; }

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
bash demo.sh
wait "$grav"

[ -s build/demo.mov ] || { echo "A gravação não foi criada. Verifique a permissão de Gravação de Tela."; exit 1; }

if ! command -v ffmpeg >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then brew install ffmpeg; else echo "Falta o ffmpeg e o Homebrew."; exit 1; fi
fi

echo "Convertendo para docs/demo.gif..."
ffmpeg -y -loglevel error -i build/demo.mov \
  -vf "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4" \
  -loop 0 docs/demo.gif
tamanho=$(du -m docs/demo.gif | cut -f1)
echo "Pronto: docs/demo.gif (${tamanho} MB)"
if [ "$tamanho" -gt 9 ]; then
  echo "Ficou grande; gerando versão mais leve (12 fps, 800 px)..."
  ffmpeg -y -loglevel error -i build/demo.mov \
    -vf "fps=12,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5" \
    -loop 0 docs/demo.gif
  echo "Novo tamanho: $(du -m docs/demo.gif | cut -f1) MB"
fi
