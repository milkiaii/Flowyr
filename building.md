# Build Flowyr

## Local signed Apple builds

The root scripts build Flowyr in **Release**, sign the result using an identity
available in the macOS Keychain, and place the final artifacts in `dist`:

| Command | Target | Artifacts |
| --- | --- | --- |
| `./build-ios.sh` | iOS device, arm64 | `dist/ios/Flowyr.app`, `dist/ios/Flowyr.ipa` |
| `./build-macos.sh` | macOS, current Mac architecture | `dist/macos/Flowyr.app`, `dist/macos/Flowyr.zip` |

Both accept `--clean` and `--help` and can be called from any working directory.
The scripts do not install the app, upload it, or submit it for notarization.
macOS support is experimental; build validation does not establish game compatibility.

Requirements: full Xcode selected with `xcode-select`, its command-line tools,
an Apple signing certificate **with its private key**, CMake 3.22+, Ninja and
Python 3.12+ and XcodeGen. iOS also needs ImageMagick; macOS needs Qt 6.11+
including Multimedia, SVG, LinguistTools and `macdeployqt`. Homebrew can provide
the build dependencies:

```sh
brew install cmake ninja python xcodegen imagemagick qt openssl
```

For a separate Qt installation, set `Qt6_ROOT` to its prefix. Source dependencies
must be present; a submodule-based checkout needs
`git submodule update --init --recursive`. CMake downloads/builds the remaining
dependencies, so the first build and a clean build require internet access.
For this repository's vendored FFmpeg snapshot, the prebuilt revision is
`e744193`; `-DVITA3K_FFMPEG_SHA=...` can override it when configuring CMake for
a different source revision.

Signing is automatic: both platforms use **Apple Development** (with legacy
iPhone/Mac Developer identities supported). iCloud requires a provisioning
profile authorizing the app, certificate and shared container. The Team ID comes
from the certificate's **OU**, not the identifier
in its display name. To select among multiple identities or limit parallelism:

```sh
FLOWYR_TEAM_ID=ABCDEFGHIJ FLOWYR_JOBS=8 ./build-ios.sh
FLOWYR_SIGNING_IDENTITY='Apple Development: Your Name (PERSONALID)' ./build-macos.sh
```

`FLOWYR_SIGNING_IDENTITY` also accepts the certificate's SHA-1 fingerprint.
Both scripts use Xcode automatic provisioning (`-allowProvisioningUpdates`);
configure the matching developer account in Xcode first. The profiles must
authorize `dev.vita3k.Flowyr` and `iCloud.dev.vita3k.Flowyr`. Both platforms
share this registered App ID to access the same saves. The development-signed
packages run on devices/Macs authorized by their profiles; they are not App Store
or Developer ID exports. The macOS script uses a small Xcode signing target to
obtain a native Mac profile, then embeds it and applies its validated entitlements
to the CMake app. All embedded code is signed with the selected certificate.

`--clean` deletes only the selected platform's intermediates: `build/ios-device`
and `build/ios-app` for iOS, or `build/macos-ninja` for macOS. It bypasses compiler
caches for that run without deleting shared caches. It preserves the other
platform's build, source files and existing `dist` output until packaging.
Each successful run replaces only that platform's `Flowyr.app` and archive.

The iOS script regenerates the icon from the root `logo.png`, builds the core,
stages it and regenerates the Xcode project before building the signed app.
The macOS build generates `Flowyr.icns` and the in-app icon from `logo.png`, deploys
Qt frameworks/plugins and the shared Swift save engine, and signs nested code
before the outer app. Its app/executable is `Flowyr`; existing desktop game/config
paths remain unchanged. See [macOS usage and iCloud](macos/README.md).

