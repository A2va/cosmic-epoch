#!/usr/bin/env bash
# Run COSMIC build/test environment in podman (preferred) or docker.
#
# Usage:
#   scripts/dev.sh                # interactive shell in the container
#   scripts/dev.sh app BIN [args] # run one built binary as a nested window
#   scripts/dev.sh greeter        # mock greetd + cosmic-greeter (password: "password")
#   scripts/dev.sh de             # full cosmic-session nested (build+install first)
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-enter}"
shift || true

# Already inside the container (e.g. Zed/VS Code devcontainer terminal)? Run directly.
if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    case "$MODE" in
    enter)   exec bash ;;
    app)     [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
             exec "$@" ;;
    greeter) exec ./scripts/inside-greeter.sh ;;
    de)      exec ./scripts/inside-de.sh ;;
    *)       echo "unknown mode: $MODE (enter|app|greeter|de)" >&2; exit 1 ;;
    esac
fi

if command -v podman >/dev/null 2>&1; then
    RT=podman
    # keep-id: files written to /cosmic-epoch stay owned by you;
    # label=disable: SELinux otherwise blocks writes to mounted dirs
    RUNARGS=(--userns=keep-id --security-opt label=disable)
else
    RT=docker
    RUNARGS=(--security-opt label=disable)
fi

IMG=localhost/cosmic-build-env
$RT build -t "$IMG" container/

RT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$RT_DIR:/run/user/1000")
ENVS=(-e XDG_RUNTIME_DIR=/run/user/1000)

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ENVS+=(-e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
elif [ -n "${DISPLAY:-}" ]; then
    MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
    ENVS+=(-e "DISPLAY=${DISPLAY}")
else
    echo "error: set WAYLAND_DISPLAY or DISPLAY so GUIs can open on your host" >&2
    exit 1
fi

[ -d /dev/dri ] && RUNARGS+=(--device /dev/dri) # absent = software rendering

# ponytail: podman run --rm discards the container, and CARGO_HOME (the registry
# download cache) lives in the ephemeral layer -> every run re-downloads crates.
# Use a named volume (independent of containers) so it survives --rm. :U chowns
# the volume to the container's uid (keep-id + rootless). Compiled artifacts stay
# in each component's target/ under the mounted repo, so they persist already.
CARGO_VOL="cosmic-cargo"
$RT volume create "$CARGO_VOL" >/dev/null 2>&1 || true
U=""; [ "$RT" = podman ] && U=":U"
MOUNTS+=(-v "$CARGO_VOL:/home/dev/.cargo$U")
ENVS+=(-e CARGO_HOME=/home/dev/.cargo -e RUSTUP_HOME=/usr/local/share/rustup)

BASE=(--rm -it "${RUNARGS[@]}" "${MOUNTS[@]}" "${ENVS[@]}" -w /cosmic-epoch "$IMG")

case "$MODE" in
enter)
    exec "$RT" run "${BASE[@]}"
    ;;
app)
    [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
    exec "$RT" run "${BASE[@]}" "$@"
    ;;
greeter)
    exec "$RT" run "${BASE[@]}" ./scripts/inside-greeter.sh
    ;;
de)
    exec "$RT" run "${BASE[@]}" ./scripts/inside-de.sh
    ;;
*)
    echo "unknown mode: $MODE (enter|app|greeter|de)" >&2
    exit 1
    ;;
esac
