#!/bin/zsh
# Ensayo visual de Ajustes: captura cada pestaña, en claro y en oscuro, sin abrir nada en pantalla.
#   macos/settings-snapshot.zsh [carpeta]   (por defecto, una carpeta temporal; imprime cuál)
# Abre una segunda copia de la app instalada con -PaperclipSettingsSnapshot, que pone cada pestaña en una
# ventana fuera de la pantalla y anota sus números en windows.txt. Aquí se capturan con screencapture -l,
# que dibuja el Liquid Glass de verdad. La terminal necesita permiso de Grabación de pantalla.
set -euo pipefail

APP_NAME=${APP_NAME:-Paperclip Swift}
OUT=${1:-$(mktemp -d)/settings}
mkdir -p "$OUT"
rm -f "$OUT/windows.txt" "$OUT/captured"

open -g -n -a "$APP_NAME" --args -PaperclipSettingsSnapshot "$OUT"

for _ in {1..90}; do
  [[ -s $OUT/windows.txt ]] && break
  sleep 1
done
[[ -s $OUT/windows.txt ]] || { print -u2 "La app no anotó sus ventanas en 90 s."; exit 1; }

while read -r window file || [[ -n ${window:-} ]]; do
  screencapture -x -o -l "$window" "$OUT/$file"
done < "$OUT/windows.txt"
touch "$OUT/captured"
print "$OUT"
