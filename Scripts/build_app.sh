#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_BINARY="$DIR/.build/release/Rehearse"
APP_ROOT="$DIR/.build/app"
APP_DIR="$APP_ROOT/interview-notes.app"
STAGING_ROOT=""
BACKUP_ROOT=""
BACKUP_APP=""

cleanup() {
    if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
        rm -rf "$STAGING_ROOT"
    fi

    # Restore the last known-good bundle if replacement was interrupted.
    if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" && ! -d "$APP_DIR" ]]; then
        mv "$BACKUP_APP" "$APP_DIR"
    fi

    if [[ -n "$BACKUP_ROOT" && -d "$BACKUP_ROOT" ]]; then
        rmdir "$BACKUP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cd "$DIR"

echo "Building Interview Notes executable (SwiftPM will reuse unchanged work)..."
/usr/bin/swift build -c release

[[ -x "$BUILD_BINARY" ]] || {
    echo "ERROR: Swift reported success, but the release executable is missing."
    exit 1
}

mkdir -p "$APP_ROOT"
STAGING_ROOT="$(mktemp -d "$APP_ROOT/.staging.XXXXXX")"
STAGED_APP="$STAGING_ROOT/interview-notes.app"
CONTENTS_DIR="$STAGED_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Assembling $APP_DIR..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_BINARY" "$MACOS_DIR/InterviewNotes"
chmod +x "$MACOS_DIR/InterviewNotes"

cat <<EOF > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>InterviewNotes</string>
    <key>CFBundleIdentifier</key>
    <string>com.rehearse.Rehearse</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Interview Notes</string>
    <key>CFBundleDisplayName</key>
    <string>Interview Notes</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
/usr/bin/codesign --force --deep --sign - "$STAGED_APP"
/usr/bin/codesign --verify "$STAGED_APP"

# Keep the existing bundle usable until the replacement has been completely
# assembled and verified.
if [[ -d "$APP_DIR" ]]; then
    BACKUP_ROOT="$(mktemp -d "$APP_ROOT/.backup.XXXXXX")"
    BACKUP_APP="$BACKUP_ROOT/interview-notes.app"
    mv "$APP_DIR" "$BACKUP_APP"
fi

if ! mv "$STAGED_APP" "$APP_DIR"; then
    echo "ERROR: Could not install the newly built app bundle."
    exit 1
fi

if ! /usr/bin/codesign --verify "$APP_DIR"; then
    echo "ERROR: The installed app bundle failed signature verification."
    rm -rf "$APP_DIR"
    exit 1
fi

if [[ -n "$BACKUP_APP" && -d "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_ROOT"
    BACKUP_ROOT=""
    BACKUP_APP=""
fi

echo "Interview Notes is ready at $APP_DIR"
