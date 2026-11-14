#!/usr/bin/env bash
#
# Builds the shippable release artifacts with Dart obfuscation.
#
#   tool/build_release.sh            # android (default)
#   tool/build_release.sh ios
#   tool/build_release.sh all
#
# Android: a single arm64-only APK. `--target-platform android-arm64` keeps
# Flutter from compiling the other ABIs, with release-only JNI packaging
# exclusions in android/app/build.gradle as a backstop.
#
# iOS: an **unsigned** .ipa for sideloading (AltStore / Sideloadly / your own
# provisioning profile). There is no Apple Developer account behind this app,
# so there is nothing to sign with here and nothing to submit to; the archive
# is built with --no-codesign and packaged by hand. Whoever installs it signs
# it with their own identity.
#
# Things this exists to get right, because all of them have already bitten us:
#
#   1. JDK version. AGP's bundled lint calls java.util.List.removeLast(), which
#      only exists on JDK 21+. Building on JDK 17 fails deep inside lint with a
#      NoSuchMethodError that says nothing about Java versions.
#   2. Symbol files. --obfuscate renames every identifier, so a crash from a
#      shipped build is unreadable without the matching .symbols file. They are
#      written to symbols/<version>/<platform>/ and must be kept for as long as that
#      version is in anyone's hands. Attach them to the GitHub release.
#   3. iOS has no CocoaPods. Every plugin this app uses ships a Package.swift,
#      so the project is integrated through Swift Package Manager and there is
#      deliberately no ios/Podfile. Do not re-add one to "fix" a build; if a
#      future plugin is Pods-only, regenerate it with `flutter create .` and
#      say so here.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-android}"
case "$TARGET" in
  android|ios|macos) PLATFORMS=("$TARGET") ;;
  all) PLATFORMS=(android ios macos) ;;
  *) echo "usage: tool/build_release.sh [android|ios|macos|all]" >&2; exit 2 ;;
esac

# Flutter is not always on PATH (it isn't on this machine), so resolve it
# rather than failing halfway through with "command not found".
FLUTTER="${FLUTTER_BIN:-$(command -v flutter || true)}"
if [ -z "$FLUTTER" ] && [ -x "$HOME/flutter/bin/flutter" ]; then
  FLUTTER="$HOME/flutter/bin/flutter"
fi
if [ -z "$FLUTTER" ]; then
  echo "error: flutter not found; set FLUTTER_BIN=/path/to/flutter" >&2
  exit 1
fi

VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')
SHORT_VERSION="${VERSION%%+*}"
RELEASE_ROOT="symbols/$VERSION"
if [ "${ALLOW_UNTAGGED:-}" = "1" ]; then
  RELEASE_ROOT="symbols/dev"
elif [ -n "$(git status --porcelain)" ] ||
     [ "$(git rev-parse "refs/tags/v$SHORT_VERSION^{commit}" 2>/dev/null)" != "$(git rev-parse HEAD)" ]; then
  echo "error: HEAD is not a clean checkout of v$SHORT_VERSION." >&2
  echo "       Set ALLOW_UNTAGGED=1 for a development build." >&2
  exit 1
fi

mkdir -p build "$RELEASE_ROOT"
LOCK=symbols/.bilibeats-release.lock
if ! mkdir "$LOCK"; then
  echo "error: another release build is using this checkout ($LOCK)." >&2
  exit 1
fi
STAGING_DIR=""
cleanup() {
  [ -z "$STAGING_DIR" ] || rm -rf -- "$STAGING_DIR"
  rmdir "$LOCK"
}
trap cleanup EXIT

symbol_prefix() {
  case "$1" in macos) echo darwin ;; *) echo "$1" ;; esac
}

if [ "$RELEASE_ROOT" != "symbols/dev" ]; then
  for platform in "${PLATFORMS[@]}"; do
    if [ -e "$RELEASE_ROOT/$platform" ] ||
       compgen -G "$RELEASE_ROOT/app.$(symbol_prefix "$platform")-*.symbols" >/dev/null; then
      echo "error: archived $platform symbols already exist for $VERSION." >&2
      echo "       Set ALLOW_UNTAGGED=1 for a separate development build." >&2
      exit 1
    fi
  done
fi

check_android() {
  local jdk_dir java_bin java_version java_major
  if [ -z "${JAVA_HOME:-}" ] && [ -x "/opt/homebrew/opt/openjdk@21/bin/java" ]; then
    export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
  fi

  # Flutter can prefer its configured JDK or Android Studio over JAVA_HOME.
  jdk_dir=$("$FLUTTER" config --machine | python3 -c 'import json, sys; print(json.load(sys.stdin).get("jdk-dir") or "")')
  java_bin=${jdk_dir:+$jdk_dir/bin/java}
  if [ -z "$java_bin" ]; then
    java_bin=$(command -v java || true)
  fi
  java_version=$("$java_bin" -version 2>&1 || true)
  if [[ "$java_version" =~ version[[:space:]]+\"([0-9]+) ]] &&
     [ -x "$(dirname "$java_bin")/javac" ]; then
    java_major=${BASH_REMATCH[1]}
  else
    java_major=0
  fi
  if [ "$java_major" -lt 21 ]; then
    echo "error: Flutter selected ${java_bin:-no Java binary}; Android release builds require JDK 21+." >&2
    echo '       Select a JDK with flutter config --jdk-dir=/path/to/jdk.' >&2
    exit 1
  fi

  if [ ! -f android/key.properties ]; then
    if [ "$RELEASE_ROOT" != "symbols/dev" ] || [ "${ALLOW_DEBUG_SIGNING:-}" != "1" ]; then
      echo "error: android/key.properties not found — the build would be signed" >&2
      echo "       with the DEBUG key and could not update an installed release." >&2
      echo "       Run tool/make_keystore.sh first. Development builds can opt into debug signing." >&2
      exit 1
    fi
    echo "WARNING: signing with the DEBUG key; this build must not be published." >&2
    echo >&2
  fi
}

build_android() {
  echo "==> Android $VERSION (obfuscated), symbols -> $SYMBOLS_DIR"
  # No --split-per-abi: with a single ABI there is nothing to split, and AGP
  # rejects `splits.abi` and `ndk.abiFilters` being set at the same time
  # ("Conflicting configuration ... cannot be present when splits abi filters
  # are set"). The output is a single app-release.apk containing only arm64.
  "$FLUTTER" build apk --release --no-pub \
    --target-platform android-arm64 \
    --obfuscate \
    --split-debug-info="$SYMBOLS_DIR"

  # Publish under a name that says what it is, rather than "app-release.apk".
  ARTIFACT="$STAGING_DIR/bilibeats-${SHORT_VERSION}-arm64-v8a.apk"
  cp build/app/outputs/flutter-apk/app-release.apk "$ARTIFACT"

  echo
  echo "==> APK"
  ls -lh "$ARTIFACT"
}

build_ios() {
  echo "==> iOS $VERSION (obfuscated, unsigned), symbols -> $SYMBOLS_DIR"
  "$FLUTTER" build ios --release --no-codesign --no-pub \
    --obfuscate \
    --split-debug-info="$SYMBOLS_DIR"

  # An .ipa is just a zip with the .app inside a Payload/ directory. Building
  # one by hand (rather than via `flutter build ipa`, which insists on an
  # export method and therefore a signing identity) is what lets an unsigned
  # build be produced at all.
  local out_dir="$STAGING_DIR"
  local ipa="$out_dir/bilibeats-${SHORT_VERSION}-unsigned.ipa"
  mkdir -p "$out_dir/Payload"
  cp -R build/ios/iphoneos/Runner.app "$out_dir/Payload/"
  (cd "$out_dir" && zip -qry "$(basename "$ipa")" Payload)
  rm -rf "$out_dir/Payload"
  ARTIFACT="$ipa"

  echo
  echo "==> IPA (UNSIGNED — sideload with AltStore/Sideloadly, or re-sign)"
  ls -lh "$ipa"
}

build_macos() {
  echo "==> macOS $VERSION (obfuscated), symbols -> $SYMBOLS_DIR"
  "$FLUTTER" build macos --release --no-pub \
    --obfuscate \
    --split-debug-info="$SYMBOLS_DIR"

  local app_path="build/macos/Build/Products/Release/BiliBeats.app"
  local dmg="$STAGING_DIR/bilibeats-${SHORT_VERSION}-macos.dmg"
  hdiutil create -volname "BiliBeats" -srcfolder "$app_path" -ov -format UDZO "$dmg"
  ARTIFACT="$dmg"

  echo
  echo "==> macOS DMG"
  ls -lh "$dmg"
}

for platform in "${PLATFORMS[@]}"; do
  if [ "$platform" = android ]; then
    check_android
  elif [ "$(uname)" != Darwin ]; then
    echo "error: $platform builds need macOS with Xcode" >&2
    exit 1
  fi
done

# This exact model and dependency resolution are shared by all artifacts.
tool/fetch_song_model.sh
"$FLUTTER" pub get --enforce-lockfile

for platform in "${PLATFORMS[@]}"; do
  STAGING_DIR=$(mktemp -d "$RELEASE_ROOT/.build-$platform.XXXXXX")
  SYMBOLS_DIR="$STAGING_DIR"
  "build_$platform"
  if ! compgen -G "$SYMBOLS_DIR/app.$(symbol_prefix "$platform")-*.symbols" >/dev/null; then
    echo "error: Flutter did not generate $platform symbols." >&2
    exit 1
  fi
  archive="$RELEASE_ROOT/$platform"
  if [ "$RELEASE_ROOT" = "symbols/dev" ]; then
    rm -rf -- "$archive"
  fi
  mv "$STAGING_DIR" "$archive"
  STAGING_DIR=""
  echo "==> Artifact: $archive/${ARTIFACT##*/}"
  echo "==> Symbols: $archive"
  echo "    flutter symbolize -i <trace.txt> -d $archive/<app.*.symbols>"
done
