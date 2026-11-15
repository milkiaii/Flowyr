#!/usr/bin/env bash
# Stage the CMake-built Vita3K core into ios/Vita3K/Vendor and (re)generate
# the Xcode project for the chosen flavor.
#
# Usage:
#   ios/Vita3K/scripts/stage-core.sh [device|simulator]   (default: device)
#
# The CMake build must exist first:
#   cmake --preset ios-device       (or ios-simulator)
#   cmake --build --preset ios-device
set -euo pipefail

FLAVOR="${1:-device}"
ROOT="$(cd "$(dirname "${0}")/../../.." && pwd)"
APP="$ROOT/ios/Vita3K"
VENDOR="$APP/Vendor"

case "$FLAVOR" in
  device)
    BUILD="$ROOT/build/ios-device"
    PROJECT="project.yml"
    ;;
  simulator)
    BUILD="$ROOT/build/ios-simulator"
    PROJECT="project-sim.yml"
    ;;
  *)
    echo "unknown flavor: $FLAVOR (use device|simulator)" >&2
    exit 1
    ;;
esac

if [ ! -f "$BUILD/vita3k/libVita3KCore.dylib" ]; then
  echo "libVita3KCore.dylib not found; build it first:" >&2
  echo "  cmake --preset ios-${FLAVOR} && cmake --build --preset ios-${FLAVOR}" >&2
  exit 1
fi

CORE_CONFIG="$BUILD/vita3k/libVita3KCore.dylib.build-config"
if [ ! -f "$CORE_CONFIG" ]; then
  echo "Missing core build configuration; reconfigure and rebuild before staging." >&2
  exit 1
fi

mkdir -p "$VENDOR/include/ios"
cp "$BUILD/vita3k/libVita3KCore.dylib" "$VENDOR/"
cp "$CORE_CONFIG" "$VENDOR/"
cp "$ROOT/vita3k/ios/include/ios/bridge.h" "$VENDOR/include/ios/"

# Swift module that re-exports the C bridge for `import Vita3KCore`.
cat > "$VENDOR/include/module.modulemap" <<'EOF'
module Vita3KCore {
    header "ios/bridge.h"
    export *
}
EOF

if [ "$FLAVOR" = "device" ]; then
  XCFW="$BUILD/external/MoltenVK/static/MoltenVK.xcframework"
  if [ ! -d "$XCFW" ]; then
    echo "MoltenVK xcframework missing ($XCFW); re-run cmake configure." >&2
    exit 1
  fi
  rm -rf "$VENDOR/MoltenVK.xcframework"
  cp -R "$XCFW" "$VENDOR/"
else
  # Step 7: the MoltenVK v1.4.1 release has no simulator slice, so the
  # simulator flavor links a static lib built from the same source
  # (scripts/build-moltenvk-sim.sh: MoltenVK + ShaderConverter + Common +
  # SPIRV-Cross combined into one archive, like the device slice).
  MKV_SIM="$ROOT/build/external/mkv-ios-simulator/libMoltenVK.a"
  if [ ! -f "$MKV_SIM" ]; then
    echo "MoltenVK simulator lib missing ($MKV_SIM); build it first:" >&2
    echo "  ios/Vita3K/scripts/build-moltenvk-sim.sh" >&2
    exit 1
  fi
  mkdir -p "$VENDOR/MoltenVK-sim"
  cp "$MKV_SIM" "$VENDOR/MoltenVK-sim/libMoltenVK.a"
fi

# The helper extension compiles StikJIT for the built-in JIT; the device project needs it on disk.
if [ "$FLAVOR" = "device" ]; then
  "$APP/scripts/fetch-stikjit.sh"
fi

(
  cd "$APP"
  xcodegen generate -s "$PROJECT"
)

echo "Staged $FLAVOR core ($(cat "$CORE_CONFIG")) into $VENDOR"
echo "Project generated from $PROJECT"
echo "Open: open $APP/Vita3K.xcodeproj"
