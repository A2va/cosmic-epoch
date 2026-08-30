#!/usr/bin/env bash
# Full COSMIC session as a nested window, running as dev through the real
# user manager (user@1000.service) and start-cosmic — the same path a real
# login takes, minus greetd/PAM. Running cosmic-session as root under
# dbus-run-session has no user manager, so systemctl --user fails
# ("Failed to connect to bus: No data available") and cosmic-session's
# tokio workers can hit EAGAIN spawning under root's throwaway session.
set -euo pipefail

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

## Preflight
for bin in cosmic-comp cosmic-session start-cosmic; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done

## Resolve the host display socket to an absolute path (dev's
## XDG_RUNTIME_DIR will be /run/user/1000, so a relative WAYLAND_DISPLAY
## would resolve there and miss the host socket). Same logic as inside-dm.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_SOCK="$WAYLAND_DISPLAY" ;;
        *)  HOST_SOCK="/run/host-user/$WAYLAND_DISPLAY" ;;
    esac
    [ -S "$HOST_SOCK" ] || die "host display socket $HOST_SOCK is missing —
log out/in (or reboot) the HOST so its compositor recreates it, then rerun"
elif [ -n "${DISPLAY:-}" ]; then
    HOST_SOCK=""
else
    die "no WAYLAND_DISPLAY or DISPLAY — start me via 'scripts/dev.sh de'"
fi

## Bring up dev's user manager if it isn't already, and wait for the user
## bus. Without this, /run/user/1000/bus doesn't exist and start-cosmic's
## systemctl --user calls all fail.
loginctl enable-linger dev 2>/dev/null || sudo loginctl enable-linger dev 2>/dev/null || true
for _ in $(seq 1 100); do
    [ -S /run/user/1000/bus ] && break
    sleep 0.1
done
[ -S /run/user/1000/bus ] || die "dev user bus didn't come up —
run 'scripts/dev.sh dm' once, or 'loginctl enable-linger dev' manually"

## Drop to dev and exec start-cosmic with the env a PAM session would
## normally inject. start-cosmic does the login-shell re-exec, env import
## into the user manager, and cosmic-session launch.
##
## cosmic-session is built with its `systemd` cargo feature, so its
## tracing-journald layer ships logs to the USER journal (not stderr) the
## moment it can reach journald — which is now, because the user manager is
## up. That's correct behavior (same as a real login / inside-dm), so we
## surface logs the same way inside-dm does: tail the user journal to stdout
## while the session runs, and tear it down on Ctrl-C.
SESSION_ENV=(XDG_RUNTIME_DIR=/run/user/1000
             DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
             XDG_CURRENT_DESKTOP=COSMIC
             SHELL=/bin/bash
             USER=dev
             HOME=/home/dev
             PATH="/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
[ -n "$HOST_SOCK" ] && SESSION_ENV+=(WAYLAND_DISPLAY="$HOST_SOCK")

log "starting cosmic-session as dev (nested on ${HOST_SOCK:-X11})"

# Tail the user journal from now on (-n 0) so startup logs aren't lost.
sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        journalctl --user -f -n 0 &
JPID=$!

# Launch the session in the background; we wait on it below so the script
# stays alive to handle Ctrl-C (otherwise `exec` would leave no trap target).
sudo -u dev env "${SESSION_ENV[@]}" /usr/bin/start-cosmic &
SPID=$!

quit() {
    printf '\n' >&2
    log "stopping cosmic-session"
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user stop cosmic-session.target 2>/dev/null || true
    kill "$SPID" 2>/dev/null || true
    pkill -P "$SPID" 2>/dev/null || true
    kill "$JPID" 2>/dev/null || true
    pkill -P "$JPID" 2>/dev/null || true
    exit 0
}
trap quit INT TERM

# Block until the session exits on its own; then silence the journal tail.
wait "$SPID" 2>/dev/null || true
kill "$JPID" 2>/dev/null || true
pkill -P "$JPID" 2>/dev/null || true
