#!/bin/bash
# Build Claude Meter into a self-contained .app bundle.
#
#   ./build.sh              build only -> build/ClaudeMeter.app
#   ./build.sh --install    build, install to /Applications, and launch
#   ./build.sh --zip        build and produce a shareable zip
#
# No dependencies beyond the Swift toolchain that ships with Xcode or the
# Command Line Tools.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/ClaudeMeter.app"
NAME="ClaudeMeter"
MIN_MACOS="13.0"

DO_INSTALL=0
DO_ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) DO_INSTALL=1 ;;
        --zip)     DO_ZIP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

command -v swiftc >/dev/null || {
    echo "error: swiftc not found. Install Xcode or run: xcode-select --install" >&2
    exit 1
}

echo "==> Cleaning"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=("$ROOT"/Sources/*.swift)

compile() { # $1 = arch triple, $2 = output path
    swiftc -O -swift-version 5 -target "$1" \
        -framework Cocoa -framework ServiceManagement -framework Security \
        -o "$2" "${SOURCES[@]}"
}

echo "==> Compiling (arm64)"
compile "arm64-apple-macos$MIN_MACOS" "$BUILD/$NAME-arm64"

# Ship a universal binary so the same build runs on Intel Macs too. If the
# x86_64 slice can't be produced on this toolchain, fall back to arm64 only.
if compile "x86_64-apple-macos$MIN_MACOS" "$BUILD/$NAME-x86_64" 2>/dev/null; then
    echo "==> Compiling (x86_64)  ok — creating universal binary"
    lipo -create -output "$APP/Contents/MacOS/$NAME" \
        "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
else
    echo "==> Compiling (x86_64)  unavailable — arm64-only build"
    cp "$BUILD/$NAME-arm64" "$APP/Contents/MacOS/$NAME"
fi
rm -f "$BUILD/$NAME-arm64" "$BUILD/$NAME-x86_64"
chmod +x "$APP/Contents/MacOS/$NAME"

echo "==> Generating icon"
swift "$ROOT/Tools/make-icon.swift" "$BUILD/AppIcon.iconset" >/dev/null
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$BUILD/AppIcon.iconset"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature with the hardened runtime: blocks debugger attach and
# library injection, which matters because this process holds an OAuth token
# in memory. Not notarized — there is no Developer ID here — so the intended
# distribution path is "build from source", which never gets quarantined.
echo "==> Signing (ad-hoc, hardened runtime)"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"

if [ "$DO_ZIP" = 1 ]; then
    ( cd "$BUILD" && ditto -c -k --keepParent "$NAME.app" "$NAME.zip" )
    echo "==> Zipped $BUILD/$NAME.zip"
fi

if [ "$DO_INSTALL" = 1 ]; then
    DEST="/Applications"
    if [ ! -w "$DEST" ]; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
    fi
    echo "==> Installing to $DEST"
    pkill -x "$NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST/$NAME.app"
    cp -R "$APP" "$DEST/$NAME.app"
    # Leave exactly one bundle with this identifier on disk, or LaunchServices
    # can resolve the app to the build copy instead of the installed one.
    rm -rf "$APP"
    open "$DEST/$NAME.app"
    echo "==> Launched. Look for the usage readout in your menu bar."
    echo "    macOS will ask once for permission to read the Claude Code"
    echo "    keychain item — choose \"Always Allow\"."
fi
