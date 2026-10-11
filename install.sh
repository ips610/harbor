#!/bin/bash
# Install the app into /Applications (Finder's Applications folder), building it
# first if needed. Falls back to ~/Applications only when /Applications isn't
# writable. Set INSTALL_DIR to install somewhere else.
set -euo pipefail
cd "$(dirname "$0")"
source ./app.conf
SRC="build/$APP_NAME.app"

if [ -n "${INSTALL_DIR:-}" ]; then
  DEST="$INSTALL_DIR"
elif [ -w /Applications ]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
TARGET="$DEST/$APP_NAME.app"

[ -d "$SRC" ] || ./build.sh

# Stop a running copy from the target (or the old ~/Applications spot) so files can be replaced.
OLD="$HOME/Applications/$APP_NAME.app"
for path in "$TARGET" "$OLD"; do
  RUNNING=$(pgrep -f "$path/Contents/MacOS/$EXECUTABLE" || true)
  if [ -n "$RUNNING" ]; then
    echo "==> Quitting the running $APP_NAME ($RUNNING)"
    kill $RUNNING || true
    for _ in 1 2 3 4 5 6; do pgrep -f "$path/Contents/MacOS/$EXECUTABLE" >/dev/null || break; sleep 1; done
    pkill -9 -f "$path/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
  fi
done

mkdir -p "$DEST"
rm -rf "$TARGET"
ditto "$SRC" "$TARGET"
echo "Installed: $TARGET"

# An older copy in ~/Applications would show up twice in Spotlight and Launchpad.
if [ -z "${INSTALL_DIR:-}" ] && [ "$DEST" = "/Applications" ] && [ -d "$OLD" ]; then
  rm -rf "$OLD"
  echo "Removed the older copy in ~/Applications"
fi
echo "Open it with:  open \"$TARGET\""
