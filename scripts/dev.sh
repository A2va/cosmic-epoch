#!/usr/bin/env bash
# Run COSMIC build/test environment in podman (preferred) or docker.
# The container boots with systemd as PID 1, like a real system.
#
# Usage:
#   scripts/dev.sh                 # systemd-booted dev shell
#   scripts/dev.sh app BIN [args]  # run one built binary as a nested window
#   scripts/dev.sh de              # full cosmic-session nested (build+install first)
#   scripts/dev.sh dm              # display-manager boot (greeter + login)
#   scripts/dev.sh tty-dm [VT]     # display-manager boot on a real host VT
#                                  # (greetd + cosmic-greeter on /dev/tty$VT via
#                                  #  DRM/KMS; VT defaults to login VT + 1)
#   scripts/dev.sh tty [CMD...]    # VT session test (toolbox-like HW passthrough, no systemd)
set -euo pipefail
cd "$(dirname "$0")/.."
die() { echo "error: $*" >&2; exit 1; }

export DE_COMPONENTS="cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-applibrary cosmic-launcher pop-launcher cosmic-icons cosmic-workspaces-epoch cosmic-settings-daemon cosmic-notifications cosmic-bg"
export DM_COMPONENTS="$DE_COMPONENTS cosmic-greeter"

MODE="${1:-enter}"
shift || true

# Already inside the container? Run directly.
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
    tty-dm)  echo "tty-dm needs a real VT — run from the host, not inside the container" >&2; exit 1 ;;
    tty)     echo "tty mode needs a real VT — run from the host, not inside the container" >&2; exit 1 ;;
    *)       echo "unknown mode: $MODE (enter|app|de|dm|tty-dm|tty)" >&2; exit 1 ;;
    esac
fi

# Rootful but unprivileged (never --privileged). No keep-id: it remaps root
# away from you and systemd can't create /init.scope.
if command -v podman >/dev/null 2>&1; then
    RT_CMD=(podman)
else
    RT_CMD=(docker)
fi
RT_BIN="${RT_CMD[0]}"  # for checks that need the runtime name, not the sudo prefix
RUNARGS=(--security-opt label=disable)

IMG=localhost/cosmic-build-env
"${RT_CMD[@]}" build -t "$IMG" .devcontainer/

RT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# Mount the host runtime dir at /run/host-user ONLY. Never at /run/user/1000:
# when the user manager stops, logind rm -rf's that path, which would wipe
# the HOST runtime dir through the bind mount.
MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$RT_DIR:/run/host-user")
# Relative WAYLAND_DISPLAY resolves here; the dm session overrides it with
# logind's /run/user/1000. Not writable by dev under rootless mapping, so
# just gets its own writable runtime dir.
ENVS=(-e XDG_RUNTIME_DIR=/run/host-user -e JUST_RUNTIME_DIR=/home/dev/.cache/just)

if [ "$MODE" != tty ] && [ "$MODE" != tty-dm ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ENVS+=(-e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
elif [ "$MODE" != tty ] && [ "$MODE" != tty-dm ] && [ -n "${DISPLAY:-}" ]; then
    MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
    ENVS+=(-e "DISPLAY=${DISPLAY}")
elif [ "$MODE" != tty ] && [ "$MODE" != tty-dm ]; then
    die "set WAYLAND_DISPLAY or DISPLAY so GUIs can open on your host"
fi

# Nested cosmic-comp defaults to US English. Detect the host layout for
# `just config`; explicit XKB_DEFAULT_* wins. Override e.g.:
#   XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys scripts/dev.sh de
_host_status="$(localectl status --no-pager 2>/dev/null || true)"
_pick_xkb() { printf '%s\n' "$_host_status" | sed -n "s/.*$1:[[:space:]]*//p" | tr -d ' ' | sed -e 's/^n\/a$//'; }
: "${XKB_DEFAULT_LAYOUT:=$(_pick_xkb 'X11 Layout')}"
: "${XKB_DEFAULT_MODEL:=$(_pick_xkb 'X11 Model')}"
: "${XKB_DEFAULT_VARIANT:=$(_pick_xkb 'X11 Variant')}"
: "${XKB_DEFAULT_OPTIONS:=$(_pick_xkb 'X11 Options')}"
unset -f _pick_xkb
if [ -z "${XKB_DEFAULT_LAYOUT:-}" ] && [ -f /etc/default/keyboard ]; then
    _kb() { sed -n "s/^$1=//p" /etc/default/keyboard 2>/dev/null | tr -d '" ' | head -n1; }
    XKB_DEFAULT_LAYOUT="$(_kb XKBLAYOUT)"; XKB_DEFAULT_MODEL="$(_kb XKBMODEL)"
    XKB_DEFAULT_VARIANT="$(_kb XKBVARIANT)"; XKB_DEFAULT_OPTIONS="$(_kb XKBOPTIONS)"
    unset -f _kb
fi
unset _host_status

# Publish the host layout as a config-pack entry via atomic-write+rename
# (what the inotify watchers expect). Regenerated every run; removed when
# undetectable; gitignored — never commit it.
PACK_XKB="cosmic-config/com.system76.CosmicComp/v1/xkb_config"
if [ -n "${XKB_DEFAULT_LAYOUT:-}" ]; then
    _opt="None"; [ -n "${XKB_DEFAULT_OPTIONS:-}" ] && _opt="Some(\"${XKB_DEFAULT_OPTIONS}\")"
    mkdir -p "$(dirname "$PACK_XKB")"
    printf '(\n    rules: "",\n    model: "%s",\n    layout: "%s",\n    variant: "%s",\n    options: %s,\n    repeat_delay: 600,\n    repeat_rate: 25,\n)\n' \
        "${XKB_DEFAULT_MODEL:-}" "${XKB_DEFAULT_LAYOUT}" "${XKB_DEFAULT_VARIANT:-}" "$_opt" > "$PACK_XKB"
    unset _opt
else
    rm -rf cosmic-config/com.system76.CosmicComp
fi
unset PACK_XKB

[ -d /dev/dri ] && RUNARGS+=(--device /dev/dri) # absent = software rendering

# Named volume so the registry cache survives recreation (:U chowns it for
# rootless podman). Artifacts stay in each component's target/ under the repo.
CARGO_VOL="cosmic-cargo"
"${RT_CMD[@]}" volume create "$CARGO_VOL" >/dev/null 2>&1 || true
U=""; [ "$RT_BIN" = podman ] && U=":U"
MOUNTS+=(-v "$CARGO_VOL:/home/dev/.cargo$U")
ENVS+=(-e CARGO_HOME=/home/dev/.cargo -e RUSTUP_HOME=/usr/local/share/rustup)

# VT test: toolbox-like passthrough so cosmic-comp gets the host seat, DRM/input
# devices and udev tags directly. Plain container, no systemd. Run from a free
# VT after host login, e.g. `scripts/dev.sh tty cosmic-comp`.
if [ "$MODE" = tty ]; then
    [ "$RT_BIN" = podman ] || die "tty mode needs podman (pid=host + keep-id)"
    # Which VT? Prefer XDG_VTNR, fall back to parsing `tty`. The compositor
    # takes over THIS vt via your logind session.
    VTNR="${XDG_VTNR:-}"
    [ -n "$VTNR" ] || VTNR="$(tty 2>/dev/null | sed -n 's#^/dev/tty\([0-9]\+\)$#\1#p')"
    [ -n "$VTNR" ] || die "no VT detected (XDG_VTNR empty, stdin $(tty 2>/dev/null || echo unknown)) — Ctrl+Alt+F3, log in on the HOST, confirm with 'tty'/'loginctl list-sessions', then rerun"
    # no --privileged, no full /dev bind — rootless crun aborts on
    # odd host nodes (e.g. VirtualBox /dev/vboxusb/*). Explicit devices only
    # + SYS_TTY_CONFIG for the VT ioctls; escalate to --cap-add=all if needed.
    TTY_DEVS=()
    for dev in /dev/dri/* /dev/input/event* /dev/input/mice /dev/input/mouse* \
               "/dev/tty$VTNR" /dev/tty0; do
        # character/block nodes only — --device rejects subdirs like /dev/dri/by-path.
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
    # cosmic-comp handles Ctrl+Alt+F1..F12 itself; print where we came from
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

# tty-dm: systemd-booted dm container (greetd + cosmic-greeter + daemon) but
# with the host VT + DRM + input devices passed through, so the greeter takes
# over /dev/tty$N via DRM/KMS like on bare metal. The image bakes
# vt="none" (no kernel VTs in a plain container); inside-dm.sh rewrites it to
# the greeter VT at runtime. Run from a VT after host login.
#
# greetd does raw VT ioctls (KDSETMODE, VT_ACTIVATE) on /dev/tty$N. Two things
# must be true for that to work:
#  (a) CAP_SYS_TTY_CONFIG against the HOST user namespace — rootless podman
#      can't provide it (cap is in the container userns, not the device's
#      owning namespace). Rootful podman (sudo) makes container root == host
#      root. inside-tty.sh dodges this by using the host logind session for VT
#      access; greetd doesn't.
#  (b) The target VT must be FREE — no active login/getty holding the
#      controlling terminal. On bare metal the DM unit Conflicts=getty@ttyN
#      and starts at boot before any login. Here the user is logged in on a
#      VT, so the greeter must target a DIFFERENT, free VT. We stop getty on
#      it (like the Conflicts= would) and pass it through.
#
# We prefix podman with sudo (NOT sudo -E re-exec — that detaches from the
# controlling tty and podman exec -it can't allocate a pty). The script keeps
# running as the user with its tty; only podman runs as root.
if [ "$MODE" = tty-dm ]; then
    # The VT the user is logged in on (for reference, not the greeter target).
    LOGIN_VT="${XDG_VTNR:-}"
    [ -n "$LOGIN_VT" ] || LOGIN_VT="$(tty 2>/dev/null | sed -n 's#^/dev/tty\([0-9]\+\)$#\1#p')"
    [ -n "$LOGIN_VT" ] || die "no VT detected (XDG_VTNR empty, stdin $(tty 2>/dev/null || echo unknown)) — Ctrl+Alt+F3, log in on the HOST, confirm with 'tty'/'loginctl list-sessions', then rerun"
    # Greeter VT: explicit arg, else default to login VT + 1 (a free VT nearby).
    GREETER_VT="${1:-}"
    if [ -z "$GREETER_VT" ]; then
        GREETER_VT=$((LOGIN_VT + 1))
        # Auto-detect: skip VTs that have an active logind session.
        occupied="$(loginctl list-sessions --no-legend 2>/dev/null \
            | sed -n 's/.*tty\([0-9]\+\).*/\1/p' | sort -u || true)"
        for _ in 1 2 3 4 5 6; do
            case "$occupied" in *"$GREETER_VT"*) GREETER_VT=$((GREETER_VT + 1)) ;; *) break ;; esac
        done
    fi
    [ "$GREETER_VT" != "$LOGIN_VT" ] \
        || die "greeter VT ($GREETER_VT) == login VT — pass a free VT: scripts/dev.sh tty-dm <vt>"
    [ -c "/dev/tty$GREETER_VT" ] || die "/dev/tty$GREETER_VT does not exist — pass a valid VT: scripts/dev.sh tty-dm <vt>"
    # Stop getty on the greeter VT (mimics the DM unit's Conflicts=getty@ttyN).
    sudo systemctl stop "getty@tty$GREETER_VT.service" 2>/dev/null || true
    DM_DEVS=()
    for dev in /dev/dri/* /dev/input/event* /dev/input/mice /dev/input/mouse* \
               "/dev/tty$GREETER_VT" /dev/tty0; do
        [ -c "$dev" ] || [ -b "$dev" ] || continue
        DM_DEVS+=(--device "$dev")
    done
    # libinput (in cosmic-comp) discovers input devices through udev: the
    # passed-through /dev/input nodes alone are useless — without the host
    # udev db they carry no ID_INPUT/seat tags, so libinput's udev backend
    # sees an empty seat and the greeter comes up with dead keyboard/mouse
    # (and no Ctrl+Alt+Fn, since the comp handles VT switching itself).
    # Read-only bind of the host db; /sys is already visible in containers.
    # NOT /run/systemd/*: the container's own logind owns that under its
    # tmpfs /run — overlaying host state there would break it.
    [ -e /run/udev ] && MOUNTS+=(-v /run/udev:/run/udev:rslave,ro)
    # GPU userspace: the image ships Mesa, which covers AMD, Intel and
    # nouveau out of the box (the kernel side is the host's — that's all
    # that matters for --device passthrough). The one case Mesa can't
    # drive is the NVIDIA *proprietary* driver: without this the comp
    # silently falls back to llvmpipe and the greeter crawls. Pass the
    # HOST nvidia userspace through — versions must match the host kernel
    # module exactly, so the host's own files are the only correct set.
    # (nvidia-open uses the same userspace, so this covers it too.)
    # Vendor EGL/GLES libs + the gbm backend (Mesa's libgbm auto-picks
    # nvidia-drm_gbm.so for nvidia-drm nodes) + control devices +
    # /proc/driver/nvidia. ldconfig runs after boot (below) to register
    # them in the container.
    if compgen -G '/dev/nvidia[0-9]*' >/dev/null; then
        for dev in /dev/nvidia* /dev/nvidia-caps/*; do
            [ -c "$dev" ] || continue
            DM_DEVS+=(--device "$dev")
        done
        for gl in /usr/lib64/libEGL_nvidia.so.* \
                  /usr/lib64/libGLESv1_CM_nvidia.so.* \
                  /usr/lib64/libGLESv2_nvidia.so.* \
                  /usr/lib64/libnvidia-eglcore.so.* \
                  /usr/lib64/libnvidia-glsi.so.* \
                  /usr/lib64/libnvidia-glvkspirv.so.* \
                  /usr/lib64/libnvidia-tls.so.* \
                  /usr/lib64/libnvidia-gpucomp.so.* \
                  /usr/lib64/libnvidia-allocator.so.* \
                  /usr/lib64/libnvidia-api.so.* \
                  /usr/lib64/libnvidia-rtcore.so.* \
                  /usr/lib64/libnvidia-cbl.so.*; do
            [ -f "$gl" ] || continue
            MOUNTS+=(-v "$gl:/usr/lib/x86_64-linux-gnu/${gl##*/}:ro")
        done
        GBM_SRC="$(readlink -f /usr/lib64/gbm/nvidia-drm_gbm.so 2>/dev/null || true)"
        [ -n "$GBM_SRC" ] && MOUNTS+=(-v "$GBM_SRC:/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so:ro")
        # glvnd discovers EGL vendors via these JSONs — the image only ships
        # 50_mesa.json. Without 10_nvidia.json, eglInitialize dispatches to
        # Mesa alone, which rejects the nvidia-backed gbm device ("gbm device
        # using incorrect/incompatible backend") and the comp falls to
        # llvmpipe with no outputs.
        for vd in /usr/share/glvnd/egl_vendor.d /etc/glvnd/egl_vendor.d; do
            [ -f "$vd/10_nvidia.json" ] \
                && MOUNTS+=(-v "$vd/10_nvidia.json:$vd/10_nvidia.json:ro") && break
        done
        # External EGL platforms (egl_external_platform.d): NVIDIA's GBM
        # platform implementation lives HERE, not in the vendor ICD — without
        # 15_nvidia_gbm.json + libnvidia-egl-gbm.so, eglGetPlatformDisplay
        # (EGL_PLATFORM_GBM_KHR) returns NO_DISPLAY (wayland/xcb/xlib jsons
        # ride along for completeness; only GBM is used by cosmic-comp).
        for f in /usr/share/egl/egl_external_platform.d/*.json; do
            [ -f "$f" ] || continue
            MOUNTS+=(-v "$f:$f:ro")
        done
        for el in /usr/lib64/libnvidia-egl-gbm.so.* \
                  /usr/lib64/libnvidia-egl-wayland.so.*; do
            [ -f "$el" ] || continue
            MOUNTS+=(-v "$el:/usr/lib/x86_64-linux-gnu/${el##*/}:ro")
        done
        [ -d /proc/driver/nvidia ] && MOUNTS+=(-v /proc/driver/nvidia:/proc/driver/nvidia:ro)
        NV=1
        log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
        log "NVIDIA driver detected — passing host userspace + /dev/nvidia* through (else llvmpipe)"
        unset -f log
    fi
    # greetd (root) needs CAP_SYS_TTY_CONFIG for KDSETMODE/VT_ACTIVATE on
    # /dev/tty$GREETER_VT. Only works under rootful podman (sudo).
    RUNARGS+=(--cap-add SYS_TTY_CONFIG "${DM_DEVS[@]}")
    # Tell inside-dm.sh to rewrite greetd's vt and skip the host-WAYLAND/DISPLAY
    # branch (no host compositor here — the greeter owns the VT via DRM/KMS).
    ENVS+=(-e "XDG_VTNR=$GREETER_VT")
    # Prefix podman with sudo so container root == host root (real
    # CAP_SYS_TTY_CONFIG). Not sudo -E re-exec: that detaches the controlling
    # tty, and podman exec -it can't allocate a pty without it.
    RT_CMD=(sudo "${RT_CMD[@]}")
    # Line 55's build ran under user podman; rootful podman has a separate
    # image store, so rebuild there or the run below tries to pull localhost/
    # cosmic-build-env from a registry and fails.
    "${RT_CMD[@]}" build -t "$IMG" .devcontainer/
    log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }
    log "tty-dm: login VT tty$LOGIN_VT, greeter VT tty$GREETER_VT (seat ${XDG_SEAT:-seat0}) — sudo prompt for rootful podman"
    log "after 'inside-dm.sh' starts the greeter, switch to it: Ctrl+Alt+F$GREETER_VT"
    log "if the greeter grabs input and Ctrl+Alt+F$LOGIN_VT dies: ssh in, 'sudo podman exec cosmic-dev systemctl stop display-manager.service'"
    unset -f log
fi

# systemd inside the container: tmpfs on /run & friends, writable cgroup fs,
# SIGRTMIN+3 stop signal. Unprivileged; never --privileged.
# https://labs.iximiuz.com/tutorials/systemd-containers-podman-30992811#filesystem
SYSTEMD_ARGS=(--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:rw,nosuid,exec
              -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host
              --stop-signal SIGRTMIN+3)
[ "$RT_BIN" = podman ] && SYSTEMD_ARGS+=(--systemd=always)

CTR=cosmic-dev
"${RT_CMD[@]}" rm -f "$CTR" >/dev/null 2>&1 || true
"${RT_CMD[@]}" run -d --name "$CTR" "${RUNARGS[@]}" "${SYSTEMD_ARGS[@]}" \
    "${MOUNTS[@]}" "${ENVS[@]}" -w /cosmic-epoch --entrypoint /sbin/init "$IMG" \
    || die "systemd container failed to start"
cleanup() {
    # Loud if it fails: a silently surviving container keeps the greeter on
    # the VT and the DRM/input devices grabbed.
    if ! "${RT_CMD[@]}" rm -f "$CTR" >/dev/null 2>&1; then
        echo "warning: could not remove container $CTR — run: ${RT_CMD[*]} rm -f $CTR" >&2
    fi
    # tty-dm: hand the greeter VT back to the getty we stopped at start.
    if [ "$MODE" = tty-dm ] && [ -n "${GREETER_VT:-}" ]; then
        sudo systemctl start "getty@tty$GREETER_VT.service" 2>/dev/null || true
    fi
}
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

# NVIDIA passthrough: ldconfig registers the host-mounted vendor GL/EGL
# libs so glvnd/dlopen resolve them without LD_LIBRARY_PATH tricks.
if [ -n "${NV:-}" ]; then
    "${RT_CMD[@]}" exec "$CTR" ldconfig 2>/dev/null \
        || echo "warning: ldconfig failed in container — EGL may miss the nvidia vendor lib" >&2
fi

# Rootless podman maps container root to you, so build as root; docker and
# rootful podman (tty-dm via sudo) both need -u dev.
EXEC=()
[ "$RT_BIN" = docker ] && EXEC=(-u dev)
[ "$MODE" = tty-dm ] && EXEC=(-u dev)

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
    echo "  sudo -u dev just config"
    echo "  ./scripts/inside-de.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
dm)
    echo "systemd container up (state: $state). Then:"
    echo "  just c $DM_COMPONENTS"
    echo "  sudo just ci $DM_COMPONENTS"
    echo "  sudo -u dev just config"
    echo "  ./scripts/inside-dm.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
tty-dm)
    echo "systemd container up (state: $state). Then:"
    echo "  just c $DM_COMPONENTS"
    echo "  sudo just ci $DM_COMPONENTS"
    echo "  sudo -u dev just config"
    echo "  ./scripts/inside-dm.sh"
    "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
    ;;
*)
    echo "unknown mode: $MODE (enter|app|de|dm|tty-dm|tty)" >&2
    exit 1
    ;;
esac
