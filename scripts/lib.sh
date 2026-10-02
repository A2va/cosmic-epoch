# Shared shell helpers for the dev scripts (enter/compile/install/stop).
# Source, don't execute.
# ponytail: one flat sourced file; a real lib layout can wait until there's a
# second consumer of each helper.

# Container runtime: podman preferred (rootless, keep-id), docker fallback.
runtime() {
    command -v podman >/dev/null 2>&1 && { echo podman; return; }
    echo docker
}

# Running container check: "$1" = container name → rc 0 if running.
# Tries user store first, then the rootful store (sudo podman, tty-dm).
container_running() {
    local rt; rt="$(runtime)"
    if "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; then return 0; fi
    if [ "$rt" = podman ] && sudo podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; then return 0; fi
    return 1
}

_layout() {
    # $1 = component dir → print "<kind>:<profvar>".
    # kind: just-cargo | just-data | make | none. profvar: how debug=0|1 is spelled.
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
    # Resolve "$@" into component dirs; default to $COMPONENTS_DE (mise env).
    comps=""
    if [ $# -gt 0 ]; then comps="$*"; else comps="${COMPONENTS_DE:?COMPONENTS_DE not set (run via mise)}"; fi
    for c in $comps; do
        c="${c%/}" # autocomplete adds a trailing slash
        [ -d "$c" ] || { echo "skipping unknown component: $c" >&2; continue; }
        echo "$c"
    done
}
