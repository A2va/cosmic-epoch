#!/usr/bin/env bash
# inside-end-to-end.sh — full display-manager boot inside the devcontainer:
#   greetd (root, VT shim)
#     ├─ greeter session (dev): cosmic-comp (nested) → cosmic-greeter
#     │   (as the cosmic-greeter user, via sudo) → PAM auth →
#     └─ user session (dev): cosmic-session → cosmic-comp (nested)
# Run interactively from the host: scripts/dev.sh dm
set -euo pipefail

log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

## Preflight
for bin in cosmic-comp cosmic-greeter cosmic-session cosmic-greeter-daemon \
           dbus-run-session dbus-send gcc; do
    command -v "$bin" >/dev/null || die "missing binary: $bin (build + install COSMIC first)"
done
GREETD_BIN="$(command -v greetd || true)"; [ -n "$GREETD_BIN" ] || GREETD_BIN=/usr/sbin/greetd
[ -x "$GREETD_BIN" ] || die "greetd missing: sudo apt-get install -y greetd"

COMP_BIN="$(command -v cosmic-comp)"
GREETER_BIN="$(command -v cosmic-greeter)"
SESSION_BIN="$(command -v cosmic-session)"
DAEMON_BIN="$(command -v cosmic-greeter-daemon)"
id cosmic-greeter >/dev/null 2>&1 || die "user 'cosmic-greeter' does not exist"

HOST_XDG=/run/user/1000            # host runtime dir, bind-mounted by dev.sh
CG_XDG="/run/user/$(id -u cosmic-greeter)"
GREETER_XDG=/tmp/cosmic-greeter-session   # comp socket dir for the greeter

## Kill leftovers from previous runs in this same container
sudo pkill -f cosmic-comp            2>/dev/null || true
sudo pkill -x cosmic-greeter         2>/dev/null || true
sudo pkill -x cosmic-greeter-daemon  2>/dev/null || true
sudo pkill -x greetd                 2>/dev/null || true
sleep 0.3

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

## System bus + D-Bus policy
sudo install -d -m 0755 /run/dbus
sudo tee /etc/dbus-1/system.d/com.system76.CosmicGreeter.conf >/dev/null <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop.org//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
    <policy group="cosmic-greeter">
        <allow send_destination="com.system76.CosmicGreeter"/>
        <allow receive_sender="com.system76.CosmicGreeter"/>
    </policy>
    <policy user="root">
        <allow own="com.system76.CosmicGreeter"/>
        <allow send_destination="com.system76.CosmicGreeter"/>
        <allow receive_sender="com.system76.CosmicGreeter"/>
    </policy>
</busconfig>
EOF
if [ ! -S /run/dbus/system_bus_socket ]; then
    sudo dbus-daemon --system --fork
    for _ in $(seq 1 50); do [ -S /run/dbus/system_bus_socket ] && break; sleep 0.1; done
else
    PID="$(sudo cat /run/dbus/pid 2>/dev/null || true)"
    [ -n "$PID" ] && sudo kill -HUP "$PID" 2>/dev/null || true   # reload policy
fi

## Fake logind on the system bus
# Without org.freedesktop.login1, cosmic-greeter's locker auto-locks immediately
# at session start (cosmic-greeter/src/locker.rs), popping a second greeter UI.
# A stub that just answers Ping makes is_available() true so the locker waits
# for a lock signal instead. Needs python3-dbus + python3-gi.
if python3 -c 'import dbus, gi' 2>/dev/null; then
    sudo tee /usr/local/bin/fake-logind.py >/dev/null <<'EOF'
#!/usr/bin/env python3
import dbus, dbus.service, dbus.mainloop.glib
from gi.repository import GLib

class Login1(dbus.service.Object):
    def __init__(self, b):
        b.request_name("org.freedesktop.login1")
        super().__init__(b, "/org/freedesktop/login1")
    @dbus.service.method("org.freedesktop.DBus.Peer", in_signature="", out_signature="")
    def Ping(self):
        pass

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
Login1(dbus.SystemBus())
GLib.MainLoop().run()
EOF
    if ! pgrep -f fake-logind.py >/dev/null; then
        sudo setsid /usr/bin/env XDG_RUNTIME_DIR=/run/user/0 python3 /usr/local/bin/fake-logind.py \
            </dev/null >/tmp/fake-logind.log 2>&1 &
    fi
    for _ in $(seq 1 50); do
        sudo dbus-send --system --print-reply --dest=org.freedesktop.DBus \
            /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
            string:org.freedesktop.login1 2>/dev/null | grep -q 'boolean true' && break
        sleep 0.1
    done
fi

## cosmic-greeter-daemon (root sidecar providing the user list)
if ! pgrep -x cosmic-greeter-daemon >/dev/null; then
    sudo install -d -m 0700 -o root -g root /run/user/0
    sudo setsid /usr/bin/env XDG_RUNTIME_DIR=/run/user/0 "$DAEMON_BIN" \
        </dev/null >/tmp/cosmic-greeter-daemon.log 2>&1 &
fi
daemon_up=0
for _ in $(seq 1 50); do
    if sudo dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner \
        string:com.system76.CosmicGreeter 2>/dev/null | grep -q 'boolean true'; then
        daemon_up=1; break
    fi
    sleep 0.2
done
[ "$daemon_up" = 1 ] || log "WARNING: cosmic-greeter-daemon not up yet — user list may be empty"

## PAM — real authentication (never add pam_permit: a zero-prompt stack makes
## cosmic-greeter auto-login with no UI)
for svc in greetd cosmic-greeter; do
    sudo tee "/etc/pam.d/$svc" >/dev/null <<'EOF'
#%PAM-1.0
auth       required    pam_unix.so
account    required    pam_unix.so
session    optional    pam_env.so
session    optional    pam_unix.so
EOF
done

## Fake VT kernel shim (containers have no VTs)
cat >/tmp/fake_vt.c <<'EOF'
#define _GNU_SOURCE
#include <sys/ioctl.h>
#include <linux/vt.h>
#include <linux/kd.h>
#include <stdarg.h>
#include <stddef.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/types.h>

typedef int (*ioctl_t)(int, unsigned long, ...);

int ioctl(int fd, unsigned long request, ...) {
    va_list ap; va_start(ap, request);
    void *argp = va_arg(ap, void *);
    va_end(ap);

    switch ((unsigned int)request) {
    case TIOCSCTTY:  return 0;
    case VT_GETSTATE:
        if (argp) { struct vt_stat *s = argp; s->v_active = 7; s->v_signal = 0; s->v_state = 1 << 7; }
        return 0;
    case VT_OPENQRY: if (argp) *(int *)argp = 7; return 0;
    case VT_GETMODE: if (argp) memset(argp, 0, sizeof(struct vt_mode)); return 0;
    case KDGETMODE:  if (argp) *(int *)argp = KD_TEXT; return 0;
    case KDGKBMODE:  if (argp) *(int *)argp = K_UNICODE; return 0;
    case VT_ACTIVATE: case VT_WAITACTIVE: case VT_RELDISP:
    case VT_SETMODE: case VT_DISALLOCATE:
    case KDSKBMODE: case KDSETMODE:
        return 0;
    default: {
        ioctl_t orig = (ioctl_t)dlsym(RTLD_NEXT, "ioctl");
        return orig(fd, request, argp);
    }
    }
}

int chown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; return 0; }
int fchown(int fd, uid_t u, gid_t g) { (void)fd; (void)u; (void)g; return 0; }
int vhangup(void) { return 0; }
EOF
gcc -O2 -shared -fPIC -o /tmp/libfake_vt.so /tmp/fake_vt.c -ldl

## Directories + greeter launcher
sudo install -d -m 0711 -o dev -g dev "$GREETER_XDG"   # a+x so the greeter uid can reach the socket
sudo install -d -m 0700 -o cosmic-greeter -g cosmic-greeter "$CG_XDG"
sudo install -m 0666 /dev/null /tmp/cosmic-greeter.log

# Runs inside the greeter compositor as uid dev; drops to the cosmic-greeter
# user for the actual UI (greetd sets GREETD_SOCK in our environment).
sudo tee /usr/local/bin/cosmic-greeter-launch >/dev/null <<EOF
#!/bin/bash
exec >>/tmp/cosmic-greeter.log 2>&1
set -x
die() { echo "cosmic-greeter-launch: \$*" >&2; exit 1; }
[ -n "\${GREETD_SOCK:-}" ]     || die "GREETD_SOCK is not set"
[ -n "\${WAYLAND_DISPLAY:-}" ] || die "WAYLAND_DISPLAY is not set"

CG_XDG="/run/user/\$(id -u cosmic-greeter)"
SOCK="\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY"

# The greeter runs as its own uid: open exactly the two sockets it needs.
/usr/bin/sudo chmod 0666 "\$GREETD_SOCK" "\$SOCK"

exec /usr/bin/sudo -u cosmic-greeter /usr/bin/env \\
    -u LD_PRELOAD \\
    -u DBUS_SESSION_BUS_ADDRESS \\
    USER=cosmic-greeter \\
    LOGNAME=cosmic-greeter \\
    HOME=/var/lib/cosmic-greeter \\
    LANG=C.UTF-8 \\
    XDG_RUNTIME_DIR="\$CG_XDG" \\
    XDG_SESSION_TYPE=wayland \\
    WAYLAND_DISPLAY="\$SOCK" \\
    GREETD_SOCK="\$GREETD_SOCK" \\
    "$GREETER_BIN"
EOF
sudo chmod 0755 /usr/local/bin/cosmic-greeter-launch

## greetd config + user-session desktop entry

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
        /*) HOST_UI="WAYLAND_DISPLAY=$WAYLAND_DISPLAY" ;;
        *)  HOST_UI="WAYLAND_DISPLAY=$HOST_XDG/$WAYLAND_DISPLAY" ;;
    esac
elif [ -n "${DISPLAY:-}" ]; then
    HOST_UI="DISPLAY=$DISPLAY"
else
    die "no WAYLAND_DISPLAY or DISPLAY — start me via 'scripts/dev.sh dm'"
fi

DEFAULT_CMD="/usr/bin/env -u LD_PRELOAD /usr/bin/dbus-run-session -- /usr/bin/env XDG_RUNTIME_DIR=$GREETER_XDG XDG_SESSION_TYPE=wayland $HOST_UI $COMP_BIN /usr/local/bin/cosmic-greeter-launch"

sudo install -d /etc/greetd
sudo tee /etc/greetd/config.toml >/dev/null <<EOF
# generated by inside-end-to-end.sh — do not edit
[terminal]
vt = 7
switch = false

[default_session]
user = "dev"
command = "$DEFAULT_CMD"
EOF

# Overwrite (not add) cosmic.desktop: cosmic-session's own desktop file has a
# bare 'Exec=cosmic-session' that would run un-nested and fail.
sudo tee /usr/share/wayland-sessions/cosmic.desktop >/dev/null <<EOF
[Desktop Entry]
Name=COSMIC
Comment=This session logs you into COSMIC (nested in the devcontainer)
Exec=/usr/bin/env -u LD_PRELOAD -u GREETD_SOCK /usr/bin/dbus-run-session -- /usr/bin/env XDG_RUNTIME_DIR=$HOST_XDG XDG_SESSION_TYPE=wayland $HOST_UI $SESSION_BIN
Type=Application
DesktopNames=COSMIC
EOF

## Point vt 7 at our pty and boot
CTTY="$(tty 2>/dev/null || true)"
[ -n "$CTTY" ] || die "no controlling terminal — run via 'scripts/dev.sh dm'"
sudo ln -sfn "$CTTY" /dev/tty7
sudo rm -f /run/greetd*.sock 2>/dev/null || true

log "booting greetd — log in as: dev / ${DM_PASSWORD}"
log "greeter log: /tmp/cosmic-greeter.log ; daemon log: /tmp/cosmic-greeter-daemon.log"
exec /usr/bin/sudo /usr/bin/env LD_PRELOAD=/tmp/libfake_vt.so RUST_LOG=greetd=trace \
    "$GREETD_BIN" --config /etc/greetd/config.toml
