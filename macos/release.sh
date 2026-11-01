#!/bin/zsh
# Arma una versión de Paperclip Dispatch para repartir y, con --publish, la publica en GitHub, donde la
# busca el actualizador de la app (Sparkle).
#
#   1. Sube la versión en macos/VERSION y convierte «## Unreleased» de CHANGELOG.md y CHANGELOG.es.md en
#      la sección de esa versión («## 1.2.0 — 2026-11-01»). Commit y push.
#   2. macos/release.sh             arma todo en macos/dist/<versión>, sin publicar (para revisar o probar)
#      macos/release.sh --publish   además notariza, crea el release en GitHub, marca el commit y pone la
#                                   versión en el cask de Homebrew (update-cask.sh), que commitea y sube al tap
#
# Lo que deja: el DMG para instalar por primera vez, el .zip que baja el actualizador (firmado con la llave
# de Sparkle) y appcast.xml, con las novedades de esa versión en inglés y en español (la app muestra las de
# su idioma).
#
# Variables (con su valor por defecto):
#   RELEASES_REPO=<el de release.env; vacía = el del remoto origin>  dónde se publica y adónde enlazan las novedades
#   BASE_URL=https://github.com/$RELEASES_REPO/releases/download/v<versión>  de dónde se baja el .zip
#   NOTARY_PROFILE=<obligatorio con --publish>  perfil de notarytool en el llavero
#       (se crea una vez con: xcrun notarytool store-credentials <nombre>)
#   DIST=macos/dist/<versión>  APP_VERSION=<la de macos/VERSION>
#   CHANGELOG_EN=CHANGELOG.md  CHANGELOG_ES=CHANGELOG.es.md  (otros, para probar)
#   HOMEBREW_TAP_DIR=<la carpeta homebrew-tap junto a la del repo>  el tap con el cask (ver update-cask.sh)
# La llave privada de Sparkle está en el llavero (generate_keys --account $SPARKLE_KEY_ACCOUNT, ver
# release.env). Lo demás de la app (nombre, identificador, appcast) sale de build.sh y release.env.
# Sin `set -u`: el gancho de cuentas de ~/.zshenv corre en cada `cd` y lee variables que pueden no existir.
set -eo pipefail

ROOT=${0:A:h}
REPO=${ROOT:h}
[[ -f $ROOT/build.local.env ]] && source "$ROOT/build.local.env"
source "$ROOT/release.env"
APP_NAME=${APP_NAME:-Paperclip Dispatch}
VERSION=${APP_VERSION:-$(<"$ROOT/VERSION")}
TAG=v$VERSION
PUBLISH=false
[[ $1 == --publish ]] && PUBLISH=true
CHANGELOG_EN=${CHANGELOG_EN:-$REPO/CHANGELOG.md}
CHANGELOG_ES=${CHANGELOG_ES:-$REPO/CHANGELOG.es.md}
DIST=${DIST:-$ROOT/dist/$VERSION}
SPARKLE_BIN=$ROOT/.build/artifacts/sparkle/Sparkle/bin
FILE_BASE=${APP_NAME// /-}-$VERSION

fail() {
  print -u2 "release: $*"
  exit 1
}

if [[ -z $RELEASES_REPO ]]; then
  RELEASES_REPO=$(git -C "$REPO" remote get-url origin 2>/dev/null \
    | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##') || true
fi
BASE_URL=${BASE_URL:-https://github.com/$RELEASES_REPO/releases/download/$TAG}

# La sección de una versión en un CHANGELOG: lo que hay entre su «## <versión>» y el siguiente «## ».
notes_for() {
  awk -v version="$VERSION" '
    /^## / { if (found) exit; if ($2 == version) { found = 1; next } }
    found { print }
  ' "$1" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

# ------------------------------------------------------------ antes de nada

[[ -f $CHANGELOG_EN && -f $CHANGELOG_ES ]] || fail "faltan $CHANGELOG_EN o $CHANGELOG_ES"
NOTES_EN=$(notes_for "$CHANGELOG_EN")
NOTES_ES=$(notes_for "$CHANGELOG_ES")
# Lo que cambió para quien la usa se escribe antes de que le llegue, en los dos idiomas.
[[ -n $NOTES_EN ]] || fail "CHANGELOG.md no tiene sección para $VERSION: convierte «## Unreleased» en «## $VERSION — $(date +%F)»"
[[ -n $NOTES_ES ]] || fail "CHANGELOG.es.md no tiene sección para $VERSION: convierte «## Unreleased» en «## $VERSION — $(date +%F)»"
[[ $NOTES_EN$NOTES_ES != *']]>'* ]] || fail "las novedades no pueden llevar «]]>»"
[[ -x $SPARKLE_BIN/sign_update ]] || swift package --package-path "$ROOT" resolve --disable-keychain >/dev/null
[[ -x $SPARKLE_BIN/sign_update ]] || fail "no encuentro las herramientas de Sparkle en $SPARKLE_BIN"

if $PUBLISH; then
  [[ -n $RELEASES_REPO ]] || fail "no sé en qué repo publicar: define RELEASES_REPO o el remoto origin"
  [[ -n $UPDATE_FEED_URL ]] || fail "release.env no tiene UPDATE_FEED_URL: sin eso, la app publicada no buscaría versiones"
  [[ -n $NOTARY_PROFILE ]] || fail "falta NOTARY_PROFILE (xcrun notarytool store-credentials <nombre>)"
  git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet \
    || fail "hay cambios sin commitear: se publica lo que está en el commit"
  git -C "$REPO" fetch --quiet origin
  SHA=$(git -C "$REPO" rev-parse HEAD)
  [[ $SHA == $(git -C "$REPO" rev-parse '@{upstream}') ]] || fail "HEAD no está en el remoto: haz push primero"
  ! git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$TAG ya existe: sube la versión"
  ! gh release view "$TAG" -R "$RELEASES_REPO" >/dev/null 2>&1 || fail "$TAG ya está publicada en $RELEASES_REPO"
  # El cask se actualiza al final: que no falle recién después de publicar.
  "$ROOT/update-cask.sh" --check --push "$VERSION" "$FILE_BASE.dmg" || fail "el tap de Homebrew no está listo (ver arriba)"
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# ------------------------------------------------------------ armar

if $PUBLISH; then
  OUTPUT_DIR=$DIST/build APP_VERSION=$VERSION UNIVERSAL=${UNIVERSAL:-1} NOTARIZE=1 "$ROOT/build.sh"
else
  OUTPUT_DIR=$DIST/build APP_VERSION=$VERSION UNIVERSAL=${UNIVERSAL:-0} "$ROOT/build.sh"
fi
APP=$DIST/build/$APP_NAME.app

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if $PUBLISH; then
  print "Notarizando la app…"
  ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
  notarize "$DIST/notarize.zip"
  rm "$DIST/notarize.zip"
  xcrun stapler staple "$APP"
  # Una Mac rechaza sin explicación una app que no está notarizada.
  spctl --assess --type execute "$APP" || fail "Gatekeeper rechaza la app: no quedó notarizada"
fi

# Lo que baja el actualizador.
ZIP=$DIST/$FILE_BASE.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGNATURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_KEY_ACCOUNT" "$ZIP") \
  || fail "no pude firmar el .zip con la llave de Sparkle (cuenta $SPARKLE_KEY_ACCOUNT del llavero)"

# Lo que se baja la primera vez: la app y un acceso a Aplicaciones para arrastrarla.
DMG=$DIST/$FILE_BASE.dmg
STAGE=$DIST/dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
if $PUBLISH; then
  codesign --force --timestamp --sign "$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')" "$DMG"
  print "Notarizando el DMG…"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

# ------------------------------------------------------------ appcast

NOTES_LINK=""
[[ -n $RELEASES_REPO ]] && NOTES_LINK="https://github.com/$RELEASES_REPO/releases/tag/$TAG"
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
MINIMUM_SYSTEM=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
{
  print '<?xml version="1.0" encoding="utf-8"?>'
  print '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  print '  <channel>'
  print "    <title>$APP_NAME</title>"
  print '    <item>'
  print "      <title>$VERSION</title>"
  print "      <pubDate>$PUB_DATE</pubDate>"
  print "      <sparkle:version>$VERSION</sparkle:version>"
  print "      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
  print "      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>"
  [[ -n $NOTES_LINK ]] && print "      <sparkle:fullReleaseNotesLink>$NOTES_LINK</sparkle:fullReleaseNotesLink>"
  print '      <description sparkle:format="markdown" xml:lang="en"><![CDATA['
  print -r -- "$NOTES_EN"
  print '      ]]></description>'
  print '      <description sparkle:format="markdown" xml:lang="es"><![CDATA['
  print -r -- "$NOTES_ES"
  print '      ]]></description>'
  print "      <enclosure url=\"$BASE_URL/$FILE_BASE.zip\" type=\"application/octet-stream\" $SIGNATURE />"
  print '    </item>'
  print '  </channel>'
  print '</rss>'
} > "$DIST/appcast.xml"
xmllint --noout "$DIST/appcast.xml"

print "Armada: $DIST"
ls -1 "$DIST" | grep -v '^build$' | sed 's/^/  /'
$PUBLISH || exit 0

# ------------------------------------------------------------ publicar

RELEASE_NOTES="$NOTES_EN

---

$NOTES_ES"
# La versión de una queja lleva al código del que salió. La etiqueta sube antes que el release: sin ella,
# gh crearía otra en la punta de la rama principal y el push de esta sería rechazado.
git -C "$REPO" tag -a "$TAG" -m "$APP_NAME $VERSION" "$SHA"
git -C "$REPO" push --quiet origin "$TAG" || fail "no pude subir la etiqueta $TAG: nada se publicó (git push origin $TAG)"
gh release create "$TAG" -R "$RELEASES_REPO" --verify-tag --title "$APP_NAME $VERSION" --notes "$RELEASE_NOTES" \
  "$DMG" "$ZIP" "$DIST/appcast.xml" \
  || fail "la etiqueta $TAG ya está en GitHub, pero no pude crear el release: gh release create $TAG --verify-tag …"
# brew install baja este mismo DMG: el cask lleva su versión y su sha256.
"$ROOT/update-cask.sh" --push "$VERSION" "$DMG" \
  || fail "publicada, pero no pude actualizar el cask: macos/update-cask.sh --push $VERSION $DMG"
print "Publicada: https://github.com/$RELEASES_REPO/releases/tag/$TAG"
