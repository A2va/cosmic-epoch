#!/usr/bin/env bash
# inside-de.sh — run a freshly built COSMIC session. One script for both
# transports (no parameters; it detects which container it's in):
#
#  tty container (VT session test): the container runs --pid=host with
#  keep-id and has the host session's /dev/tty$VTNR passed through, so
#  start-cosmic runs as the HOST user on the HOST logind session — the stock
#  login path minus PAM. Uses the stock start-cosmic launcher, but the session
#  bus is PRIVATE (start-cosmic's own dbus-run-session fallback) and systemctl
#  is a no-op shim: the host bus is bind-mounted and shared uid, so routing
#  the session at it lets the session's cosmic-settings-daemon steal
#  com.system76.CosmicSettingsDaemon from the host's daemon (after the
#  session stops the name is unowned and host apps' config watchers sit in
#  growing 2^n backoff — theme changes stop propagating host-wide), its
#  gsettings calls write the HOST dconf, and start-cosmic's
#  `systemctl --user import-environment` diff loop imports the CONTAINER env
#  (HOME=/home/dev, PATH, WAYLAND_DISPLAY=wayland-2) into the HOST user
#  manager. No systemd supervision inside the container: cosmic-session
#  supervises components itself via launch_pad, handing comp its env over a
#  socket fd.
#
#  systemd dev container (nested): runs as dev under user@1000.service and
#  start-cosmic — the real login path minus greetd/PAM. Static config lives
#  in the image.
#
# The tty container runs with --pid=host --userns=keep-id, so every process
# there is a host PID as the host UID. NEVER pkill in that branch — it would
# kill the host's desktop too. cosmic-session tears down its own children on
# SIGTERM.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
. scripts/lib.sh

# Container-only: on the host the binary check would lie ("build + install"),
# or — with COSMIC installed there — the tty branch would start a host session.
in_container || die "run me inside the dev container (mise run enter, then mise run de)"

# TTY detection: only the tty container passes the host session's VT node
# through (--device /dev/tty$VTNR); the systemd container has no kernel VTs.
if [ -n "${XDG_SESSION_ID:-}" ] && [ -c "/dev/tty${XDG_VTNR:-}" ]; then
    for bin in start-cosmic cosmic-session cosmic-comp; do
        command -v "$bin" >/dev/null || die "missing binary: $bin (build + install first: ./scripts/compile.sh && sudo ./scripts/install.sh)"
    done

    # Unset so cosmic-comp takes over the VT instead of nesting into a compositor.
    unset WAYLAND_DISPLAY DISPLAY

    # start-cosmic uses `${XDG_SESSION_TYPE:=wayland}` — won't override the
    # "tty" value PAM sets on a VT login. Force wayland so cosmic-session picks
    # the Wayland code path (the host VT is ours to drive via DRM/KMS).
    export XDG_SESSION_TYPE=wayland

    # Private session bus + no-op systemctl (see the header comment):
    # start-cosmic's `set -e` needs systemctl to succeed, but nothing in the
    # session needs the real one (no systemd inside; cosmic-session supervises
    # via launch_pad). The shim also keeps cosmic-session's env writes off the
    # HOST user manager. DBUS_SESSION_BUS_ADDRESS stays unset so start-cosmic's
    # own fallback runs the session under dbus-run-session — a private bus.
    shim_dir="/tmp/cosmic-epoch-shims"
    mkdir -p "$shim_dir"
    printf '#!/bin/sh\nexit 0\n' > "$shim_dir/systemctl"
    chmod +x "$shim_dir/systemctl"
    export PATH="$shim_dir:$PATH"
    unset DBUS_SESSION_BUS_ADDRESS

    for bin in cosmic-settings-daemon cosmic-panel cosmic-launcher cosmic-bg cosmic-notifications; do
        command -v "$bin" >/dev/null || log "warning: missing $bin — session will be incomplete (./scripts/compile.sh && sudo ./scripts/install.sh)"
    done

    log "starting start-cosmic on ${XDG_SEAT:-seat0} VT ${XDG_VTNR:-?} (panel, launcher, bg, ...)"
    log "clients: on another VT export the printed socket, e.g. WAYLAND_DISPLAY=wayland-1 cosmic-term"
    # $$ is cosmic-session's PID after exec (--pid=host: same PID on host).
    log "to stop: podman exec cosmic-tty kill -TERM $$   (or: kill -TERM $$ from any VT/host shell)"

    # --in-login-shell skips start-cosmic's login-shell re-exec (we're already
    # past the VT login; the re-exec would just fork bash -l -c start-cosmic again).
    exec start-cosmic --in-login-shell "$@"
fi

# --- nested (systemd dev container) ------------------------------------------
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
    # Getting here in the tty container means the session env was stripped —
    # almost always sudo: env_reset drops XDG_SESSION_ID/XDG_VTNR, so the tty
    # branch above can't match. The session must run as dev, never as root.
    die "no WAYLAND_DISPLAY or DISPLAY — run 'mise run de' (without sudo) inside the dev container"
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
