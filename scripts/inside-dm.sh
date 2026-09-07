#!/usr/bin/env bash
# inside-dm.sh — full display-manager boot inside the devcontainer,
# driven by systemd. Start from the host with `scripts/dev.sh dm`:
#
#   systemd
#     ├─ cosmic-greeter-daemon.service  (system bus: user list)
#     └─ display-manager.service → cosmic-greeter.service
#          └─ greetd (root)
#               ├─ greeter session (cosmic-greeter user): pam_systemd opens a
#               │   real logind session, pam_env injects the host display,
#               │   then cosmic-greeter-start → cosmic-comp → cosmic-greeter UI
#               └─ user session (dev, after PAM auth): start-cosmic →
#                   cosmic-session (stock desktop file, stock script)
#
# Static config (greetd.toml, PAM stacks, greeter-start, units, task caps,
# password, trimmings for the container's 8MB RLIMIT_MEMLOCK) is baked into
# the image — this script only handles what changes per run: the host
# display env and debug vars.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

## Preflight
for bin in cosmic-comp cosmic-greeter cosmic-greeter-daemon cosmic-session start-cosmic; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done
[ -f /usr/share/dbus-1/system.d/com.system76.CosmicGreeter.conf ] \
    || die "dbus policy missing — run 'sudo just ci cosmic-greeter'"

## Wait for systemd to finish booting the container
state=""
for _ in $(seq 1 100); do
    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "$state" in running|degraded) break ;; esac
    sleep 0.2
done
case "$state" in
    running|degraded) ;;
    *) die "systemd is not managing this container (state: ${state:-none}) — start via 'scripts/dev.sh dm'" ;;
esac

## Point the nested compositors at the host display. Both the greeter
## session (pam_env in the greetd-greeter stack) and the user session
## (pam_env in the cosmic-greeter stack) read /etc/environment, so one
## write covers both. greetd scrubs its env, so it can't be inherited.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_SOCK="$WAYLAND_DISPLAY" ;;
        *)  HOST_SOCK="/run/host-user/$WAYLAND_DISPLAY" ;;
    esac
    [ -S "$HOST_SOCK" ] || die "host display socket $HOST_SOCK is missing —
log out/in (or reboot) the HOST so its compositor recreates it, then rerun"
    # Under rootless podman the container root maps to you but the session
    # uids don't — open the host display socket to them. Harmless under
    # docker (dev's uid 1000 already owns both).
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
    HOST_ENV="WAYLAND_DISPLAY=$HOST_SOCK"
elif [ -n "${DISPLAY:-}" ]; then
    HOST_ENV="DISPLAY=$DISPLAY"
else
    die "no WAYLAND_DISPLAY or DISPLAY — start me via 'scripts/dev.sh dm'"
fi

# /etc/environment feeds pam_env of BOTH greeter and user sessions (replace,
# not append, so reruns don't stack entries). Debug vars get the same
# passthrough: pam_env injects them into start-cosmic → cosmic-session →
# components. allowlist-by-construction — only what's written here passes.
sudo sed -i -e '/^\(WAYLAND_DISPLAY\|DISPLAY\)=/d' -e '/^RUST_\(LOG\|BACKTRACE\)=/d' /etc/environment
echo "$HOST_ENV" | sudo tee -a /etc/environment >/dev/null
for dbg in RUST_LOG RUST_BACKTRACE; do
    [ -n "${!dbg:-}" ] && echo "$dbg=${!dbg}" | sudo tee -a /etc/environment >/dev/null
done

# Seed dev's user manager too (systemd reads environment.d at manager
# startup; cosmic-session merges the manager env into the components it
# spawns, which start-cosmic's import-environment allowlist would drop).
# Best-effort live import in case the manager is already running; remove the
# file when unset so a previous debug run doesn't leak into the next one.
if [ -n "${RUST_LOG:-}${RUST_BACKTRACE:-}" ]; then
    sudo mkdir -p /home/dev/.config/environment.d
    {
        [ -n "${RUST_LOG:-}" ] && printf 'RUST_LOG=%s\n' "$RUST_LOG"
        [ -n "${RUST_BACKTRACE:-}" ] && printf 'RUST_BACKTRACE=%s\n' "$RUST_BACKTRACE"
    } | sudo tee /home/dev/.config/environment.d/10-debug.conf >/dev/null
    [ -S /run/user/1000/bus ] && sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user import-environment RUST_LOG RUST_BACKTRACE 2>/dev/null || true
else
    sudo rm -f /home/dev/.config/environment.d/10-debug.conf
fi

## The greeter service files, greetd config and PAM stacks are baked into
## the image; `just ci cosmic-greeter` refreshes the dbus policy, which
## dbus only scans at startup — HUP it so the new file is picked up, and
## apply tmpfiles (/run/cosmic-greeter) which a real boot does before units.
sudo systemctl kill -s HUP dbus.service 2>/dev/null || true
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/cosmic-greeter.conf 2>/dev/null || true

## Sweep orphans from a previous login — but only when no session is live,
## so re-running this with an active desktop doesn't nuke it.
if ! pgrep -u dev -x cosmic-session >/dev/null 2>&1; then
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done
fi

# The image sets dev's password to 'cosmic' (SHA512 — yescrypt can't verify
# inside greetd's mlockall()ed worker with the container's 8MB RLIMIT_MEMLOCK).
# Only re-set when overridden.
if [ -n "${DM_PASSWORD:-}" ] && [ "$DM_PASSWORD" != cosmic ]; then
    printf '%s:%s\n' dev "$DM_PASSWORD" | sudo chpasswd -c SHA512
fi

log "booting greeter — log in as: dev / ${DM_PASSWORD:-cosmic}"
sudo systemctl daemon-reload
sudo systemctl restart display-manager.service

## Ctrl-C tears the whole thing down (the unit's Restart=always would keep
## respawning the greeter forever otherwise)
quit() {
    printf '\n' >&2
    log "stopping greeter (user session keeps running)"
    sudo systemctl stop display-manager.service || true
    exit 0
}
trap quit INT TERM

log "greeter up — greeter log: /tmp/cosmic-greeter.log, journal: journalctl -u cosmic-greeter"
log "Ctrl-C to tear down"
if sudo systemctl is-failed --quiet cosmic-greeter.service; then
    sudo journalctl -u cosmic-greeter.service --no-pager -n 50 || true
    die "cosmic-greeter.service failed (journal above)"
fi
exec sudo journalctl -f -u cosmic-greeter.service -u cosmic-greeter-daemon.service
