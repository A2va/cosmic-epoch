#!/usr/bin/env bash
# app.sh — run a COSMIC app as a window on the host compositor (mise task
# 'app'). First arg is a component dir (cosmic-term, pop-launcher, ...) and is
# run with `cargo run` inside it, or any other command/binary path run as-is.
# DEBUG=0 runs release. Creates or reuses the systemd dev container.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

[ $# -ge 1 ] || die "usage: mise run app COMPONENT|BINARY [args...]"

# Apps must run as the graphical user: a superuser has no session access to
# the host compositor (WAYLAND_DISPLAY/XAUTHORITY) and would nest a root-owned
# window. Evaluated INSIDE the container, where the app actually executes —
# sudo always sets SUDO_USER, so one check covers every sudo path:
#   - host:  sudo mise run app ...   (SUDO_USER forwarded below)
#   - app:   mise run app sudo ...   (sudo inside the container)
#   - tty:   sudo ./scripts/app.sh   (sudo shell inside the container)
# Only sudo is refused, not root in general: rootless podman maps container
# uid 0 to the host user, so plain container-uid-0 has no real elevation.
GUARD='[ -z "${SUDO_USER:-}" ] || { printf "\033[1;31merror:\033[0m refusing to run under sudo (by %s) — run the app as the graphical user\n" "$SUDO_USER" >&2; exit 1; }; exec "$@"'

# Component dir? Then cargo run in it — no build/install round trip.
if [ -d "$1" ] && [ -f "$1/Cargo.toml" ]; then
    comp="$1"; shift
    cmd=(cargo run)
    [ "${DEBUG:-1}" = 0 ] && cmd+=(--release)
    [ $# -gt 0 ] && cmd+=(-- "$@")
else
    comp="."
    cmd=("$@")
fi

# Inside the container: run directly.
if in_container; then
    [ -n "$comp" ] && cd "$comp"
    exec bash -c "$GUARD" app "${cmd[@]}"
fi

# Apps open windows — pointless from a VT without a compositor to nest into.
[ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] \
    || die "app mode opens a window on the host compositor — run from a graphical shell"

ensure_dev_container
# Forward the host's SUDO_USER (iff set) so the in-container guard sees it.
sudo_env=()
[ -n "${SUDO_USER:-}" ] && sudo_env=(-e "SUDO_USER=$SUDO_USER")
exec "${RT_CMD[@]}" exec -it "${sudo_env[@]}" "${EXEC[@]}" -w "/cosmic-epoch/$comp" "$CTR" \
    bash -c "$GUARD" app "${cmd[@]}"
