#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
if [[ -e android/key.properties || -e android/app/localbeat-release.jks ]]; then
  echo 'Signing material already exists; it has not been replaced.'
  exit 0
fi
umask 077
localbeat_password="$(openssl rand -hex 24)"
export LOCALBEAT_KEY_PASSWORD="$localbeat_password"
keytool -genkeypair -keystore android/app/localbeat-release.jks -alias localbeat \
  -storepass:env LOCALBEAT_KEY_PASSWORD -keypass:env LOCALBEAT_KEY_PASSWORD \
  -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=LocalBeat, O=Personal, C=IN'
# Generated signing configuration, not application source.
printf 'storeFile=localbeat-release.jks\nstorePassword=%s\nkeyAlias=localbeat\nkeyPassword=%s\n' \
  "$localbeat_password" "$localbeat_password" > android/key.properties
unset LOCALBEAT_KEY_PASSWORD localbeat_password
echo 'Signing key created. Keep android/key.properties and the keystore for future updates.'
