#!/usr/bin/env bash
# app.sh — run a built COSMIC binary/app as a window on the host compositor
# (mise task 'app'). Creates or reuses the systemd dev container.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

[ $# -ge 1 ] || die "usage: mise run app BINARY [args...]"

# Inside the container: run directly.
if [ -f /.dockerenv ] || [ -n "${container:-}" ]; then
    exec "$@"
fi

# Apps open windows — pointless from a VT without a compositor to nest into.
[ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ] \
    || die "app mode opens a window on the host compositor — run from a graphical shell"

ensure_dev_container
exec "${RT_CMD[@]}" exec -it "${EXEC[@]}" "$CTR" "$@"
