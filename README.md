# remora

Opportunistic RandomX supervisor with automatic thread-count scaling.

Self-contained xmrig wrapper that auto-scales thread count to idle CPU,
backing off gracefully when the host has real work to do.
Supports **OpenRC**, **systemd**, and **runit**.

Mining traffic is routed through Tor via
[oniux](https://gitlab.torproject.org/tpo/core/oniux), which wraps the
miner in a private network namespace.  A companion watcher process
monitors system load and adjusts xmrig's thread count in real time —
spinning up to full speed when the host is idle and stepping back down
automatically when other workloads appear.

## Prerequisites

- **xmrig** — compile from [xmrig/xmrig](https://github.com/xmrig/xmrig),
  place binary at `bin/xmrig`
- **oniux** — compile from the
  [Tor Project](https://gitlab.torproject.org/tpo/core/oniux), place binary
  at `bin/oniux`; a running `tor` daemon must be reachable on the host
- Tested on OpenRC; systemd and runit scripts are included but
  untested — they should work as-is, but if not, PRs welcome
- `doas` configured for the installing user, `bash`, `jq`
- `shadow-subids` and optionally `msr-tools` — setup.sh will prompt to
  install if missing

## Getting started

```sh
# 1. Compile xmrig and oniux, put them in bin/
cp /path/to/xmrig bin/xmrig
cp /path/to/oniux bin/oniux

# 2. Bundle, copy to target, install
tar -czf /tmp/remora-bundle.tar.gz -C /opt/bench remora
scp /tmp/remora-bundle.tar.gz <target>:/tmp/

# on target:
doas tar --no-same-owner -xzf /tmp/remora-bundle.tar.gz -C /opt/bench
doas sh /opt/bench/remora/install.sh
```

`install.sh` copies files into `/opt/remora`, then runs `setup.sh`
interactively (wallet, pool URL, rig ID, intensity, optional target
difficulty, optional CPU underclock).  Press enter at each prompt to
accept the current value.

## Daily use

```sh
rc-service remora start
rc-service remora stop
rc-service remora restart
```

**Adjust mining intensity** by writing one word to `/opt/remora/intensity`
(no restart needed — picked up within ~30 s):

```sh
echo normal  > /opt/remora/intensity   # default: 10 threads on 12T CPU
echo more    > /opt/remora/intensity   # 12 threads, tolerates more load
echo extreme > /opt/remora/intensity   # holds at ceiling under high load
echo less    > /opt/remora/intensity   # 6 threads, backs off sooner
echo barely  > /opt/remora/intensity   # 4 threads, minimal footprint
```

**Pin pool difficulty** to avoid the post-restart vardiff ramp-up: re-run
setup after a session and enter the difficulty the pool settled on.  It is
appended to the wallet field as `WALLET+N`, which most snipa-style pools
accept.

## Further reading

See [SPEC.md](SPEC.md) for the full design — how the load-scaling algorithm
works, the intensity tier table, file permissions, and design constraints
(why no HTTP API, why both start_pre and stop_post sweep for orphans, etc.).

## License

[AGPL-3.0-or-later](LICENSE)
