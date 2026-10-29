#!/usr/bin/env bash
set -euo pipefail

FLOWYR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$FLOWYR_ROOT/.ci/apple-build-common.sh"

usage() {
    cat <<'EOF'
Usage: ./build-macos.sh [--clean]
Build and sign the Release app for this Mac's architecture.
Outputs: dist/macos/Flowyr.app and dist/macos/Flowyr.zip.
--clean removes build/macos-ninja before compiling.
Optional environment: FLOWYR_JOBS, FLOWYR_SIGNING_IDENTITY (name or SHA-1), FLOWYR_TEAM_ID, Qt6_ROOT.
Requires Xcode with a developer account, XcodeGen, CMake, Ninja, Python 3.12+, and Qt 6.11+.
Uses Apple Development/Mac Developer and an automatic iCloud-enabled provisioning profile.
The development-signed app runs on Macs authorized by that profile.
Produces signed artifacts; does not submit them to Apple's notarization service.
EOF
}

apple_build_options "$@"
apple_build_require openssl xcodegen
apple_build_identity macos-icloud
cd "$FLOWYR_ROOT"
apple_build_clean "$FLOWYR_ROOT/build/macos-ninja"

cmake --preset macos-ninja -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
    -DUSE_LTO=RELEASE_ONLY -DPython3_EXECUTABLE="$FLOWYR_PYTHON"
# A portable Qt bundle needs the deploy tool, not only Qt's headers/libraries.
FLOWYR_MACDEPLOYQT=$(sed -n 's/^MACDEPLOYQT_EXECUTABLE:FILEPATH=//p' build/macos-ninja/CMakeCache.txt)
if [[ ! -x "$FLOWYR_MACDEPLOYQT" ]]; then
    echo 'macdeployqt was not found. Install Qt deployment tools or set Qt6_ROOT.' >&2
    exit 1
fi
cmake --build --preset macos-ninja-release --target vita3k --parallel "$FLOWYR_JOBS"

mkdir -p "$FLOWYR_ROOT/dist/macos"
FLOWYR_PACKAGE=$(mktemp -d "$FLOWYR_ROOT/build/macos-ninja/package.XXXXXX")
trap 'rm -rf -- "$FLOWYR_PACKAGE"' EXIT
ditto "$FLOWYR_ROOT/build/macos-ninja/bin/Release/Flowyr.app" "$FLOWYR_PACKAGE/Flowyr.app"
# Resolve dependencies of the plugins that CMake deployed, using the final
# bundle name/location, before applying the certificate signature.
"$FLOWYR_MACDEPLOYQT" "$FLOWYR_PACKAGE/Flowyr.app"
# iCloud entitlements must be authorized by an embedded macOS profile. Xcode
# resolves that profile using the App ID/container already shared with iOS.
xcodegen generate --spec macos/signing/project.yml
xcodebuild -project macos/signing/FlowyrSigning.xcodeproj -scheme FlowyrSigning \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$FLOWYR_ROOT/build/macos-ninja/signing" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$FLOWYR_TEAM_ID" CODE_SIGN_IDENTITY="${FLOWYR_CERT_NAME%%:*}" build
FLOWYR_SIGNING_APP="$FLOWYR_ROOT/build/macos-ninja/signing/Build/Products/Release/FlowyrSigning.app"
python3 macos/prepare-signing.py "$FLOWYR_SIGNING_APP" "$FLOWYR_PACKAGE/Flowyr.app" \
    "$FLOWYR_CERT_SHA1" "$FLOWYR_TEAM_ID" "$FLOWYR_PACKAGE/Flowyr.entitlements"
apple_build_sign_bundle "$FLOWYR_PACKAGE/Flowyr.app" "$FLOWYR_PACKAGE/Flowyr.entitlements"
ditto -c -k --sequesterRsrc --keepParent "$FLOWYR_PACKAGE/Flowyr.app" "$FLOWYR_PACKAGE/Flowyr.zip"
rm -rf -- "$FLOWYR_ROOT/dist/macos/Flowyr.app"
mv "$FLOWYR_PACKAGE/Flowyr.app" "$FLOWYR_ROOT/dist/macos/Flowyr.app"
mv -f "$FLOWYR_PACKAGE/Flowyr.zip" "$FLOWYR_ROOT/dist/macos/Flowyr.zip"
printf '\nBuilt and signed:\n  %s\n  %s\n' "$FLOWYR_ROOT/dist/macos/Flowyr.app" "$FLOWYR_ROOT/dist/macos/Flowyr.zip"
