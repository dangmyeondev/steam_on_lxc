#!/bin/bash
# Timer-side idle checker: stop the headless display stack when nothing is
# streaming. Runs every minute via sunshine-display-idle.timer and only powers
# the stack down after several consecutive idle ticks, so quick Moonlight
# reconnects never flap the display.
#
# "Active" means any of:
#   - gamescope or steam running (game session)
#   - an established Sunshine control TCP session
#   - sunshine.log's latest CLIENT event is a CONNECTED (covers plain Desktop
#     streams, which may hold no Sunshine TCP after the RTSP handshake)
set -u

STATE_DIR="$HOME/.local/state"
COUNT_FILE="$STATE_DIR/display-idle-count"
LOG="$STATE_DIR/display-idle.log"
SUNSHINE_LOG="$HOME/.config/sunshine/sunshine.log"
GRACE_TICKS=3

mkdir -p "$STATE_DIR"

# "Is the display stack up?" must be answered by the X server itself: plain
# `systemctl is-active gaming-x.service` from this user goes through polkit
# and occasionally reports inactive in this LXC, which pinned the idle
# counter at 0 and the stack never shut down.
x_up() { xset -display :0 q >/dev/null 2>&1; }

if ! x_up; then
    echo 0 > "$COUNT_FILE"
    exit 0
fi

active=0
pgrep -x gamescope >/dev/null 2>&1 && active=1
pgrep -u "${USER:-sunshine}" -x steam >/dev/null 2>&1 && active=1
if ss -Htn state established 2>/dev/null | grep -qE ':(47984|47989|47990|48010)\b'; then
    active=1
fi

if [ "$active" -eq 0 ] && [ -r "$SUNSHINE_LOG" ]; then
    conn=$(grep -a "CLIENT CONNECTED" "$SUNSHINE_LOG" | tail -n1 \
           | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+' || true)
    disc=$(grep -a "CLIENT DISCONNECTED" "$SUNSHINE_LOG" | tail -n1 \
           | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+' || true)
    # ISO-style timestamps compare correctly as plain strings.
    if [ -n "$conn" ] && { [ -z "$disc" ] || [ "$conn" \> "$disc" ]; }; then
        active=1
    fi
fi

if [ "$active" -eq 1 ]; then
    echo 0 > "$COUNT_FILE"
    exit 0
fi

count=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$COUNT_FILE"
if [ "$count" -lt "$GRACE_TICKS" ]; then
    exit 0
fi

echo 0 > "$COUNT_FILE"
echo "$(date +%H:%M:%S) idle for ${GRACE_TICKS}m, stopping display stack" >> "$LOG"
systemctl --user stop input-bridge.service plasma-x11.service
sudo -n systemctl stop gaming-x.service || \
    echo "$(date +%H:%M:%S) WARN: sudo stop gaming-x failed" >> "$LOG"
