#!/bin/sh
# /opt/remora/cpu-freq.sh — set or release max CPU frequency on all cores.
#
# Usage:
#   cpu-freq.sh <percent>          # e.g. "90" — clamp scaling_max_freq
#                                  # to 90% of cpuinfo_max_freq on every
#                                  # cpu[0-9]+
#   cpu-freq.sh reset              # restore full speed (= cpuinfo_max_freq)
#   cpu-freq.sh release <applied>  # graceful partial restore on remora-stop:
#                                  # if applied < 50, set to applied*2
#                                  # (capped at 100); if applied >= 50,
#                                  # leave at applied.  E.g. 40% → 80% on
#                                  # stop; 90% stays at 90%.
#
# Auto-detects the hardware max from /sys/devices/system/cpu/cpu0/
# cpufreq/cpuinfo_max_freq, so this works unchanged across CPUs.  Must
# run as root; remora.init's start_pre/stop_post invoke it under
# OpenRC's root context regardless of the daemon's command_user.

set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "cpu-freq: must run as root" >&2
    exit 1
fi

mode=${1:-}
if [ -z "$mode" ]; then
    echo "usage: cpu-freq.sh <percent|reset|release <applied>>" >&2
    exit 2
fi

base_file=/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
if [ ! -r "$base_file" ]; then
    echo "cpu-freq: $base_file unreadable (cpufreq driver loaded?)" >&2
    exit 3
fi
base=$(cat "$base_file")

# Resolve final percent based on mode.
case "$mode" in
    reset)
        new_pct=100
        ;;
    release)
        applied=${2:-}
        case "$applied" in
            ''|*[!0-9]*)
                echo "cpu-freq: 'release' needs the applied percent as arg 2" >&2
                exit 2
                ;;
        esac
        if [ "$applied" -lt 50 ]; then
            new_pct=$(( applied * 2 ))
            [ "$new_pct" -gt 100 ] && new_pct=100
        else
            new_pct=$applied
        fi
        ;;
    *)
        case "$mode" in
            ''|*[!0-9]*) echo "cpu-freq: percent must be an integer" >&2; exit 2 ;;
        esac
        new_pct=$mode
        ;;
esac

target=$(( base * new_pct / 100 ))

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -f "$cpu/cpufreq/scaling_max_freq" ] || continue
    echo "$target" > "$cpu/cpufreq/scaling_max_freq"
done

echo "cpu-freq: scaling_max_freq set to $target kHz (= ${new_pct}% of $base kHz) on all cores"
