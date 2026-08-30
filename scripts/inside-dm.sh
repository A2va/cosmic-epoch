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
# and the host display is exported via /etc/environment, which pam_env
# injects into every greetd session so the compositors nest instead of
# grabbing DRM. PAM files are the distro's own; systemd-logind, journald and
# the system dbus are the real deal.
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
    || die "dbus policy missing — run 'sudo just cosmic-greeter/install'"

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

## Point the nested compositors at the host display, via /etc/environment:
## pam_env (readenv=1, part of the stock login stack) injects it into every
## greetd session — greeter and user alike — so neither needs a wrapper.
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
# replace (not append) so reruns don't stack entries
sudo sed -i '/^\(WAYLAND_DISPLAY\|DISPLAY\)=/d' /etc/environment
echo "$HOST_ENV" | sudo tee -a /etc/environment >/dev/null

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
## container) and our greeter-start.
sudo install -d /etc/greetd
sudo tee /etc/greetd/cosmic-greeter.toml >/dev/null <<'EOF'
# generated by inside-dm.sh — do not edit
[terminal]
vt = "none"

[general]
service = "cosmic-greeter"

[default_session]
command = "/usr/local/bin/cosmic-greeter-start"
user = "cosmic-greeter"
EOF

## The deb package's PAM file for the service named above (greetd ≥0.10;
## greetd 0.9 ignores [general].service and uses its own stock stacks).
sudo cp cosmic-greeter/debian/cosmic-greeter.pam /etc/pam.d/cosmic-greeter

## Unit files straight from the submodule — normally shipped by the deb
## package; our justfiles only install binaries/data.
sudo cp cosmic-greeter/debian/cosmic-greeter.service \
     cosmic-greeter/debian/cosmic-greeter-daemon.service /lib/systemd/system/

## dbus only scans system.d at startup: HUP it so the policy file that
## `just cosmic-greeter/install` dropped in is picked up. Also apply the
## shipped tmpfiles (creates /run/cosmic-greeter) — at a real boot
## systemd-tmpfiles-setup.service does this before any unit starts.
sudo systemctl kill -s HUP dbus.service 2>/dev/null || true
sudo systemd-tmpfiles create 2>/dev/null || true

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
