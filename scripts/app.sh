#!/usr/bin/env bash
# app.sh — run a COSMIC app as a window on the host compositor (mise task
# 'app'). First arg is a component dir (cosmic-term, pop-launcher, ...) and is
# run with `cargo run` inside it, or any other command/binary path run as-is.
# DEBUG=0 runs release. Creates or reuses the systemd dev container.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

[ $# -ge 1 ] || die "usage: mise run app COMPONENT|BINARY [args...]"

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
    exec "${cmd[@]}"
fi

# Apps open windows — pointless from a VT without a compositor to nest into.
[ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] \
    || die "app mode opens a window on the host compositor — run from a graphical shell"

ensure_dev_container
exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" -w "/cosmic-epoch/$comp" "$CTR" "${cmd[@]}"
