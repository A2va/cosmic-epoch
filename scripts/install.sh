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
# container, not by env vars someone could fake on the host. in_container
# reads /proc/1/environ: the $container env var is dropped by sudo's
# env_reset, so 'sudo mise run install' inside the container failed the old check.
[ -d "$PWD/.devcontainer" ] && in_container \
    || die "install must run inside the dev container (mise run enter, then mise run install)"

[ "$(id -u)" = 0 ] || die "run me as root: sudo mise run install"

d="${DEBUG:-1}"
[ "$d" = 0 ] || d=1
# 'de'/'dm' select the COMPONENTS_DE/DM sets from mise.toml; expand here so
# the greeter + config-pack checks below see the real component list.
case " $* " in
    " de ") set -- $COMPONENTS_DE ;;
    " dm ") set -- $COMPONENTS_DM ;;
esac
comps="$(_collect "$@")"

# Install logic identical to the old justfile `_install` recipe.
for c in $comps; do
    IFS=: read -r kind profvar <<<"$(_layout "$c")"
    case "$kind" in
    just-cargo)
        # Updated submodules dropped the `debug` variable (just errors on
        # overriding an unknown one) and hardcode the release binary in
        # bin-src. When declared, override bin-src with the debug path
        # instead — just 1.58 passes overrides through unevaluated, so the
        # value must be the plain relative path.
        dbg=""
        tgt_env=()
        f="$c/"[jJ]ustfile
        if grep -qaE '^[[:space:]]*debug[[:space:]]*:?[:+]?=' $f 2>/dev/null; then
            dd="$d"; [ "$c" = pop-launcher ] && dd=0
            dbg="debug=$dd"
        elif [ "$d" = 1 ] && grep -qaE '^[[:space:]]*bin-src[[:space:]]*:=' $f 2>/dev/null; then
            binname=$(sed -n "s/^[[:space:]]*name[[:space:]]*:=[[:space:]]*'\\([^']*\\)'.*/\\1/p" $f | head -1)
            if [ -n "$binname" ]; then
                dbg="bin-src=target/debug/$binname"
                # Extra binaries like the cosmic-files applet hardcode their
                # release path in another *-src var the same way; resolve
                # each via just and override it with the flipped path so the
                # value matches the var expression (not just the name var).
                for var in $(grep -oaE '^[[:space:]]*[a-zA-Z]+-src[[:space:]]*:=' $f 2>/dev/null | awk '{print $1}'); do
                    case "$var" in
                        bin-src|desktop-src|metainfo-src|icons-src) continue ;;
                    esac
                    val=$( (cd "$c" && HOME=/home/dev just --evaluate "$var") 2>/dev/null ) || continue
                    [ "${val/release/}" != "$val" ] || continue
                    dbg="$dbg $var=${val/release/debug}"
                done
            fi
        elif [ "$d" = 1 ]; then
            # Third hardcode style (cosmic-session, cosmic-osd, cosmic-settings,
            # cosmic-initial-setup): the release path sits inline in the install
            # recipe with no `debug`/`bin-src` variable to override. Patching
            # the file would break git pulls; instead use the CARGO_TARGET_DIR
            # they read at the top (cargo-target-dir := env('CARGO_TARGET_DIR',
            # 'target')): stage a '.debug-view' whose release/ holds symlinks to
            # the debug artifacts and point install at it. Install recipes
            # never build, so the view is read-only for them.
            if grep -qaE '\}\}[[:space:]]*/?release|target-dir[[:space:]]*/[[:space:]]*.release.' $f 2>/dev/null; then
                [ -d "$c/target/debug" ] || die "no debug build of $c (mise run compile $c); DEBUG=1 must not silently install release — use DEBUG=0 for that"
                view="$PWD/$c/target/.debug-view"
                rm -rf "$view"
                mkdir -p "$view/release"
                found=""
                for b in "$c"/target/debug/*; do
                    [ -f "$b" ] && [ -x "$b" ] || continue
                    ln -sf "$(readlink -f "$b")" "$view/release/$(basename "$b")"
                    found=1
                done
                [ -n "$found" ] || die "no debug binaries in $c/target/debug (mise run compile $c); DEBUG=1 must not silently install release — use DEBUG=0 for that"
                tgt_env=(CARGO_TARGET_DIR="$view")
                # Recreated on every DEBUG=1 install; stale links are ruled out.
            fi
        fi
        # tgt_env may be empty (set -u) — ${tgt_env[@]+...} skips it then.
        # The assignment goes through env: an expanded word like
        # 'CARGO_TARGET_DIR=x' is a command name, not an assignment prefix.
        # dbg may hold several overrides (bin-src + applet-src) — just needs
        # them as separate args, hence unquoted (no spaces in paths here).
        if [ "$c" = pop-launcher ]; then
            (cd "$c" && HOME=/home/dev env ${tgt_env[@]+"${tgt_env[@]}"} just ${dbg} install)
        else
            (cd "$c" && HOME=/home/dev env ${tgt_env[@]+"${tgt_env[@]}"} just "prefix=${COSMIC_PREFIX:-/usr}" ${dbg} install)
        fi
        ;;
    just-data)
        # Only some data justfiles declare prefix (cosmic-config installs to
        # dev's home and doesn't take one).
        pf="prefix=${COSMIC_PREFIX:-/usr}"
        grep -q 'prefix[[:space:]]*:=' "$c/"[jJ]ustfile 2>/dev/null || pf=
        (cd "$c" && HOME=/home/dev just ${pf:+"$pf"} install)
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
# The dir only appears on the launcher's first run — absent = nothing to fix.
if [ "$d" = 1 ] && [ -d /home/dev/.local/share/pop-launcher ]; then
    chown -R dev:dev /home/dev/.local/share/pop-launcher
fi

# cosmic-greeter ships the DM assets the deb would install (units, tmpfiles,
# PAM stack), trimmed like `ci` did. Staging runs (COSMIC_ROOTDIR) must not
# touch the live system.
# comps is newline-separated (_collect prints one per line) and case
# doesn't word-split — fold to spaces so 'dm' and 'cosmic-greeter/'
# both match. No args = full install, assets included (as before).
# (checked on comps, not $*: autocomplete passes a trailing slash)
want_greeter=1
if [ $# -eq 0 ]; then :; else
    case " ${comps//$'\n'/ } " in
        *" cosmic-greeter "*) ;;
        *) want_greeter=0 ;;
    esac
fi
if [ -z "${COSMIC_ROOTDIR:-}" ] && [ "$want_greeter" = 1 ] && [ -d cosmic-greeter ]; then
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
