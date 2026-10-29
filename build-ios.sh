#!/usr/bin/env bash
set -euo pipefail

FLOWYR_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$FLOWYR_ROOT/.ci/apple-build-common.sh"

usage() {
    cat <<'EOF'
Usage: ./build-ios.sh [--clean]
Build and sign the Release iOS device app; write dist/ios/Flowyr.app and Flowyr.ipa.
--clean removes build/ios-device and build/ios-app before compiling.
Optional environment: FLOWYR_JOBS, FLOWYR_SIGNING_IDENTITY (name or SHA-1), FLOWYR_TEAM_ID.
Requires Xcode with a developer account, CMake, Ninja, Python 3.12+, XcodeGen and ImageMagick.
The development-signed IPA is for devices authorized by its provisioning profile.
EOF
}

apple_build_options "$@"
apple_build_require xcodegen magick openssl
apple_build_identity ios
FLOWYR_XCODE_IDENTITY=${FLOWYR_CERT_NAME%%:*}
xcrun --sdk iphoneos --show-sdk-path >/dev/null
cd "$FLOWYR_ROOT"
apple_build_clean "$FLOWYR_ROOT/build/ios-device" "$FLOWYR_ROOT/build/ios-app"

python3 ios/Vita3K/scripts/render-app-icon.py
cmake --preset ios-device
cmake --build --preset ios-device --target vita3k --parallel "$FLOWYR_JOBS"
ios/Vita3K/scripts/stage-core.sh device
xcodebuild -project ios/Vita3K/Vita3K.xcodeproj -scheme Vita3K \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$FLOWYR_ROOT/build/ios-app" -jobs "$FLOWYR_JOBS" \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$FLOWYR_TEAM_ID" \
    CODE_SIGN_IDENTITY="$FLOWYR_XCODE_IDENTITY" CODE_SIGN_STYLE=Automatic build

FLOWYR_APP="$FLOWYR_ROOT/build/ios-app/Build/Products/Release-iphoneos/Vita3K.app"
codesign --verify --deep --strict "$FLOWYR_APP"
[[ -f "$FLOWYR_APP/embedded.mobileprovision" ]] || { echo 'Missing iOS provisioning profile.' >&2; exit 1; }
apple_build_check_ios_profile "$FLOWYR_APP"
mkdir -p "$FLOWYR_ROOT/dist/ios"
FLOWYR_PACKAGE=$(mktemp -d "$FLOWYR_ROOT/build/ios-app/package.XXXXXX")
trap 'rm -rf -- "$FLOWYR_PACKAGE"' EXIT
mkdir "$FLOWYR_PACKAGE/Payload"
ditto "$FLOWYR_APP" "$FLOWYR_PACKAGE/Payload/Flowyr.app"
# Automatic provisioning requires Xcode's generic identity selector. Pin the
# final app and nested code to our exact certificate after validating its profile.
apple_build_sign_bundle "$FLOWYR_PACKAGE/Payload/Flowyr.app"
ditto -c -k --keepParent "$FLOWYR_PACKAGE/Payload" "$FLOWYR_PACKAGE/Flowyr.ipa"
# Replace only these generated artifacts; keep other dist content intact.
rm -rf -- "$FLOWYR_ROOT/dist/ios/Flowyr.app"
ditto "$FLOWYR_PACKAGE/Payload/Flowyr.app" "$FLOWYR_ROOT/dist/ios/Flowyr.app"
mv -f "$FLOWYR_PACKAGE/Flowyr.ipa" "$FLOWYR_ROOT/dist/ios/Flowyr.ipa"
printf '\nBuilt and signed:\n  %s\n  %s\n' "$FLOWYR_ROOT/dist/ios/Flowyr.app" "$FLOWYR_ROOT/dist/ios/Flowyr.ipa"
