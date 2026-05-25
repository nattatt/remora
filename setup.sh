#!/bin/sh
# /opt/remora/setup.sh
#
# Idempotent configurator for the remora stack.
# Supports OpenRC (Alpine/Gentoo), systemd, and runit.
# Normally invoked by install.sh once the canonical bundle has been
# copied into /opt/remora; can also be run directly if the files are
# already in place.
#
# Steps (all idempotent):
#   1. Create `remora` system user (no login shell, home = /opt/remora).
#      Also allocates a subuid/subgid range — oniux needs one to create
#      user namespaces.  Prompts to install shadow-subids if missing,
#      and msr-tools if `wrmsr` isn't on PATH (optional, for RandomX
#      MSR boost via randomx-msr.sh).
#   2. Prompt for runtime values (wallet, pool, rig-id, intensity,
#      target difficulty, underclock %), defaulting to whatever's
#      already in the rendered config / on disk.  Hitting enter on
#      every prompt = re-render with the current values, nothing
#      changes.  Target difficulty pins the pool's vardiff via the
#      `WALLET+N` user-field convention — blank uses pool default.
#   3. Render xmrig.json from the template using those values.
#   4. Write /opt/remora/intensity and /etc/conf.d/remora.
#   5. Install init scripts and add to default runlevel.
#
# Before any of that, a drift guard compares /opt/bench/remora (canonical
# bundle) against /opt/remora and refuses to run if any of the bundled
# inputs (setup.sh, launcher.sh, watcher, template, init, binaries)
# differ — the install must match the bundle before re-rendering.

set -eu

REMORA_DIR=/opt/remora
BUNDLE_DIR=/opt/bench/remora
TEMPLATE=$REMORA_DIR/xmrig.template.json
RENDERED=$REMORA_DIR/xmrig.json
INTENSITY_FILE=$REMORA_DIR/intensity

if [ "$(id -u)" -ne 0 ]; then
    echo "setup.sh: must run as root (try: doas $0)" >&2
    exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
    echo "setup.sh: template missing at $TEMPLATE" >&2
    exit 1
fi

# ---- drift guard ----------------------------------------------------------
# The bundle at $BUNDLE_DIR is the canonical source; $REMORA_DIR is the
# install copy.  setup.sh renders from $REMORA_DIR/xmrig.template.json,
# not the bundle's, so if any canonical input has drifted between the
# two we'd re-render from a stale copy and silently propagate bugs.
# Refuse to run until the install matches the bundle.  Skip when
# invoked from the bundle directory itself (rare but valid: running
# setup.sh in-place).
if [ -d "$BUNDLE_DIR" ] && [ "$BUNDLE_DIR" != "$REMORA_DIR" ]; then
    drift_files=""
    for f in \
        setup.sh \
        launcher.sh \
        xmrig.template.json \
        scale-watcher.sh \
        cpu-freq.sh \
        randomx-msr.sh \
        init/openrc/remora.init \
        init/runit/run \
        init/runit/finish \
        init/systemd/remora.service \
        bin/xmrig \
        bin/oniux
    do
        [ -f "$BUNDLE_DIR/$f" ] || continue
        if ! cmp -s "$BUNDLE_DIR/$f" "$REMORA_DIR/$f" 2>/dev/null; then
            drift_files="$drift_files $f"
        fi
    done
    if [ -n "$drift_files" ]; then
        {
            echo "setup.sh: bundle vs install drift detected."
            echo
            echo "These files differ between $BUNDLE_DIR (canonical) and $REMORA_DIR:"
            for f in $drift_files; do
                printf '  %s\n' "$f"
            done
            echo
            echo "Sync with:"
            for f in $drift_files; do
                printf '  cp %s/%s %s/%s\n' "$BUNDLE_DIR" "$f" "$REMORA_DIR" "$f"
            done
            printf '  chown -R remora:remora %s\n' "$REMORA_DIR"
            echo
            echo "…or re-extract the bundle tarball over /, then re-run setup."
        } >&2
        exit 3
    fi
fi

# ---- helpers --------------------------------------------------------------
prompt() {
    # $1 = label, $2 = default value (may be empty)
    # echoes the user's response (or default if empty)
    label=$1
    default=$2
    if [ -n "$default" ]; then
        printf "%s [%s]: " "$label" "$default" >&2
    else
        printf "%s: " "$label" >&2
    fi
    read -r value </dev/tty
    if [ -z "$value" ]; then
        value=$default
    fi
    printf '%s' "$value"
}

get_existing_string() {
    # Pull a string-typed key from the rendered config, if it exists.
    [ -f "$RENDERED" ] || { printf ''; return; }
    awk -F'"' -v k="$1" '$0 ~ "\""k"\"[[:space:]]*:" {print $4; exit}' "$RENDERED"
}

# The pool's `user` field carries both the wallet and (optionally) a
# pinned vardiff: `WALLET+DIFFICULTY`.  Split for prompt defaults so
# round-tripping setup doesn't pollute the wallet prompt with the
# difficulty suffix.  Monero addresses are Base58 (no `+`), so first-
# `+` split is unambiguous.
get_existing_wallet() {
    raw=$(get_existing_string user)
    printf '%s' "${raw%%+*}"
}
get_existing_difficulty() {
    raw=$(get_existing_string user)
    case "$raw" in
        *+*) printf '%s' "${raw#*+}" ;;
        *)   printf '' ;;
    esac
}

get_existing_env_var() {
    # Read a KEY=value from whichever init-system env file exists.
    for _ef in /etc/conf.d/remora /etc/default/remora /etc/sv/remora/conf; do
        [ -f "$_ef" ] || continue
        awk -F= -v k="$1" '$1 == k { sub(/^"/, "", $2); sub(/"$/, "", $2); print $2; exit }' "$_ef"
        return
    done
}

detect_init() {
    if [ -d /run/systemd/system ]; then
        echo systemd
    elif [ -d /run/runit ] || [ -d /etc/runit/runsvdir ]; then
        echo runit
    elif command -v rc-service >/dev/null 2>&1; then
        echo openrc
    else
        echo unknown
    fi
}

get_existing_intensity() {
    # Pull the current intensity (single-word file, optional).
    [ -r "$INTENSITY_FILE" ] || { printf ''; return; }
    tr -d '[:space:]' < "$INTENSITY_FILE" 2>/dev/null \
        | tr '[:upper:]' '[:lower:]'
}

# ---- 1. remora user --------------------------------------------------------
if ! getent group remora >/dev/null; then
    addgroup -S remora
fi
if ! id remora >/dev/null 2>&1; then
    adduser -S -D -H -s /sbin/nologin -h "$REMORA_DIR" -G remora remora
fi

# ---- 1a. subuid / subgid for remora ----------------------------------------
# oniux creates a user namespace, which needs a subuid + subgid range
# allocated for the calling user.  `adduser -S` does NOT allocate one, so
# the namespace creation hits EPERM at runtime.
#
# Prerequisite: /etc/subuid and /etc/subgid must exist (on Alpine these
# come from the `shadow-subids` package).  Prompt to install if missing
# rather than silently failing later.
if [ ! -f /etc/subuid ] || [ ! -f /etc/subgid ]; then
    printf "setup: /etc/subuid or /etc/subgid missing.  Install shadow-subids now? [Y/n] " >&2
    read -r resp </dev/tty
    case "$resp" in
        n|N|no|NO)
            echo "setup: aborting — install shadow-subids manually and re-run" >&2
            exit 1
            ;;
        *)
            apk add --no-progress shadow-subids
            ;;
    esac
fi

# ---- 1b. msr-tools for RandomX boost --------------------------------------
# randomx-msr.sh writes CPU MSRs in remora.init's start_pre to enable
# xmrig's RandomX optimizations.  Needs the `wrmsr` binary from
# msr-tools.  Optional — without it, xmrig still mines, just logs
# "FAILED TO APPLY MSR MOD" and runs 5-15% slower.
if ! command -v wrmsr >/dev/null 2>&1; then
    printf "setup: msr-tools not installed (RandomX boost helper).  Install now? [Y/n] " >&2
    read -r resp </dev/tty
    case "$resp" in
        n|N|no|NO)
            echo "setup: skipping msr-tools — xmrig will log a MSR-mod warning at start"
            ;;
        *)
            apk add --no-progress msr-tools
            ;;
    esac
fi

# Allocate a 65536-uid range for remora if not already present.  Next slot
# after whatever's already mapped so we never collide with existing
# entries (other users' ranges, etc.).
next_subid_start() {
    awk -F: 'NF>=3 { e=$2+$3; if (e>max) max=e } END { print (max ? max : 100000) }' "$1"
}
if ! grep -q '^remora:' /etc/subuid; then
    start=$(next_subid_start /etc/subuid)
    echo "remora:$start:65536" >> /etc/subuid
    echo "setup: added remora subuid range $start-$((start + 65535))"
fi
if ! grep -q '^remora:' /etc/subgid; then
    start=$(next_subid_start /etc/subgid)
    echo "remora:$start:65536" >> /etc/subgid
    echo "setup: added remora subgid range $start-$((start + 65535))"
fi

# ---- 2. ownership on bundled binaries -------------------------------------
# oniux does NOT need file capabilities on this kernel — userns is
# enabled for unprivileged users, and adding caps actually breaks oniux
# (triggers AT_SECURE/secure-exec which sends oniux down a different
# code path that EPERMs).  Just plain perms.
mkdir -p "$REMORA_DIR" "$REMORA_DIR/bin"
chown -R remora:remora "$REMORA_DIR"
chmod 0755 "$REMORA_DIR" "$REMORA_DIR/bin"
chmod 0755 "$REMORA_DIR"/bin/xmrig         2>/dev/null || true
chmod 0755 "$REMORA_DIR"/bin/oniux         2>/dev/null || true
chmod 0755 "$REMORA_DIR"/cpu-freq.sh       2>/dev/null || true
chmod 0755 "$REMORA_DIR"/launcher.sh       2>/dev/null || true
chmod 0755 "$REMORA_DIR"/scale-watcher.sh 2>/dev/null || true
chmod 0755 "$REMORA_DIR"/randomx-msr.sh    2>/dev/null || true

# Strip any stale file caps from a prior setup run; their presence is
# what was breaking namespace creation.
if [ -f "$REMORA_DIR/bin/oniux" ]; then
    setcap -r "$REMORA_DIR/bin/oniux" 2>/dev/null || true
fi

# Pre-touch the log files + the watcher's status.json with remora:wheel
# + 0640 so when supervise-daemon opens the logs (O_APPEND) and the
# watcher truncates status.json (`>`), the existing inode perms are
# inherited and wheel members can read them without doas.  Without
# this, OpenRC creates them as 0600 remora:remora and you'd need doas
# to read them ever after.
for f in xmrig.log watcher.log; do
    touch "$REMORA_DIR/$f"
    chown remora:wheel "$REMORA_DIR/$f"
    chmod 0640        "$REMORA_DIR/$f"
done

# Also ensure the rendered config is remora-writable (the watcher edits
# cpu.rx in place to drive thread scaling) while staying wheel-readable.
if [ -f "$REMORA_DIR/xmrig.json" ]; then
    chown remora:wheel "$REMORA_DIR/xmrig.json"
    chmod 0640        "$REMORA_DIR/xmrig.json"
fi

# ---- 3. interactive prompts -----------------------------------------------
CUR_WALLET=$(   get_existing_wallet)
CUR_DIFFICULTY=$(get_existing_difficulty)
CUR_POOL=$(     get_existing_string url)
CUR_RIG=$(      get_existing_string rig-id)
CUR_INTENSITY=$(get_existing_intensity)
CUR_UNCLOCK=$(  get_existing_env_var UNCLOCK_PERCENT)
[ -z "$CUR_UNCLOCK"   ] && CUR_UNCLOCK=90
[ -z "$CUR_POOL"      ] && CUR_POOL=pool.supportxmr.com:443
[ -z "$CUR_RIG"       ] && CUR_RIG=$(hostname 2>/dev/null || echo "remora")
[ -z "$CUR_INTENSITY" ] && CUR_INTENSITY=normal

echo
echo "remora setup — press enter to accept the value in [brackets]."
echo

WALLET=$(   prompt "Monero wallet address"  "$CUR_WALLET")
POOL_URL=$( prompt "Pool URL"               "$CUR_POOL")
RIG_ID=$(   prompt "Rig ID / worker name"   "$CUR_RIG")
INTENSITY=$(prompt "Intensity (barely|less|normal|more|extreme)" "$CUR_INTENSITY")
DIFFICULTY=$(prompt "Target difficulty (blank = pool vardiff)" "$CUR_DIFFICULTY")
UNCLOCK_PERCENT=$(prompt "Underclock percent (blank = disable)" "$CUR_UNCLOCK")

if [ -z "$WALLET" ]; then
    echo "setup.sh: wallet address can't be blank" >&2
    exit 2
fi

case "$INTENSITY" in
    barely|less|normal|more|extreme) ;;
    *)
        echo "setup.sh: invalid intensity '$INTENSITY' — must be barely|less|normal|more|extreme" >&2
        exit 2
        ;;
esac

case "$DIFFICULTY" in
    "") ;;
    *[!0-9]*)
        echo "setup.sh: target difficulty must be a positive integer or blank" >&2
        exit 2
        ;;
esac

# Construct the pool `user` field.  Most Monero pools (snipa-style
# included) accept `WALLET+DIFFICULTY` to pin vardiff on connect,
# avoiding the post-restart ramp-up penalty.  Blank difficulty = bare
# wallet, pool falls back to its default vardiff.
if [ -n "$DIFFICULTY" ]; then
    POOL_USER="$WALLET+$DIFFICULTY"
else
    POOL_USER="$WALLET"
fi

# ---- 4. render xmrig.json -------------------------------------------------
# Escape sed metachars in values; the values shouldn't contain `|` but
# being defensive lets future "weird passwords" not break this.
esc() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

sed \
    -e "s|__WALLET__|$(esc "$POOL_USER")|g" \
    -e "s|__POOL_URL__|$(esc "$POOL_URL")|g" \
    -e "s|__RIG_ID__|$(esc "$RIG_ID")|g" \
    "$TEMPLATE" > "$RENDERED"
# remora:wheel + 0640 = readable by remora (the daemon) AND any sysadmin
# in wheel — that lets wheel members inspect cpu.rx / pool config without doas,
# without leaking it world-readable.
chown remora:wheel "$RENDERED"
chmod 0640        "$RENDERED"

# ---- 4a. intensity file ---------------------------------------------------
# Single-word file, mode 0664 so wheel members can flip it without
# doas: `echo extreme > /opt/remora/intensity`.  Watcher re-reads on every
# sample (~30s).
echo "$INTENSITY" > "$INTENSITY_FILE"
chown remora:wheel "$INTENSITY_FILE"
chmod 0664        "$INTENSITY_FILE"

# ---- 5. init-system env file + service install ----------------------------
INIT_SYS=$(detect_init)

case "$INIT_SYS" in
    openrc)
        mkdir -p /etc/conf.d
        cat > /etc/conf.d/remora <<EOF
# /etc/conf.d/remora — sourced by OpenRC before remora.init runs.
# Re-run /opt/remora/setup.sh to change (or edit then rc-service remora restart).
UNCLOCK_PERCENT=$UNCLOCK_PERCENT
EOF
        chmod 0644 /etc/conf.d/remora
        # Clean up any legacy separate-watcher service from older deploys.
        if [ -f /etc/init.d/remora-watcher ]; then
            rc-service remora-watcher stop 2>/dev/null || true
            rc-update del remora-watcher 2>/dev/null || true
            rm -f /etc/init.d/remora-watcher
        fi
        install -m 0755 "$REMORA_DIR/init/openrc/remora.init" /etc/init.d/remora
        rc-update add remora default 2>/dev/null || true
        START_CMD="rc-service remora start"
        ;;
    systemd)
        mkdir -p /etc/default
        cat > /etc/default/remora <<EOF
# /etc/default/remora — loaded by the remora systemd unit (EnvironmentFile=).
# Re-run /opt/remora/setup.sh to change (or edit then systemctl restart remora).
UNCLOCK_PERCENT=$UNCLOCK_PERCENT
EOF
        chmod 0644 /etc/default/remora
        install -m 0644 "$REMORA_DIR/init/systemd/remora.service" \
            /etc/systemd/system/remora.service
        systemctl daemon-reload
        systemctl enable remora
        START_CMD="systemctl start remora"
        ;;
    runit)
        mkdir -p /etc/sv/remora
        cat > /etc/sv/remora/conf <<EOF
# /etc/sv/remora/conf — sourced by the remora runit run script.
# Re-run /opt/remora/setup.sh to change (or edit then sv restart remora).
UNCLOCK_PERCENT=$UNCLOCK_PERCENT
EOF
        chmod 0644 /etc/sv/remora/conf
        install -m 0755 "$REMORA_DIR/init/runit/run"    /etc/sv/remora/run
        install -m 0755 "$REMORA_DIR/init/runit/finish" /etc/sv/remora/finish
        # Link into the live service directory if it exists.
        if [ -d /var/service ] && [ ! -e /var/service/remora ]; then
            ln -s /etc/sv/remora /var/service/remora
        fi
        START_CMD="sv start remora"
        ;;
    *)
        echo "setup: unrecognised init system — init scripts NOT installed." >&2
        echo "    Manually install the appropriate script from $REMORA_DIR/init/" >&2
        START_CMD="(install init script manually)"
        ;;
esac

# ---- done -----------------------------------------------------------------
echo
echo "setup: done."
echo "  init:           $INIT_SYS"
echo "  user:           remora ($(id -u remora):$(id -g remora)) -- shell /sbin/nologin"
echo "  data dir:       $REMORA_DIR"
echo "  rendered cfg:   $RENDERED"
echo "  intensity:      $INTENSITY  (edit $INTENSITY_FILE to change)"
echo "  pool user:      $POOL_USER"
echo "  difficulty:     ${DIFFICULTY:-pool vardiff}"
echo "  underclock:     ${UNCLOCK_PERCENT:-disabled}"
echo
echo "Start with:    $START_CMD"
