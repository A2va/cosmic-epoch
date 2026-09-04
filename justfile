set dotenv-load
just := just_executable()
make := `which make`

build:
    mkdir -p build
    {{ just }} cosmic-applets/build-release
    {{ just }} cosmic-applibrary/build-release
    {{ just }} cosmic-bg/build-release
    {{ make }} -C cosmic-comp all
    {{ just }} cosmic-edit/build-release
    {{ just }} cosmic-files/build-release
    {{ just }} cosmic-greeter/build-release
    {{ just }} cosmic-idle/build-release
    {{ just }} cosmic-initial-setup/build-release
    {{ just }} cosmic-launcher/build-release
    {{ just }} cosmic-monitor/build-release
    {{ just }} cosmic-notifications/build-release
    {{ just }} cosmic-osd/build-release
    {{ just }} cosmic-panel/build-release
    {{ just }} cosmic-player/build-release
    {{ just }} cosmic-randr/build-release
    {{ just }} cosmic-screenshot/build-release
    {{ just }} cosmic-settings/build-release
    {{ make }} -C cosmic-settings-daemon all
    {{ just }} cosmic-session/build-release
    {{ just }} cosmic-store/build-release
    {{ just }} cosmic-term/build-release
    {{ make }} -C cosmic-wallpapers all
    {{ make }} -C cosmic-workspaces-epoch all
    {{ just }} pop-launcher/build-release
    {{ make }} -C xdg-desktop-portal-cosmic all

# Build only listed submodules, e.g. just c cosmic-files cosmic-comp
# (empty = everything). DEBUG=1 by default; DEBUG=0 for release.
c *components:
    #!/usr/bin/env sh
    set -e
    d="${DEBUG:-1}"
    set -- {{ components }}
    [ $# -gt 0 ] || exec {{ just }} build
    for c in "$@"; do
        if [ ! -d "$c" ]; then echo "skipping unknown component: $c" >&2; continue; fi
        # pop-launcher's CLI defines '-m' twice; clap's debug_assert
        # (compiled only in debug builds) panics on it, so keep it release-only
        dd="$d"; [ "$c" = pop-launcher ] && dd=0
        jf=""
        for f in justfile Justfile; do
            if [ -f "$c/$f" ]; then jf="$c/$f"; break; fi
        done
        if [ -n "$jf" ]; then
            # 'build-release' hardcodes --release upstream; a debug build must
            # call build-debug explicitly (the debug var only affects install paths)
            if [ "$dd" = 1 ] && grep -q '^build-debug' "$jf"; then
                dvar=""; grep -qE '^debug *:=' "$jf" && dvar="debug=1"
                (cd "$c" && {{ just }} $dvar build-debug)
            elif grep -q '^build-release' "$jf"; then
                (cd "$c" && {{ just }} build-release)
            fi # else data-only, e.g. cosmic-icons
        elif [ -f "$c/Makefile" ] && grep -q '^DEBUG' "$c/Makefile"; then
            {{ make }} -C "$c" "DEBUG=$d" all
        else
            {{ make }} -C "$c" all
        fi
    done

# Install only listed submodules, e.g. just ci cosmic-icons cosmic-files
ci *components:
    #!/usr/bin/env sh
    set -e
    d="${DEBUG:-1}"
    set -- {{ components }}
    [ $# -gt 0 ] || exec {{ just }} install
    for c in "$@"; do
        if [ ! -d "$c" ]; then echo "skipping unknown component: $c" >&2; continue; fi
        # pop-launcher's CLI defines '-m' twice; clap's debug_assert
        # (compiled only in debug builds) panics on it, so keep it release-only
        dd="$d"; [ "$c" = pop-launcher ] && dd=0
        jf=""
        for f in justfile Justfile; do
            if [ -f "$c/$f" ]; then jf="$c/$f"; break; fi
        done
        if [ -n "$jf" ]; then
            # some justfiles (cosmic-launcher) hardcode a literal
            # 'debug'/bin path that ignores CARGO_TARGET_DIR; symlink so the
            # install finds the real artifact without editing the submodule
            if grep -qE '^debug *:=' "$jf"; then
                (cd "$c" && ln -sfn target/debug debug && ln -sfn target/release release \
                          && HOME=/home/dev {{ just }} "debug=$dd" install)
            elif [ "$dd" = 1 ]; then
                # knob-less justfiles hardcode 'release' in bin-src; override
                # with the debug artifact when it exists. The binary name is
                # not always the dir name (cosmic-applibrary -> cosmic-app-library),
                # so read it from the justfile and fall back to the dir name —
                # else the stale release binary gets installed silently.
                pkg="$(sed -n "s/^name := *'\([^']*\)'/\1/p" "$jf" | head -n1)"
                pkg="${pkg:-$c}"
                if [ -f "$c/target/debug/$pkg" ]; then
                    o="bin-src=target/debug/$pkg"
                    [ -f "$c/target/debug/$pkg-daemon" ] && o="$o daemon-src=target/debug/$pkg-daemon"
                    (cd "$c" && HOME=/home/dev {{ just }} $o install)
                else
                    (cd "$c" && HOME=/home/dev {{ just }} install)
                fi
            else
                (cd "$c" && HOME=/home/dev {{ just }} install)
            fi
        elif [ -f "$c/Makefile" ] && grep -q '^DEBUG' "$c/Makefile"; then
            # sudo sets HOME=/root, but pop-launcher installs into
            # $HOME/.local; point it at the dev user so the session can find it
            HOME=/home/dev {{ make }} -C "$c" "DEBUG=$d" install DESTDIR="${COSMIC_ROOTDIR:-}" prefix="${COSMIC_PREFIX:-/usr/local}"
        else
            HOME=/home/dev {{ make }} -C "$c" install DESTDIR="${COSMIC_ROOTDIR:-}" prefix="${COSMIC_PREFIX:-/usr/local}"
        fi
    done
    # sudo installs (pop-launcher et al) drop root-owned files into dev's
    # home; reclaim them or dev-run daemons can't create their config/state dirs
    # (~/.config/cosmic, ~/.local/state) and crash-loop with PermissionDenied
    [ "$(id -u)" = 0 ] && chown -R dev:dev /home/dev/.config /home/dev/.local || true
    # icon themes need a cache or launchers/panel buttons render blank
    # rebuild after installs (cosmic-icons adds the Cosmic theme at runtime)
    gtk-update-icon-cache -f /usr/share/icons/Cosmic 2>/dev/null || true
    gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true

# Clean only listed submodules, e.g. just cl cosmic-comp (empty = everything)
cl *components:
    #!/usr/bin/env sh
    set -e
    set -- {{ components }}
    [ $# -gt 0 ] || exec {{ just }} clean
    for c in "$@"; do (
        cd "$c" || continue
        jf=""
        for f in justfile Justfile; do
            if [ -f "$f" ]; then jf="$f"; break; fi
        done
        if [ -n "$jf" ]; then
            # dry-run detects the recipe; grepping for 'clean:' also
            # matches the 'clean := x' variable naming pattern used upstream
            if {{ just }} -n clean >/dev/null 2>&1; then
                {{ just }} clean
            elif [ -f Cargo.toml ]; then
                cargo clean
            fi
        elif [ -f Makefile ]; then
            {{ make }} clean
        fi
    ); done

# Reset one or more submodules to the commit pinned by the superproject (the
# "release" state), discarding local edits. No args = reset all submodules.
# e.g. just reset cosmic-settings-daemon cosmic-files
reset *subs:
    #!/usr/bin/env sh
    set -e
    set -- {{ subs }}
    [ $# -gt 0 ] || set -- $(git submodule status | awk '{print $2}')
    for s in "$@"; do
        [ -e "$s" ] || { echo "skip (not a submodule): $s" >&2; continue; }
        # fetch all remotes (origin may be a fork, upstream = pop-os) so the
        # pinned commit is reachable; non-fatal if offline
        git -C "$s" fetch --all -q 2>/dev/null || true
        echo "reset $s -> superproject pinned commit"
        git submodule update --init --force --checkout "$s"
    done

# Local config/theme pack lives in cosmic-config/ (its own justfile). `just config` == `just cosmic-config/install`.
config:
    {{ just }} cosmic-config/install

install rootdir="" prefix="/usr/local": build
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-applets/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-applibrary/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-bg/install
    {{ make }} -C cosmic-comp install DESTDIR={{rootdir}} prefix={{prefix}}
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-edit/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-files/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-greeter/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-icons/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-idle/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-initial-setup/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-launcher/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-monitor/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-notifications/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-osd/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-panel/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-player/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-randr/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-screenshot/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-settings/install
    {{ make }} -C cosmic-settings-daemon install DESTDIR={{rootdir}} prefix={{prefix}}
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-session/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-store/install
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} cosmic-term/install
    {{ make }} -C cosmic-wallpapers install DESTDIR={{rootdir}} prefix={{prefix}}
    {{ make }} -C cosmic-workspaces-epoch install DESTDIR={{rootdir}} prefix={{prefix}}
    {{ just }} rootdir={{rootdir}} prefix={{prefix}} pop-launcher/install
    {{ make }} -C xdg-desktop-portal-cosmic install DESTDIR={{rootdir}} prefix={{prefix}}
    {{ just }} cosmic-config/install

_mkdir dir:
   mkdir -p dir

sysext dir=(invocation_directory() / "cosmic-sysext") version=("nightly-" + `git rev-parse --short HEAD`): (_mkdir dir) (install dir "/usr")
    #!/usr/bin/env sh
    mkdir -p {{dir}}/usr/lib/extension-release.d/
    cat >{{dir}}/usr/lib/extension-release.d/extension-release.cosmic-sysext <<EOF
    NAME="Cosmic DE"
    VERSION={{version}}
    $(cat /etc/os-release | grep '^ID=')
    $(cat /etc/os-release | grep '^VERSION_ID=')
    EOF
    echo "Done"

clean:
    rm -rf cosmic-sysext
    rm -rf cosmic-applets/target
    rm -rf cosmic-applibrary/target
    rm -rf cosmic-bg/target
    rm -rf cosmic-comp/target
    rm -rf cosmic-edit/target
    {{ just }} cosmic-files/clean
    rm -rf cosmic-greeter/target
    {{ just }} cosmic-idle/clean
    {{ just }} cosmic-initial-setup/clean
    rm -rf cosmic-launcher/target
    {{ just }} cosmic-monitor/clean
    rm -rf cosmic-panel/target
    rm -rf cosmic-player/target
    rm -rf cosmic-notifications/target
    rm -rf cosmic-osd/target
    rm -rf cosmic-randr/target
    rm -rf cosmic-screenshot/target
    rm -rf cosmic-settings/target
    rm -rf cosmic-settings-daemon/target
    rm -rf cosmic-session/target
    {{ just }} cosmic-store/clean
    {{ just }} cosmic-term/clean
    {{ make }} -C cosmic-wallpapers clean
    rm -rf cosmic-workspaces-epoch/target
    {{ just }} pop-launcher/clean
    rm -rf xdg-desktop-portal-cosmic/target
