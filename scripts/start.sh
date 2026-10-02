#!/usr/bin/env bash
# start.sh — boot the VT test containers and run the session inside them.
# Called by scripts/enter.sh when it detects a real host VT; run from a
# logged-in VT (Ctrl+Alt+F<N> on the HOST, confirm with 'tty').
#
#   start.sh shell|de   rootless podman, plain container (no systemd):
#                       toolbox-like passthrough so cosmic-comp gets the host
#                       seat, DRM/input devices and udev tags directly. The
#                       session uses the host logind session (libseat backend),
#                       dodging the greetd CAP_SYS_TTY_CONFIG problem below.
#                       execs bash (shell) or ./scripts/inside-de.sh (de).
#   start.sh dm         systemd-booted dm container (greetd + cosmic-greeter
#                       + daemon) with the host VT + DRM + input devices
#                       passed through, so the greeter takes over
#                       /dev/tty$N via DRM/KMS like on bare metal. The image
#                       bakes vt="none" (no kernel VTs in a plain container);
#                       inside-dm.sh rewrites it to the greeter VT at runtime.
#                       execs ./scripts/inside-dm.sh.
#
# greetd does raw VT ioctls (KDSETMODE, VT_ACTIVATE) on /dev/tty$N. Two things
# must be true for that to work:
#  (a) CAP_SYS_TTY_CONFIG against the HOST user namespace — rootless podman
#      can't provide it (cap is in the container userns, not the device's
#      owning namespace). Rootful podman (sudo) makes container root == host
#      root. inside-de.sh (tty) dodges this via the host logind session;
#      greetd doesn't.
#  (b) The target VT must be FREE — no active login/getty holding the
#      controlling terminal. On bare metal the DM unit Conflicts=getty@ttyN
#      and starts at boot before any login. Here the user is logged in on a
#      VT, so the greeter must target a DIFFERENT, free VT. We stop getty on
#      it (like the Conflicts= would) and pass it through.
#
# We prefix podman with sudo (NOT sudo -E re-exec — that detaches from the
# controlling tty and podman exec -it can't allocate a pty). The script keeps
# running as the user with its tty; only podman runs as root.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

SESSION="${1:-shell}"
if [ $# -gt 0 ]; then shift; fi
case "$SESSION" in
shell|de) ;;
dm)       ;;
*)        die "unknown session: $SESSION (shell|de|dm)" ;;
esac

if command -v podman >/dev/null 2>&1; then RT_CMD=(podman); else RT_CMD=(docker); fi
RT_BIN="${RT_CMD[0]}"
IMG=localhost/cosmic-build-env
RT_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
CARGO_VOL="cosmic-cargo"

gen_xkb_pack
"${RT_CMD[@]}" volume create "$CARGO_VOL" >/dev/null 2>&1 || true

# --- rootless VT session container (shell / de) ------------------------------
if [ "$SESSION" != dm ]; then
    "${RT_CMD[@]}" build -f .devcontainer/Dockerfile -t "$IMG" .
    [ "$RT_BIN" = podman ] || die "VT session needs podman (pid=host + keep-id)"
    # Which VT? The compositor takes over THIS vt via your logind session.
    VTNR="$(vtnr)"
    [ -n "$VTNR" ] || die "no VT detected (XDG_VTNR empty, stdin $(tty 2>/dev/null || echo unknown)) — Ctrl+Alt+F3, log in on the HOST, confirm with 'tty'/'loginctl list-sessions', then rerun"
    # no --privileged, no full /dev bind — rootless crun aborts on
    # odd host nodes (e.g. VirtualBox /dev/vboxusb/*). Explicit devices only
    # + SYS_TTY_CONFIG for the VT ioctls; escalate to --cap-add=all if needed.
    DEVS=()
    while IFS= read -r dev; do DEVS+=(--device "$dev"); done < <(vt_devices "$VTNR")
    MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$CARGO_VOL:/home/dev/.cargo:U"
            -v "$RT_DIR:$RT_DIR")
    for src in /run/systemd/sessions /run/systemd/users /run/systemd/seats \
               /run/udev /run/dbus/system_bus_socket; do
        [ -e "$src" ] && MOUNTS+=(-v "$src:$src:rslave")
    done
    ENVS=(-e "XDG_RUNTIME_DIR=$RT_DIR" -e JUST_RUNTIME_DIR=/home/dev/.cache/just
          -e HOME=/home/dev -e USER=dev
          -e XDG_SESSION_ID -e XDG_SEAT -e XDG_SESSION_TYPE -e "XDG_VTNR=$VTNR")
    for dbg in RUST_LOG RUST_BACKTRACE; do
        [ -n "${!dbg:-}" ] && ENVS+=(-e "$dbg=${!dbg}")
    done
    case "$SESSION" in
    shell)
        echo "tty container (VT tty$VTNR). Then:"
        echo "  sudo mise run install           # full DE + config pack"
        echo "  ./scripts/inside-de.sh          # session: comp, panel, launcher, bg"
        CMD=(bash)
        ;;
    de) CMD=(./scripts/inside-de.sh) ;;
    esac
    # cosmic-comp handles Ctrl+Alt+F1..F12 itself; print where we came from
    # so the switch-back target is obvious from the session screen.
    log "VT tty$VTNR (session ${XDG_SESSION_ID:-?}, seat ${XDG_SEAT:-seat0})"
    log "session takes over THIS vt — switch back to your login with Ctrl+Alt+F$VTNR"
    # No --rm: the container survives 'mise run stop' (session killed only),
    # and a leftover shell stays inspectable. --replace clears an exited
    # leftover so a rerun doesn't hit "name in use".
    exec "${RT_CMD[@]}" run --replace -it --name cosmic-tty \
        --pid=host --ipc=host --network=host --cgroupns=host \
        --userns=keep-id --user "$(id -u):$(id -g)" \
        --cap-add SYS_TTY_CONFIG \
        --security-opt label=disable --ulimit host \
        "${DEVS[@]}" "${MOUNTS[@]}" "${ENVS[@]}" \
        -w /cosmic-epoch "$IMG" "${CMD[@]}"
fi

# --- rootful dm container (greeter on a real VT) -----------------------------
# The VT the user is logged in on (for reference, not the greeter target).
LOGIN_VT="$(vtnr)"
[ -n "$LOGIN_VT" ] || die "no VT detected (XDG_VTNR empty, stdin $(tty 2>/dev/null || echo unknown)) — Ctrl+Alt+F3, log in on the HOST, confirm with 'tty'/'loginctl list-sessions', then rerun"

CTR=cosmic-dev
EXEC=()
REUSED=0
# A rootless cosmic-dev can't serve dm (needs rootful); a rootful leftover
# (previous dm run) can be reused — inside-dm.sh tears down its old session
# and restarts the greeter, no getty dance needed again.
if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
    die "rootless $CTR is running — 'mise run stop --rm' first (dm needs the rootful store)"
elif sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
    REUSED=1
    RT_CMD=(sudo podman)
    EXEC=(-u dev)
    log "reusing rootful container $CTR"
fi

if [ "$REUSED" = 0 ]; then
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
        || die "greeter VT ($GREETER_VT) == login VT — pass a free VT: mise run enter dm -- <vt>"
    [ -c "/dev/tty$GREETER_VT" ] || die "/dev/tty$GREETER_VT does not exist — pass a valid VT: mise run enter dm -- <vt>"
    # Stop getty on the greeter VT (mimics the DM unit's Conflicts=getty@ttyN).
    sudo systemctl stop "getty@tty$GREETER_VT.service" 2>/dev/null || true
    DEVS=()
    while IFS= read -r dev; do DEVS+=(--device "$dev"); done < <(vt_devices "$GREETER_VT")
    # libinput (in cosmic-comp) discovers input devices through udev: the
    # passed-through /dev/input nodes alone are useless — without the host
    # udev db they carry no ID_INPUT/seat tags, so libinput's udev backend
    # sees an empty seat and the greeter comes up with dead keyboard/mouse
    # (and no Ctrl+Alt+Fn, since the comp handles VT switching itself).
    # Read-only bind of the host db; /sys is already visible in containers.
    # NOT /run/systemd/*: the container's own logind owns that under its
    # tmpfs /run — overlaying host state there would break it.
    MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$RT_DIR:/run/host-user")
    [ -e /run/udev ] && MOUNTS+=(-v /run/udev:/run/udev:rslave,ro)
    ENVS=(-e XDG_RUNTIME_DIR=/run/host-user -e JUST_RUNTIME_DIR=/home/dev/.cache/just)
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
            DEVS+=(--device "$dev")
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
        log "NVIDIA driver detected — passing host userspace + /dev/nvidia* through (else llvmpipe)"
    fi
    # greetd (root) needs CAP_SYS_TTY_CONFIG for KDSETMODE/VT_ACTIVATE on
    # /dev/tty$GREETER_VT. Only works under rootful podman (sudo).
    RUNARGS=(--security-opt label=disable --cap-add SYS_TTY_CONFIG "${DEVS[@]}")
    # Tell inside-dm.sh to rewrite greetd's vt and skip the host-WAYLAND/DISPLAY
    # branch (no host compositor here — the greeter owns the VT via DRM/KMS).
    ENVS+=(-e "XDG_VTNR=$GREETER_VT")
    # Rootful podman has a separate image store from the user's — build there
    # or the run below tries to pull localhost/cosmic-build-env from a
    # registry and fails. (No user-side build happened in dm mode.)
    RT_CMD=(sudo "${RT_CMD[@]}")
    "${RT_CMD[@]}" build -f .devcontainer/Dockerfile -t "$IMG" .
    log "dm: login VT tty$LOGIN_VT, greeter VT tty$GREETER_VT (seat ${XDG_SEAT:-seat0}) — sudo prompt for rootful podman"
    log "if the greeter grabs input and Ctrl+Alt+F$LOGIN_VT dies: ssh in, 'sudo podman exec cosmic-dev systemctl stop display-manager.service'"
fi

# systemd inside the container: tmpfs on /run & friends, writable cgroup fs,
# SIGRTMIN+3 stop signal. Unprivileged; never --privileged.
# https://labs.iximiuz.com/tutorials/systemd-containers-podman-30992811#filesystem
if [ "$REUSED" = 0 ]; then
    SYSTEMD_ARGS=(--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:rw,nosuid,exec
                  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host
                  --stop-signal SIGRTMIN+3)
    [ "$RT_BIN" = podman ] && SYSTEMD_ARGS+=(--systemd=always)

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
        # Hand the greeter VT back to the getty we stopped at start.
        sudo systemctl start "getty@tty$GREETER_VT.service" 2>/dev/null || true
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
    # after inside-dm.sh starts the greeter, switch to it: Ctrl+Alt+F$GREETER_VT
fi

# Plain call (no exec): the EXIT trap must survive to clean up the container
# and restore the greeter getty when inside-dm.sh ends.
"${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" ./scripts/inside-dm.sh
