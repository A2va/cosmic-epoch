set dotenv-load
# Recipe args must reach scripts as $1..$n: newer `just` doesn't pass them otherwise.
set positional-arguments
just := just_executable()

# Every component in build/install order. Not listed: cosmic-config (the live
# config/theme pack, installed by `just config`), libcosmic and
# cosmic-sound-theme (no standalone install).
# Name `allcomponents` (not `components`) so the recipe params below don't
# shadow it — `{{ allcomponents }}` would otherwise expand to the per-recipe arg.
allcomponents := 'cosmic-applets cosmic-applibrary cosmic-bg cosmic-comp cosmic-edit cosmic-files cosmic-greeter cosmic-icons cosmic-idle cosmic-initial-setup cosmic-launcher cosmic-monitor cosmic-notifications cosmic-osd cosmic-panel cosmic-player cosmic-randr cosmic-screenshot cosmic-session cosmic-settings cosmic-settings-daemon cosmic-store cosmic-term cosmic-wallpapers cosmic-workspaces-epoch pop-launcher xdg-desktop-portal-cosmic'

# Every cargo component's justfile takes a debug=0|1 knob that picks the
# target/debug or target/release artifacts for `install`; every Makefile takes
# DEBUG=0|1. `c`/`ci`/`cl` pass it through, so both modes work uniformly.

# Build only listed submodules, e.g. just c cosmic-files cosmic-comp
# (empty = everything). DEBUG=1 by default; DEBUG=0 for release.
c *components:
    #!/usr/bin/env sh
    set -e
    d="${DEBUG:-1}"; [ "$d" = 0 ] || d=1
    [ $# -gt 0 ] || set -- {{ allcomponents }}
    for c in "$@"; do
        c="${c%/}" # autocomplete adds a trailing slash
        [ -d "$c" ] || { echo "skipping unknown component: $c" >&2; continue; }
        # pop-launcher's CLI defines '-m' twice; clap's debug_assert
        # (compiled only in debug builds) panics on it, so build it release-only
        dd="$d"; [ "$c" = pop-launcher ] && dd=0
        prof=debug; [ "$dd" = 0 ] && prof=release
        if [ -f "$c/justfile" ] || [ -f "$c/Justfile" ]; then
            # components without Cargo.toml are data-only: nothing to build
            if [ -f "$c/Cargo.toml" ]; then
                (cd "$c" && {{ just }} "build-$prof")
            fi
        elif [ -f "$c/Makefile" ]; then
            make -C "$c" "DEBUG=$dd" all
        fi
    done

# Install only listed submodules, e.g. sudo just ci cosmic-icons cosmic-files
# (empty = everything, plus the config pack). Run as root; installs to
# $COSMIC_PREFIX (default /usr) or $COSMIC_ROOTDIR as DESTDIR.
# DEBUG=1 by default: installs the binaries `just c` built; DEBUG=0 release.
ci *components:
    #!/usr/bin/env sh
    set -e
    d="${DEBUG:-1}"; [ "$d" = 0 ] || d=1
    {{ just }} _install "${COSMIC_ROOTDIR:-}" "${COSMIC_PREFIX:-/usr}" "$d" "$*"
    # Root-owned files in dev's home make daemons crash-loop with
    # PermissionDenied; reclaim them (sudo sets HOME=/root).
    if [ "$(id -u)" = 0 ]; then
        mkdir -p /home/dev/.config /home/dev/.local
        chown -R dev:dev /home/dev/.config /home/dev/.local
    fi
    # cosmic-greeter ships the DM assets the deb would install (units,
    # tmpfiles, PAM stack), trimmed for the container's mlockall() worker and
    # pointed at /etc/environment for the host display. Staging runs
    # (COSMIC_ROOTDIR) must not touch the live system.
    want_greeter=1
    if [ $# -gt 0 ]; then
        want_greeter=0
        case " $* " in *" cosmic-greeter "*) want_greeter=1 ;; esac
    fi
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
    if [ $# -eq 0 ]; then {{ just }} config; fi

# Install `comps` (empty = all) at profile d (1 debug / 0 release) into
# rootdir+prefix. Empty rootdir means the live system: components install to
# their own default (/usr) and pop-launcher to dev's ~/.local (kept working
# under sudo via HOME=/home/dev).
[private]
_install rootdir prefix d comps:
    #!/usr/bin/env sh
    set -e
    # with positional-arguments, params arrive as $1..$n (not exported env)
    rootdir="$1"; prefix="$2"; d="$3"; comps="$4"
    if [ -n "$comps" ]; then set -- $comps; else set -- {{ allcomponents }}; fi
    for c in "$@"; do
        c="${c%/}" # autocomplete adds a trailing slash
        [ -d "$c" ] || { echo "skipping unknown component: $c" >&2; continue; }
        # pop-launcher: release-only build (see `c`); no prefix var, and with
        # a rootdir it stages under rootdir/usr itself.
        dd="$d"; [ "$c" = pop-launcher ] && dd=0
        if [ "$c" = pop-launcher ]; then
            if [ -n "$rootdir" ]; then
                (cd "$c" && {{ just }} "rootdir=$rootdir" install)
            else
                (cd "$c" && HOME=/home/dev {{ just }} "debug=$dd" install)
            fi
        elif [ -f "$c/justfile" ] || [ -f "$c/Justfile" ]; then
            if [ -f "$c/Cargo.toml" ]; then
                # HOME: keep pop-launcher-style installs in dev's home under
                # sudo; rootdir/prefix are the component defaults when empty.
                (cd "$c" && HOME=/home/dev {{ just }} "rootdir=$rootdir" "prefix=$prefix" "debug=$dd" install)
            else
                # data-only (cosmic-icons): no debug knob, no binaries
                (cd "$c" && HOME=/home/dev {{ just }} "rootdir=$rootdir" "prefix=$prefix" install)
            fi
        elif [ -f "$c/Makefile" ]; then
            HOME=/home/dev make -C "$c" "DEBUG=$d" install "DESTDIR=$rootdir" "prefix=$prefix"
        fi
    done

# Clean only listed submodules, e.g. just cl cosmic-comp (empty = everything)
cl *components:
    #!/usr/bin/env sh
    set -e
    [ $# -gt 0 ] || set -- {{ allcomponents }}
    for c in "$@"; do
        c="${c%/}" # autocomplete adds a trailing slash
        [ -d "$c" ] || { echo "skipping unknown component: $c" >&2; continue; }
        if [ -f "$c/justfile" ] || [ -f "$c/Justfile" ]; then
            # components without Cargo.toml are data-only: nothing to clean
            if [ -f "$c/Cargo.toml" ]; then
                (cd "$c" && {{ just }} clean)
            fi
        elif [ -f "$c/Makefile" ]; then
            make -C "$c" clean
        fi
    done

# Reset one or more submodules to the commit pinned by the superproject (the
# "release" state), discarding local edits. No args = reset all submodules.
# e.g. just reset cosmic-settings-daemon cosmic-files
reset *subs:
    #!/usr/bin/env sh
    set -e
    set -- {{ subs }}
    [ $# -gt 0 ] || set -- $(git submodule status | awk '{print $2}')
    for s in "$@"; do
        s="${s%/}" # autocomplete adds trailing slash
        [ -e "$s" ] || { echo "skip (not a submodule): $s" >&2; continue; }
        # Fetch all remotes so the pinned commit is reachable; non-fatal if offline.
        git -C "$s" fetch --all -q 2>/dev/null || true
        echo "reset $s -> superproject pinned commit"
        git submodule update --init --force --checkout "$s"
    done

# Local config/theme pack lives in cosmic-config/ (its own justfile).
# `just config` == `just cosmic-config/install`.
config:
    {{ just }} cosmic-config/install

# Release build of every component (packaging; `just c` is the everyday build)
build:
    DEBUG=0 {{ just }} c

# Stage a full release install under rootdir+prefix (sysroot; sysext uses this)
install rootdir="" prefix="/usr/local": build
    {{ just }} _install "{{ rootdir }}" "{{ prefix }}" 0 ""

# Clean every component's build artifacts and the sysext staging dir
clean:
    {{ just }} cl
    rm -rf cosmic-sysext

sysext dir=(invocation_directory() / "cosmic-sysext") version=("nightly-" + `git rev-parse --short HEAD`): (install dir "/usr")
    #!/usr/bin/env sh
    mkdir -p {{dir}}/usr/lib/extension-release.d/
    cat >{{dir}}/usr/lib/extension-release.d/extension-release.cosmic-sysext <<EOF
    NAME="Cosmic DE"
    VERSION={{version}}
    $(cat /etc/os-release | grep '^ID=')
    $(cat /etc/os-release | grep '^VERSION_ID=')
    EOF
    echo "Done"
