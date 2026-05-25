#!/bin/sh
# /opt/bench/remora/install.sh
#
# Idempotent installer.  Copies the canonical bundle from this script's
# own directory into /opt/remora, then hands off to setup.sh to
# create the `remora` user, render xmrig.json, install the OpenRC
# service, and set perms.  Lives only in the bundle (not in /opt/remora)
# — re-running it is the right way to redeploy after editing bundle
# files, because it puts the install copy back in sync with the bundle
# (which is what setup.sh's drift guard expects).
#
# Usage:
#     doas sh /opt/bench/remora/install.sh
#
# Fresh-host workflow:
#     # on the machine that already has the bundle:
#     tar -czf /tmp/remora-bundle.tar.gz -C /opt/bench remora
#     scp /tmp/remora-bundle.tar.gz <host>:/tmp/
#     # on target:
#     doas tar --no-same-owner -xzf /tmp/remora-bundle.tar.gz -C /opt/bench
#     doas sh /opt/bench/remora/install.sh

set -eu

BUNDLE_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
TARGET_DIR=/opt/remora

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root (try: doas $0)" >&2
    exit 1
fi

if [ "$BUNDLE_DIR" = "$TARGET_DIR" ]; then
    echo "install.sh: bundle dir == target dir ($BUNDLE_DIR) — refusing." >&2
    echo "    Run this from the canonical bundle path (e.g. /opt/bench/remora)." >&2
    exit 1
fi

# Sanity-check the non-binary bundle files are present.
missing=""
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
    init/systemd/remora.service
do
    [ -f "$BUNDLE_DIR/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
    echo "install.sh: bundle at $BUNDLE_DIR is missing:" >&2
    # shellcheck disable=SC2086
    printf '   %s\n' $missing >&2
    exit 2
fi

mkdir -p "$TARGET_DIR/bin"

# cp -p preserves permissions (0755 for scripts, 0644 for the init,
# matching what the bundle ships).  We don't preserve ownership — the
# target file's owner is set by setup.sh's `chown -R remora:remora`
# step right after it creates the remora user.
for f in \
    setup.sh \
    launcher.sh \
    xmrig.template.json \
    scale-watcher.sh \
    cpu-freq.sh \
    randomx-msr.sh
do
    cp -p "$BUNDLE_DIR/$f" "$TARGET_DIR/$f"
done

cp -rp "$BUNDLE_DIR/init" "$TARGET_DIR/init"

# Binaries: prefer the bundled copy in bin/, fall back to PATH.
for b in xmrig oniux; do
    if [ -x "$BUNDLE_DIR/bin/$b" ]; then
        cp -p "$BUNDLE_DIR/bin/$b" "$TARGET_DIR/bin/$b"
    else
        sys=$(command -v "$b" 2>/dev/null || true)
        if [ -n "$sys" ] && [ -x "$sys" ]; then
            echo "install.sh: $b not in bin/, using system binary at $sys"
            cp "$sys" "$TARGET_DIR/bin/$b"
        else
            echo "install.sh: $b not found in bin/ or PATH" >&2
            echo "    See $BUNDLE_DIR/bin/README for build instructions." >&2
            exit 2
        fi
    fi
done

echo "install.sh: bundle copied from $BUNDLE_DIR to $TARGET_DIR"
echo "install.sh: handing off to setup.sh"
echo

exec sh "$TARGET_DIR/setup.sh"
