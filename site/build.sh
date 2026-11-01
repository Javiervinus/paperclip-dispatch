#!/usr/bin/env bash
# Arma la landing en una carpeta lista para servir o publicar (GitHub Pages): copia lo de site/, trae de
# docs/images solo las capturas que usa la página (docs/images es su única fuente: no se copian al repo) y
# llena los datos que no se escriben a mano.
#   site/build.sh                        deja la página en _site/ (ignorada por git)
#   OUTPUT_DIR=/tmp/landing site/build.sh   en otra carpeta
# Para verla: python3 -m http.server 8080 --bind 127.0.0.1 --directory _site
#
# Los datos salen de:
#   %%REPO_URL%%    REPOSITORY_URL de macos/release.env (el repo de RELEASES_REPO)
#   %%VERSION%%     el último release publicado en GitHub (tag_name, sin la «v»)
#   %%DMG_URL%%     el .dmg de ese release
#   %%BREW_CASK%%   <dueño>/tap/<repo>, en minúsculas: el tap Javiervinus/homebrew-tap y el cask del repo.
#                   HOMEBREW_TAP y CASK_TOKEN lo cambian.
# Si GitHub no responde (sin red, límite de la API), el botón apunta a releases/latest y la línea de la versión
# se quita. GITHUB_TOKEN, si está, se usa para la API (en Actions evita el límite de pedidos).
set -euo pipefail

SITE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$SITE")
OUTPUT_DIR=${OUTPUT_DIR:-$ROOT/_site}

fail() { echo "build.sh: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "falta jq"

# shellcheck source=../macos/release.env
source "$ROOT/macos/release.env"
[[ -n ${RELEASES_REPO:-} && -n ${REPOSITORY_URL:-} ]] || fail "macos/release.env no trae RELEASES_REPO ni REPOSITORY_URL"
OWNER=${RELEASES_REPO%%/*}
REPO=${RELEASES_REPO#*/}
HOMEBREW_TAP=${HOMEBREW_TAP:-$(tr '[:upper:]' '[:lower:]' <<<"$OWNER")/tap}
CASK_TOKEN=${CASK_TOKEN:-$(tr '[:upper:]' '[:lower:]' <<<"$REPO")}

# La última versión publicada y su DMG
VERSION=
DMG_URL=
auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
if release=$(curl -fsSL --max-time 20 ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$RELEASES_REPO/releases/latest" 2>/dev/null); then
  VERSION=$(jq -r '.tag_name // empty | ltrimstr("v")' <<<"$release")
  DMG_URL=$(jq -r '[.assets[] | select(.name | endswith(".dmg")) | .browser_download_url][0] // empty' <<<"$release")
fi
if [[ -z $VERSION || -z $DMG_URL ]]; then
  echo "build.sh: no pude leer el último release de $RELEASES_REPO; el botón va a releases/latest, sin versión" >&2
  VERSION=
  DMG_URL=$REPOSITORY_URL/releases/latest
fi

# La carpeta de salida, desde cero
[[ $OUTPUT_DIR != "$ROOT" && $OUTPUT_DIR != "$SITE" && $OUTPUT_DIR != / ]] || fail "OUTPUT_DIR no puede ser $OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/images"

# Todo lo de site/ menos este script
(cd "$SITE" && find . -type f ! -name build.sh -print0 | while IFS= read -r -d '' file; do
  mkdir -p "$OUTPUT_DIR/$(dirname "$file")"
  cp "$file" "$OUTPUT_DIR/$file"
done)

# Las capturas que nombra la página, tal como están en docs/images
images=$(grep -rhoE 'images/[A-Za-z0-9._-]+\.png' "$SITE" --include='*.html' --include='*.css' | sort -u)
for image in $images; do
  [[ -f $ROOT/docs/$image ]] || fail "la página usa $image y no está en docs/images"
  cp "$ROOT/docs/$image" "$OUTPUT_DIR/$image"
done

# Los datos
escape() { sed -e 's/[\/&|]/\\&/g' <<<"$1"; }
while IFS= read -r -d '' page; do
  if [[ -n $VERSION ]]; then
    sed -i.bak -e "s|%%VERSION%%|$(escape "$VERSION")|g" "$page"
  else
    sed -i.bak -e '/build-version/d' "$page"
  fi
  sed -i.bak \
    -e "s|%%REPO_URL%%|$(escape "$REPOSITORY_URL")|g" \
    -e "s|%%DMG_URL%%|$(escape "$DMG_URL")|g" \
    -e "s|%%BREW_CASK%%|$(escape "$HOMEBREW_TAP/$CASK_TOKEN")|g" \
    "$page"
  rm -f "$page.bak"
  if grep -n '%%[A-Z_]*%%' "$page" >&2; then fail "quedaron datos sin llenar en ${page#"$OUTPUT_DIR"/}"; fi
done < <(find "$OUTPUT_DIR" -name '*.html' -print0)

echo "Página armada en $OUTPUT_DIR (versión ${VERSION:-sin número}, $(wc -w <<<"$images" | tr -d ' ') capturas)"
echo "$DMG_URL"
