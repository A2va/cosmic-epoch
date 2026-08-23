#!/bin/sh
# Full COSMIC session as a nested window.
set -e
if ! command -v cosmic-session >/dev/null 2>&1; then
    echo "cosmic-session not installed. Run first:"
    echo "  just c cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications"
    echo "  sudo just ci cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications"
    exit 1
fi
export XDG_CURRENT_DESKTOP=COSMIC
export PATH="$HOME/.local/bin:$PATH"
exec dbus-run-session -- cosmic-session
