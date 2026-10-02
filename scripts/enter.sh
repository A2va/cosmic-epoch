#!/usr/bin/env bash
# enter.sh — COSMIC dev container entry point (mise tasks: enter / de / dm).
# podman preferred, docker fallback. The graphical container boots with
# systemd as PID 1, like a real system.
#
# TTY detection decides the transport:
#   graphical terminal (WAYLAND_DISPLAY/DISPLAY set):
#     mise run enter        systemd dev container + bash session (reuse the
#                           running one; it stays up for 'app'/'compile'/
#                           'install'; 'mise run stop' tears it down)
#     mise run enter de     boot it, then run ./scripts/inside-de.sh (nested
#                           session on the host compositor)
#     mise run enter dm     boot it, then run ./scripts/inside-dm.sh (nested
#                           greeter)
#   real VT (no compositor; login shell has XDG_VTNR / /dev/ttyN):
#     mise run enter        VT session container + bash (toolbox-like HW
#                           passthrough, no systemd)
#     mise run enter de     VT session container → ./scripts/inside-de.sh
#     mise run enter dm     greeter on a free host VT (rootful podman;
#                           VT defaults to login VT + 1) → ./scripts/inside-dm.sh
#   inside the container, the same modes still resolve sensibly.
#
# Component lists (compile/install defaults) come from mise.toml [env] —
# mise is installed on the host and in the image, so nothing is forwarded.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

MODE="${1:-}"
if [ $# -gt 0 ]; then shift; fi
case "$MODE" in
""|de|dm) ;;
*)        die "unknown mode: $MODE (enter|de|dm)" ;;
esac

# Inside the container: same modes, no runtime needed; VT modes can't run here.
if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    case "$MODE" in
    ""|enter) exec bash ;;
    de)       exec ./scripts/inside-de.sh ;;
    dm)       exec ./scripts/inside-dm.sh ;;
    esac
fi

# TTY detection: graphical terminal (compositor env) → nested dev container;
# real VT (XDG_VTNR or stdin /dev/ttyN) → VT session container (start.sh).
# PAM sets neither on a bare VT login, so this is reliable.
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    ensure_dev_container
    case "$MODE" in
    "") exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash ;;
    de) exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" ./scripts/inside-de.sh ;;
    dm) exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" ./scripts/inside-dm.sh ;;
    esac
elif [ -n "$(vtnr)" ]; then
    exec ./scripts/start.sh "${MODE:-shell}" "$@"
else
    die "no WAYLAND_DISPLAY/DISPLAY and no VT detected — run from a graphical shell or log in on a VT"
fi
