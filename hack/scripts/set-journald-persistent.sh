#!/usr/bin/env bash
#
# set-journald-persistent.sh
#
# Makes the systemd journal survive a reboot on every cluster node.
#
# Under Ubuntu's default Storage=auto, the journal persists only if
# /var/log/journal/ already exists, otherwise it lives in tmpfs and is erased on
# every boot. That directory exists on these nodes today, so persistence is
# accidental: nothing enforces it, and any rebuild that misses the directory
# reverts to a volatile journal.
#
# Persistence matters because the question is usually about the previous boot -
# why the node rebooted, whether it shut down cleanly. A volatile journal loses
# that record in the very reboot being investigated.
#
# Also caps the journal at MAX_USE; journald's default ceiling is 10% of the
# filesystem, several gigabytes here.
#
# Idempotent. Safe to run repeatedly.
#
# Usage:
#   ./set-journald-persistent.sh              # all nodes
#   ./set-journald-persistent.sh 10.0.10.60   # one node
#
set -uo pipefail

SSH_USER=k3s
MAX_USE=500M

NODES="
10.0.10.50
10.0.10.51
10.0.10.52
10.0.10.60
10.0.10.61
10.0.10.62
"

[ $# -gt 0 ] && NODES="$1"

SSH_OPTS="
-o ConnectTimeout=5
-o BatchMode=yes
-o ControlMaster=auto
-o ControlPath=/tmp/journald-%r@%h:%p
-o ControlPersist=60s
"

run() {
    ssh $SSH_OPTS "$SSH_USER@$NODE" "$1"
}


echo "Setting journald to persistent - $(date '+%Y-%m-%d %H:%M')"

for NODE in $NODES; do
    echo
    echo "=== $NODE ==="

    if ! run true 2>/dev/null; then
        echo "  UNREACHABLE - skipped"
        continue
    fi

    # Drop-in, not an edit to journald.conf: the packaged file is replaced on
    # upgrade, a drop-in survives and keeps the change in one obvious file.
    run "sudo mkdir -p /etc/systemd/journald.conf.d"

    run "sudo tee /etc/systemd/journald.conf.d/persistent.conf >/dev/null <<'EOF'
# Managed by set-journald-persistent.sh
#
# Storage=persistent writes the journal to /var/log/journal, creating the
# directory if absent rather than depending on it. Without this the journal, and
# the record of why the node rebooted, is lost on reboot.
[Journal]
Storage=persistent
SystemMaxUse=$MAX_USE
EOF"

    run "sudo systemctl restart systemd-journald"

    # Verify by where the journal actually lives, not what the config says: they
    # agree only if the restart took effect. Persistent is a directory under
    # /var/log/journal; volatile lives under /run/log/journal and is gone next boot.
    if run "sudo test -d /var/log/journal"; then
        SIZE=$(run "sudo du -sh /var/log/journal | cut -f1")
        BOOTS=$(run "sudo journalctl --list-boots --no-pager | wc -l")

        echo "  storage: persistent"
        echo "  size:    $SIZE (capped at $MAX_USE)"
        echo "  boots:   $BOOTS retained"
    else
        echo "  storage: STILL VOLATILE - the journal will not survive a reboot"
    fi
done

echo
echo "================================================================"
echo "Done."
echo
echo "Boots retained should be greater than 1. If it is 1, this node has no"
echo "record of any earlier boot, and it will build one from here on."
echo "================================================================"
