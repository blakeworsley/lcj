#!/usr/bin/env bash
# build.sh — assemble Clodex.app from an SPM release build.
# Structure ported from mlg87/lcj clusage-menubar.
#
# WHY per-arch builds + lipo instead of one multi-arch build:
# `swift build --arch arm64 --arch x86_64` requires xcbuild / full Xcode;
# it fails under Command Line Tools only (CLT). The per-invocation+lipo
# approach works with CLT alone.
#
# Optional env vars:
#   CODESIGN_IDENTITY  — code signing identity (default: ad-hoc "-")
#   ARCHS              — space-separated arch list (default: host arch only)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(cat version.txt)"
BIN_NAME="ClodexMenubar"
APP_NAME="Clodex"
APP_DIR="build/${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"
ARCHS="${ARCHS:-$(uname -m)}"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Building Clodex v${VERSION}"

# -- Compile each arch --
BINARY_PATHS=()
for ARCH in $ARCHS; do
    echo "--> swift build -c release --arch ${ARCH}"
    swift build -c release --arch "$ARCH"
    BINARY_PATHS+=(".build/${ARCH}-apple-macosx/release/${BIN_NAME}")
done

# -- Assemble app bundle --
echo "--> Assembling ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Produce universal binary (or copy single-arch if only one arch built)
if [[ ${#BINARY_PATHS[@]} -eq 1 ]]; then
    cp "${BINARY_PATHS[0]}" "${MACOS}/${BIN_NAME}"
else
    lipo -create "${BINARY_PATHS[@]}" -output "${MACOS}/${BIN_NAME}"
fi

# Info.plist with version stamped in
cp Info.plist "${CONTENTS}/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${VERSION}" \
    -c "Set :CFBundleVersion ${VERSION}" \
    "${CONTENTS}/Info.plist"

# -- Sign --
echo "--> codesign (${CODESIGN_IDENTITY})"
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "==> Done: ${APP_DIR}"
