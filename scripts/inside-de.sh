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
    # Under rootless podman the container root maps to you but the session
    # uids don't — dev can't connect to the host socket, and winit dies with
    # NoCompositor. Same chmods as inside-dm (they persist on the host socket
    # file, which is why inside-de appears to "start working after inside-dm
    # ran once"). Harmless under docker (dev already owns the socket).
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
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

## Fresh budget, fresh start. Two task caps bite here, and orphans from a run
## that died without cleanup eat both, so applet threads fail with EAGAIN:
##  - user-1000.slice TasksMax (stock 675): raised via set-property. NB it's a
##    *system* unit — must go over the system bus, --user silently no-ops.
##  - the user manager's DefaultTasksMax (stock 307!): every cosmic-*.scope
##    inherits it, and panel + ~19 applets share cosmic-panel.scope, bursting
##    past 307 at startup. Raised via user.conf drop-in + daemon-reexec.
## Also clear failed scopes (bg/launcher/workspaces linger as failed and make
## scope creation fail with UnitExists on the next run).
log "sweeping stale session processes and raising task caps"
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done
sudo systemctl set-property user-1000.slice TasksMax=4096 2>/dev/null || true
sudo install -d /etc/systemd/user.conf.d
printf '[Manager]\nDefaultTasksMax=4096\n' | sudo tee /etc/systemd/user.conf.d/10-tasks.conf >/dev/null
sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        systemctl --user daemon-reexec 2>/dev/null || true
sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
        systemctl --user reset-failed 2>/dev/null || true

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

# explicit allowlist — SESSION_ENV/sudo/login-shell/import-environment
# all drop anything not listed, so pass debug vars through when set.
[ -n "${RUST_LOG:-}" ] && SESSION_ENV+=(RUST_LOG="$RUST_LOG")
[ -n "${RUST_BACKTRACE:-}" ] && SESSION_ENV+=(RUST_BACKTRACE="$RUST_BACKTRACE")

log "starting cosmic-session as dev (nested on ${HOST_SOCK:-X11})"

# start-cosmic re-execs via a login shell and only imports allowlisted vars
# into the user manager, so seed the manager env directly (sudo strips env,
# hence the explicit assignment).
if [ -n "${RUST_LOG:-}${RUST_BACKTRACE:-}" ]; then
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            ${RUST_LOG:+RUST_LOG="$RUST_LOG"} \
            ${RUST_BACKTRACE:+RUST_BACKTRACE="$RUST_BACKTRACE"} \
            systemctl --user import-environment ${RUST_LOG:+RUST_LOG} ${RUST_BACKTRACE:+RUST_BACKTRACE}
fi

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
    # cosmic-session only traps SIGTERM once startup has finished; if Ctrl-C
    # lands mid-startup it dies instantly and whatever it already spawned
    # (cosmic-comp first) is orphaned — still holding the nested window and a
    # wayland socket, which makes the next run churn (session restarts,
    # applets missing). Wait out its graceful exit, then sweep survivors.
    for _ in $(seq 1 50); do kill -0 "$SPID" 2>/dev/null || break; sleep 0.1; done
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    kill "$JPID" 2>/dev/null || true
    pkill -P "$JPID" 2>/dev/null || true
    exit 0
}
trap quit INT TERM

# Block until the session exits on its own; then silence the journal tail.
# Same orphan sweep as quit(): if comp died before sending its env, cosmic-
# session panics and its restarted comp keeps running parentless.
wait "$SPID" 2>/dev/null || true
pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
kill "$JPID" 2>/dev/null || true
pkill -P "$JPID" 2>/dev/null || true
