#!/bin/bash
# /opt/remora/scale-watcher.sh
#
# Dynamic thread-count scaler for xmrig (RandomX / Monero, NUMA-aware).
# Reads /proc/loadavg, maps EXTERNAL load-per-logical-core → target
# thread count, and edits /opt/remora/xmrig.json in place — xmrig's
# `watch: true` then picks up the file change via inotify and reloads
# its CPU config.
#
# "External" load = loadavg - our_modelled_self_contribution.  Naive
# subtraction (loadavg - current_thread_count) overestimates external
# load for ~1 min after every scale change, because loadavg is a
# 60s-tau EWMA and lags reality.  We model self-load with the SAME
# EWMA shape so the subtraction stays valid through transitions —
# otherwise a single external-load bump cascade-scales-down.
#
# Intensity knob: /opt/remora/intensity (single-word file) selects from
# barely|less|normal|more|extreme.  Re-read every sample; the file is
# wheel-writable so wheel members can flip it without doas:
#     echo extreme > /opt/remora/intensity
#
# Filesystem-based instead of HTTP-API based because the API approach
# can't survive oniux's network namespace: oniux force-routes ALL TCP
# (localhost included) through tor's SOCKS5 proxy, which makes the
# watcher → xmrig API call return SOCKS5 errors even when both
# processes live in the same netns.  Disk reads/writes cross the netns
# boundary cleanly.

set -euo pipefail

CONFIG_FILE="/opt/remora/xmrig.json"
INTENSITY_FILE="/opt/remora/intensity"
DEFAULT_INTENSITY="normal"
SAMPLE_SECS=30
# tau for the /proc/loadavg 1-min row.  Used to decay our self-load
# model in lockstep with the signal we're subtracting from.
LOAD_TAU_SECS=60
# Require N consecutive samples in a new tier before scaling.  Absorbs
# single-sample boundary noise (e.g. loadavg crossing a tier line once
# then settling back).
HYSTERESIS_SAMPLES=2

CORES=$(nproc)

read_intensity() {
    local val=""
    if [ -r "$INTENSITY_FILE" ]; then
        val=$(tr -d '[:space:]' < "$INTENSITY_FILE" 2>/dev/null \
              | tr '[:upper:]' '[:lower:]')
    fi
    case "$val" in
        barely|less|normal|more|extreme) echo "$val" ;;
        *)                               echo "$DEFAULT_INTENSITY" ;;
    esac
}

# Map a named intensity to (LOAD_TIERS, THREAD_PCTS).  THREAD_PCTS are
# percentages of `nproc` and LOAD_TIERS are per-logical-core, so both
# scale automatically across hosts.  Sample output:
#                       nproc=12          nproc=16
#     barely:           4 /  2 / 1 / 0    5 /  2 / 1 / 0
#     less:             6 /  4 / 2 / 0    8 /  5 / 2 / 0
#     normal:          10 /  6 / 3 / 0   13 /  8 / 4 / 0
#     more:            12 /  8 / 4 / 0   16 / 10 / 5 / 0
#     extreme:         12 / 10 / 6 / 0   16 / 13 / 8 / 0
#
# Cache architecture (L3 size vs RandomX scratchpad) is the remaining
# non-portable axis — on a CPU with much smaller L3-per-thread the
# upper tiers may need dialing back; with more L3 you can push harder.
# extreme tolerates ~5× the external load of barely before yielding
# its top tier.
set_tiers_for_intensity() {
    case "$1" in
        barely)  LOAD_TIERS=(0.10 0.30 0.60); THREAD_PCTS=( 34 17  9 0) ;;
        less)    LOAD_TIERS=(0.15 0.40 0.70); THREAD_PCTS=( 50 34 17 0) ;;
        normal)  LOAD_TIERS=(0.25 0.55 0.85); THREAD_PCTS=( 84 50 25 0) ;;
        more)    LOAD_TIERS=(0.40 0.75 1.00); THREAD_PCTS=(100 67 34 0) ;;
        extreme) LOAD_TIERS=(0.60 1.00 1.50); THREAD_PCTS=(100 84 50 0) ;;
    esac
}

pick_pct() {
    local lpc=$1 i=0
    for t in "${LOAD_TIERS[@]}"; do
        if awk -v x="$lpc" -v thr="$t" 'BEGIN{ exit !(x < thr) }'; then
            echo "${THREAD_PCTS[$i]}"
            return
        fi
        i=$((i+1))
    done
    echo "${THREAD_PCTS[$i]}"
}

# Seed prev_intensity first so THREAD_PCTS is populated for the
# fallback path below.
prev_intensity=$(read_intensity)
set_tiers_for_intensity "$prev_intensity"

# Seed prev_count and self_load from the rendered config.  xmrig is
# already running by the time the watcher starts (launcher.sh forks
# xmrig first), so loadavg already reflects xmrig's contribution —
# starting self_load=0 would attribute all of loadavg to "external"
# load on the first samples and scale down to 0 within one hysteresis
# window.
#
# If cpu.rx isn't a clean integer (it's `true` on a freshly-rendered
# config, or an affinity array if xmrig's autosave wrote back), guess
# the intensity's top tier and force-write it.  Without that force-
# write, xmrig's actual thread count and the watcher's model would
# mismatch and the main loop's `target == prev_count` short-circuit
# would keep them misaligned indefinitely.
prev_count=$(jq -r 'if (.cpu.rx | type) == "number" then .cpu.rx else -1 end' \
             "$CONFIG_FILE" 2>/dev/null || echo -1)
if [ "$prev_count" -le 0 ]; then
    prev_count=$(awk -v c="$CORES" -v p="${THREAD_PCTS[0]}" \
        'BEGIN{ printf "%d", c * p / 100 }')
    # Wait for xmrig to reach READY before triggering a config-change
    # reload.  A reload during xmrig's startup bails with "cpu disabled
    # (no suitable configuration found)" and falls back to the
    # originally-read config, ignoring our intended cpu.rx.  20 s
    # covers pool-connect (~5 s) plus randomx dataset init (~8 s on
    # typical CPUs).
    sleep 20
    tmp=$(mktemp)
    if jq --argjson rx "$prev_count" '.cpu.rx = $rx' "$CONFIG_FILE" > "$tmp"; then
        cat "$tmp" > "$CONFIG_FILE"
        echo "$(date -Is) [initial] cpu.rx wasn't numeric — wrote $prev_count for intensity=$prev_intensity"
    fi
    rm -f "$tmp"
fi
self_load=$prev_count
pending_count=-1
pending_streak=0

while true; do
    intensity=$(read_intensity)
    if [ "$intensity" != "$prev_intensity" ]; then
        echo "$(date -Is) intensity: $prev_intensity → $intensity"
        prev_intensity=$intensity
        # Clear pending — old hysteresis vote was for the old tier table.
        pending_count=-1
        pending_streak=0
    fi
    set_tiers_for_intensity "$intensity"

    load=$(awk '{print $1}' /proc/loadavg)
    threads=$(( prev_count > 0 ? prev_count : 0 ))

    # Advance our self-load EWMA one tick, matching kernel loadavg shape.
    self_load=$(awk -v p="$self_load" -v n="$threads" \
                    -v dt="$SAMPLE_SECS" -v tau="$LOAD_TAU_SECS" \
        'BEGIN{ d = exp(-dt / tau); printf "%.4f", p * d + n * (1 - d) }')
    external=$(awk -v l="$load" -v s="$self_load" \
        'BEGIN{ x = l - s; printf "%.2f", (x < 0 ? 0 : x) }')
    lpc=$(awk -v l="$external" -v c="$CORES" 'BEGIN{ printf "%.2f", l / c }')
    pct=$(pick_pct "$lpc")
    target=$(awk -v c="$CORES" -v p="$pct" 'BEGIN{ printf "%d", c * p / 100 }')

    if [ "$target" -eq "$prev_count" ]; then
        pending_count=-1
        pending_streak=0
    elif [ "$target" -eq "$pending_count" ]; then
        pending_streak=$((pending_streak + 1))
    else
        pending_count=$target
        pending_streak=1
    fi

    if [ "$target" -ne "$prev_count" ] && [ "$pending_streak" -ge "$HYSTERESIS_SAMPLES" ]; then
        # Edit cpu.rx in place.  jq → tmpfile → cat-truncate so the
        # inode is preserved (perms stay remora:wheel 0640) and xmrig's
        # inotify watcher sees IN_CLOSE_WRITE after we finish.
        tmp=$(mktemp)
        if jq --argjson rx "$target" '.cpu.rx = $rx' "$CONFIG_FILE" > "$tmp"; then
            cat "$tmp" > "$CONFIG_FILE"
            echo "$(date -Is) [$intensity] load=$load self=$self_load ext/lcore=$lpc → $pct% → $target threads"
            prev_count=$target
            pending_count=-1
            pending_streak=0
        else
            echo "$(date -Is) jq failed; keeping prev_count=$prev_count" >&2
        fi
        rm -f "$tmp"
    fi

    sleep "$SAMPLE_SECS"
done
