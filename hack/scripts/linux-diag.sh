#!/usr/bin/env bash
#
# linux-diag.sh
#
# OS-level diagnostic for the cluster nodes. Read-only.
#
# Loops the nodes over SSH and runs the same checks on each so they can be
# compared. Drift between nodes that should be identical is what this surfaces.
#
# Usage:
#   ./linux-diag.sh                # all nodes
#   ./linux-diag.sh 10.0.10.60     # one node
#
set -uo pipefail

SSH_USER=k3s

NODES="
10.0.10.50
10.0.10.51
10.0.10.52
10.0.10.60
10.0.10.61
10.0.10.62
"

# If a node address was given on the command line, use only that one.
[ $# -gt 0 ] && NODES="$1"


# Run a command on a node over SSH. Everything goes through here.
#
# BatchMode stops SSH hanging on a password prompt if the key is missing, which
# would stall the whole loop on an unreachable node.
#
# ControlMaster reuses one TCP connection per node instead of a fresh handshake
# per command. This script runs ~30 commands per node across 6 nodes.
SSH_OPTS="
-o ConnectTimeout=5
-o BatchMode=yes
-o ControlMaster=auto
-o ControlPath=/tmp/linux-diag-%r@%h:%p
-o ControlPersist=60s
"

run() {
    ssh $SSH_OPTS "$SSH_USER@$NODE" "$1" 2>/dev/null
}


check_node() {
    echo
    echo "================================================================"
    echo "  $NODE"
    echo "================================================================"

    if ! run true; then
        echo "  UNREACHABLE"
        return
    fi

    echo
    echo "--- Identity ---"
    echo "hostname:  $(run hostname)"
    echo "uptime:    $(run 'uptime -p')"
    echo "booted:    $(run 'uptime -s')"

    # The running kernel only changes on reboot; the installed kernel changes
    # whenever unattended-upgrades runs. If these differ the node has a reboot
    # pending and will come up on the newer one.
    RUNNING_KERNEL=$(run 'uname -r')
    NEWEST_KERNEL=$(run 'ls /boot/vmlinuz-* | sed "s|.*/vmlinuz-||" | sort -V | tail -1')

    echo "kernel running:   $RUNNING_KERNEL"
    echo "kernel installed: $NEWEST_KERNEL"

    if [ "$RUNNING_KERNEL" != "$NEWEST_KERNEL" ]; then
        echo "  NOTE: reboot pending, will come up on $NEWEST_KERNEL"
    fi

    echo
    echo "recent boots and shutdowns:"
    run 'last -x reboot shutdown | head -8' | sed 's/^/  /'

    # An orderly shutdown writes a "shutdown" record before the next "reboot"
    # record. A power cut writes nothing, so a reboot with no shutdown line
    # above it is a node that died hard.
    #
    # wtmp is the source rather than the journal: reading the previous boot's
    # journal for the word "shutdown" only looks one boot back and depends on
    # what the last log lines happened to say.
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
        echo "  this node lost power or hung. Check the UPS and the Proxmox host."
    fi

    echo
    echo "--- CPU ---"
    echo "cores: $(run nproc)"
    echo "load:  $(run 'cat /proc/loadavg')"

    # Steal time is CPU the hypervisor took from this VM to give to another. It
    # is not visible from inside the guest by any other means, so check it when
    # a VM is slow but its own metrics look normal.
    echo
    echo "cpu time breakdown (cumulative since boot):"
    run "cat /proc/stat | head -1" | awk '{
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
        printf "  user:   %5.1f%%\n", ($2 / total) * 100
        printf "  system: %5.1f%%\n", ($4 / total) * 100
        printf "  idle:   %5.1f%%\n", ($5 / total) * 100
        printf "  iowait: %5.1f%%\n", ($6 / total) * 100
        printf "  steal:  %5.1f%%", ($9 / total) * 100
        if (($9 / total) * 100 > 5) printf "   <-- HIGH, the Proxmox host is oversubscribed"
        printf "\n"
    }'

    echo
    echo "--- Memory ---"
    run 'free -h' | sed 's/^/  /'

    # Swap should be off on every node: on a control plane node it raises etcd
    # latency, and on a worker it makes the kubelet's memory accounting wrong.
    SWAP_TOTAL=$(run "awk '/SwapTotal/ {print \$2}' /proc/meminfo")

    echo
    if [ "$SWAP_TOTAL" = "0" ]; then
        echo "swap: disabled (correct)"
    else
        echo "swap: ENABLED - it should be off on all nodes"
    fi

    echo
    echo "recent OOM kills:"
    OOM_KILLS=$(run 'dmesg -T 2>/dev/null | grep -i "killed process" | tail -3')
    if [ -z "$OOM_KILLS" ]; then
        echo "  none"
    else
        echo "$OOM_KILLS" | sed 's/^/  /'
    fi

    echo
    echo "--- Disk ---"
    run 'df -h -x tmpfs -x devtmpfs' | sed 's/^/  /'

    # Inodes are a separate pool from disk space: gigabytes can be free and no
    # file can still be created.
    echo
    echo "inode usage:"
    run 'df -i -x tmpfs -x devtmpfs' | sed 's/^/  /'

    # Unbooted kernels accumulate in /boot and eventually fill it, which breaks
    # apt.
    KERNEL_COUNT=$(run 'ls /boot/vmlinuz-* | wc -l')
    echo
    echo "installed kernels: $KERNEL_COUNT"
    [ "$KERNEL_COUNT" -gt 4 ] && echo "  NOTE: consider 'apt autoremove' to clear old kernels"

    echo
    echo "largest directories under /var:"
    run 'du -shx /var/* 2>/dev/null | sort -rh | head -5' | sed 's/^/  /'

    echo
    echo "--- Network ---"

    # Drop the veth interfaces: one per pod, created and destroyed constantly,
    # and a busy worker prints twenty of them.
    run 'ip -br addr' | grep -vE '^veth|^cni0' | sed 's/^/  /'

    # kube-vip parks the API server VIP on whichever control plane node holds it,
    # as a /32 on top of that node's real address. Labelled here so it is not
    # read as an unexplained extra IP on one node.
    if run 'ip -br addr' | grep -q '10.0.10.49/32'; then
        echo
        echo "  this node currently holds the kube-vip API VIP (10.0.10.49)"
    fi

    # resolv.conf shows what DNS is configured, not whether it works, so run an
    # actual lookup.
    echo
    echo "can this node resolve DNS?"
    if run 'getent hosts google.com' >/dev/null; then
        echo "  yes"
    else
        echo "  NO - DNS resolution is failing"
    fi

    echo
    echo "can this node reach the API server VIP?"
    if run 'ping -c1 -W2 10.0.10.49' >/dev/null; then
        echo "  yes"
    else
        echo "  NO - cannot reach 10.0.10.49"
    fi

    echo
    echo "--- VLAN 20 segment (provisioned, not used by Longhorn) ---"

    # VLAN 20 is east-west only across the CRS305, not routed through OPNsense.
    #
    # Longhorn does NOT replicate over it: `storage-network` is unset, so
    # replication rides VLAN 10 over the flannel VXLAN overlay. Measured
    # 2026-07-14; see docs/benchmarks/storage-replication/2026-07-14-results.md.
    # These checks therefore validate the segment itself, not any live traffic
    # path, and a failure here does not currently affect replication.
    #
    # Only the workers would carry replication if it moved onto VLAN 20. Control
    # plane nodes carry VLAN 20 addresses that nothing uses.
    #
    # Each node's VLAN 20 address mirrors its VLAN 10 last octet: 10.0.10.60 ->
    # 10.0.20.60.
    WORKERS="60 61 62"

    LAST_OCTET=$(echo "$NODE" | cut -d. -f4)
    STORAGE_IP="10.0.20.$LAST_OCTET"

    IS_WORKER=no
    for OCTET in $WORKERS; do
        [ "$LAST_OCTET" = "$OCTET" ] && IS_WORKER=yes
    done

    if [ "$IS_WORKER" = "no" ]; then
        echo "  control plane node, holds no Longhorn replicas"
    else
        STORAGE_LINE=$(run "ip -br addr | grep $STORAGE_IP")

        if [ -z "$STORAGE_LINE" ]; then
            echo "  $STORAGE_IP is NOT configured on this worker"
        else
            echo "  $STORAGE_LINE"

            # If replication ever moves onto VLAN 20, every worker has to reach
            # every other worker, since each holds one replica of every volume.
            echo
            echo "  can this worker reach the other workers on VLAN 20?"
            for PEER_OCTET in $WORKERS; do
                PEER="10.0.20.$PEER_OCTET"
                [ "$PEER" = "$STORAGE_IP" ] && continue

                if run "ping -c1 -W2 $PEER" >/dev/null; then
                    echo "    $PEER: yes"
                else
                    echo "    $PEER: NO - this leg of the VLAN 20 segment is down"
                fi
            done

            STORAGE_IFACE=$(run "ip -o addr show | awk '/$STORAGE_IP/ {print \$2}'")

            if [ -n "$STORAGE_IFACE" ]; then
                echo
                echo "  interface $STORAGE_IFACE:"

                # Jumbo frames are set in three places: the CRS305 ports, the
                # Proxmox bridge, and the guest interface. If they disagree
                # nothing errors; the path fragments and throughput drops. Assert
                # the expected value rather than printing whatever is there.
                EXPECTED_MTU=9000

                MTU=$(run "ip -o link show $STORAGE_IFACE" \
                    | awk '{for (i = 1; i <= NF; i++) if ($i == "mtu") print $(i + 1)}')

                if [ "$MTU" = "$EXPECTED_MTU" ]; then
                    echo "    MTU: $MTU"
                else
                    echo "    MTU: $MTU - expected $EXPECTED_MTU, jumbo frames are not set"
                fi

                # Errors and drops here surface as slow rebuilds.
                run "ip -s link show $STORAGE_IFACE" \
                    | awk '/RX:|TX:/ {
                        direction = $1
                        getline
                        if ($3 + $4 > 0) print "    " direction " errors=" $3 " dropped=" $4
                    }'
            fi
        fi
    fi

    echo
    echo "--- Services ---"

    echo "systemd state: $(run 'systemctl is-system-running')"

    echo
    echo "failed units:"
    FAILED_UNITS=$(run 'systemctl --failed --no-legend')
    if [ -z "$FAILED_UNITS" ]; then
        echo "  none"
    else
        echo "$FAILED_UNITS" | sed 's/^/  /'
    fi

    # K3s installs k3s.service on servers and k3s-agent.service on agents; no
    # single name covers both.
    #
    # Check which unit exists first. Chaining the two with || does not work:
    # systemctl is-active prints "inactive" to stdout, not stderr, so the first
    # check's output is captured alongside the second and every worker reports
    # "inactive" followed by "active".
    echo
    if run 'systemctl cat k3s.service' >/dev/null 2>&1; then
        K3S_UNIT=k3s
    else
        K3S_UNIT=k3s-agent
    fi

    echo "$K3S_UNIT: $(run "systemctl is-active $K3S_UNIT")"

    echo
    echo "--- Logs ---"

    # Two of these fire on every boot of every node. They are artifacts of the
    # virtual hardware Proxmox presents, not faults, so they are filtered out:
    #
    #   shpchp          PCI hotplug driver failing on emulated slots
    #   snd_hda_intel   an audio device with no codec, on a server with no sound
    echo "kernel errors this boot:"
    KERNEL_ERRORS=$(run 'journalctl -k -p err -b --no-pager' \
        | grep -viE 'shpchp|snd_hda_intel' \
        | tail -5)

    if [ -z "$KERNEL_ERRORS" ]; then
        echo "  none"
    else
        echo "$KERNEL_ERRORS" | sed 's/^/  /'
    fi

    echo
    echo "hardware and filesystem errors:"
    HW_ERRORS=$(run 'journalctl -k -b --no-pager | grep -iE "machine check|hardware error|i/o error|ext4-fs error|remounting.*read-only" | tail -3')
    if [ -z "$HW_ERRORS" ]; then
        echo "  none"
    else
        echo "$HW_ERRORS" | sed 's/^/  /'
    fi

    echo
    echo "--- Updates ---"

    # A node that reboots itself outside the drain sequence leaves etcd and
    # Longhorn replicas to recover unassisted.
    AUTO_REBOOT=$(run 'grep -rh "Automatic-Reboot" /etc/apt/apt.conf.d/ 2>/dev/null | grep -v "^//"')

    if [ -z "$AUTO_REBOOT" ]; then
        echo "Automatic-Reboot: not set (defaults to false, which is ideal)"
    else
        echo "Automatic-Reboot: $AUTO_REBOOT"
        echo "$AUTO_REBOOT" | grep -qi true && \
            echo "  WARNING: this node can reboot itself without draining first"
    fi

    echo
    echo "upgradable packages: $(run 'apt list --upgradable 2>/dev/null | tail -n +2 | wc -l')"

    echo
    echo "--- Time ---"

    # Clock skew breaks etcd and TLS.
    echo "NTP synchronized: $(run 'timedatectl show -p NTPSynchronized --value')"
}


# These nodes are built from the same image, so a difference between them is a
# comparison result, not something visible in any single node's output. Collect
# the values that should match into one table at the end.
summarise() {
    printf "%-12s %-20s %-6s %-6s %-12s %-6s %s\n" \
        "NODE" "KERNEL" "SWAP" "MTU" "K3S" "PKGS" "UNCLEAN"

    for NODE in $NODES; do
        HOSTNAME=$(run hostname)

        if [ -z "$HOSTNAME" ]; then
            printf "%-12s %s\n" "$NODE" "unreachable"
            continue
        fi

        KERNEL=$(run 'uname -r')

        SWAP_TOTAL=$(run "awk '/SwapTotal/ {print \$2}' /proc/meminfo")
        if [ "$SWAP_TOTAL" = "0" ]; then
            SWAP=off
        else
            SWAP=ON
        fi

        LAST_OCTET=$(echo "$NODE" | cut -d. -f4)
        STORAGE_IFACE=$(run "ip -o addr show | awk '/10.0.20.$LAST_OCTET/ {print \$2}'")

        if [ -z "$STORAGE_IFACE" ]; then
            MTU="-"
        else
            MTU=$(run "ip -o link show $STORAGE_IFACE" \
                | awk '{for (i = 1; i <= NF; i++) if ($i == "mtu") print $(i + 1)}')
        fi

        if run 'systemctl cat k3s.service' >/dev/null 2>&1; then
            K3S_UNIT=k3s
        else
            K3S_UNIT=k3s-agent
        fi
        K3S_STATE=$(run "systemctl is-active $K3S_UNIT")

        PACKAGES=$(run 'apt list --upgradable 2>/dev/null | tail -n +2 | wc -l')

        UNCLEAN=$(run 'last -x reboot shutdown' | tac | awk '
            /^shutdown/ { clean = 1; next }
            /^reboot/ {
                # Skip the oldest boot: nothing precedes it to compare against.
                if (!first) { first = 1; clean = 0; next }

                if (!clean) count++
                clean = 0
            }
            END { print count + 0 }
        ')

        printf "%-12s %-20s %-6s %-6s %-12s %-6s %s\n" \
            "$HOSTNAME" "$KERNEL" "$SWAP" "$MTU" "$K3S_STATE" "$PACKAGES" "$UNCLEAN"
    done
}


echo "Linux diagnostic - $(date '+%Y-%m-%d %H:%M')"

for NODE in $NODES; do
    check_node
done

echo
echo "================================================================"
echo "  Summary"
echo "================================================================"
echo
echo "These nodes are built the same and should read the same. Check any value"
echo "that differs from its neighbours."
echo
summarise
echo
echo "UNCLEAN is the number of times this node booted without a shutdown having"
echo "been recorded first. Anything above zero is a power cut or a hard hang."
echo "================================================================"
