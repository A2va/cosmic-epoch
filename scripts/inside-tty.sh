#!/usr/bin/env bash
# inside-tty.sh — run a freshly built COSMIC session directly on the host VT
# (DRM/KMS), from inside `scripts/enter.sh tty`. Uses the stock start-cosmic
# launcher (same env, same `systemctl --user import-environment`, same
# dbus-run-session fallback as a real host login) by routing the user bus at
# the host user manager — the tty container bind-mounts $XDG_RUNTIME_DIR and
# passes --pid=host, so start-cosmic's `systemctl --user` calls land on the
# host's manager exactly like they would on bare metal.
#
# No systemd supervision inside the container: cosmic-session supervises
# components itself via launch_pad, handing comp its env over a socket fd.
#
# The tty container runs with --pid=host --userns=keep-id, so every process
# here is a host PID as the host UID. NEVER pkill here — it would kill the
# host's desktop too. cosmic-session tears down its own children on SIGTERM.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v start-cosmic   >/dev/null || die "missing binary: start-cosmic (build + install first: ./scripts/compile.sh cosmic-session && sudo ./scripts/install.sh cosmic-session)"
command -v cosmic-session >/dev/null || die "missing binary: cosmic-session (build + install first: ./scripts/compile.sh cosmic-session && sudo ./scripts/install.sh cosmic-session)"
command -v cosmic-comp    >/dev/null || die "missing binary: cosmic-comp (build + install first: ./scripts/compile.sh cosmic-comp && sudo ./scripts/install.sh cosmic-comp)"
[ -n "${XDG_SESSION_ID:-}" ] || die "no logind session (XDG_SESSION_ID empty) — launch via 'scripts/enter.sh tty' from a VT login"

# Unset so cosmic-comp takes over the VT instead of nesting into a compositor.
unset WAYLAND_DISPLAY DISPLAY

# start-cosmic uses `${XDG_SESSION_TYPE:=wayland}` — won't override the
# "tty" value PAM sets on a VT login. Force wayland so cosmic-session picks
# the Wayland code path (the host VT is ours to drive via DRM/KMS).
export XDG_SESSION_TYPE=wayland

# Route start-cosmic's `systemctl --user` and cosmic-session's env writes to
# the HOST user manager (bind-mounted at $XDG_RUNTIME_DIR) — same as a real
# host login. Without this, start-cosmic's `set -e` + `systemctl --user
# import-environment` aborts on a missing user manager, so die loudly rather
# than fall back to a private bus that desyncs the host activation env.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    [ -S "$XDG_RUNTIME_DIR/bus" ] \
        || die "host user bus not at $XDG_RUNTIME_DIR/bus — launch via 'scripts/enter.sh tty' from a VT login (host user manager must be up)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

for bin in cosmic-settings-daemon cosmic-panel cosmic-launcher cosmic-bg cosmic-notifications; do
    command -v "$bin" >/dev/null || log "warning: missing $bin — session will be incomplete (./scripts/compile.sh $bin && sudo ./scripts/install.sh $bin)"
done

log "starting start-cosmic on ${XDG_SEAT:-seat0} VT ${XDG_VTNR:-?} (panel, launcher, bg, ...)"
log "clients: on another VT export the printed socket, e.g. WAYLAND_DISPLAY=wayland-1 cosmic-term"
# $$ is cosmic-session's PID after exec (--pid=host: same PID on host).
log "to stop: podman exec cosmic-tty kill -TERM $$   (or: kill -TERM $$ from any VT/host shell)"

# --in-login-shell skips start-cosmic's login-shell re-exec (we're already
# past the VT login; the re-exec would just fork bash -l -c start-cosmic again).
exec start-cosmic --in-login-shell "$@"
