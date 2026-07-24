#!/usr/bin/env bash
#
# preflight-check.sh
#
# Go/no-go gate. Run this BEFORE any drain, reboot, or shutdown.
#
#   exit 0 = safe to proceed
#   exit 1 = do not proceed, blocking conditions are listed
#
# Usage:
#   ./preflight-check.sh              # check the cluster
#   ./preflight-check.sh k3s-wk-01    # also show what draining this node costs
#
set -uo pipefail

CP_NODE=10.0.10.50          # any control plane node, used for the snapshot check
SSH_USER=k3s
SNAPSHOT_MAX_AGE_HOURS=24

TARGET_NODE="${1:-}"

# Only emit colour when writing to a terminal. Redirected to a file, the escape
# codes are printed literally and make the log harder to read than no colour.
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    RESET=""
fi

FAILURES=0

ok()   { echo "  ${GREEN}OK${RESET}    $1"; }
bad()  { echo "  ${RED}FAIL${RESET}  $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo "  ${YELLOW}WARN${RESET}  $1"; }

echo "Preflight check - $(date '+%Y-%m-%d %H:%M')"
[ -n "$TARGET_NODE" ] && echo "Target node: $TARGET_NODE"


echo
echo "=== Nodes ==="

# A NotReady node is already one failure domain down before another is
# deliberately removed.
NOT_READY=$(kubectl get nodes --no-headers | grep -v ' Ready' | awk '{print $1}')
if [ -n "$NOT_READY" ]; then
    for NODE in $NOT_READY; do
        bad "node not Ready: $NODE"
    done
else
    ok "all nodes Ready"
fi

# A node left cordoned from an earlier operation is invisible to Longhorn, which
# then never rebuilds a replica onto it - how a volume ends up stuck degraded.
CORDONED=$(kubectl get nodes --no-headers | grep SchedulingDisabled | awk '{print $1}')
if [ -z "$CORDONED" ]; then
    ok "no cordoned nodes"
else
    for NODE in $CORDONED; do
        if [ "$NODE" = "$TARGET_NODE" ]; then
            ok "node cordoned: $NODE (expected, it is the target)"
        else
            bad "node cordoned: $NODE (Longhorn cannot rebuild replicas here)"
        fi
    done
fi


echo
echo "=== Control plane ==="

# Three control plane nodes tolerate exactly one failure. Taking a second one
# down loses etcd quorum and leaves the API server read-only.
CP_TOTAL=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l | tr -d ' ')
CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | grep -c ' Ready')

if [ "$CP_READY" -eq "$CP_TOTAL" ]; then
    ok "control plane at full strength ($CP_READY/$CP_TOTAL Ready)"
else
    bad "control plane degraded ($CP_READY/$CP_TOTAL Ready) - no quorum margin left"
fi

# The API server publishes its own etcd health check. No SSH, no etcdctl.
if kubectl get --raw='/readyz?verbose' 2>/dev/null | grep -q '^\[+\]etcd'; then
    ok "API server reports etcd healthy"
else
    bad "API server reports etcd unhealthy"
fi


echo
echo "=== etcd snapshot ==="

# This is the rollback. Confirm it exists before it is needed, not after.
SNAPSHOT_DIR=/var/lib/rancher/k3s/server/db/snapshots
NEWEST=$(ssh -o ConnectTimeout=5 "$SSH_USER@$CP_NODE" "sudo ls -t $SNAPSHOT_DIR 2>/dev/null | head -1")

if [ -z "$NEWEST" ]; then
    bad "no etcd snapshot found"
    echo "          take one: ssh $SSH_USER@$CP_NODE 'sudo k3s etcd-snapshot save'"
else
    SNAPSHOT_TIME=$(ssh -o ConnectTimeout=5 "$SSH_USER@$CP_NODE" "sudo stat -c %Y $SNAPSHOT_DIR/$NEWEST")
    AGE_HOURS=$(( ($(date +%s) - SNAPSHOT_TIME) / 3600 ))

    if [ "$AGE_HOURS" -le "$SNAPSHOT_MAX_AGE_HOURS" ]; then
        ok "etcd snapshot is ${AGE_HOURS}h old: $NEWEST"
    else
        bad "newest etcd snapshot is ${AGE_HOURS}h old (want under ${SNAPSHOT_MAX_AGE_HOURS}h)"
    fi
fi


echo
echo "=== Longhorn volumes ==="

# THE CHECK THAT MATTERS MOST.
#
# A volume below its desired replica count has less redundancy than it should.
# "Fewer replicas than wanted" has two causes, and only one should block:
#
#   REBUILDING  Longhorn is copying data onto a new replica now - working, not
#               stuck. Happens after every drain, reboot, and replica move, and
#               finishes on its own. Wait for it.
#
#   STUCK       The replica is missing and nothing is bringing it back, usually
#               no node has room or a node is cordoned. Does not self-resolve.
#
# The volume's robustness field says "degraded" for both, so it is not enough on
# its own; look at the replica states instead. Blocking on a rebuild would fail
# after every routine drain, and a gate that cries wolf goes unread - so warn on
# a rebuild and block only when nothing is rebuilding.

REPLICA_STATES=$(kubectl -n longhorn-system get replicas \
    -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState,NODE:.spec.nodeID \
    --no-headers)

for VOLUME in $(kubectl -n longhorn-system get volumes -o name | cut -d/ -f2); do

    WANTED=$(kubectl -n longhorn-system get volume "$VOLUME" \
        -o jsonpath='{.spec.numberOfReplicas}')

    RUNNING=$(echo "$REPLICA_STATES" | awk -v vol="$VOLUME" \
        '$1 == vol && $2 == "running"' | wc -l | tr -d ' ')

    REBUILDING=$(echo "$REPLICA_STATES" | awk -v vol="$VOLUME" \
        '$1 == vol && $2 == "rebuilding"' | wc -l | tr -d ' ')

    if [ "$RUNNING" -ge "$WANTED" ]; then
        ok "volume $VOLUME has $RUNNING/$WANTED replicas"

    elif [ "$REBUILDING" -gt 0 ]; then
        # Longhorn is already fixing this - not a fault. Do not power down
        # mid-copy; wait a few minutes and re-run.
        warn "volume $VOLUME has $RUNNING/$WANTED replicas, $REBUILDING rebuilding - wait, then re-run"
        echo "$REPLICA_STATES" | awk -v vol="$VOLUME" '$1 == vol {print "          " $3 " " $2}'

    else
        # Replicas are missing and nothing is rebuilding them. This will not fix
        # itself.
        bad "volume $VOLUME has $RUNNING/$WANTED replicas and nothing is rebuilding"
        echo "$REPLICA_STATES" | awk -v vol="$VOLUME" '$1 == vol {print "          " $3 " " $2}'
        echo "          check for cordoned nodes and for Longhorn nodes with no usable space"
    fi
done

# Longhorn silently refuses to place replicas on a node with scheduling disabled,
# and will keep refusing forever.
for NODE in $(kubectl -n longhorn-system get nodes.longhorn.io -o name | cut -d/ -f2); do
    ALLOWED=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.spec.allowScheduling}')
    [ "$ALLOWED" != "true" ] && warn "Longhorn scheduling disabled on $NODE"
done


echo
echo "=== PodDisruptionBudgets ==="

# A PDB showing 0 allowed disruptions blocks eviction, for two very different
# reasons that are dangerous to confuse:
#
#   WAIT   Longhorn creates the instance-manager and csi-* PDBs itself and
#          removes them once volumes detach. They correctly show 0 allowed while
#          volumes are attached. Force-deleting these pods rips volumes out from
#          under running workloads. Wait them out.
#
#   FAIL   minAvailable >= the number of pods that exist. Nothing satisfies it,
#          so waiting never helps and the drain retries forever. Fix the PDB.
#
# The arithmetic cannot tell them apart - both can be minAvailable=1 against a
# single pod. What separates them is whether anything will ever clear the
# condition, which comes down to who owns the PDB. So match Longhorn's own
# dynamically-managed PDBs by name and treat those as transient.

is_longhorn_managed() {
    case "$1" in
        instance-manager-*|csi-attacher|csi-provisioner|csi-resizer|csi-snapshotter)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# Write the blocked PDBs to a temp file first. Piping kubectl straight into a
# while loop would run the loop in a subshell, where FAILURES cannot be updated.
BLOCKED_PDBS=$(mktemp)
kubectl get pdb -A --no-headers | awk '$5 == 0 {print $1, $2, $3}' > "$BLOCKED_PDBS"

if [ ! -s "$BLOCKED_PDBS" ]; then
    ok "no PDBs are blocking eviction"
fi

while read -r NAMESPACE NAME MIN_AVAILABLE; do
    [ -z "$NAME" ] && continue

    if is_longhorn_managed "$NAME"; then
        warn "$NAMESPACE/$NAME - Longhorn-managed, clears once volumes detach. Wait, do not delete."
        continue
    fi

    EXPECTED=$(kubectl -n "$NAMESPACE" get pdb "$NAME" -o jsonpath='{.status.expectedPods}')

    if [ "$MIN_AVAILABLE" != "N/A" ] && [ "$MIN_AVAILABLE" -ge "$EXPECTED" ]; then
        bad "$NAMESPACE/$NAME is unsatisfiable (minAvailable=$MIN_AVAILABLE, pods=$EXPECTED)"
        echo "          It will block every drain forever. Fix the PDB in Git."
    else
        warn "$NAMESPACE/$NAME - 0 allowed right now, but should clear on its own"
    fi
done < "$BLOCKED_PDBS"

rm -f "$BLOCKED_PDBS"


echo
echo "=== Workloads ==="

# Do not stack a deliberate disruption on top of an unintended one.
#
# Ask for the phase by name rather than parsing the default table: a restarted
# pod shows RESTARTS as "10 (2d1h ago)", shifting every column after it, and
# grepping the whole line would match the pod NAME as well as the STATUS.
#
# Succeeded is the phase for a finished Job; the default table calls it Completed.
BROKEN=$(kubectl get pods -A \
    -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase \
    --no-headers \
    | awk '$3 != "Running" && $3 != "Succeeded"')

if [ -z "$BROKEN" ]; then
    ok "all pods Running or Succeeded"
else
    bad "$(echo "$BROKEN" | wc -l | tr -d ' ') pods not Running or Succeeded"
    echo "$BROKEN" | sed 's/^/          /'
fi


if [ -n "$TARGET_NODE" ]; then
    echo
    echo "=== Cost of draining $TARGET_NODE ==="

    # DaemonSet pods do not relocate, drain skips them with --ignore-daemonsets.
    # Everything else has to find room on the remaining nodes.
    EVICTABLE=$(kubectl get pods -A --field-selector "spec.nodeName=$TARGET_NODE" \
        -o custom-columns=OWNER:.metadata.ownerReferences[0].kind --no-headers \
        | grep -vc DaemonSet)

    echo "  $EVICTABLE pods will need to move to other nodes"

    ATTACHED=$(kubectl -n longhorn-system get volumes \
        -o custom-columns=NAME:.metadata.name,NODE:.status.currentNodeID --no-headers \
        | awk -v node="$TARGET_NODE" '$2 == node {print $1}')

    if [ -n "$ATTACHED" ]; then
        echo "  these volumes are attached here and will detach, then reattach elsewhere:"
        echo "$ATTACHED" | sed 's/^/          /'
    fi

    # Volumes are not spread evenly across the workers. They attach wherever the
    # consuming pod is scheduled, so one node can end up holding every volume.
    # Draining it detaches them all at once, each to detach, reattach elsewhere,
    # and settle - worth seeing beforehand rather than mid-drain.
    TOTAL_VOLUMES=$(kubectl -n longhorn-system get volumes --no-headers | wc -l | tr -d ' ')
    HERE=$(echo "$ATTACHED" | grep -c .)

    echo
    echo "  volumes attached per node:"
    kubectl -n longhorn-system get volumes \
        -o custom-columns=NODE:.status.currentNodeID --no-headers \
        | sort | uniq -c | awk '{print "          " $2 ": " $1}'

    if [ "$HERE" -eq "$TOTAL_VOLUMES" ] && [ "$TOTAL_VOLUMES" -gt 0 ]; then
        warn "every volume in the cluster ($TOTAL_VOLUMES) is attached to $TARGET_NODE"
        echo "          draining it detaches all of them at once"
    fi
fi


echo
echo "========================================"

if [ "$FAILURES" -eq 0 ]; then
    echo "${GREEN}PASS - safe to proceed${RESET}"
    exit 0
else
    echo "${RED}FAIL - $FAILURES blocking condition(s). Do not proceed.${RESET}"
    exit 1
fi
