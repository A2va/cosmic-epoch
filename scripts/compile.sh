#!/usr/bin/env bash
# compile.sh — build COSMIC components from the host (what was `just c`).
# Args = components; none = COMPONENTS_DE from mise.toml. DEBUG=0 for release.
# pop-launcher is built release-only: its CLI defines '-m' twice and clap's
# debug_assert panics on it in debug builds.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

d="${DEBUG:-1}"
[ "$d" = 0 ] || d=1

for c in $(_collect "$@"); do
    read -r kind profvar <<<"$(_layout "$c")"
    case "$kind" in
    just-cargo)
        prof="$d"; [ "$c" = pop-launcher ] && prof=0
        if [ "$prof" = 1 ]; then
            (cd "$c" && just build-debug)
        else
            (cd "$c" && just build-release)
        fi
        ;;
    just-data) ;; # data-only components have no build step
    make)      make -C "$c" "DEBUG=$d" all ;;
    esac
done
