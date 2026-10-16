#!/usr/bin/env bash
# clean.sh — remove build artifacts of COSMIC components, from the host.
# Args = components or groups ('de'/'dm'); none = all (COMPONENTS_DE from
# mise.toml), like compile.sh/install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

# Remove $1/target. Fallback for root-owned leftovers: install.sh runs under
# sudo, so target/.debug-view symlinks etc. may be owned by the container's
# root — inside a rootless container that uid is unmapped on the host and
# even container-root can't remove it; do it from the host instead.
rm_target() {
    rm -rf "$1/target" 2>/dev/null && return 0
    if sudo -n rm -rf "$1/target" 2>/dev/null; then return 0; fi
    die "could not remove $1/target (owned by root from a sudo install; run 'sudo rm -rf $1/target' on the host)"
}

run_clean() {
    local c="$1"
    IFS=: read -r kind _ <<<"$(_layout "$c")"
    case "$kind" in
    just-cargo)
        # cargo clean chokes on root-owned .debug-view leftovers; fall back.
        if ! cargo clean --manifest-path "$c/Cargo.toml" 2>/dev/null && [ -e "$c/target" ]; then
            rm_target "$c"
        fi
        ;;
    just-data)  # data-only, no build step; drop any stray target/ anyway
        [ -e "$c/target" ] && rm_target "$c" || true
        ;;
    make)
        # `make clean` is what the component ships; absent = nothing to do.
        # A root-owned target/ (sudo install) may still be left: drop it too.
        if ! make -C "$c" clean >/dev/null 2>&1 && [ -e "$c/target" ]; then
            rm_target "$c"
        fi
        ;;
    esac
}

# 'de'/'dm' select the COMPONENTS_DE/DM sets from mise.toml, like compile.sh.
case " $* " in
    " de ") set -- $COMPONENTS_DE ;;
    " dm ") set -- $COMPONENTS_DM ;;
esac

for c in $(_collect "$@"); do
    log "clean: $c"
    run_clean "$c"
done
