#!/usr/bin/env bash
# Run COSMIC build/test environment in podman (preferred) or docker.
# The container boots with systemd as PID 1 — like a real system: dbus,
# journald, logind and the greeter units all come up at boot.
#
# Usage:
#   scripts/dev.sh                 # systemd-booted dev shell
#   scripts/dev.sh app BIN [args]  # run one built binary as a nested window
#   scripts/dev.sh de              # full cosmic-session nested (build+install first)
#   scripts/dev.sh dm              # display-manager boot (greeter + login)
#   scripts/dev.sh tty [CMD...]    # VT session test (toolbox-like HW passthrough, no systemd)
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }

export DE_COMPONENTS="cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-applibrary cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications cosmic-bg"
export DM_COMPONENTS="$DE_COMPONENTS cosmic-greeter"

MODE="${1:-enter}"
shift || true

# Already inside the container (systemd shell / VS Code devcontainer)? Run directly.
if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    case "$MODE" in
    enter)   exec bash ;;
    app)     [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
             exec "$@" ;;
    de)      echo "  just c $DE_COMPONENTS"
             echo "  sudo just ci $DE_COMPONENTS"
             echo "  ./scripts/inside-de.sh"
             exec ./scripts/inside-de.sh ;;
    dm)      echo "  just c $DM_COMPONENTS"
             echo "  sudo just ci $DM_COMPONENTS"
             echo "  ./scripts/inside-dm.sh"
             exec ./scripts/inside-dm.sh ;;
    tty)     echo "tty mode needs a real VT — run from the host, not inside the container" >&2; exit 1 ;;
    *)       echo "unknown mode: $MODE (enter|app|de|dm|tty)" >&2; exit 1 ;;
    esac
fi

# systemd must be PID 1 and manage its own cgroups: run rootful but
# unprivileged (never --privileged). Rootless podman works with the same
# flags as docker because the container's root maps to you (no keep-id —
# keep-id remaps root away from you and systemd can't create /init.scope).
if command -v podman >/dev/null 2>&1; then
    RT_CMD=(podman)
else
    RT_CMD=(docker)
fi
RUNARGS=(--security-opt label=disable)

IMG=localhost/cosmic-build-env
"${RT_CMD[@]}" build -t "$IMG" .devcontainer/

RT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# The host runtime dir is mounted at /run/host-user ONLY. Never bind it at
# /run/user/1000: when the user manager (enable-linger in inside-dm)
# stops, logind rm -rf's that path — through a bind mount that would wipe the
# HOST runtime dir (sockets, bus, everything).
MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$RT_DIR:/run/host-user")
# XDG_RUNTIME_DIR points at the host dir for build shells and nested apps
# (relative WAYLAND_DISPLAY resolves there); the dm session overrides it with
# logind's own /run/user/1000. The host dir is not writable by dev (rootless
# uid mapping), so give just its own writable runtime dir.
ENVS=(-e XDG_RUNTIME_DIR=/run/host-user -e JUST_RUNTIME_DIR=/home/dev/.cache/just)

if [ "$MODE" != tty ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ENVS+=(-e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
elif [ "$MODE" != tty ] && [ -n "${DISPLAY:-}" ]; then
    MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
    ENVS+=(-e "DISPLAY=${DISPLAY}")
elif [ "$MODE" != tty ]; then
    die "set WAYLAND_DISPLAY or DISPLAY so GUIs can open on your host"
fi

[ -d /dev/dri ] && RUNARGS+=(--device /dev/dri) # absent = software rendering

# CARGO_HOME (the registry download cache) lives in the container's
# writable layer, which is discarded on recreation. Use a named volume
# so it persists across runs. :U chowns the volume
# to the container's uid (rootless podman maps root to you).
# Compiled artifacts stay in each component's target/ under the mounted repo.
CARGO_VOL="cosmic-cargo"
"${RT_CMD[@]}" volume create "$CARGO_VOL" >/dev/null 2>&1 || true
U=""; [ "${RT_CMD[0]}" = podman ] && U=":U"
MOUNTS+=(-v "$CARGO_VOL:/home/dev/.cargo$U")
ENVS+=(-e CARGO_HOME=/home/dev/.cargo -e RUSTUP_HOME=/usr/local/share/rustup)

# VT compositor test: toolbox-like passthrough (PR containers/toolbox#997:
# /run/systemd/sessions + /run/udev/tags, plus the follow-ups
# /run/systemd/system + /run/systemd/users) so cosmic-comp gets the host
# seat, DRM/input devices and udev seat tags directly. Plain container, no
# systemd: tmpfs /run + PID isolation would hide exactly that. Run from a
# free VT after host login (Ctrl+Alt+F3), e.g. `scripts/dev.sh tty cosmic-comp`.
if [ "$MODE" = tty ]; then
    [ "${RT_CMD[0]}" = podman ] || die "tty mode needs podman (pid=host + keep-id)"
    # Which VT are we on? logind sets XDG_VTNR in a VT login shell;
    # fall back to parsing `tty` (/dev/ttyN). The compositor takes over
    # THIS vt via your logind session — check `loginctl list-sessions`.
    VTNR="${XDG_VTNR:-}"
    [ -n "$VTNR" ] || VTNR="$(tty 2>/dev/null | sed -n 's#^/dev/tty\([0-9]\+\)$#\1#p')"
    [ -n "$VTNR" ] || die "no VT detected (XDG_VTNR empty, stdin $(tty 2>/dev/null || echo unknown)) — Ctrl+Alt+F3, log in on the HOST, confirm with 'tty'/'loginctl list-sessions', then rerun"
    # ponytail: no --privileged, no full /dev bind — rootless crun aborts
    # recreating odd host nodes (e.g. VirtualBox /dev/vboxusb/*). Explicit
    # devices only (seat ACLs from logind cover perms) + SYS_TTY_CONFIG
    # for the VT ioctls; escalate to --cap-add=all if VT setup fails.
    TTY_DEVS=()
    for dev in /dev/dri/* /dev/input/event* /dev/input/mice /dev/input/mouse* \
               "/dev/tty$VTNR" /dev/tty0; do
        # character/block nodes only — skips subdirs like /dev/dri/by-path,
        # which --device rejects ("could not find device")
        [ -c "$dev" ] || [ -b "$dev" ] || continue
        TTY_DEVS+=(--device "$dev")
    done
    TTY_MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$CARGO_VOL:/home/dev/.cargo:U"
                -v "$RT_DIR:$RT_DIR")
    for src in /run/systemd/sessions /run/systemd/users /run/systemd/seats \
               /run/udev /run/dbus/system_bus_socket; do
        [ -e "$src" ] && TTY_MOUNTS+=(-v "$src:$src:rslave")
    done
    TTY_ENVS=(-e "XDG_RUNTIME_DIR=$RT_DIR" -e JUST_RUNTIME_DIR=/home/dev/.cache/just
              -e HOME=/home/dev -e USER=dev
              -e XDG_SESSION_ID -e XDG_SEAT -e XDG_SESSION_TYPE -e "XDG_VTNR=$VTNR")
    for dbg in RUST_LOG RUST_BACKTRACE; do
        [ -n "${!dbg:-}" ] && TTY_ENVS+=(-e "$dbg=${!dbg}")
    done
    if [ $# -eq 0 ]; then
        echo "tty container (VT tty$VTNR). Then:"
        echo "  sudo just ci cosmic-config $DE_COMPONENTS"
        echo "  ./scripts/inside-tty.sh            # full session: comp, panel, launcher, bg"
        set -- bash
    fi
    # cosmic-comp handles Ctrl+Alt+F1..F12 itself (input/mod.rs -> libseat
    # change_vt); the gotcha is remembering which VT you came from. Print it
    # so the switch-back target is obvious from the session screen.
    log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
    log "VT tty$VTNR (session ${XDG_SESSION_ID:-?}, seat ${XDG_SEAT:-seat0})"
    log "session takes over THIS vt — switch back to your login with Ctrl+Alt+F$VTNR"
    unset -f log
    exec "${RT_CMD[@]}" run --rm -it --name cosmic-tty \
        --pid=host --ipc=host --network=host --cgroupns=host \
        --userns=keep-id --user "$(id -u):$(id -g)" \
        --cap-add SYS_TTY_CONFIG \
        --security-opt label=disable --ulimit host \
        "${TTY_DEVS[@]}" "${TTY_MOUNTS[@]}" "${TTY_ENVS[@]}" \
        -w /cosmic-epoch "$IMG" "$@"
fi

# What systemd needs inside the container — the same for docker and podman:
# tmpfs on /run & friends, a writable cgroup fs, SIGRTMIN+3 stop signal.
# The container itself stays unprivileged; never --privileged.
# https://labs.iximiuz.com/tutorials/systemd-containers-podman-30992811#filesystem
SYSTEMD_ARGS=(--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:rw,nosuid,exec
              -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host
              --stop-signal SIGRTMIN+3)
[ "${RT_CMD[0]}" = podman ] && SYSTEMD_ARGS+=(--systemd=always)

CTR=cosmic-dev
"${RT_CMD[@]}" rm -f "$CTR" >/dev/null 2>&1 || true
"${RT_CMD[@]}" run -d --name "$CTR" "${RUNARGS[@]}" "${SYSTEMD_ARGS[@]}" \
    "${MOUNTS[@]}" "${ENVS[@]}" -w /cosmic-epoch --entrypoint /sbin/init "$IMG" \
    || die "systemd container failed to start"
cleanup() { "${RT_CMD[@]}" rm -f "$CTR" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# wait for systemd to finish booting
state=""
for _ in $(seq 1 120); do
    state="$("${RT_CMD[@]}" exec "$CTR" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in running|degraded) break ;; esac
    sleep 0.5
done
case "$state" in
    running|degraded) ;;
    *) "${RT_CMD[@]}" logs "$CTR" >&2 || true; die "systemd did not boot (state: ${state:-none})" ;;
esac
"${RT_CMD[@]}" exec "$CTR" chown -R dev:dev /home/dev/.cargo >/dev/null 2>&1 || true

# podman rootless maps the container root to you, so build as root; docker is
# rootful, so the dev user (uid 1000) is the host user.
EXEC=(); [ "${RT_CMD[0]}" = docker ] && EXEC=(-u dev)

case "$MODE" in
enter)
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
app)
    [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" "$@"
    ;;
de)
    echo "systemd container up (state: $state). Then:"
    echo "  just c $DE_COMPONENTS"
    echo "  sudo just ci $DE_COMPONENTS"
    echo "  ./scripts/inside-de.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
dm)
    echo "systemd container up (state: $state). Then:"
    echo "  just c $DM_COMPONENTS"
    echo "  sudo just ci $DM_COMPONENTS"
    echo "  ./scripts/inside-dm.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
*)
    echo "unknown mode: $MODE (enter|app|de|dm|tty)" >&2
    exit 1
    ;;
esac
