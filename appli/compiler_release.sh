#!/usr/bin/env bash
# Compile l'APK release signé avec le keystore personnel, puis l'installe sur le téléphone branché.
# Le mot de passe est demandé ici, passé à Gradle pour cette compilation seulement, jamais enregistré.
#
# Usage : ./compiler_release.sh [chemin du keystore]   (défaut : ~/cles/applitransport.jks)
set -euo pipefail
cd "$(dirname "$0")"

KEYSTORE="${1:-$HOME/cles/applitransport.jks}"
FLUTTER="${FLUTTER:-$HOME/flutter/bin/flutter}"
ADB="${ADB:-$HOME/Android/sdk/platform-tools/adb}"

[ -f "$KEYSTORE" ] || { echo "Keystore introuvable : $KEYSTORE"; exit 1; }
read -r -s -p "Mot de passe du keystore : " PASS; echo

export APPLI_KEYSTORE="$KEYSTORE" APPLI_KEY_ALIAS=applitransport APPLI_KEYSTORE_PASSWORD="$PASS" APPLI_KEY_PASSWORD="$PASS"
unset PASS
"$FLUTTER" build apk --release
unset APPLI_KEYSTORE_PASSWORD APPLI_KEY_PASSWORD

# copie nommée avec la version (pubspec.yaml), prête à joindre à une Release GitHub
VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
APK=build/app/outputs/flutter-apk/applitransport-$VERSION.apk
cp build/app/outputs/flutter-apk/app-release.apk "$APK"
echo "✓ APK signé : $APK ($(du -h "$APK" | cut -f1))"
echo "  SHA-256 : $(sha256sum "$APK" | cut -d' ' -f1)"

if "$ADB" get-state >/dev/null 2>&1; then
  "$ADB" install -r "$APK" && echo "✓ installé sur le téléphone"
else
  echo "Aucun téléphone détecté : branchez-le (débogage USB) puis : $ADB install -r $APK"
fi
