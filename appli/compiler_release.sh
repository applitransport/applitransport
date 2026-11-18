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
# un APK par type de processeur (64 bits et 32 bits), signés tous deux avec la même clé
"$FLUTTER" build apk --release --split-per-abi --target-platform android-arm64,android-arm
unset APPLI_KEYSTORE_PASSWORD APPLI_KEY_PASSWORD

# copies nommées avec la version (pubspec.yaml), prêtes à joindre à une Release GitHub,
# GitHub les liste par ordre alphabétique et les versions 1.3.0 et antérieures prennent le premier APK :
# « …-arm64.apk » doit passer avant « …-vieux-arm32.apk » (le nom doit finir par -arm32.apk, cf. app_update.dart)
VERSION=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
OUT=build/app/outputs/flutter-apk
declare -A ABI=([arm64]=arm64-v8a [vieux-arm32]=armeabi-v7a)
for k in arm64 vieux-arm32; do
  APK=$OUT/applitransport-$VERSION-$k.apk
  cp "$OUT/app-${ABI[$k]}-release.apk" "$APK"
  echo "✓ APK signé : $APK ($(du -h "$APK" | cut -f1))"
  echo "  SHA-256 : $(sha256sum "$APK" | cut -d' ' -f1)"
done

if "$ADB" get-state >/dev/null 2>&1; then
  # l'APK qui correspond au processeur du téléphone branché
  CPU=$("$ADB" shell getprop ro.product.cpu.abi | tr -d '\r')
  K=vieux-arm32; [ "$CPU" = arm64-v8a ] && K=arm64
  "$ADB" install -r "$OUT/applitransport-$VERSION-$K.apk" && echo "✓ installé sur le téléphone ($K)"
else
  echo "Aucun téléphone détecté : branchez-le (débogage USB) puis : $ADB install -r $OUT/applitransport-$VERSION-arm64.apk"
fi
