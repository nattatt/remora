#!/bin/sh
# /opt/remora/randomx-msr.sh
#
# Apply CPU MSR tunings that boost xmrig's RandomX hashrate (5–15 % on
# Zen 2 / Zen 3, less on Intel).  Run as root from remora.init's
# start_pre — xmrig itself runs as `remora` and can't write MSRs.
# Values mirror xmrig's official scripts/randomx_boost.sh; they vary
# by CPU family because the relevant MSR semantics changed across
# generations.
#
# Tolerant of missing dependencies: if `wrmsr` (msr-tools) isn't
# installed or the `msr` kernel module is unavailable, we log and exit
# 0 so the service still comes up — xmrig will just log "FAILED TO
# APPLY MSR MOD" and run with default settings.  setup.sh prompts to
# install msr-tools on first run.
#
# Unknown CPU vendor/family: no-op + warning.  Add a branch below if
# this bundle moves to a host with a different CPU.

set -eu

if ! command -v wrmsr >/dev/null 2>&1; then
    echo "randomx-msr: wrmsr not found — install msr-tools to enable RandomX boost" >&2
    exit 0
fi

# May be built-in on some kernels (modprobe then no-ops); not available
# on stripped kernels (modprobe fails — we log and bail).
if ! modprobe msr 2>/dev/null; then
    echo "randomx-msr: msr kernel module unavailable — skipping" >&2
    exit 0
fi

vendor=$(awk -F: '/^vendor_id/ { gsub(/[ \t]/,"",$2); print $2; exit }' /proc/cpuinfo)
family=$(awk -F: '/^cpu family/ { gsub(/[ \t]/,"",$2); print $2; exit }' /proc/cpuinfo)

case "$vendor:$family" in
    AuthenticAMD:23)
        # Zen / Zen+ / Zen 2 — Ryzen 1xxx / 2xxx / 3xxx / 4xxx.
        wrmsr -a 0xc0011020 0
        wrmsr -a 0xc0011021 0x40
        wrmsr -a 0xc0011022 0x1510000
        wrmsr -a 0xc001102b 0x2000cc16
        echo "randomx-msr: applied Zen/Zen+/Zen 2 values"
        ;;
    AuthenticAMD:25)
        # Zen 3 / early Zen 4 — Ryzen 5xxx / 7xxx.  If a future Zen
        # iteration needs different values, branch on stepping or
        # model below.
        wrmsr -a 0xc0011020 0x4480000000000
        wrmsr -a 0xc0011021 0x1c000200000040
        wrmsr -a 0xc0011022 0xc000000401570000
        wrmsr -a 0xc001102b 0x2000cc14
        echo "randomx-msr: applied Zen 3/4 values"
        ;;
    GenuineIntel:*)
        # Disable hardware prefetchers (MLC streamer + spatial + DCU
        # + IP); the RandomX scratchpad pattern defeats them anyway,
        # and they waste memory bandwidth.
        wrmsr -a 0x1a4 0xf
        echo "randomx-msr: applied Intel prefetcher-disable values"
        ;;
    *)
        echo "randomx-msr: unrecognized CPU $vendor family $family — leaving MSRs alone" >&2
        ;;
esac
