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
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }

MODE="${1:-enter}"
shift || true

# Already inside the container (systemd shell / VS Code devcontainer)? Run directly.
if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    case "$MODE" in
    enter)   exec bash ;;
    app)     [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
             exec "$@" ;;
    de)      exec ./scripts/inside-de.sh ;;
    dm)      exec ./scripts/inside-dm.sh ;;
    *)       echo "unknown mode: $MODE (enter|app|de|dm)" >&2; exit 1 ;;
    esac
fi

# systemd must be PID 1 and manage its own cgroups: run rootful but
# unprivileged (never --privileged). Rootless podman works with the same
# flags as docker because the container's root maps to you (no keep-id —
# keep-id remaps root away from you and systemd can't create /init.scope).
if command -v podman >/dev/null 2>&1; then
    RT_CMD=(podman); EXEC_USER=dev
else
    RT_CMD=(docker); EXEC_USER=dev
fi
RUNARGS=(--security-opt label=disable)

IMG=localhost/cosmic-build-env
"${RT_CMD[@]}" build -t "$IMG" container/

RT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# The host runtime dir is mounted at /run/host-user ONLY. Never bind it at
# /run/user/1000: when the user manager (enable-linger in inside-dm)
# stops, logind rm -rf's that path — through a bind mount that would wipe the
# HOST runtime dir (sockets, bus, everything).
MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$RT_DIR:/run/host-user")
# XDG_RUNTIME_DIR points at the host dir for build shells and nested apps
# (relative WAYLAND_DISPLAY resolves there); the dm session overrides it with
# logind's own /run/user/1000.
ENVS=(-e XDG_RUNTIME_DIR=/run/host-user)

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ENVS+=(-e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
elif [ -n "${DISPLAY:-}" ]; then
    MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
    ENVS+=(-e "DISPLAY=${DISPLAY}")
else
    die "set WAYLAND_DISPLAY or DISPLAY so GUIs can open on your host"
fi

[ -d /dev/dri ] && RUNARGS+=(--device /dev/dri) # absent = software rendering

# ponytail: podman run --rm discards the container, and CARGO_HOME (the registry
# download cache) lives in the ephemeral layer -> every run re-downloads crates.
# Use a named volume (independent of containers) so it survives --rm. :U chowns
# the volume to the container's uid (rootless podman maps root to you).
# Compiled artifacts stay in each component's target/ under the mounted repo.
CARGO_VOL="cosmic-cargo"
"${RT_CMD[@]}" volume create "$CARGO_VOL" >/dev/null 2>&1 || true
U=""; [ "${RT_CMD[0]}" = podman ] && U=":U"
MOUNTS+=(-v "$CARGO_VOL:/home/dev/.cargo$U")
ENVS+=(-e CARGO_HOME=/home/dev/.cargo -e RUSTUP_HOME=/usr/local/share/rustup)

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
EXEC=(); [ "$EXEC_USER" = dev ] && EXEC=(-u dev)

case "$MODE" in
enter)
    # no exec: let the EXIT trap below remove the container when the session ends
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
app)
    [ $# -ge 1 ] || { echo "usage: $0 app BINARY [args...]" >&2; exit 1; }
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" "$@"
    ;;
de)
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" ./scripts/inside-de.sh
    ;;
dm)
    COMPONENTS="cosmic-comp cosmic-greeter cosmic-session cosmic-panel cosmic-applets cosmic-applibrary cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications cosmic-bg cosmic-osd cosmic-idle"
    echo "systemd container up (state: $state). Then:"
    echo "  just c $COMPONENTS"
    echo "  sudo just ci $COMPONENTS"
    echo "  ./scripts/inside-dm.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
*)
    echo "unknown mode: $MODE (enter|app|de|dm)" >&2
    exit 1
    ;;
esac
