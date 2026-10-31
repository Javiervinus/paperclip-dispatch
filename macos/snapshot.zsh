#!/bin/zsh
# Ensayo visual: captura ventanas de la app sin abrir nada en pantalla.
#   macos/snapshot.zsh settings [carpeta]       cada pestaña de Ajustes, en claro y en oscuro
#   macos/snapshot.zsh window [carpeta]         la ventana de Paperclip, normal y con Liquid Glass
#   macos/snapshot.zsh page <ruta> [carpeta]    una página de Paperclip con la app, para mostrarla
#       SIZE=1512x982 (tamaño de la ventana, en puntos)
#       ANCHORS="|En qué se fue la semana" (una captura por ancla, separadas por «|»; vacía = arriba)
#       La captura de page lleva la sombra de la ventana, para ponerla sobre un fondo.
# Por defecto usa una carpeta temporal e imprime cuál. Abre una segunda copia de la app instalada, que pone
# las ventanas fuera de la pantalla y anota sus números en windows.txt. Aquí se capturan con
# screencapture -l, que dibuja el Liquid Glass de verdad. La terminal necesita permiso de Grabación de
# pantalla.
set -euo pipefail

USAGE="Uso: snapshot.zsh settings|window [carpeta] · snapshot.zsh page <ruta> [carpeta]"
KIND=${1:?$USAGE}
APP_NAME=${APP_NAME:-Paperclip Swift}
EXTRA=()
SHADOW=(-o)
case $KIND in
  settings|window)
    OUT=${2:-$(mktemp -d)/$KIND} ;;
  page)
    ROUTE=${2:?$USAGE}
    OUT=${3:-$(mktemp -d)/$KIND}
    EXTRA=(-PaperclipSnapshotPath "$ROUTE" -PaperclipSnapshotSize "${SIZE:-1512x982}"
      -PaperclipSnapshotAnchors "${ANCHORS:-}")
    SHADOW=() ;;
  *)
    print -u2 "$USAGE"; exit 2 ;;
esac
mkdir -p "$OUT"
rm -f "$OUT/windows.txt" "$OUT/captured"

open -g -n -a "$APP_NAME" --args -PaperclipSnapshot "$KIND" -PaperclipSnapshotDirectory "$OUT" "${EXTRA[@]}"

for _ in {1..90}; do
  [[ -s $OUT/windows.txt ]] && break
  sleep 1
done
[[ -s $OUT/windows.txt ]] || { print -u2 "La app no anotó sus ventanas en 90 s."; exit 1; }

while read -r window file || [[ -n ${window:-} ]]; do
  screencapture -x "${SHADOW[@]}" -l "$window" "$OUT/$file"
done < "$OUT/windows.txt"
touch "$OUT/captured"
print "$OUT"
