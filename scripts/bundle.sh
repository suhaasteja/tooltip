#!/usr/bin/env bash
# Assemble and ad-hoc sign dist/AskAI.app from the SwiftPM release build.
#
# RULE 4 from PLAN.md: editing Info.plist invalidates the code signature, so this
# script always rebuilds the bundle from scratch and re-signs. Never test a
# Services change without running it.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="AskAI"
BUNDLE="dist/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"

cp "${BIN_PATH}/${APP_NAME}" "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"

# SwiftPM emits a resource bundle for targets with resources; copy any along.
for res in "${BIN_PATH}"/*.bundle; do
  [ -e "$res" ] || continue
  cp -R "$res" "${BUNDLE}/Contents/Resources/"
done

printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

echo "==> codesign (ad-hoc, with entitlements)"
codesign --force --sign - \
  --entitlements Resources/AskAI.entitlements \
  --timestamp=none \
  "${BUNDLE}"

codesign --verify --verbose=2 "${BUNDLE}"
echo "==> built ${BUNDLE}"
