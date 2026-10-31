#!/bin/zsh
# Convierte icon/icon.svg en un .icns: make-icns.zsh <salida.icns>
#
# El SVG ya trae la plantilla de íconos de Apple (824 px sobre 1024). Va como .icns porque Pake usa un
# .icns tal cual, pero a un PNG le aplica su propia máscara y lo achica a 840 px.
set -eo pipefail

ROOT=${0:A:h:h}
OUTPUT=${1:?Uso: make-icns.zsh <salida.icns>}

iconset=$(mktemp -d)/icon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$ROOT/icon/icon.svg" -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$ROOT/icon/icon.svg" -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$OUTPUT"
rm -rf "${iconset:h}"
