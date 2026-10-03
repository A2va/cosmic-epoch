# Shared shell helpers for the dev scripts (enter/start/app/compile/install/stop).
# Source, don't execute.
# ponytail: one flat sourced file; split only when a helper gets a second consumer.

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;36m==>\033[0m %s\n' "$*" >&2; }

# Run the interactive shell session and end the script with a sane status.
# Interactive bash exits with its LAST COMMAND's status — 'exit'/Ctrl-D after
# a failed command must not fail the mise task. 125 is the runtime's own
# error code (podman/docker exec couldn't run): keep it.
shell_exit() {
    local st
    set +e
    if [ $# -gt 0 ]; then "$@"; else bash; fi
    st=$?
    set -e
    [ "$st" -eq 125 ] && exit "$st"
    exit 0
}

# Inside a container? /proc/1/environ has container=podman|docker injected by
# the runtime and survives sudo's env_reset (the $container env var doesn't) —
# but only in the systemd dev container: the tty container runs --pid=host, so
# its /proc/1 is the HOST init (unreadable, no container= there). Podman's
# runtime-injected /run/.containerenv marker (tmpfs, not a fakeable repo file)
# covers that one; /.dockerenv covers docker. Env var fallback so non-root
# callers still get the right next error (e.g. install's "run me as root").
in_container() {
    grep -zqa '^container=' /proc/1/environ 2>/dev/null \
        || [ -f /run/.containerenv ] || [ -f /.dockerenv ] \
        || [ -n "${container:-}" ]
}

# Container runtime: podman preferred (rootless, keep-id), docker fallback.
runtime() {
    command -v podman >/dev/null 2>&1 && { echo podman; return; }
    echo docker
}

# Is container "$1" running? Checks the user store, then the rootful store
# (sudo podman — tty-dm leftovers live there). Pass "probe" to use `sudo -n`
# so detection never blocks on a password prompt (nested enter/de runs).
container_running() {
    local rt; rt="$(runtime)"
    if "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; then return 0; fi
    local sn=""
    [ "${2:-}" = probe ] && sn="-n"
    if [ "$rt" = podman ] && sudo $sn podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; then return 0; fi
    return 1
}

# Login VT number: XDG_VTNR, else parse /dev/ttyN from stdin.
vtnr() {
    if [ -n "${XDG_VTNR:-}" ]; then echo "$XDG_VTNR"; return; fi
    tty 2>/dev/null | sed -n 's#^/dev/tty\([0-9]\+\)$#\1#p'
}

# Passthrough device nodes for a VT session (char/block only — --device
# rejects subdirs like /dev/dri/by-path). Print one node per line.
vt_devices() {
    local dev
    for dev in /dev/dri/* /dev/input/event* /dev/input/mice /dev/input/mouse* \
               "/dev/tty$1" /dev/tty0; do
        [ -c "$dev" ] || [ -b "$dev" ] || continue
        printf '%s\n' "$dev"
    done
}

# Publish the host keyboard layout as a config-pack entry via
# atomic-write+rename (what the inotify watchers expect). Regenerated every
# run; removed when undetectable; gitignored — never commit it.
gen_xkb_pack() {
    local status opt
    # Nested cosmic-comp defaults to US English. Detect the host layout;
    # explicit XKB_DEFAULT_* wins. Override e.g.:
    #   XKB_DEFAULT_LAYOUT=de XKB_DEFAULT_VARIANT=nodeadkeys mise run enter de
    status="$(localectl status --no-pager 2>/dev/null || true)"
    _pick_xkb() { printf '%s\n' "$status" | sed -n "s/.*$1:[[:space:]]*//p" | tr -d ' ' | sed -e 's/^n\/a$//'; }
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
    local pack="cosmic-config/com.system76.CosmicComp/v1/xkb_config"
    if [ -n "${XKB_DEFAULT_LAYOUT:-}" ]; then
        opt="None"; [ -n "${XKB_DEFAULT_OPTIONS:-}" ] && opt="Some(\"${XKB_DEFAULT_OPTIONS}\")"
        mkdir -p "$(dirname "$pack")"
        printf '(\n    rules: "",\n    model: "%s",\n    layout: "%s",\n    variant: "%s",\n    options: %s,\n    repeat_delay: 600,\n    repeat_rate: 25,\n)\n' \
            "${XKB_DEFAULT_MODEL:-}" "${XKB_DEFAULT_LAYOUT}" "${XKB_DEFAULT_VARIANT:-}" "$opt" > "$pack"
    else
        rm -rf cosmic-config/com.system76.CosmicComp
    fi
}

# Create (or reuse) the systemd dev container. Sets globals for the caller:
#   RT_CMD (possibly sudo-prefixed), RT_BIN, EXEC, CTR, IMG, state, REUSED.
# No cleanup trap on purpose: the container must outlive this call so
# 'enter' → 'app' → 'compile'/'install' can all reuse it; 'mise run stop --rm'
# tears it down.
ensure_dev_container() {
    RT_CMD=()
    if command -v podman >/dev/null 2>&1; then RT_CMD=(podman); else RT_CMD=(docker); fi
    RT_BIN="${RT_CMD[0]}" # runtime name, not the sudo prefix
    RUNARGS=(--security-opt label=disable)
    EXEC=()
    CTR=cosmic-dev
    IMG=localhost/cosmic-build-env
    REUSED=0

    # Rootless podman maps container root to you, so exec as root; docker and
    # rootful podman (tty-dm leftovers via sudo) both need -u dev.
    # Probing only — tty-dm leftovers are irrelevant here, and an unconditional
    # sudo podman ps would prompt for a password outside a tty (nested mode).
    if container_running "$CTR" probe; then
        REUSED=1
        if ! "${RT_CMD[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CTR"; then
            RT_CMD=(sudo "${RT_CMD[@]}")
            EXEC=(-u dev)
        fi
    fi
    state="none"
    [ "$REUSED" = 1 ] && state="running (reused)"

    [ "$REUSED" = 1 ] || "${RT_CMD[@]}" build -f .devcontainer/Dockerfile -t "$IMG" .

    local rt_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    # Mount the host runtime dir at /run/host-user ONLY. Never at /run/user/1000:
    # when the user manager stops, logind rm -rf's that path, which would wipe
    # the HOST runtime dir through the bind mount.
    MOUNTS=(-v "$PWD:/cosmic-epoch" -v "$rt_dir:/run/host-user")
    # Relative WAYLAND_DISPLAY resolves here; the dm session overrides it with
    # logind's /run/user/1000. Not writable by dev under rootless mapping, so
    # just gets its own writable runtime dir.
    ENVS=(-e XDG_RUNTIME_DIR=/run/host-user -e JUST_RUNTIME_DIR=/home/dev/.cache/just)

    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        ENVS+=(-e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}")
    elif [ -n "${DISPLAY:-}" ]; then
        MOUNTS+=(-v /tmp/.X11-unix:/tmp/.X11-unix)
        ENVS+=(-e "DISPLAY=${DISPLAY}")
    else
        die "set WAYLAND_DISPLAY or DISPLAY so GUIs can open on your host"
    fi

    gen_xkb_pack

    [ -d /dev/dri ] && RUNARGS+=(--device /dev/dri) # absent = software rendering

    # Named volume so the registry cache survives recreation (:U chowns it
    # for rootless podman). Artifacts stay in each component's target/.
    local cargo_vol="cosmic-cargo" u=""
    "${RT_CMD[@]}" volume create "$cargo_vol" >/dev/null 2>&1 || true
    [ "$RT_BIN" = podman ] && u=":U"
    MOUNTS+=(-v "$cargo_vol:/home/dev/.cargo$u")
    ENVS+=(-e CARGO_HOME=/home/dev/.cargo -e RUSTUP_HOME=/usr/local/share/rustup)

    [ "$REUSED" = 1 ] && return 0

    # systemd inside the container: tmpfs on /run & friends, writable cgroup
    # fs, SIGRTMIN+3 stop signal. Unprivileged; never --privileged.
    # https://labs.iximiuz.com/tutorials/systemd-containers-podman-30992811#filesystem
    local systemd_args=(--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:rw,nosuid,exec
                        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host
                        --stop-signal SIGRTMIN+3)
    [ "$RT_BIN" = podman ] && systemd_args+=(--systemd=always)

    "${RT_CMD[@]}" rm -f "$CTR" >/dev/null 2>&1 || true
    "${RT_CMD[@]}" run -d --name "$CTR" "${RUNARGS[@]}" "${systemd_args[@]}" \
        "${MOUNTS[@]}" "${ENVS[@]}" -w /cosmic-epoch --entrypoint /sbin/init "$IMG" \
        || die "systemd container failed to start"

    # wait for systemd to finish booting
    state=""
    local _
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
}

# Shared component loop for compile/install.
_layout() {
    # $1 = component dir → print "<kind>:<profvar>".
    # kind: just-cargo | just-data | make. profvar: how debug=0|1 is spelled.
    if [ -f "$1/justfile" ] || [ -f "$1/Justfile" ]; then
        if [ -f "$1/Cargo.toml" ]; then
            echo "just-cargo:debug"
        else
            echo "just-data:debug"
        fi
    elif [ -f "$1/Makefile" ]; then
        echo "make:DEBUG"
    fi
}

_collect() {
    # Resolve "$@" into component dirs. Default: COMPONENTS_DE (mise env).
    # Arg 'dm': the DM set (adds cosmic-greeter) via COMPONENTS_DM.
    local comps
    if [ $# -gt 0 ]; then comps="$*"; else comps="${COMPONENTS_DE:?COMPONENTS_DE not set (run via mise)}"; fi
    [ "$comps" = dm ] && comps="${COMPONENTS_DM:?COMPONENTS_DM not set (run via mise)}"
    local c
    for c in $comps; do
        c="${c%/}" # autocomplete adds a trailing slash
        [ -d "$c" ] || { echo "skipping unknown component: $c" >&2; continue; }
        echo "$c"
    done
}
