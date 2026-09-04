#!/usr/bin/env bash
# inside-dm.sh — full display-manager boot inside the devcontainer,
# driven by systemd. Start from the host with `scripts/dev.sh dm` (that runs
# the container with /sbin/init as PID 1, then execs this script inside):
#
#   systemd
#     ├─ cosmic-greeter-daemon.service  (system bus: user list)
#     └─ display-manager.service → cosmic-greeter.service
#          └─ greetd (root)
#               ├─ greeter session (cosmic-greeter user): pam_systemd opens a
#               │   real logind session (XDG_RUNTIME_DIR, user bus), then
#               │   cosmic-greeter-start → cosmic-comp → cosmic-greeter UI
#               └─ user session (dev, after PAM auth): start-cosmic →
#                   cosmic-session (stock desktop file, stock script)
#
# This is the stock distro flow with only two container-isms: greetd runs
# with vt="none" (containers have no kernel VTs — no LD_PRELOAD shim needed)
# and the host display is passed to the greeter via `env VAR=…` prefixed on
# its session command (greetd scrubs the env, so it can't be inherited) so the
# compositors nest instead of grabbing DRM.
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

## Preflight
for bin in cosmic-comp cosmic-greeter cosmic-greeter-daemon cosmic-session start-cosmic; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done
command -v greetd >/dev/null 2>&1 || [ -x /usr/sbin/greetd ] || die "greetd missing"
id cosmic-greeter >/dev/null 2>&1 || die "user 'cosmic-greeter' does not exist"
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

## dev must have a real password for pam_unix
# Do NOT gate this on `passwd -S dev`: the base image's old 'ubuntu' user
# (now dev) ships with hash '*' in /etc/shadow, which passwd -S reports as
# "P" (usable) even though crypt() can never match it. pam_unix then returns
# AUTH_ERR for every attempt, correct or not. Setting it every boot is
# idempotent and takes milliseconds, so just do it unconditionally.
DM_PASSWORD="${DM_PASSWORD:-cosmic}"
# -c SHA512: chpasswd defaults to yescrypt ($y$). greetd's session worker
# calls mlockall(), so with the container's 8MB RLIMIT_MEMLOCK yescrypt's
# ~16MB hashing buffer fails to mmap (EAGAIN) and pam_unix returns AUTH_ERR
# for EVERY password, right or wrong. SHA512 crypt needs no big allocation.
printf '%s:%s\n' dev "$DM_PASSWORD" | sudo chpasswd -c SHA512
DEV_HASH="$(sudo getent shadow dev | cut -d: -f2)"
case "$DEV_HASH" in
    '$'*) : ;;
    *) die "chpasswd did not produce a hash for dev (got: ${DEV_HASH:-empty})" ;;
esac
log "login: dev / ${DM_PASSWORD} (override with DM_PASSWORD)"

## Point the nested compositors at the host display. Two injection points,
## because the greeter and the user session are launched differently:
#  - Greeter session: greetd runs `[default_session].command` via sh, so we
#    prefix it with `env VAR=…` below (greetd scrubs the env, so it can't be
#    inherited from the unit). The greeter's cosmic-comp nests on it.
#  - User session: greetd runs whatever command the greeter sends over IPC,
#    and cosmic-greeter only adds XDG_SESSION_TYPE/DESKTOP — NOT the display.
#    But the cosmic-greeter PAM stack still loads pam_env (readenv=1), so we
#    write the display to /etc/environment here and pam_env injects it into
#    the user session. That's how the user's start-cosmic → cosmic-comp nests.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_SOCK="$WAYLAND_DISPLAY" ;;
        *)  HOST_SOCK="/run/host-user/$WAYLAND_DISPLAY" ;;
    esac
    # Under rootless podman the container root maps to you but the session
    # uids don't — open the host display socket to them. Harmless under
    # docker (dev's uid 1000 already owns both).
    sudo chmod 0711 /run/host-user 2>/dev/null || true
    sudo chmod 0666 "$HOST_SOCK" 2>/dev/null || true
    [ -S "$HOST_SOCK" ] || die "host display socket $HOST_SOCK is missing —
log out/in (or reboot) the HOST so its compositor recreates it, then rerun"
    HOST_ENV="WAYLAND_DISPLAY=$HOST_SOCK"
elif [ -n "${DISPLAY:-}" ]; then
    HOST_ENV="DISPLAY=$DISPLAY"
else
    die "no WAYLAND_DISPLAY or DISPLAY — start me via 'scripts/dev.sh dm'"
fi
# /etc/environment feeds the USER session's pam_env (replace, not append, so
# reruns don't stack entries).
sudo sed -i '/^\(WAYLAND_DISPLAY\|DISPLAY\)=/d' /etc/environment
echo "$HOST_ENV" | sudo tee -a /etc/environment >/dev/null

# Same passthrough for debug vars: pam_env injects them into the user session
# (start-cosmic → cosmic-session → components).
# allowlist-by-construction — pam_env/greetd only pass what's written here.
for dbg in RUST_LOG RUST_BACKTRACE; do
    sudo sed -i "/^${dbg}=/d" /etc/environment
    [ -n "${!dbg:-}" ] && echo "${dbg}=${!dbg}" | sudo tee -a /etc/environment >/dev/null
done
# Seed dev's user manager too (systemd reads environment.d at manager startup;
# cosmic-session merges the manager env into the components it spawns, which is
# what start-cosmic's import-environment allowlist would otherwise drop).
# Best-effort live import in case the manager is already running; remove the
# file when unset so a previous debug run doesn't leak into the next one.
if [ -n "${RUST_LOG:-}${RUST_BACKTRACE:-}" ]; then
    sudo mkdir -p /home/dev/.config/environment.d
    {
        [ -n "${RUST_LOG:-}" ] && printf 'RUST_LOG=%s\n' "$RUST_LOG"
        [ -n "${RUST_BACKTRACE:-}" ] && printf 'RUST_BACKTRACE=%s\n' "$RUST_BACKTRACE"
    } | sudo tee /home/dev/.config/environment.d/10-debug.conf >/dev/null
    if [ -S /run/user/1000/bus ]; then
        sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
                ${RUST_LOG:+RUST_LOG="$RUST_LOG"} \
                ${RUST_BACKTRACE:+RUST_BACKTRACE="$RUST_BACKTRACE"} \
                systemctl --user import-environment ${RUST_LOG:+RUST_LOG} ${RUST_BACKTRACE:+RUST_BACKTRACE} 2>/dev/null || true
    fi
else
    sudo rm -f /home/dev/.config/environment.d/10-debug.conf
fi

## Greeter session command — the real cosmic-greeter-start is
## `exec cosmic-comp cosmic-greeter`; ours adds only logging (the UI's own
# stdout/stderr would otherwise be swallowed by the distro script).
sudo tee /usr/local/bin/cosmic-greeter-start >/dev/null <<'EOF'
#!/bin/bash
exec >>/tmp/cosmic-greeter.log 2>&1
set -x
exec cosmic-comp cosmic-greeter
EOF
sudo chmod 0755 /usr/local/bin/cosmic-greeter-start

## greetd config at the path the stock unit expects (/etc/greetd/
## cosmic-greeter.toml, same as the distro package) — same as the repo's
## cosmic-greeter/cosmic-greeter.toml except vt="none" (no kernel VTs in a
## container), our greeter-start, and the host display exported inline (greetd
## scrubs the env, so it can't come from the unit or PAM).
sudo install -d /etc/greetd
sudo tee /etc/greetd/cosmic-greeter.toml >/dev/null <<EOF
# generated by inside-dm.sh — do not edit
[terminal]
vt = "none"

[general]
service = "cosmic-greeter"

[default_session]
command = "env $HOST_ENV /usr/local/bin/cosmic-greeter-start"
user = "cosmic-greeter"
EOF

## The deb package's PAM file for the service named above (greetd ≥0.10;
## greetd 0.9 ignores [general].service and uses its own stock stacks).
sudo cp cosmic-greeter/debian/cosmic-greeter.pam /etc/pam.d/cosmic-greeter

## greetd's session worker runs mlockall(MCL_FUTURE) and, in this rootless
## container, has neither CAP_IPC_LOCK nor a raisable RLIMIT_MEMLOCK (8MB hard
## limit comes from the host session). Every library it dlopens after that is
## charged against the 8MB. Ubuntu 26.04's PAM modules drag in fat deps
## (pam_limits→libsystemd, pam_unix→libselinux/libpcre2, pam_systemd→libm), so
## the stock stacks no longer fit: dlopen fails with ENOENT on the fallback
## path and PAM reports MODULE_UNKNOWN. Trim the stacks to what fits:
#
# Greeter session: greetd hardcodes the service name "greetd-greeter", whose
# stock Ubuntu definition is a bare `@include login` — the entire login stack
# (including common-session's pam_limits/pam_systemd, which no longer fit the
# worker's memlock budget). Replace it with the minimum a greeter needs:
# auth/account passthrough, pam_unix (session open/close audit), pam_systemd
# (XDG_RUNTIME_DIR + user bus). WAYLAND_DISPLAY does NOT come from here — it is
# exported inline on the greetd session `command` above (greetd scrubs the env).
sudo tee /etc/pam.d/greetd-greeter >/dev/null <<'EOF'
#%PAM-1.0
auth     requisite pam_nologin.so
auth     required  pam_permit.so
account  required  pam_permit.so
session  required  pam_unix.so
session  optional  pam_systemd.so
EOF
# User session: drop pam_limits (its libsystemd is 2MB of memlock for nothing
# here — ulimits come from systemd units, not limits.conf) and pam_selinux
# (no-op without SELinux; marked module_unknown=ignore anyway). Also drop
# pam_gnome_keyring — not installed on 26.04, so PAM registers it as a faulty
# module and its auth line returns AUTH_ERR even when the password is right
# (verified: removing it makes dev/cosmic authenticate and open a session).
sudo sed -i -e '/pam_limits\.so/d' -e '/pam_selinux\.so/d' \
            -e '/pam_gnome_keyring\.so/d' /etc/pam.d/cosmic-greeter
# /etc/default/locale is a dangling symlink in the container (target
# /etc/locale.conf doesn't exist), which makes the pam_env line that reads it
# fail. Point that line at /etc/environment instead.
sudo sed -i 's#envfile=/etc/default/locale#envfile=/etc/environment#' /etc/pam.d/cosmic-greeter

## Unit files straight from the submodule — normally shipped by the deb
## package; our justfiles only install binaries/data.
sudo cp cosmic-greeter/debian/cosmic-greeter.service \
     cosmic-greeter/debian/cosmic-greeter-daemon.service /lib/systemd/system/

## dbus only scans system.d at startup: HUP it so the policy file that
## `just ci cosmic-greeter` dropped in is picked up. Also apply the
## shipped tmpfiles (creates /run/cosmic-greeter) — at a real boot
## systemd-tmpfiles-setup.service does this before any unit starts.
sudo systemctl kill -s HUP dbus.service 2>/dev/null || true
sudo systemd-tmpfiles create 2>/dev/null || true

# `just ci` runs as root with HOME=/home/dev, leaving root-owned files under
# dev's home; dev-run daemons then can't create their config dirs and
# crash-loop with PermissionDenied. Reclaim (same as justfile's post-install
# chown) so already-broken homes are repaired on every run.
sudo chown -R dev:dev /home/dev/.config /home/dev/.local 2>/dev/null || true

## Same task-budget fix as inside-de.sh: the session's applet burst can exceed
## user-1000.slice's stock TasksMax (675), failing thread spawn with EAGAIN.
## A drop-in, not set-property: the slice only appears at first login, after
## any set-property would have run. The daemon-reload below picks it up.
sudo install -d /etc/systemd/system/user-1000.slice.d
printf '[Slice]\nTasksMax=4096\n' | sudo tee /etc/systemd/system/user-1000.slice.d/10-tasks.conf >/dev/null
## Same for the user manager default: every cosmic-*.scope inherits
## DefaultTasksMax (stock 307 — panel + ~19 applets share one scope and burst
## past that at startup, EAGAIN). The manager reads this at startup, i.e. at
## first login, which is after this script runs — hence a file, not runtime.
## Best-effort reexec too, for re-runs while a manager is already up.
sudo install -d /etc/systemd/user.conf.d
printf '[Manager]\nDefaultTasksMax=4096\n' | sudo tee /etc/systemd/user.conf.d/10-tasks.conf >/dev/null
if [ -S /run/user/1000/bus ]; then
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user daemon-reexec 2>/dev/null || true
fi
## Sweep orphans from a previous login — but only when no session is live,
## so re-running this with an active desktop doesn't nuke it.
if ! pgrep -u dev -x cosmic-session >/dev/null 2>&1; then
    pkill -KILL -u dev '^cosmic-' 2>/dev/null || true
    for _ in $(seq 1 50); do pkill -0 -u dev '^cosmic-' 2>/dev/null || break; sleep 0.1; done
fi

## Start the DM the distro way (display-manager alias — exactly what
## cosmic-greeter's .postinst does on a real system).
sudo systemctl daemon-reload
sudo ln -sf /lib/systemd/system/cosmic-greeter.service /etc/systemd/system/display-manager.service

log "booting greeter — log in as: dev / ${DM_PASSWORD}"
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
sudo journalctl -f -u cosmic-greeter.service -u cosmic-greeter-daemon.service &
JPID=$!
wait $JPID
