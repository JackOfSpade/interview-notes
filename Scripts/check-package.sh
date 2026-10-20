#!/usr/bin/env bash
# Verify the real local-use app package without launching audio capture or asking for permissions.
set -euo pipefail
cd "$(dirname "$0")/.."
bash Scripts/build_app.sh
APP='.build/app/interview-notes.app'
PLIST="$APP/Contents/Info.plist"
/usr/bin/plutil -lint "$PLIST"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$PLIST")" = 'com.rehearse.Rehearse'
test "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$PLIST")" = InterviewNotes
test -n "$(/usr/bin/plutil -extract NSSpeechRecognitionUsageDescription raw -o - "$PLIST")"
test -x "$APP/Contents/MacOS/InterviewNotes"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p build/ci-artifacts
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" build/ci-artifacts/interview-notes-macOS.zip
