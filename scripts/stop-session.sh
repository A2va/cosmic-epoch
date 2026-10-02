#!/usr/bin/env bash
# stop-session.sh — stop the COSMIC session in the running dev container
# (cosmic-dev or cosmic-tty). Default: kill the session's processes only —
# the container itself keeps running. --rm: stop and remove the containers.
# Inside the container the session target is stopped directly, like
# scripts/inside-dm.sh does (--rm is ignored there — you're inside it).
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh

rm_container=false
for a in "$@"; do
    case "$a" in
        --rm) rm_container=true ;;
        *) die "unknown argument: $a (usage: stop-session.sh [--rm])" ;;
    esac
done

# Stop every cosmic-* process inside a cgroup-v2 subtree — and ONLY there.
# The tty container runs --pid=host, so a plain `pkill -u <uid>` would also
# match the HOST's own cosmic processes (e.g. a real COSMIC desktop running
# as the same uid); the container's cgroup subtree is the exact "inside this
# container" boundary. cgroup.procs lists only direct members, so recurse
# into sub-cgroups (the systemd dev container keeps the session under
# user@1000.service sub-scopes). Self-contained: runs via eval or exec.
#
# Graceful FIRST: SIGTERM cosmic-session (it tears down cosmic-comp cleanly,
# and a cleanly exiting comp restores the KMS/CRTC state it saved at takeover).
# A bare SIGKILL skips that restore and leaves the kernel's last committed
# gamma/CTM in place — display-wide washed-out colors on the host until
# reboot. 5s grace, then SIGKILL stragglers.
kill_tree_sn='
cg="$(sed -n "s/^0:://p" /proc/$$/cgroup)"
[ -n "$cg" ] || { echo "no cgroup v2 path for pid $$ — refusing an unscoped kill" >&2; exit 1; }
list_cosmic() {
    local d="/sys/fs/cgroup$1" p sub
    [ -r "$d/cgroup.procs" ] || return 0
    while read -r p; do
        case "$(cat "/proc/$p/comm" 2>/dev/null)" in cosmic-*) echo "$p" ;; esac
    done < "$d/cgroup.procs"
    for sub in "$d"/*/; do
        [ -d "$sub" ] && list_cosmic "${sub#/sys/fs/cgroup}"
    done
}
for p in $(list_cosmic "$cg"); do
    [ "$(cat /proc/$p/comm 2>/dev/null)" = cosmic-session ] && kill -TERM "$p" 2>/dev/null || true
done
for _ in $(seq 1 50); do
    [ -z "$(list_cosmic "$cg")" ] && break
    sleep 0.1
done
for p in $(list_cosmic "$cg"); do
    kill -KILL "$p" 2>/dev/null || true
done
'

# systemd dev container teardown: polite target stop first, then stragglers
# via the cgroup sweep; display-manager.service is a symlink to
# cosmic-greeter.service (baked in the image), so stopping it also tears down
# greetd on a real-VT (tty-dm) run. Identical inside and via runtime exec.
stop_session='
    sudo -u dev env XDG_RUNTIME_DIR=/run/user/1000 \
            DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
            systemctl --user stop cosmic-session.target 2>/dev/null || true
'"$kill_tree_sn"'
    if [ -e /etc/systemd/system/display-manager.service ]; then
        sudo systemctl stop display-manager.service 2>/dev/null || true
    fi
    echo "cosmic session stopped"
'

if in_container; then
    [ "$rm_container" = true ] && echo "--rm ignored inside the container (stop it from the host)" >&2
    eval "$stop_session"
else
    rt="$(runtime)"
    rt_cmd=("$rt")
    # Rootful cosmic-dev (tty-dm leftovers) lives in sudo podman's store.
    # sudo -n: probe only — never block on a password prompt.
    if ! "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev \
        && [ "$rt" = podman ] \
        && sudo -n podman ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev; then
        rt_cmd=(sudo podman)
    fi

    found=false
    if "${rt_cmd[@]}" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-dev; then
        found=true
        "${rt_cmd[@]}" exec cosmic-dev bash -c "$stop_session"
        echo "cosmic-dev kept running (mise run stop --rm removes it)"
    fi
    if "$rt" ps --format '{{.Names}}' 2>/dev/null | grep -qx cosmic-tty; then
        found=true
        # No systemd here — sweep via exec: the exec process lands in the
        # container's cgroup, which scopes the kill (see kill_tree_sn).
        rc=0
        "$rt" exec cosmic-tty bash -c "$kill_tree_sn" || rc=$?
        # de mode: PID 1 is cosmic-session (exec chain) → the container goes
        # Exited and the teardown SIGKILLs the exec'd sweeper itself (rc≠0 is
        # success); shell mode: idle bash keeps it Up.
        st="$("$rt" inspect -f '{{.State.Status}}' cosmic-tty 2>/dev/null || true)"
        if [ "$rc" -ne 0 ] && [ "$st" = running ]; then
            echo "warning: cosmic-tty sweep failed — session may still be running" >&2
        fi
        case "$st" in
            running) echo "cosmic-tty kept running (podman attach cosmic-tty)" ;;
            *)       echo "cosmic-tty exited (podman start cosmic-tty restarts it)" ;;
        esac
    fi
    [ "$found" = true ] || die "no running cosmic-dev/cosmic-tty container (and not inside one)"

    if [ "$rm_container" = true ]; then
        "${rt_cmd[@]}" rm -f cosmic-dev 2>/dev/null || true
        "$rt" rm -f cosmic-tty 2>/dev/null || true
        echo "containers removed (if they existed)"
    fi
fi
