#!/bin/zsh
# Ensayo visual: captura ventanas de la app sin abrir nada en pantalla.
#   macos/snapshot.zsh settings [carpeta]   cada pestaña de Ajustes, en claro y en oscuro
#   macos/snapshot.zsh window [carpeta]     la ventana de Paperclip, normal y con Liquid Glass
# Por defecto usa una carpeta temporal e imprime cuál. Abre una segunda copia de la app instalada, que pone
# las ventanas fuera de la pantalla y anota sus números en windows.txt. Aquí se capturan con
# screencapture -l, que dibuja el Liquid Glass de verdad. La terminal necesita permiso de Grabación de
# pantalla.
set -euo pipefail

KIND=${1:?Uso: snapshot.zsh settings|window [carpeta]}
APP_NAME=${APP_NAME:-Paperclip Swift}
OUT=${2:-$(mktemp -d)/$KIND}
mkdir -p "$OUT"
rm -f "$OUT/windows.txt" "$OUT/captured"

open -g -n -a "$APP_NAME" --args -PaperclipSnapshot "$KIND" -PaperclipSnapshotDirectory "$OUT"

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
