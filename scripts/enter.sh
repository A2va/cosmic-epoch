#!/usr/bin/env bash
# enter.sh — COSMIC dev container entry point (mise tasks: enter / de / dm).
# podman preferred, docker fallback. The graphical container boots with
# systemd as PID 1, like a real system.
#
# TTY detection decides the transport:
#   graphical terminal (WAYLAND_DISPLAY/DISPLAY set):
#     mise run enter        systemd dev container + bash session (reuse the
#                           running one; it stays up for 'app'/'compile'/
#                           'install'; 'mise run stop' tears it down).
#                           de|dm args enter too — a nested session needs the
#                           components built+installed first, so it's started
#                           manually inside: 'mise run de' (session on the
#                           host compositor) or 'mise run dm' (nested greeter)
#   real VT (no compositor; login shell has XDG_VTNR / /dev/ttyN):
#     mise run enter        VT session container + bash (toolbox-like HW
#                           passthrough, no systemd)
#     mise run enter de     VT session container → ./scripts/inside-de.sh
#     mise run enter dm     greeter on a free host VT (rootful podman;
#                           VT defaults to login VT + 1) → ./scripts/inside-dm.sh
#   inside the container, enter is just a shell; run the inside-*.sh scripts
#   directly.
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

# Inside the container: just a shell — run ./scripts/inside-*.sh directly.
if in_container; then
    exec bash
fi

# TTY detection: graphical terminal (compositor env) → nested dev container;
# real VT (XDG_VTNR or stdin /dev/ttyN) → VT session container (start.sh).
# PAM sets neither on a bare VT login, so this is reliable.
if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    ensure_dev_container
    # enter just enters (de/dm included): a nested session needs the
    # components built+installed first — run the inside-*.sh script manually.
    [ -n "$MODE" ] && log "enter only — for the session: mise run compile (host), sudo mise run install (here), then mise run $MODE"
    exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" bash
elif [ -n "$(vtnr)" ]; then
    exec ./scripts/start.sh "${MODE:-shell}" "$@"
else
    die "no WAYLAND_DISPLAY/DISPLAY and no VT detected — run from a graphical shell or log in on a VT"
fi
