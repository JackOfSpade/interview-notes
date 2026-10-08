#!/usr/bin/env bash
set -euo pipefail

# Creates a local interviewer-question fixture without playing it aloud. This
# is useful for a permissioned, manual ScreenCaptureKit check: play the file
# inside a selected test app, then confirm that Live Assist recognises it while
# the normal meeting output device remains untouched.
#
# It deliberately does *not* try to automate ScreenCaptureKit or Speech. Those
# APIs require the signed app plus the person's macOS privacy decisions, so a
# headless CI run should use transcript simulation instead.

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 /absolute/path/interviewer-question.aiff" >&2
  exit 64
fi

voice="${REHEARSE_TTS_VOICE:-Samantha}"
rate="${REHEARSE_TTS_RATE:-175}"

/usr/bin/say -v "$voice" -r "$rate" -o "$1" \
  "Could you walk me through a time you disagreed with a regional stakeholder about the checkout experience? What did you do, what trade-off did you make, and what was the result?"
