#!/usr/bin/env bash
# stop-session.sh — stop a running COSMIC dev session.
#   Outside the container: stop the cosmic-dev container (it holds the
#     session/greeter — stopping it tears everything down and releases the VT),
#   Inside: stop the session target directly, like scripts/inside-dm.sh does.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    # Inside: sweep the user session (polite target stop, then stragglers).
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user stop cosmic-session.target 2>/dev/null || true
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    # display-manager.service is a symlink to cosmic-greeter.service (baked in
    # the image); stopping it also tears down greetd on a real-VT (tty-dm) run.
    if [ -e /etc/systemd/system/display-manager.service ]; then
        sudo systemctl stop display-manager.service 2>/dev/null || true
    fi
    echo "cosmic session stopped"
else
    if container_running cosmic-dev; then
        rt="$(runtime)"
        # If only the rootful store has it, stop through sudo podman.
        if [ "$rt" = podman ] \
            && ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev; then
            sudo podman stop cosmic-dev
        else
            "$rt" stop cosmic-dev
        fi
        echo "container cosmic-dev stopped"
    else
        echo "no running cosmic-dev container (and not inside one)" >&2
        exit 1
    fi
fi
