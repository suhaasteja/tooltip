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

# Sprite frames, copied by hand rather than declared as SwiftPM resources:
# `Bundle.module` in an executable target looks beside the executable's *bundle
# root*, which is wrong for a .app, and it traps rather than degrading. Putting
# them in Contents/Resources means plain `Bundle.main` lookups work. See NOTES.md.
cp -R "Sources/AskAI/Sprites" "${BUNDLE}/Contents/Resources/Sprites"

printf 'APPL????' > "${BUNDLE}/Contents/PkgInfo"

# Signing identity.
#
# Ad-hoc (`-`) mints a NEW code identity on every signature. The Keychain binds
# an item's ACL to the signing identity, so each rebuild looks like a different
# application and macOS re-prompts for the login password before handing over the
# API key. Rebuilding a dozen times in a session means a dozen prompts.
#
# A stable identity fixes it: authorize once, and every later build is the same
# app as far as the Keychain is concerned. Set ASKAI_SIGN_ID to a certificate
# name from `security find-identity -v -p codesigning`, or leave it unset to fall
# back to ad-hoc. See NOTES.md.
SIGN_ID="${ASKAI_SIGN_ID:--}"
if [ "${SIGN_ID}" = "-" ]; then
  echo "==> codesign (ad-hoc -- expect Keychain prompts after every rebuild)"
else
  echo "==> codesign (${SIGN_ID})"
fi

codesign --force --sign "${SIGN_ID}" \
  --entitlements Resources/AskAI.entitlements \
  --timestamp=none \
  "${BUNDLE}"

codesign --verify --verbose=2 "${BUNDLE}"
echo "==> built ${BUNDLE}"
