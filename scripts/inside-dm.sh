#!/usr/bin/env bash
# inside-dm.sh — full display-manager boot inside the devcontainer,
# driven by systemd. Nested: 'mise run enter' on the host, then 'mise run dm'
# inside; real-VT greeter: 'mise run enter dm' on a host VT.
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
. scripts/lib.sh

# Container-only: the host has none of what this drives (systemd units, dev user).
in_container || die "run me inside the dev container (mise run enter, then mise run dm)"

for bin in cosmic-comp cosmic-greeter cosmic-greeter-daemon cosmic-session start-cosmic; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done
[ -f /usr/share/dbus-1/system.d/com.system76.CosmicGreeter.conf ] \
    || die "dbus policy missing — run 'sudo mise run install dm' (installs cosmic-greeter)"

state=""
for _ in $(seq 1 100); do
    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "$state" in running|degraded) break ;; esac
    sleep 0.2
done
case "$state" in
    running|degraded) ;;
    *) die "systemd is not managing this container (state: ${state:-none}) — 'mise run enter dm' on a VT, or 'mise run enter' then 'mise run dm' (nested)" ;;
esac

# greetd scrubs its env, so the host display must go via pam_env
# (/etc/environment), which both the greeter and user sessions read.
# tty-dm (XDG_VTNR set): no host compositor — the greeter owns the VT via
# DRM/KMS; rewrite greetd's vt to the host VT instead.
#
# cosmic-comp uses libseat (via smithay) for DRM/KMS access. The container's
# own logind (tmpfs /run) can't grant the passed-through DRM nodes (no udev
# for --device passthrough → no seat tags → TakeDevice fails), so we run
# seatd as a systemd service (opens /dev/dri/* + /dev/input/* as root,
# hands fds to clients via a socket) and point libseat at it: SEATD_SOCK +
# LIBSEAT_BACKEND via /etc/environment (pam_env), so both the greeter
# session and the user session after login pick them up.
if [ -n "${XDG_VTNR:-}" ]; then
    TTY_DM=1
    command -v seatd >/dev/null \
        || die "seatd not installed — rebuild the image: 'scripts/enter.sh dm [VT]' (picks up Dockerfile change)"
    sudo sed -i "s/^vt = .*/vt = \"${XDG_VTNR}\"/" /etc/greetd/cosmic-greeter.toml
    grep -q "^vt = \"${XDG_VTNR}\"" /etc/greetd/cosmic-greeter.toml \
        || die "failed to set vt = $XDG_VTNR in /etc/greetd/cosmic-greeter.toml"
    # seatd: opens /dev/dri/* + /dev/input/* as root, passes fds to
    # cosmic-comp via /run/seatd/seatd.sock. libseat (in cosmic-comp) auto-
    # falls back to it when logind TakeDevice fails. Use the unit shipped by
    # the seatd package (`ExecStart=seatd -g video`, RuntimeDirectory=seatd);
    # remove any stale override first — an earlier revision of this script
    # wrote one with a `-s seat0` flag that seatd 0.9.x rejects (crash loop).
    sudo rm -f /etc/systemd/system/seatd.service
    sudo systemctl daemon-reload
    sudo systemctl enable --now seatd.service 2>/dev/null || sudo systemctl restart seatd.service
    # Wait for the socket (seatd creates it async). Its path varies by build
    # (/run/seatd/seatd.sock, /run/seatd.sock) — discover it instead of
    # assuming, so SEATD_SOCK always points at the real one.
    SEATD_SOCK_PATH=""
    for _ in $(seq 1 50); do
        # || true: find exits 1 on unreadable dirs under /run (e.g. /run/sudo)
        # even after finding the socket — pipefail + set -e would kill the
        # script silently otherwise.
        SEATD_SOCK_PATH="$(find /run -maxdepth 2 -type s -name '*seatd*' 2>/dev/null | head -n1 || true)"
        [ -n "$SEATD_SOCK_PATH" ] && break
        sleep 0.1
    done
    [ -n "$SEATD_SOCK_PATH" ] || die "seatd socket not found (proc: $(pgrep -x seatd || echo none); sockets under /run: $(find /run -maxdepth 2 -type s 2>/dev/null | tr '\n' ' '))"
    # cosmic-greeter and dev both need to connect; seatd's socket is
    # root:video by default, so open it up to all users.
    sudo chmod 0666 "$SEATD_SOCK_PATH"
    sudo sed -i '/^SEATD_SOCK=/d' /etc/environment
    echo "SEATD_SOCK=$SEATD_SOCK_PATH" | sudo tee -a /etc/environment >/dev/null
    # pam_systemd must STAY: it's what sets XDG_RUNTIME_DIR — the greeter
    # comp died with 'RuntimeDirNotSet' the moment it was dropped. But it
    # also enrols the session in the CONTAINER's logind, which can never
    # grant the passed-through DRM nodes (no udev → no seat tags →
    # TakeDevice fails at comp startup, after backend choice). libseat
    # tries backends until one OPENS — logind would "open" fine here and
    # die later — so force the seatd backend explicitly (works for both
    # the greeter session and dev's session after login; both read
    # /etc/environment via pam_env). Undo any stale comment left by the
    # old drop-pam_systemd approach first.
    sudo sed -i 's/^# tty-dm: \(session  optional  pam_systemd\.so\)$/\1/' /etc/pam.d/greetd-greeter
    sudo sed -i '/^LIBSEAT_BACKEND=/d' /etc/environment
    echo 'LIBSEAT_BACKEND=seatd' | sudo tee -a /etc/environment >/dev/null
elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_SOCK="$WAYLAND_DISPLAY" ;;
        *)  HOST_SOCK="/run/host-user/$WAYLAND_DISPLAY" ;;
    esac
    [ -S "$HOST_SOCK" ] || die "host display socket $HOST_SOCK is missing —
log out/in (or reboot) the HOST so its compositor recreates it, then rerun"
    # Rootless podman maps container root to you but not the session uids —
    # open the socket for them. No-op under docker.
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
    HOST_ENV="WAYLAND_DISPLAY=$HOST_SOCK"
elif [ -n "${DISPLAY:-}" ]; then
    HOST_ENV="DISPLAY=$DISPLAY"
else
    die "no WAYLAND_DISPLAY or DISPLAY — run 'mise run dm' inside the dev container"
fi

# Replace (not append) so reruns don't stack entries. Only what's
# written here passes into the sessions. tty-dm keeps its seatd entries
# (written above); every other mode purges them so they don't leak
# into a nested run.
sudo sed -i -e '/^\(WAYLAND_DISPLAY\|DISPLAY\)=/d' -e '/^RUST_\(LOG\|BACKTRACE\)=/d' /etc/environment
[ -n "${TTY_DM:-}" ] || sudo sed -i -e '/^SEATD_SOCK=/d' -e '/^LIBSEAT_BACKEND=/d' /etc/environment
if [ -n "${HOST_ENV:-}" ]; then
    echo "$HOST_ENV" | sudo tee -a /etc/environment >/dev/null
fi
for dbg in RUST_LOG RUST_BACKTRACE; do
    [ -n "${!dbg:-}" ] && echo "$dbg=${!dbg}" | sudo tee -a /etc/environment >/dev/null
done

# Seed dev's user manager too — cosmic-session inherits its env, which
# start-cosmic's import-environment allowlist would otherwise drop.
# Remove when unset so a previous debug run doesn't leak.
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

# dbus scans policy only at startup — HUP it after install; apply tmpfiles as a real boot would.
sudo systemctl kill -s HUP dbus.service 2>/dev/null || true
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/cosmic-greeter.conf 2>/dev/null || true

# Tear down dev's user session (the session leader holds the greeter VT as
# its controlling tty; polite stop first so cosmic-session can clean up its
# children, then sweep whatever ignored it).
stop_session() {
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user stop cosmic-session.target 2>/dev/null || true
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done
}

# Sweep orphans only with no live session — else we'd nuke the active desktop.
# tty-dm is the exception: it tears down EVERY time. A session left from a
# previous run holds the greeter VT as its ctty, and greetd — running without
# CAP_SYS_ADMIN under podman — can't TIOCSCTTY-steal it back: worker dies
# with 'unable to take controlling terminal: EPERM'. A rerun means a fresh
# greeter run, so the old session must go.
if [ -n "${TTY_DM:-}" ]; then
    log "tty-dm: tearing down leftover session from a previous run"
    stop_session
elif ! pgrep -u dev -x cosmic-session >/dev/null 2>&1; then
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
[ -n "${XDG_VTNR:-}" ] && log "tty-dm: greeter on VT $XDG_VTNR — the console will switch away when it starts"
sudo systemctl daemon-reload
sudo systemctl restart display-manager.service

# Stop the unit on Ctrl-C, else Restart=always respawns the greeter forever.
# tty-dm: tear down EVERYTHING (user session included) — a surviving
# session keeps the greeter VT as its ctty and its processes linger after
# tty-dm exits. HUP too: closing the tty-dm shell kills the exec session
# with SIGHUP, not SIGINT.
quit() {
    printf '\n' >&2
    if [ -n "${TTY_DM:-}" ]; then
        log "tty-dm: stopping greeter + user session"
        sudo systemctl stop display-manager.service || true
        stop_session
    else
        log "stopping greeter (user session keeps running)"
        sudo systemctl stop display-manager.service || true
    fi
    exit 0
}
trap quit INT TERM HUP

log "greeter up — greeter log: /tmp/cosmic-greeter.log, journal: journalctl -u cosmic-greeter"
log "Ctrl-C or closing the greeter window tears down"
if sudo systemctl is-failed --quiet cosmic-greeter.service; then
    sudo journalctl -u cosmic-greeter.service --no-pager -n 50 || true
    die "cosmic-greeter.service failed (journal above)"
fi

# No exec so the INT/TERM trap survives; exit when the greeter window
# closes with no user session (a login keeps a dev session alive).
sudo journalctl -f -u cosmic-greeter.service -u cosmic-greeter-daemon.service &
JOURNAL_PID=$!
while kill -0 "$JOURNAL_PID" 2>/dev/null; do
    sleep 2
    if ! pgrep -u cosmic-greeter -x cosmic-comp >/dev/null 2>&1 \
        && ! pgrep -u dev -x cosmic-session >/dev/null 2>&1; then
        log "greeter window closed — tearing down"
        kill "$JOURNAL_PID" 2>/dev/null || true
        quit
    fi
done
wait "$JOURNAL_PID" 2>/dev/null || true
