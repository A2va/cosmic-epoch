#!/usr/bin/env bash
# install.sh — install COSMIC components (what was `sudo just ci`). Must run
# inside the dev container as root (sudo): it writes /usr, /etc and dev's home.
# Staging install outside a container hasn't existed; nothing lost by the guard.
# Args = components; none = COMPONENTS_DE from mise.toml. DEBUG=0 installs the
# release artifacts `mise run compile DEBUG=0` built.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

die() { echo "error: $*" >&2; exit 1; }

# Trust boundary: this script writes the live system, so verify it in the
# container, not by env vars someone could fake on the host.
[ -d "$PWD/.devcontainer" ] && [ -f /.dockerenv -o -n "${container:-}" ] \
    || die "install must run inside the dev container (mise run enter, then mise run install)"

[ "$(id -u)" = 0 ] || die "run me as root: sudo mise run install"

d="${DEBUG:-1}"
[ "$d" = 0 ] || d=1
comps="$(_collect "$@")"

# Install logic identical to the old justfile `_install` recipe.
for c in $comps; do
    read -r kind profvar <<<"$(_layout "$c")"
    case "$kind" in
    just-cargo)
        dd="$d"; [ "$c" = pop-launcher ] && dd=0
        if [ "$c" = pop-launcher ]; then
            (cd "$c" && HOME=/home/dev just "debug=$dd" install)
        else
            (cd "$c" && HOME=/home/dev just "prefix=${COSMIC_PREFIX:-/usr}" "debug=$dd" install)
        fi
        ;;
    just-data)
        (cd "$c" && HOME=/home/dev just "prefix=${COSMIC_PREFIX:-/usr}" install)
        ;;
    make)
        (cd "$c" && HOME=/home/dev make "DEBUG=$d" install "DESTDIR=${COSMIC_ROOTDIR:-}" "prefix=${COSMIC_PREFIX:-/usr}")
        ;;
    esac
done

# Root-owned files in dev's home make daemons crash-loop with
# PermissionDenied; reclaim them (sudo sets HOME=/root).
mkdir -p /home/dev/.config /home/dev/.local
chown -R dev:dev /home/dev/.config /home/dev/.local

# pop-launcher: its plugin dir must be user-writable (it writes recovered
# plugin state there); a root-owned copy breaks the launcher silently.
[ "$d" = 1 ] && chown -R dev:dev /home/dev/.local/share/pop-launcher

# cosmic-greeter ships the DM assets the deb would install (units, tmpfiles,
# PAM stack), trimmed like `ci` did. Staging runs (COSMIC_ROOTDIR) must not
# touch the live system.
want_greeter=1
[ $# -eq 0 ] || case " $* " in *" cosmic-greeter "*) ;; *) want_greeter=0 ;; esac
if [ "$(id -u)" = 0 ] && [ -z "${COSMIC_ROOTDIR:-}" ] \
    && [ "$want_greeter" = 1 ] && [ -d cosmic-greeter ]; then
    install -Dm0644 cosmic-greeter/debian/cosmic-greeter.service /lib/systemd/system/cosmic-greeter.service
    install -Dm0644 cosmic-greeter/debian/cosmic-greeter-daemon.service /lib/systemd/system/cosmic-greeter-daemon.service
    install -Dm0644 cosmic-greeter/debian/cosmic-greeter.pam /etc/pam.d/cosmic-greeter
    sed -i -e '/pam_limits\.so/d' -e '/pam_selinux\.so/d' -e '/pam_gnome_keyring\.so/d' /etc/pam.d/cosmic-greeter
    ln -sf /lib/systemd/system/cosmic-greeter.service /etc/systemd/system/display-manager.service
fi

# Icon cache or launchers/panel buttons render blank.
gtk-update-icon-cache -f /usr/share/icons/Cosmic 2>/dev/null || true
gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# A full install also deploys the local config/theme pack.
if [ $# -eq 0 ]; then
    just --justfile cosmic-config/justfile install
fi
