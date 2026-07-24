#!/usr/bin/env bash
#
# set-storage-mtu.sh
#
# Sets MTU 9000 on the VLAN 20 interface of the three worker nodes.
#
# Does not currently affect Longhorn. VLAN 20 was provisioned for storage
# replication, but Longhorn's `storage-network` is unset, so replication rides
# VLAN 10 (enp6s18) over the flannel VXLAN overlay. Measured 2026-07-14: during a
# 1 GiB write a remote replica received 659 MB on VLAN 10 and 0 on VLAN 20. See
# docs/benchmarks/storage-replication/2026-07-14-results.md. Kept because --check
# and the jumbo-frame verification validate the VLAN 20 path on their own, and
# because it becomes relevant once VLAN 20 is wired up (Longhorn `storage-network`
# plus a Multus NetworkAttachmentDefinition).
#
# MTU 9000 is delivered from above: the CRS305 (ports + bridge) and the Proxmox
# hosts' /etc/network/interfaces (ifupdown, where the vmbr bridge MTU lives).
# Guests inherit it from the hypervisor NIC. The interface therefore already reads
# 9000, so the idempotency check short-circuits and the netplan write never runs -
# correct, but it means this script does not hold the MTU, and guests have no
# backstop if the Proxmox side is reset or a VM rebuilt.
#
# MTU must agree across every hop. Three layers:
#
#   1. CRS305 switch ports      MikroTik CLI, not this script
#   2. Proxmox bridge / VLAN    on the hosts, not this script
#   3. Guest interface          this script
#
# This script does layer 3 only. Run before the other two and the workers emit
# 9000-byte frames onto a path that cannot carry them. The failure mode warrants
# care: nothing errors or logs; oversized frames are silently dropped or
# fragmented, TCP backs off, and the only symptom is slower Longhorn rebuilds. A
# half-applied MTU change is worse than none because it looks fine. So: switch
# first, then hosts, then this, verifying each layer before the next.
#
# Only the workers hold Longhorn replicas, so only they would carry replication if
# it moved onto VLAN 20. The control plane nodes have VLAN 20 addresses that
# nothing uses, and are left alone here.
#
# Idempotent. Safe to run repeatedly.
#
# Usage:
#   ./set-storage-mtu.sh --check     # report current MTU, change nothing
#   ./set-storage-mtu.sh --apply     # set MTU 9000 and verify
#
set -uo pipefail

SSH_USER=k3s
TARGET_MTU=9000

# Workers only: they hold Longhorn replicas, and would carry replication if it
# ever moved onto VLAN 20.
WORKERS="
10.0.10.60
10.0.10.61
10.0.10.62
"

SSH_OPTS="
-o ConnectTimeout=5
-o BatchMode=yes
-o ControlMaster=auto
-o ControlPath=/tmp/storage-mtu-%r@%h:%p
-o ControlPersist=60s
"

run() {
    ssh $SSH_OPTS "$SSH_USER@$NODE" "$1"
}

MODE="${1:-}"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--apply" ]; then
    echo "usage: $0 --check | --apply"
    echo
    echo "  --check   report the current MTU on each worker, change nothing"
    echo "  --apply   set MTU $TARGET_MTU, then verify a large frame crosses the path"
    exit 1
fi


# Find the interface holding this node's VLAN 20 address rather than assuming a
# name. Kernel-assigned interface names are not a contract.
storage_iface() {
    LAST_OCTET=$(echo "$NODE" | cut -d. -f4)
    run "ip -o addr show | awk '/10.0.20.$LAST_OCTET/ {print \$2}'"
}

current_mtu() {
    run "ip -o link show $IFACE" \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "mtu") print $(i + 1)}'
}


echo "Storage network MTU - $(date '+%Y-%m-%d %H:%M')"
echo "Target: $TARGET_MTU"


if [ "$MODE" = "--check" ]; then
    echo
    for NODE in $WORKERS; do
        IFACE=$(storage_iface)
        echo "  $NODE  $IFACE  mtu $(current_mtu)"
    done

    echo
    echo "The switch and the Proxmox bridge must also be at $TARGET_MTU."
    echo "This only reports the guest side."
    exit 0
fi


# --apply from here.

echo
echo "This changes the guest interface only. Confirm the CRS305 ports and the"
echo "Proxmox bridges are already at $TARGET_MTU before continuing."
echo
read -r -p "Are both upstream layers set to $TARGET_MTU? (yes/no) " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Stopping. Set the switch and the hosts first."
    exit 1
fi


for NODE in $WORKERS; do
    echo
    echo "=== $NODE ==="

    IFACE=$(storage_iface)

    if [ -z "$IFACE" ]; then
        echo "  no VLAN 20 address on this node - skipped"
        continue
    fi

    BEFORE=$(current_mtu)
    echo "  interface: $IFACE"
    echo "  before:    $BEFORE"

    if [ "$BEFORE" = "$TARGET_MTU" ]; then
        echo "  already at $TARGET_MTU, nothing to do"
        continue
    fi

    # Set at runtime first: effective immediately, survives until reboot, enough
    # to test the path before persisting. If the switch is not carrying jumbo
    # frames, the test below fails with nothing written to disk.
    run "sudo ip link set $IFACE mtu $TARGET_MTU"

    AFTER=$(current_mtu)
    echo "  after:     $AFTER"

    if [ "$AFTER" != "$TARGET_MTU" ]; then
        echo "  FAILED to set MTU - the interface refused it"
        continue
    fi

    # Persist it: netplan owns interface config on Ubuntu, and a runtime ip link
    # change does not survive reboot. A separate file, not an edit to the
    # installer's, keeps the change isolated and obvious.
    run "sudo tee /etc/netplan/99-storage-mtu.yaml >/dev/null <<EOF
# Managed by set-storage-mtu.sh
#
# Jumbo frames on the VLAN 20 segment. Must match the CRS305 port MTU and the
# Proxmox bridge MTU. If they disagree, throughput collapses silently.
#
# NB: VLAN 20 is not currently Longhorn's replication path — replication runs on
# VLAN 10. This file tunes the segment for if/when that changes.
network:
  version: 2
  ethernets:
    $IFACE:
      mtu: $TARGET_MTU
EOF"

    run "sudo chmod 600 /etc/netplan/99-storage-mtu.yaml"
    run "sudo netplan apply"

    echo "  persisted to /etc/netplan/99-storage-mtu.yaml"
done


# Setting the interface MTU only says what the interface will send, not whether
# the path can carry it. Test it: ping with a payload that fills a jumbo frame and
# forbid fragmentation. If any hop is still at 1500 the packet is too big to
# forward, cannot be split, and is dropped. A passing ping is the only evidence
# all three layers agree.
#
# 8972 = 9000 minus 20 bytes IP header and 8 bytes ICMP header.
echo
echo "================================================================"
echo "  Verifying the path carries jumbo frames"
echo "================================================================"

PAYLOAD=8972
FAILED=0

for NODE in $WORKERS; do
    LAST_OCTET=$(echo "$NODE" | cut -d. -f4)
    SOURCE="10.0.20.$LAST_OCTET"

    echo
    echo "from $SOURCE:"

    for PEER_OCTET in 60 61 62; do
        PEER="10.0.20.$PEER_OCTET"
        [ "$PEER" = "$SOURCE" ] && continue

        # -M do sets the do-not-fragment bit. -s sets the payload size.
        if run "ping -c1 -W2 -M do -s $PAYLOAD $PEER" >/dev/null 2>&1; then
            echo "  $PEER: jumbo frames OK"
        else
            echo "  $PEER: FAILED - something on this path is still at 1500"
            FAILED=$((FAILED + 1))
        fi
    done
done

echo
echo "================================================================"

if [ "$FAILED" -eq 0 ]; then
    echo "All VLAN 20 paths carry $TARGET_MTU."
    echo
    echo "Note: this does not change Longhorn today. Longhorn replicates over"
    echo "VLAN 10, not VLAN 20 (storage-network is unset). See the header."
    exit 0
fi

echo "$FAILED path(s) failed."
echo
echo "The guest interfaces are set, but something upstream is not. Check the"
echo "CRS305 port MTU and the Proxmox bridge MTU. Until those match, replication"
echo "is slower than before, not faster."
exit 1
