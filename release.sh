#!/bin/bash
# Publie la version courante (Resources/Info.plist) : compile, archive l'appli signée, crée la release GitHub vX.Y.Z.
# L'appli installée se met à jour toute seule depuis cette release (UpdateManager). Usage : ./release.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"
[ -z "$(git status --porcelain)" ] || { echo "Modifications non commitées : commitez d'abord." >&2; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG existe déjà : changez la version dans Resources/Info.plist." >&2; exit 1; }

DIST="$(mktemp -d)"
INSTALL_DIR="$DIST" ./build.sh
ZIP="$DIST/mCLEAN-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$DIST/mCLEAN.app" "$ZIP"
git push origin main
gh release create "$TAG" "$ZIP" --title "mCLEAN $VERSION" --notes "${NOTES:-Version $VERSION}"
rm -rf "$DIST"
echo "OK : release $TAG publiée"
