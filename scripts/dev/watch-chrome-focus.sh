#!/bin/bash
# Logs Chrome's focused AX element once a second while Chrome is frontmost. Usage: watch-chrome-focus.sh <seconds> <out file>
cd "$(dirname "$0")/../.." || exit 1
end=$((SECONDS + ${1:-180}))
while [ $SECONDS -lt $end ]; do
  front=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
  if [ "$front" = "com.google.Chrome" ]; then
    echo "=== $(date +%H:%M:%S)"; logs/ax-chrome-focused
  fi
  sleep 1
done
