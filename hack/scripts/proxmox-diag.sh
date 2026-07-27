#!/usr/bin/env bash
#
# proxmox-diag.sh
#
# Diagnostic for the Proxmox hosts underneath the K3s cluster. Read-only.
#
# The K3s nodes are VMs, so when something goes wrong on a host the guests only
# show the aftermath. A host that loses power takes its CP node and its worker
# with it, which from inside the cluster looks like two unrelated nodes
# rebooting at once.
#
# Usage:
#   ./proxmox-diag.sh              # all hosts
#   ./proxmox-diag.sh 10.0.10.11   # one host
#
set -uo pipefail

# Proxmox does not create an unprivileged admin user by default, so this is root
# unless another user was created.
SSH_USER=root

# The Proxmox hosts themselves, not the K3s VMs running on them.
#
# Each host also has addresses on VLAN 20 (provisioned for storage, 10.0.20.x) and
# VLAN 99 (management, 10.0.99.x). These are the VLAN 10 addresses, which is the
# path the workstation reaches them on over WireGuard.
HOSTS="
10.0.10.10
10.0.10.11
10.0.10.12
"

[ $# -gt 0 ] && HOSTS="$1"


# ControlMaster reuses one connection per host instead of a fresh handshake per
# command. This script runs many small qm and smartctl calls.
SSH_OPTS="
-o ConnectTimeout=5
-o BatchMode=yes
-o ControlMaster=auto
-o ControlPath=/tmp/proxmox-diag-%r@%h:%p
-o ControlPersist=60s
"

run() {
    ssh $SSH_OPTS "$SSH_USER@$HOST" "$1" 2>/dev/null
}


check_host() {
    echo
    echo "================================================================"
    echo "  $HOST"
    echo "================================================================"

    # A bare "UNREACHABLE" collapses no route, no listener, wrong key, and an
    # unknown host key into one word, and each needs a different fix. Re-run the
    # probe without discarding stderr and print what SSH said.
    if ! run true; then
        echo "  UNREACHABLE"
        ssh $SSH_OPTS "$SSH_USER@$HOST" true 2>&1 | sed 's/^/    /'
        return
    fi

    echo
    echo "--- Identity ---"
    echo "hostname: $(run hostname)"
    echo "version:  $(run 'pveversion' | head -1)"
    echo "uptime:   $(run 'uptime -p')"
    echo "booted:   $(run 'uptime -s')"

    # A host reboot takes both of its guests with it, so a recent boot that
    # nobody initiated needs explaining.
    echo
    echo "recent boots:"
    run 'last -x reboot shutdown | head -4' | sed 's/^/  /'

    # A clean shutdown writes a "shutdown" record before the next "reboot". A
    # power cut writes nothing, so a reboot with no shutdown line above it is a
    # host that died hard.
    #
    # wtmp is the source rather than the journal: reading the previous boot's
    # journal for the word "shutdown" only looks one boot back. This walks every
    # boot in the window.
    #
    # last prints newest first, so reverse it with tac and walk forward, judging
    # each reboot against whether a shutdown preceded it.
    echo
    echo "unclean shutdowns (a reboot with no shutdown recorded before it):"

    UNCLEAN=$(run 'last -x reboot shutdown' | tac | awk '
        /^shutdown/ { clean = 1; next }
        /^reboot/ {
            # Skip the oldest boot in the window. Nothing precedes it, so its
            # missing shutdown means the log begins there, not that it crashed.
            if (!first) { first = 1; clean = 0; next }

            if (!clean) print
            clean = 0
        }
    ')

    if [ -z "$UNCLEAN" ]; then
        echo "  none"
    else
        echo "$UNCLEAN" | sed 's/^/  /'
        echo "  this host lost power or hung. Check the UPS and power feed."
    fi

    echo
    echo "--- Cluster ---"

    # Proxmox runs its own quorum, separate from etcd. Losing it does not stop
    # running VMs, only managing them. Currently not configured; relying on K3s
    # etcd quorum.
    run 'pvecm status 2>/dev/null | grep -E "Quorate|Nodes|Expected"' | sed 's/^/  /'

    QUORATE=$(run 'pvecm status 2>/dev/null | awk "/Quorate/ {print \$2}"')
    [ "$QUORATE" != "Yes" ] && echo "  WARNING: this host does not have Proxmox cluster quorum"

    echo
    echo "--- Guests ---"

    # onboot decides whether a VM comes back by itself after the host reboots.
    echo "VMs on this host:"
    run 'qm list' | sed 's/^/  /'

    echo
    echo "will these VMs restart automatically after a host reboot?"
    for VMID in $(run "qm list | awk 'NR>1 {print \$1}'"); do
        ONBOOT=$(run "qm config $VMID | awk '/^onboot:/ {print \$2}'")
        NAME=$(run "qm config $VMID | awk '/^name:/ {print \$2}'")

        if [ "$ONBOOT" = "1" ]; then
            echo "  $VMID $NAME: yes"
        else
            echo "  $VMID $NAME: NO - this VM will stay down until started by hand"
        fi
    done

    echo
    echo "--- Resources ---"

    echo "cores: $(run nproc)"
    echo "load:  $(run 'cat /proc/loadavg')"

    # The host owns the memory. If it is overcommitted the guests are squeezed,
    # which presents inside them as slowness with no local cause.
    echo
    run 'free -h' | sed 's/^/  /'

    # Total vCPU and RAM handed out to guests, against what the host has. Some
    # overcommit is expected; heavy overcommit shows up as CPU steal.
    echo
    echo "allocated to guests vs available on host:"

    HOST_CORES=$(run nproc)
    HOST_RAM_MB=$(run "free -m | awk '/^Mem:/ {print \$2}'")

    ALLOCATED_CORES=0
    ALLOCATED_RAM=0

    for VMID in $(run "qm list | awk 'NR>1 {print \$1}'"); do
        VM_CORES=$(run "qm config $VMID | awk '/^cores:/ {print \$2}'")
        VM_RAM=$(run "qm config $VMID | awk '/^memory:/ {print \$2}'")
        ALLOCATED_CORES=$((ALLOCATED_CORES + ${VM_CORES:-0}))
        ALLOCATED_RAM=$((ALLOCATED_RAM + ${VM_RAM:-0}))
    done

    echo "  vCPU:   $ALLOCATED_CORES allocated, $HOST_CORES physical cores"
    echo "  memory: ${ALLOCATED_RAM}MB allocated, ${HOST_RAM_MB}MB on the host"

    if [ "$ALLOCATED_RAM" -gt "$HOST_RAM_MB" ]; then
        echo "  WARNING: more memory promised to guests than the host has"
    fi

    # Ballooning lets the host reclaim memory from a guest under pressure. The
    # kubelet sizes itself to the memory it saw at boot and does not notice when
    # it is taken away, so ballooning should be off on Kubernetes nodes.
    echo
    echo "guests with ballooning enabled:"
    BALLOONING=""
    for VMID in $(run "qm list | awk 'NR>1 {print \$1}'"); do
        BALLOON=$(run "qm config $VMID | awk '/^balloon:/ {print \$2}'")
        # A balloon value of 0 means ballooning is off, which is ideal.
        if [ -n "$BALLOON" ] && [ "$BALLOON" != "0" ]; then
            echo "  $VMID: balloon=$BALLOON - the host can take memory back from this VM"
            BALLOONING=yes
        fi
    done
    [ -z "$BALLOONING" ] && echo "  none (correct for Kubernetes nodes)"

    echo
    echo "--- VLAN 20 segment (provisioned, not used by Longhorn) ---"

    # Longhorn does not replicate over VLAN 20: `storage-network` is unset, so
    # replication rides VLAN 10. The hosts carry VLAN 20 addresses, and so do the
    # worker VMs (10.0.20.60-62), which linux-diag.sh checks.
    #
    # This only shows the underlay is up; a pass here does not mean the workers
    # can reach each other.
    LAST_OCTET=$(echo "$HOST" | cut -d. -f4)
    STORAGE_IP="10.0.20.$LAST_OCTET"

    STORAGE_LINE=$(run "ip -br addr | grep $STORAGE_IP")

    if [ -z "$STORAGE_LINE" ]; then
        echo "  $STORAGE_IP is not configured on this host"
    else
        echo "  $STORAGE_LINE"
        echo "  (run linux-diag.sh to test the workers' VLAN 20 legs)"
    fi

    echo
    echo "--- Storage ---"

    echo "storage pools:"
    run 'pvesm status' | sed 's/^/  /'

    # A full pool means VMs cannot write, which presents as filesystem errors
    # inside the guest rather than as a host-level error.
    FULL_POOLS=$(run "pvesm status | awk 'NR>1 && \$7+0 > 85 {print \$1, \$7}'")
    if [ -n "$FULL_POOLS" ]; then
        echo
        echo "  pools over 85% full:"
        echo "$FULL_POOLS" | sed 's/^/    /'
    fi

    echo
    echo "host filesystem:"
    run 'df -h / /var/lib/vz 2>/dev/null' | sed 's/^/  /'

    # ZFS pool health, if the host runs ZFS.
    if run 'command -v zpool' >/dev/null; then
        echo
        echo "ZFS pools:"
        run 'zpool list' | sed 's/^/  /'

        ZFS_HEALTH=$(run "zpool list -H -o health")
        for STATE in $ZFS_HEALTH; do
            [ "$STATE" != "ONLINE" ] && echo "  WARNING: a ZFS pool is $STATE"
        done
    fi

    echo
    echo "--- Disks ---"

    # These are physical machines with real disks, so SMART data is meaningful
    # here and not in the guests.
    for DISK in $(run "lsblk -dn -o NAME | grep -E '^(sd|nvme)'"); do
        HEALTH=$(run "smartctl -H /dev/$DISK 2>/dev/null | grep -i 'overall-health\|SMART Health'")
        echo "  /dev/$DISK: ${HEALTH:-no SMART data}"

        # Unsafe shutdowns count power cuts, as recorded by the disk itself. A
        # climbing number is a power problem.
        UNSAFE=$(run "smartctl -A /dev/$DISK 2>/dev/null | awk '/Unsafe_Shutdown|unsafe_shutdowns/ {print \$NF}'")
        [ -n "$UNSAFE" ] && echo "      unsafe shutdowns: $UNSAFE"
    done

    echo
    echo "--- Logs ---"

    echo "hardware errors this boot:"
    HW=$(run 'journalctl -k -b --no-pager | grep -iE "machine check|mce:|hardware error|thermal|i/o error" | tail -3')
    if [ -z "$HW" ]; then
        echo "  none"
    else
        echo "$HW" | sed 's/^/  /'
    fi

    echo
    echo "failed services:"
    FAILED=$(run 'systemctl --failed --no-legend')
    if [ -z "$FAILED" ]; then
        echo "  none"
    else
        echo "$FAILED" | sed 's/^/  /'
    fi

    echo
    echo "--- Updates ---"

    # A host that reboots itself takes two cluster nodes down with no drain.
    # This must be off.
    AUTO_REBOOT=$(run 'grep -rh "Automatic-Reboot" /etc/apt/apt.conf.d/ 2>/dev/null | grep -v "^//"')

    if [ -z "$AUTO_REBOOT" ]; then
        echo "Automatic-Reboot: not set (defaults to false, which is ideal)"
    else
        echo "Automatic-Reboot: $AUTO_REBOOT"
        echo "$AUTO_REBOOT" | grep -qi true && \
            echo "  WARNING: this host can reboot itself, taking both its guests down without draining"
    fi

    echo
    echo "--- Time ---"
    echo "NTP synchronized: $(run 'timedatectl show -p NTPSynchronized --value')"
}


echo "Proxmox diagnostic - $(date '+%Y-%m-%d %H:%M')"

for HOST in $HOSTS; do
    check_host
done

echo
echo "================================================================"
echo "Done."
echo
echo "Each host runs one control plane VM and one worker. A host that goes down"
echo "takes both with it, so a single host failure presents as two unrelated"
echo "node failures from inside the cluster."
echo "================================================================"
