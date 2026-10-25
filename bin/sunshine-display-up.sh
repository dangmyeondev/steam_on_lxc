#!/bin/bash
# Bring the headless display stack up right before Sunshine launches an app.
# Wired via global_prep_cmd in ~/.config/sunshine/sunshine.conf.
# Xorg (gaming-x.service) is root-owned, so this needs the sudoers rule
# installed by ~/staging/apply-display-split.sh.
set -u

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
STATE_DIR="$HOME/.local/state"
LOG="$STATE_DIR/display-up.log"
mkdir -p "$STATE_DIR"

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

x_ready() { xset -display "$DISPLAY" q >/dev/null 2>&1; }

# Activity marker: keeps the idle-stop timer from racing a just-connected client.
touch "$STATE_DIR/display-up.stamp"

if ! x_ready; then
    log "X not ready; starting gaming-x.service"
    if ! sudo -n systemctl start gaming-x.service; then
        log "ERROR: sudo systemctl start gaming-x.service failed"
        exit 1
    fi
    for _ in $(seq 1 40); do
        x_ready && break
        sleep 0.5
    done
    COLD_X=1
fi

if ! x_ready; then
    log "ERROR: X :0 still not ready after 20s"
    exit 1
fi

# KDE + input bridge boot in the background. The gamescope/Steam path owns the
# screen fullscreen and must not wait for a whole desktop session.
systemctl --user start input-bridge.service plasma-x11.service >>"$LOG" 2>&1 &

if [ "${COLD_X:-0}" = 1 ]; then
    # Sunshine enumerates displays at process start and never rescans. An
    # instance that came up while X was down has an empty display list and
    # 503s every stream, so this very connection cannot succeed: restart
    # Sunshine (via a 1s transient timer, outside our own cgroup) and let the
    # client retry, which then connects instantly to a healthy instance.
    systemd-run --user --on-active=1 --unit=sunshine-cold-restart \
        systemctl --user restart sunshine.service 2>>"$LOG" || true
    log "cold display start: sunshine restart scheduled; client should retry now"
else
    log "X already up; proceeding normally"
fi
exit 0
