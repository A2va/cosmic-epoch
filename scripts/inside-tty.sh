#!/usr/bin/env bash
# inside-tty.sh — run a freshly built COSMIC session directly on the host VT
# (DRM/KMS), from inside `scripts/dev.sh tty`.
#
#   ./scripts/inside-tty.sh [args...]   # full session (panel, launcher, bg, ...)
#
# The session needs no systemd user manager: cosmic-session supervises every
# component itself via launch_pad (systemd is only consulted when
# /run/systemd/system exists, which it doesn't in this plain container), and
# the comp<->session env handoff is a socket fd (COSMIC_SESSION_SOCK).
# start-cosmic itself is bypassed — its `systemctl --user` calls would die
# under `set -e` with no user manager; the env it sets is replicated below.
# (inside-de.sh is the nested equivalent and needs a host WAYLAND_DISPLAY,
# so it can't run here.)
#
# The tty container runs with --pid=host --userns=keep-id, so every process
# here is a host PID running as the host UID. NEVER pkill -u dev '^cosmic-'
# here — it would kill the host's desktop session too. cosmic-session handles
# SIGTERM and tears down its own children (launch_pad); just kill its PID.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v cosmic-session >/dev/null || die "missing binary: cosmic-session (build + install first: just c cosmic-session && sudo just ci cosmic-session)"
command -v cosmic-comp    >/dev/null || die "missing binary: cosmic-comp (build + install first: just c cosmic-comp && sudo just ci cosmic-comp)"
[ -n "${XDG_SESSION_ID:-}" ] || die "no logind session (XDG_SESSION_ID empty) — launch via 'scripts/dev.sh tty' from a VT login"

# Force the KMS/DRM backend: with WAYLAND_DISPLAY or DISPLAY set,
# cosmic-comp nests into that compositor instead of taking over the VT.
unset WAYLAND_DISPLAY DISPLAY

# Private session bus: the runtime dir is shared with the host, so without
# this the compositor talks to the HOST bus and rewrites the host's
# activation env with its own socket (dbus::ready). dbus-daemon ships in the
# image; if it ever fails we keep the inherited bus (old behavior), never a
# hard error (lib.rs only warns on ready() failure anyway).
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-daemon >/dev/null; then
    _addr="$(dbus-daemon --session --fork --print-address 2>/dev/null)" || _addr=""
    [ -n "$_addr" ] && export DBUS_SESSION_BUS_ADDRESS="$_addr"
    unset _addr
fi

# start-cosmic env, minus its login-shell re-exec and systemctl calls.
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:=COSMIC}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:=COSMIC}"
export XDG_SESSION_TYPE=wayland
export _JAVA_AWT_WM_NONREPARENTING=1
export GDK_BACKEND=wayland,x11
export MOZ_ENABLE_WAYLAND=1
export QT_QPA_PLATFORM="wayland;xcb"
export QT_AUTO_SCREEN_SCALE_FACTOR=1
export QT_ENABLE_HIGHDPI_SCALING=1
export DCONF_PROFILE=cosmic

for bin in cosmic-settings-daemon cosmic-panel cosmic-launcher cosmic-bg cosmic-notifications; do
    command -v "$bin" >/dev/null || log "warning: missing $bin — session will be incomplete (just c $bin && sudo just ci $bin)"
done

log "starting cosmic-session on ${XDG_SEAT:-seat0} (panel, launcher, bg, ...)"
log "clients: on another VT export the printed socket, e.g. WAYLAND_DISPLAY=wayland-1 cosmic-term"
# $$ survives exec — this IS cosmic-session's PID (--pid=host: same PID on host).
log "to stop: podman exec cosmic-tty kill -TERM $$   (or: kill -TERM $$ from any VT/host shell)"

# Run in the foreground — cosmic-comp captures all keyboard input on the VT
# (DRM/KMS mode), so Ctrl+C never reaches this script. To stop the session:
#   kill -TERM $$        # from a terminal within the session (cosmic-term)
#   podman exec -t cosmic-tty kill -TERM <pid>  # from the host / another VT
# cosmic-session traps SIGTERM (main.rs) and tears down all children via
# launch_pad — one signal cleans the whole seat, no pkill needed.
exec cosmic-session "$@"
