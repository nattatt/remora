# remora

Self-contained xmrig wrapper that routes mining traffic through Tor (via
oniux) and yields CPU to other workloads automatically.

Supports OpenRC, systemd, and runit; `setup.sh` auto-detects the init
system and installs the appropriate service from `init/`.

xmrig runs as an unprivileged system user inside oniux's network namespace;
all traffic — including pool connections — goes through Tor's SOCKS5 proxy.
A companion watcher process reads `/proc/loadavg`, computes the *external*
load on the machine (subtracting xmrig's own contribution), and adjusts
xmrig's thread count via `cpu.rx` in the config file.  xmrig's `watch: true`
reloads on file change, so scaling happens without a process restart.

## Dependencies

**xmrig** ([github.com/xmrig/xmrig](https://github.com/xmrig/xmrig)) — the
RandomX miner.  Compile for your target architecture and place the binary at
`bin/xmrig`.  remora was developed against v6.26.0; other recent versions
should work.

**oniux** ([gitlab.torproject.org/tpo/core/oniux](https://gitlab.torproject.org/tpo/core/oniux))
— runs a command inside a new network namespace backed by a Tor SOCKS5 proxy,
so all of xmrig's traffic exits through Tor without any application-level
configuration.  A running `tor` daemon must be reachable on the host.
Compile and place the binary at `bin/oniux`.

**Alpine Linux + OpenRC** — the init system and package tooling (`apk`,
`doas`, `rc-service`) are assumed throughout.  The scripts are portable sh
but the service lifecycle (`remora.init`) is OpenRC-specific.

**jq, bash** — `scale-watcher.sh` requires bash (uses arrays); `jq` is used
by both the watcher and `setup.sh` to read/write `xmrig.json`.

**shadow-subids** — oniux creates user namespaces, which requires the calling
user to have a `subuid`/`subgid` range allocated.  Alpine's `adduser -S`
doesn't allocate one automatically; `setup.sh` handles it and prompts to
install `shadow-subids` if `/etc/subuid` is absent.

**msr-tools** (optional) — provides `wrmsr`/`rdmsr` for the RandomX CPU MSR
tunings applied by `randomx-msr.sh` at service start.  Gains ~5–15 %
hashrate on Zen 2/3/4 and Intel; setup.sh prompts to install it.

## Layout

```
remora/
├── bin/
│   ├── README                 where to get / how to build the binaries
│   ├── xmrig                  place compiled xmrig here
│   └── oniux                  place compiled oniux here
├── cpu-freq.sh                CPU frequency helper (optional underclock)
├── install.sh                 copies bundle → /opt/remora then runs setup.sh
├── launcher.sh                netns entry point: forks xmrig + scale-watcher
├── randomx-msr.sh             writes RandomX MSR tunings as root at start_pre
├── remora.init                OpenRC service
├── scale-watcher.sh           reads load, edits cpu.rx in xmrig.json
├── setup.sh                   interactive idempotent configurator
└── xmrig.template.json        rendered to xmrig.json at setup time
```

## Installation

```sh
# on the machine that has the bundle:
tar -czf /tmp/remora-bundle.tar.gz -C /opt/bench remora
scp /tmp/remora-bundle.tar.gz <target>:/tmp/

# on target:
doas tar --no-same-owner -xzf /tmp/remora-bundle.tar.gz -C /opt/bench
doas sh /opt/bench/remora/install.sh
```

`install.sh` copies bundle files into `/opt/remora` then execs `setup.sh`,
which prompts for wallet / pool / rig-id / intensity / target difficulty /
underclock % and installs the OpenRC service.

To redeploy after editing bundle files: `doas sh /opt/bench/remora/install.sh`
(the drift guard in `setup.sh` ensures `/opt/remora` always matches the bundle
before re-rendering).

## How it works

1. `install.sh` copies canonical files from the bundle into `/opt/remora`
   (`cp -p`, modes preserved) and execs `setup.sh`.
2. `setup.sh` prompts for runtime values, creates the `remora` system user,
   allocates subuid/subgid (oniux needs these for user namespaces), renders
   `xmrig.json` from the template, writes the intensity file, installs the
   OpenRC init script.  Drift-guarded: refuses (exit 3) if any bundled input
   differs between `/opt/bench/remora` and `/opt/remora`; the error prints
   exact `cp` commands to sync.
3. `rc-service remora start` → `remora.init` invokes `oniux launcher.sh`
   under `supervise-daemon` as the `remora` user.
4. `launcher.sh` forks xmrig and `scale-watcher.sh` as siblings inside
   oniux's netns.  `start_pre` runs an orphan sweep (see Design constraints),
   applies RandomX MSR tunings (`randomx-msr.sh`), and optionally underclocks
   the CPU (`cpu-freq.sh`).
5. `scale-watcher.sh` reads `/proc/loadavg` every 30 s, subtracts an
   EWMA-modelled estimate of xmrig's own contribution, maps the remaining
   external-load-per-logical-core to a target thread count, and writes
   `cpu.rx` to `xmrig.json` once the same target holds for two consecutive
   samples (hysteresis).  Intensity and tier breakpoints come from
   `/opt/remora/intensity` (re-read every sample).
6. `stop_post` runs the same orphan sweep, then releases the underclock.

## Intensity knob

`/opt/remora/intensity` (single-word file, `remora:wheel 0664`) selects how
aggressively the watcher claims CPU.  Re-read every sample (~30 s lag); no
service restart needed.  The file is wheel-writable:

```sh
echo extreme > /opt/remora/intensity
```

| level   | top tier | mid | low | external-load tolerance     |
|---------|---------:|----:|----:|-----------------------------|
| barely  |        4 |   2 |   1 | very low — yields early     |
| less    |        6 |   4 |   2 | low                         |
| normal  |       10 |   6 |   3 | medium *(default)*          |
| more    |       12 |   8 |   4 | high                        |
| extreme |       12 |  10 |   6 | very high — barely yields   |

Thread counts above are for a 12-logical-core CPU.  `THREAD_PCTS` in
`scale-watcher.sh` are percentages of `nproc`, so counts scale
automatically on other hardware; `LOAD_TIERS` are per-logical-core and
scale the same way.  Cache architecture (L3 size vs RandomX's 2.25 MB
scratchpad) is the remaining non-portable axis — tune `normal` empirically
on a new CPU class and the other levels fan out from there.

A shell wrapper can expose `nudge {up|down|max|min}` subcommands by
reading and writing the file; see the example in `contrib/` if included.

## File permissions

- `xmrig.json`: `remora:wheel 0640` — `remora` user owns it (watcher
  edits `cpu.rx`); wheel can read for inspection without doas.
- `intensity`: `remora:wheel 0664` — wheel-writable for no-doas level changes.
- `xmrig.log`, `watcher.log`: `remora:wheel 0640` — pre-touched by setup so
  supervise-daemon's O_APPEND open doesn't reset perms to 0600.
- `bin/oniux`, `bin/xmrig`: `remora:remora 0755`, no file capabilities.
- `/opt/remora`: `remora:remora 0755`.

## What still needs work

1. **Watcher tier portability — cache architecture.**  Thread counts and
   load breakpoints scale with `nproc` automatically.  What doesn't scale is
   the *shape* of the tier table: the default percentages assume a
   bandwidth-bound workload (moderate L3, fast RAM).  On a CPU where RandomX
   is genuinely L3-cache-bound, the upper tiers may need dialing back.
   Re-validate `normal` empirically when deploying to a different CPU class.

## Design constraints

- **No file caps on `bin/oniux`.**  Setting `cap_net_admin` or
  `cap_sys_admin` triggers the kernel's AT_SECURE / secure-exec path, which
  breaks oniux's namespace creation with EPERM.  `kernel.unprivileged_userns_clone`
  (or equivalent) must be enabled; setup.sh checks this via subuid allocation.

- **oniux doesn't propagate SIGTERM to its children.**  supervise-daemon
  SIGTERMs oniux on stop; oniux exits but launcher.sh / xmrig / watcher
  reparent to init and keep running.  The pidfile goes stale, and the next
  `start` spawns a fresh tree alongside the orphan — two xmrigs competing on
  the same cores.  Both `start_pre` and `stop_post` run
  `pkill -9 -u remora -f /opt/remora` to prevent this.  Removing either
  sweep re-introduces the race.

- **xmrig's HTTP API is unreachable inside the netns.**  oniux routes all
  TCP — including 127.0.0.1 — through Tor's SOCKS5 proxy.  The watcher
  uses filesystem writes to `xmrig.json` instead of the API; this also
  crosses the netns boundary cleanly (unlike TCP).

- **`autosave: false` in the template is required.**  With `autosave: true`,
  xmrig rewrites `cpu.rx` from an integer to a CPU-affinity array whenever it
  autosaves.  The watcher seeds `prev_count` from `cpu.rx` at startup; if it
  finds an array rather than an integer it falls back to a top-tier guess and
  force-writes — which races with xmrig's own startup reload and can result
  in a silent "cpu disabled" failure.

- **Watcher uses an EWMA self-load model, not raw subtraction.**
  `loadavg - current_thread_count` overestimates external load for ~60 s
  after every scale change because `/proc/loadavg`'s 1-min row is a τ=60 s
  EWMA.  The watcher models self-load with the same decay constant so the
  subtraction stays valid through transitions.  Naive subtraction causes
  cascade scale-down: one external-load event triggers 10→8, then the still-
  high loadavg triggers 8→4, and so on.

- **Thread changes require 2 consecutive samples (hysteresis).**  A single
  loadavg sample crossing a tier boundary is often transient noise.
  Hysteresis absorbs it; removing it reintroduces rapid back-and-forth
  reloads at tier boundaries, each of which pauses hashing while xmrig
  re-initialises the RandomX VM.
