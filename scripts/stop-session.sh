#!/usr/bin/env bash
# stop-session.sh — stop the COSMIC session in the running dev container
# (cosmic-dev or cosmic-tty). Default: kill the session's processes only —
# the container itself keeps running. --rm: stop and remove the containers.
# Inside the container the session target is stopped directly, like
# scripts/inside-dm.sh does (--rm is ignored there — you're inside it).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

rm_container=false
for a in "$@"; do
    case "$a" in
        --rm) rm_container=true ;;
        *) die "unknown argument: $a (usage: stop-session.sh [--rm])" ;;
    esac
done

# Session teardown, identical from inside and outside (outside runs it via
# runtime exec). Polite target stop first, then stragglers; display-manager
# is a symlink to cosmic-greeter.service (baked in the image), so stopping it
# also tears down greetd on a real-VT (tty-dm) run.
stop_session='
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user stop cosmic-session.target 2>/dev/null || true
    pkill -KILL -u dev "^cosmic-" 2>/dev/null || true
    if [ -e /etc/systemd/system/display-manager.service ]; then
        sudo systemctl stop display-manager.service 2>/dev/null || true
    fi
    echo "cosmic session stopped"
'

if in_container; then
    [ "$rm_container" = true ] && echo "--rm ignored inside the container (stop it from the host)" >&2
    eval "$stop_session"
else
    rt="$(runtime)"
    rt_cmd=("$rt")
    # cosmic-dev may be in the rootful store (tty-dm leftovers): sudo podman.
    if ! "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev \
        && [ "$rt" = podman ] \
        && sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev; then
        rt_cmd=(sudo podman)
    fi

    found=false
    if "${rt_cmd[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev; then
        found=true
        "${rt_cmd[@]}" exec cosmic-dev bash -c "$stop_session"
        echo "cosmic-dev kept running (mise run stop --rm removes it)"
    fi
    if "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-tty; then
        found=true
        # No systemd here — kill the session's cosmic-* processes directly.
        # The exec runs as the container's own (keep-id) user, so it can only
        # signal that container's processes, never host/other-user ones.
        "$rt" exec cosmic-tty bash -c 'pkill -KILL -u "$(id -u)" "^cosmic-"' || true
        # de mode: PID 1 is cosmic-session (exec chain) → the container goes
        # Exited; shell mode: idle bash keeps it Up.
        st="$("$rt" inspect -f '{{.State.Status}}' cosmic-tty 2>/dev/null || true)"
        case "$st" in
            running) echo "cosmic-tty kept running (podman attach cosmic-tty)" ;;
            *)       echo "cosmic-tty exited (podman start cosmic-tty restarts it)" ;;
        esac
    fi
    [ "$found" = true ] || die "no running cosmic-dev/cosmic-tty container (and not inside one)"

    if [ "$rm_container" = true ]; then
        "${rt_cmd[@]}" rm -f cosmic-dev 2>/dev/null || true
        "$rt" rm -f cosmic-tty 2>/dev/null || true
        echo "containers removed (if they existed)"
    fi
fi
