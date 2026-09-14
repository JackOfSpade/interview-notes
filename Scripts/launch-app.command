#!/bin/zsh
# Canonical, version-controlled launcher. The Desktop `Interview Notes.command`
# file is only a thin wrapper around this script.

setopt NO_UNSET PIPE_FAIL

PROJECT_DIR="${0:A:h:h}"
CANONICAL_LAUNCHER="${0:A}"
BUILD_SCRIPT="$PROJECT_DIR/Scripts/build_app.sh"
APP="$PROJECT_DIR/.build/app/interview-notes.app"
STATE_DIR="$PROJECT_DIR/.build/launcher"
LOCK="$STATE_DIR/build.lock"
LOG="$STATE_DIR/last-build.log"
APP_BUNDLE_ID="com.rehearse.Rehearse"
APP_PROCESS_NAME="InterviewNotes"
APP_EXECUTABLE="$APP/Contents/MacOS/$APP_PROCESS_NAME"
APP_PROCESS_PATTERN='interview-notes[.]app/Contents/MacOS/InterviewNotes'
FRESH_APP_PROCESS_PATTERN="${APP_EXECUTABLE//./[.]}"
QUIT_TIMEOUT_SECONDS=30

notify() {
  local message="$1"
  message="${message//\\/\\\\}"
  message="${message//\"/\\\"}"
  /usr/bin/osascript -e "display notification \"$message\" with title \"Interview Notes\" sound name \"$2\"" >/dev/null 2>&1
}

pause_if_interactive() {
  if [[ -t 0 ]]; then
    echo
    echo "Press any key to close this window..."
    read -k1 2>/dev/null || true
  fi
}

fail() {
  echo "ERROR: $1"
  if [[ -f "$LOG" ]]; then
    echo "---- last 40 build-log lines ----"
    /usr/bin/tail -n 40 "$LOG"
  fi
  notify "$1" "Basso"
  # The outer launcher pauses only after lockf has released the build lock.
  [[ "${REHEARSE_LAUNCHER_LOCKED:-0}" == "1" ]] || pause_if_interactive
  exit 1
}

running_app_pids() {
  # Match only the main executable path; app helpers, unrelated processes,
  # and this launcher cannot collide with this path fragment.
  /usr/bin/pgrep -f "$APP_PROCESS_PATTERN" 2>/dev/null || true
}

fresh_app_is_running() {
  /usr/bin/pgrep -f "$FRESH_APP_PROCESS_PATTERN" >/dev/null 2>&1
}

quit_previous_instances() {
  local pid_list
  local -a pids
  pid_list="$(running_app_pids)"
  [[ -n "$pid_list" ]] || return 0
  pids=("${(@f)pid_list}")

  echo "> Build verified; asking the previous Interview Notes instance to quit and save..."
  /usr/bin/osascript \
    -e 'with timeout of 5 seconds' \
    -e "tell application id \"$APP_BUNDLE_ID\" to quit" \
    -e 'end timeout' >/dev/null 2>&1 || true

  local deadline=$(( $(/bin/date +%s) + QUIT_TIMEOUT_SECONDS ))
  local pid still_running
  while true; do
    still_running=0
    for pid in "${pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && still_running=1
    done
    (( still_running == 0 )) && return 0

    if (( $(/bin/date +%s) >= deadline )); then
      return 1
    fi
    /bin/sleep 0.5
  done
}

cd "$PROJECT_DIR" 2>/dev/null || fail "Project folder not found: $PROJECT_DIR"
[[ -x "$BUILD_SCRIPT" ]] || fail "Build script is missing or not executable: $BUILD_SCRIPT"

/bin/mkdir -p "$STATE_DIR"

# Re-run the complete build/relaunch transaction under one kernel-managed
# file lock. The lock is automatically released on normal exit, errors,
# signals, or crashes; -k preserves one inode so competing clicks cannot race
# across an unlink/recreate boundary.
if [[ "${REHEARSE_LAUNCHER_LOCKED:-0}" != "1" ]]; then
  REHEARSE_LAUNCHER_LOCKED=1 \
    /usr/bin/lockf -s -k -t 0 "$LOCK" "$CANONICAL_LAUNCHER" "$@"
  launcher_status=$?

  if [[ "$launcher_status" -eq 75 ]]; then
    fail "Another Interview Notes build or relaunch is already running."
  elif [[ "$launcher_status" -eq 73 ]]; then
    fail "Could not create the Interview Notes build lock."
  elif [[ "$launcher_status" -ne 0 ]]; then
    # The locked child already printed the specific error and notification.
    pause_if_interactive
  fi
  exit "$launcher_status"
fi

echo "> Checking and building the latest Interview Notes code..."
"$BUILD_SCRIPT" 2>&1 | /usr/bin/tee "$LOG"
build_status=${pipestatus[1]}
[[ "$build_status" -eq 0 ]] || fail "Build failed (exit $build_status)."

[[ -d "$APP" && -x "$APP_EXECUTABLE" ]] || fail "The built app is incomplete."
/usr/bin/codesign --verify "$APP" >/dev/null 2>&1 || fail "The built app failed signature verification."

# Used by automated checks so the real launcher path can be validated without
# opening a GUI or touching the user's live app process.
if [[ "${REHEARSE_LAUNCHER_BUILD_ONLY:-0}" == "1" ]]; then
  echo "> Build-only check complete."
  exit 0
fi

if ! quit_previous_instances; then
  fail "The previous app did not quit within ${QUIT_TIMEOUT_SECONDS}s. Quit it with Command-Q, then click the launcher again."
fi

# Do not let an instance started during the graceful-quit window make `open`
# reactivate stale code.
if [[ -n "$(running_app_pids)" ]]; then
  fail "Another Interview Notes instance started during the rebuild. Quit it, then click the launcher again."
fi

/usr/bin/open "$APP" || fail "macOS refused to open the freshly built app."

launched=0
for attempt in {1..20}; do
  if fresh_app_is_running; then
    launched=1
    break
  fi
  /bin/sleep 0.5
done

[[ "$launched" -eq 1 ]] || fail "macOS accepted the launch request, but the app did not start within 10 seconds."

notify "Built from the latest code and launched." "Glass"
echo "> Interview Notes is running with the latest code."
