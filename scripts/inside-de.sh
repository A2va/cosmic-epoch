#!/usr/bin/env bash
# Full COSMIC session as a nested window, running as dev through the real
# user manager (user@1000.service) and start-cosmic — the same path a real
# login takes, minus greetd/PAM. Task caps, dev's linger, and /run/cosmic-greeter
# come from the image; orphans from an unclean run are swept here.
set -euo pipefail

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

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
    # Under rootless podman the container root maps to you but the session
    # uids don't — dev can't connect to the host socket, and winit dies with
    # NoCompositor. Same chmods as inside-dm (they persist on the host socket
    # file, which is why inside-de appears to "start working after inside-dm
    # ran once"). Harmless under docker (dev already owns the socket).
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
elif [ -z "${DISPLAY:-}" ]; then
    die "no WAYLAND_DISPLAY or DISPLAY — start me via 'scripts/dev.sh de'"
fi

## Wait for dev's user manager (linger is baked into the image, but it takes
## a moment to come up). Without it /run/user/1000/bus doesn't exist and
## start-cosmic's systemctl --user calls all fail.
for _ in $(seq 1 100); do
    [ -S /run/user/1000/bus ] && break
    sleep 0.1
done
[ -S /run/user/1000/bus ] || die "dev user bus didn't come up —
run 'loginctl enable-linger dev', or boot the image once"

## Sweep orphans from a run that died without cleanup, else failed scopes
## linger and the next run churns (EAGAIN from the task caps, UnitExists).
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done

## Drop to dev and exec start-cosmic with the env a PAM session would
## normally inject. cosmic-session (systemd cargo feature) logs to the USER
## journal, not stderr, so tail it while the session runs.
ENV_BIN=(sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000
         DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
SESSION_ENV=(XDG_CURRENT_DESKTOP=COSMIC
             SHELL=/bin/bash
             USER=dev
             HOME=/home/dev
             PATH="/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
[ -n "${WAYLAND_DISPLAY:-}" ] && SESSION_ENV+=(WAYLAND_DISPLAY="$HOST_SOCK")

# explicit allowlist — sudo/login-shell/import-environment all drop anything
# not listed, so pass debug vars through when set (seeded into the manager
# env so start-cosmic's re-exec keeps them).
for dbg in RUST_LOG RUST_BACKTRACE; do
    if [ -n "${!dbg:-}" ]; then
        SESSION_ENV+=("$dbg=${!dbg}")
        "${ENV_BIN[@]}" "$dbg=${!dbg}" systemctl --user import-environment "$dbg"
    fi
done

log "starting cosmic-session as dev (nested on ${HOST_SOCK:-X11})"

"${ENV_BIN[@]}" journalctl --user -f -n 0 &
JPID=$!

# Launch in the background so the script stays alive to handle Ctrl-C.
"${ENV_BIN[@]}" "${SESSION_ENV[@]}" /usr/bin/start-cosmic &
SPID=$!

quit() {
    printf '\n' >&2
    log "stopping cosmic-session"
    "${ENV_BIN[@]}" systemctl --user stop cosmic-session.target 2>/dev/null || true
    kill "$SPID" 2>/dev/null || true
    # cosmic-session only traps SIGTERM once startup has finished; if Ctrl-C
    # lands mid-startup it dies instantly and whatever it already spawned
    # (cosmic-comp first) is orphaned — still holding the nested window and a
    # wayland socket, which makes the next run churn. Wait it out, then sweep.
    for _ in $(seq 1 50); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    kill "$JPID" 2>/dev/null || true
    exit 0
}
trap quit INT TERM

# Block until the session exits on its own, then sweep orphans (if comp died
# before sending its env, cosmic-session panics and its comp keeps running
# parentless) and silence the journal tail.
wait "$SPID" 2>/dev/null || true
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
kill "$JPID" 2>/dev/null || true
