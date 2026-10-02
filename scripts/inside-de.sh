#!/usr/bin/env bash
# Nested COSMIC session as dev via user@1000.service and start-cosmic —
# the real login path minus greetd/PAM. Static config lives in the image.
set -euo pipefail

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

for bin in cosmic-comp cosmic-session start-cosmic; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done

# Absolute host-socket path — a relative WAYLAND_DISPLAY would resolve
# under dev's /run/user/1000 and miss the host socket.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_SOCK="$WAYLAND_DISPLAY" ;;
        *)  HOST_SOCK="/run/host-user/$WAYLAND_DISPLAY" ;;
    esac
    [ -S "$HOST_SOCK" ] || die "host display socket $HOST_SOCK is missing —
log out/in (or reboot) the HOST so its compositor recreates it, then rerun"
    # Rootless podman: session uids differ, so open the socket (winit dies
    # with NoCompositor otherwise). No-op under docker.
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
elif [ -z "${DISPLAY:-}" ]; then
    die "no WAYLAND_DISPLAY or DISPLAY — start me via './scripts/enter.sh de'"
fi

# start-cosmic needs dev's user manager bus; linger is baked in but it takes a moment.
for _ in $(seq 1 100); do
    [ -S /run/user/1000/bus ] && break
    sleep 0.1
done
[ -S /run/user/1000/bus ] || die "dev user bus didn't come up —
run 'loginctl enable-linger dev', or boot the image once"

# Sweep orphans from an unclean run, else failed scopes linger and the next run churns.
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done

# Env a PAM session would normally inject. cosmic-session logs to the user
# journal, not stderr, so tail it while the session runs.
ENV_BIN=(sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000
         DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus)
SESSION_ENV=(XDG_CURRENT_DESKTOP=COSMIC
             SHELL=/bin/bash
             USER=dev
             HOME=/home/dev
             PATH="/home/dev/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
[ -n "${WAYLAND_DISPLAY:-}" ] && SESSION_ENV+=(WAYLAND_DISPLAY="$HOST_SOCK")

# sudo/import-environment drop anything not listed, so pass debug vars
# through and seed the manager env so start-cosmic's re-exec keeps them.
for dbg in RUST_LOG RUST_BACKTRACE; do
    if [ -n "${!dbg:-}" ]; then
        SESSION_ENV+=("$dbg=${!dbg}")
        "${ENV_BIN[@]}" "$dbg=${!dbg}" systemctl --user import-environment "$dbg"
    fi
done

log "starting cosmic-session as dev (nested on ${HOST_SOCK:-X11})"

"${ENV_BIN[@]}" journalctl --user -f -n 0 &
JPID=$!

# Stay alive to handle Ctrl-C.
"${ENV_BIN[@]}" "${SESSION_ENV[@]}" /usr/bin/start-cosmic &
SPID=$!

quit() {
    printf '\n' >&2
    log "stopping cosmic-session"
    "${ENV_BIN[@]}" systemctl --user stop cosmic-session.target 2>/dev/null || true
    kill "$SPID" 2>/dev/null || true
    # cosmic-session only traps SIGTERM once startup has finished; a Ctrl-C
    # mid-startup orphans what it already spawned (cosmic-comp first), which
    # holds the window and wayland socket and makes the next run churn.
    for _ in $(seq 1 50); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    kill "$JPID" 2>/dev/null || true
    exit 0
}
trap quit INT TERM

# Sweep orphans when the session exits on its own (a comp that died before
# sending its env leaves cosmic-session panicked with a parentless comp).
wait "$SPID" 2>/dev/null || true
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
kill "$JPID" 2>/dev/null || true
