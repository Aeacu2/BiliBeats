#!/usr/bin/env bash
#
# Creates the release signing keystore and android/key.properties.
#
# Run this ONCE, ever. Then back up BOTH files somewhere you will still have
# them in five years:
#
#     android/bilibeats-release.jks
#     android/key.properties
#
# Losing the keystore is unrecoverable: Android identifies an app by its
# signing key, so a replacement key cannot update an existing install. Every
# user would have to uninstall (losing downloaded audio and playlists) and
# install fresh. Both files are gitignored — they must never be committed.
#
# keytool prompts for the passwords interactively; they are not passed on the
# command line, so they stay out of your shell history and process list.
set -euo pipefail

cd "$(dirname "$0")/.."

KEYSTORE="android/bilibeats-release.jks"
PROPS="android/key.properties"
ALIAS="bilibeats"

if [ -e "$PROPS" ]; then
  echo "error: $PROPS already exists." >&2
  echo "Refusing to overwrite — that would orphan every existing install." >&2
  exit 1
fi

: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@21}"
export PATH="$JAVA_HOME/bin:$PATH"
command -v keytool >/dev/null || { echo "error: keytool not on PATH" >&2; exit 1; }

# The keystore without its properties file is a run that stopped half way:
# only the properties are written, for the key that is already there.
HAVE_KEY=0
if [ -e "$KEYSTORE" ]; then
  HAVE_KEY=1
  echo "$KEYSTORE exists; writing $PROPS for it."
fi

echo "Creating a 10000-day RSA-4096 key. You will be asked for:"
echo "  * a keystore password (choose a strong one, store it in a password manager)"
echo "  * a name/organisation (any value is fine for a personal app)"
echo

if [ "$HAVE_KEY" = 0 ]; then
  keytool -genkeypair \
    -v \
    -keystore "$KEYSTORE" \
    -alias "$ALIAS" \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000
fi

# keytool -genkeypair uses one password for both store and key here. What is
# typed is checked against the keystore before it is written down: a wrong
# one would only surface as a failed release build.
while :; do
  printf 'Re-enter the keystore password to write %s: ' "$PROPS"
  IFS= read -rs PASS
  echo
  if KS_PASS="$PASS" keytool -list -keystore "$KEYSTORE" -alias "$ALIAS" \
      -storepass:env KS_PASS >/dev/null 2>&1; then
    break
  fi
  echo "That password does not open $KEYSTORE. Try again (Ctrl-C to stop)." >&2
done

umask 077
# printf '%s', not a heredoc: an unquoted heredoc would shell-expand a
# password containing $ or backticks, and a quoted one writes the literal
# text "$PASS". A .properties file reads a backslash as an escape, so each
# one in the password is doubled.
ESCAPED="${PASS//\\/\\\\}"
{
  printf 'storeFile=%s\n' "bilibeats-release.jks"
  printf 'storePassword=%s\n' "$ESCAPED"
  printf 'keyAlias=%s\n' "$ALIAS"
  printf 'keyPassword=%s\n' "$ESCAPED"
} > "$PROPS"
unset PASS ESCAPED
chmod 600 "$KEYSTORE"

echo
echo "Wrote $PROPS (mode $(stat -f '%Lp' "$PROPS"))."
echo "Verify the build picks it up:"
echo "  tool/build_release.sh"
echo "  # then confirm the signer is no longer 'Android Debug':"
echo "  apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk"
