#!/usr/bin/env bash
#
# k3s-diag.sh
#
# Cluster-wide diagnostic. Read-only, reports what it finds and changes nothing.
#
# Prints each section as it goes, then a summary of anything that looked wrong.
# Exits 1 if it found problems, 0 if the cluster is clean.
#
# Usage:
#   ./k3s-diag.sh
#
set -uo pipefail

# The etcd checks read metrics from a control plane node over SSH. Any of the
# three will do, they all serve the same cluster-wide numbers.
SSH_USER=k3s
CP_NODE=10.0.10.50

# Only emit color when writing to a terminal. Redirected to a file, the escape
# codes are printed literally and make the log harder to read than no color.
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    YELLOW=$'\033[0;33m'
    RESET=$'\033[0m'
else
    RED=""
    YELLOW=""
    RESET=""
fi

# Problems get appended here as they are found, then printed at the end.
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }

echo "K3s diagnostic - $(date '+%Y-%m-%d %H:%M')"
echo "Context: $(kubectl config current-context)"


echo
echo "=== Nodes ==="
kubectl get nodes -o wide

# Identical nodes should be running identical kernels. If they are not, some
# subset of them rebooted, and we should know why.
KERNELS=$(kubectl get nodes -o custom-columns=KERNEL:.status.nodeInfo.kernelVersion --no-headers | sort -u)
KERNEL_COUNT=$(echo "$KERNELS" | wc -l | tr -d ' ')

if [ "$KERNEL_COUNT" -gt 1 ]; then
    problem "kernel drift: $KERNEL_COUNT different kernels across nodes"
    echo
    echo "kernel drift:"
    kubectl get nodes -o custom-columns=NODE:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion --no-headers \
        | sed 's/^/  /'
fi

NOT_READY=$(kubectl get nodes --no-headers | grep -v ' Ready' | awk '{print $1}')
for NODE in $NOT_READY; do
    problem "node not Ready: $NODE"
done

# A forgotten cordon silently stops Longhorn rebuilding replicas onto that node.
CORDONED=$(kubectl get nodes --no-headers | grep SchedulingDisabled | awk '{print $1}')
for NODE in $CORDONED; do
    problem "node cordoned: $NODE (Longhorn will not rebuild replicas here)"
done

# Kubernetes already knows about disk and memory pressure and almost nobody
# looks. These conditions read "False" when things are healthy, so anything
# saying "True" is a problem.
#
# Clear the scratch file first. If a previous run crashed partway through, its
# leftovers would otherwise be reported as if they were found this time.
rm -f /tmp/k3s-diag-pressure

for CONDITION in MemoryPressure DiskPressure PIDPressure; do

    # Print one line per node: the node name, then the status of this condition.
    kubectl get nodes \
        -o custom-columns="NODE:.metadata.name,STATUS:.status.conditions[?(@.type=='$CONDITION')].status" \
        --no-headers \
    | while read -r NODE STATUS; do
        [ "$STATUS" = "True" ] && echo "$NODE $CONDITION" >> /tmp/k3s-diag-pressure
    done
done

if [ -f /tmp/k3s-diag-pressure ]; then
    while read -r NODE CONDITION; do
        problem "node $NODE reports $CONDITION"
    done < /tmp/k3s-diag-pressure
    rm -f /tmp/k3s-diag-pressure
fi


echo
echo "=== Control plane ==="

CP_TOTAL=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l | tr -d ' ')
CP_READY=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | grep -c ' Ready')

echo "control plane nodes Ready: $CP_READY/$CP_TOTAL"

# Three control plane nodes tolerate exactly one failure. Two down means etcd
# has no quorum and the API server goes read-only.
if [ "$CP_READY" -lt 2 ]; then
    problem "ETCD QUORUM LOST: only $CP_READY/$CP_TOTAL control plane nodes Ready"
elif [ "$CP_READY" -lt "$CP_TOTAL" ]; then
    problem "control plane degraded ($CP_READY/$CP_TOTAL) - no margin left"
fi

# The API server runs its own health checks and publishes the results. A failing
# check is prefixed with [-] instead of [+].
echo
echo "failing API server health checks:"
FAILING=$(kubectl get --raw='/readyz?verbose' 2>/dev/null | grep '^\[-\]')

if [ -z "$FAILING" ]; then
    echo "  none"
else
    echo "$FAILING" | sed 's/^/  /'
    problem "API server health checks failing"
fi


echo
echo "=== etcd ==="

# K3s embeds etcd, so there is no etcdctl binary on the nodes to query. But etcd
# publishes Prometheus metrics on port 2381, which needs no client and no certs.
# Read them over SSH from one control plane node.
#
# Grab the whole page once rather than SSHing repeatedly for each number.
ETCD_METRICS=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$CP_NODE" \
    'curl -s http://127.0.0.1:2381/metrics' 2>/dev/null)

if [ -z "$ETCD_METRICS" ]; then
    echo "  could not reach etcd metrics on $CP_NODE:2381"
else
    # The database has a 2GB quota by default. Past it, etcd goes read-only and
    # the whole cluster follows. Well worth knowing before that happens.
    DB_BYTES=$(echo "$ETCD_METRICS" | awk '/^etcd_mvcc_db_total_size_in_bytes/ {print $2}')
    DB_MB=$(echo "$DB_BYTES" | awk '{printf "%.0f", $1 / 1048576}')

    echo "database size: ${DB_MB}MB (quota is 2048MB)"
    [ "$DB_MB" -gt 1500 ] && problem "etcd database is ${DB_MB}MB, approaching the 2048MB quota"

    # No leader means etcd cannot accept writes at all. This is as bad as it gets.
    # The metric is 1 when a leader exists, 0 when one does not.
    HAS_LEADER=$(echo "$ETCD_METRICS" | awk '/^etcd_server_has_leader/ {print $2}')

    if [ "$HAS_LEADER" = "1" ]; then
        echo "leader: present"
    else
        problem "ETCD HAS NO LEADER - the cluster cannot accept writes"
    fi

    # Leader elections should be rare, but a handful over months of uptime is
    # normal and means nothing. Only say anything when the count is high enough to
    # suggest the CP nodes keep losing contact with each other, which points at
    # disk or network latency rather than at etcd itself.
    #
    # Printing the raw number every run just invites worry with nothing to do
    # about it, so it is only shown when it crosses the threshold.
    ELECTIONS=$(echo "$ETCD_METRICS" | awk '/^etcd_server_leader_changes_seen_total/ {print $2}')

    if [ -n "$ELECTIONS" ] && [ "${ELECTIONS%.*}" -gt 10 ]; then
        echo "leader changes since boot: $ELECTIONS"
        problem "etcd has changed leader $ELECTIONS times - check CP disk and network latency"
    fi

    # etcd commits every write to disk before acknowledging it. If that fsync is
    # slow, everything above it is slow, and on a VM the usual cause is the
    # Proxmox host being busy rather than anything wrong with etcd.
    #
    # The metric is a histogram. Its _sum and _count give the running average.
    FSYNC_SUM=$(echo "$ETCD_METRICS" | awk '/^etcd_disk_wal_fsync_duration_seconds_sum/ {print $2}')
    FSYNC_COUNT=$(echo "$ETCD_METRICS" | awk '/^etcd_disk_wal_fsync_duration_seconds_count/ {print $2}')

    if [ -n "$FSYNC_SUM" ] && [ -n "$FSYNC_COUNT" ]; then
        echo "$FSYNC_SUM $FSYNC_COUNT" | awk '{
            avg_ms = ($1 / $2) * 1000
            printf "average fsync: %.1fms", avg_ms
            if (avg_ms > 25) printf "   <-- SLOW, disk cannot keep up with etcd"
            printf "\n"
        }'

        # 25ms is etcd own warning threshold. Past that it starts logging
        # "apply request took too long".
        SLOW=$(echo "$FSYNC_SUM $FSYNC_COUNT" | awk '{ if (($1 / $2) * 1000 > 25) print "yes" }')
        [ "$SLOW" = "yes" ] && problem "etcd fsync is slow - check disk latency on the control plane nodes"
    fi
fi

echo
echo "etcd snapshots:"

SNAPSHOT_DIR=/var/lib/rancher/k3s/server/db/snapshots
NEWEST=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$CP_NODE" \
    "sudo ls -t $SNAPSHOT_DIR 2>/dev/null | head -1")

if [ -z "$NEWEST" ]; then
    problem "no etcd snapshots found"
    echo "  none"
else
    SNAPSHOT_TIME=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$SSH_USER@$CP_NODE" \
        "sudo stat -c %Y $SNAPSHOT_DIR/$NEWEST")
    AGE_HOURS=$(( ($(date +%s) - SNAPSHOT_TIME) / 3600 ))

    echo "  newest: $NEWEST (${AGE_HOURS}h old)"
    [ "$AGE_HOURS" -gt 24 ] && problem "newest etcd snapshot is ${AGE_HOURS}h old"
fi


echo
echo "=== Workloads ==="

# DO NOT parse the default 'kubectl get pods' table. Its columns are a display
# format, not data: once a pod has restarted, the RESTARTS column reads
# "10 (2d1h ago)", which shifts every field after it. Ask for the fields by name
# instead, and they arrive one per column, always.
#
# STATUS here is .status.phase, which is Running / Pending / Failed / Succeeded.
# Note that a finished Job shows as Succeeded in the phase, even though the
# default table prints it as "Completed".
PODS=$(kubectl get pods -A -o custom-columns=\
NS:.metadata.namespace,\
NAME:.metadata.name,\
PHASE:.status.phase,\
READY:.status.containerStatuses[*].ready,\
RESTARTS:.status.containerStatuses[*].restartCount \
    --no-headers)

echo "pods not Running or Succeeded:"
BROKEN=$(echo "$PODS" | awk '$3 != "Running" && $3 != "Succeeded" {print $1"/"$2, $3}')

if [ -z "$BROKEN" ]; then
    echo "  none"
else
    echo "$BROKEN" | sed 's/^/  /'
    problem "$(echo "$BROKEN" | wc -l | tr -d ' ') pods not Running or Succeeded"
fi

# A pod can be Running while its containers are not Ready. The READY column here
# is a comma separated list, one true/false per container, so a pod is unhealthy
# if any entry is false.
echo
echo "pods Running but not Ready:"
NOT_READY_PODS=$(echo "$PODS" | awk '$3 == "Running" && $4 ~ /false/ {print $1"/"$2, "ready="$4}')

if [ -z "$NOT_READY_PODS" ]; then
    echo "  none"
else
    echo "$NOT_READY_PODS" | sed 's/^/  /'
    problem "$(echo "$NOT_READY_PODS" | wc -l | tr -d ' ') pods Running but not Ready"
fi

# Restarts accumulate silently. A pod with 200 restarts is still "Running".
#
# RESTARTS is one count per container, comma separated, so add them up. Only look
# at Running pods: a Succeeded Job that retried a few times is not a live problem.
echo
echo "pods with more than 10 restarts:"
RESTARTING=$(echo "$PODS" | awk '$3 == "Running" {
    split($5, counts, ",")
    total = 0
    for (i in counts) total += counts[i]
    if (total > 10) print $1"/"$2, total" restarts"
}')

if [ -z "$RESTARTING" ]; then
    echo "  none"
else
    echo "$RESTARTING" | sed 's/^/  /'
    problem "pods with high restart counts (see above)"
fi

# Pending pods have a reason, but 'get pods' does not show it. It lives in the
# events, and it is usually "insufficient memory" or "no nodes available".
PENDING=$(echo "$PODS" | awk '$3 == "Pending" {print $1, $2}')

if [ -n "$PENDING" ]; then
    echo
    echo "why pods are Pending:"
    echo "$PENDING" | while read -r NAMESPACE POD; do
        REASON=$(kubectl -n "$NAMESPACE" get events \
            --field-selector "involvedObject.name=$POD,reason=FailedScheduling" \
            -o jsonpath='{.items[-1:].message}' 2>/dev/null)
        echo "  $NAMESPACE/$POD: ${REASON:-no scheduling event found}"
    done
    problem "pods stuck Pending"
fi


echo
echo "=== Storage ==="

echo "storage classes:"
kubectl get sc | sed 's/^/  /'

echo
echo "PVCs not Bound:"
UNBOUND=$(kubectl get pvc -A --no-headers | grep -v Bound)

if [ -z "$UNBOUND" ]; then
    echo "  none"
else
    echo "$UNBOUND" | sed 's/^/  /'
    problem "PVCs not Bound"
fi

echo
echo "Longhorn volumes:"
kubectl -n longhorn-system get volumes \
    -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,WANT:.spec.numberOfReplicas,ATTACHED:.status.currentNodeID \
    | sed 's/^/  /'

# Replicas are spread across all three workers, but the volume itself attaches to
# whichever node runs the pod using it. Those are different things, and the second
# one clusters: several volumes commonly end up attached to the same node.
#
# That node then becomes the expensive one to drain, because every volume on it
# has to detach and reattach elsewhere at the same time. Worth knowing which node
# that is before one is chosen to be worked on.
echo
echo "volumes attached per node:"
kubectl -n longhorn-system get volumes \
    -o custom-columns=NODE:.status.currentNodeID --no-headers \
    | sort | uniq -c | awk '{print "  " $2 ": " $1}'

# THE CHECK THAT MATTERS MOST.
#
# A volume below its desired replica count has no redundancy margin. Rebooting or
# draining on top of that is how a recoverable state becomes data loss.
#
# The volume's own 'robustness' field lags behind reality, so count the running
# replicas directly and compare against what the volume asked for.
echo
echo "replica counts:"

REPLICAS=$(kubectl -n longhorn-system get replicas \
    -o custom-columns=VOLUME:.spec.volumeName,STATE:.status.currentState,NODE:.spec.nodeID \
    --no-headers)

for VOLUME in $(kubectl -n longhorn-system get volumes -o name | cut -d/ -f2); do
    WANTED=$(kubectl -n longhorn-system get volume "$VOLUME" -o jsonpath='{.spec.numberOfReplicas}')
    RUNNING=$(echo "$REPLICAS" | awk -v v="$VOLUME" '$1 == v && $2 == "running"' | wc -l | tr -d ' ')

    # A rebuilding replica is Longhorn working, not Longhorn stuck. It happens
    # after every drain and reboot and it finishes on its own. Only report a
    # problem when replicas are missing and nothing is replacing them.
    REBUILDING=$(echo "$REPLICAS" | awk -v v="$VOLUME" \
        '$1 == v && $2 == "rebuilding"' | wc -l | tr -d ' ')

    if [ "$RUNNING" -ge "$WANTED" ]; then
        echo "  $VOLUME: $RUNNING/$WANTED"

    elif [ "$REBUILDING" -gt 0 ]; then
        echo "  ${YELLOW}$VOLUME: $RUNNING/$WANTED ($REBUILDING rebuilding)${RESET}"
        echo "$REPLICAS" | awk -v v="$VOLUME" '$1 == v {print "      " $3 " " $2}'

    else
        echo "  ${RED}$VOLUME: $RUNNING/$WANTED, nothing rebuilding${RESET}"
        echo "$REPLICAS" | awk -v v="$VOLUME" '$1 == v {print "      " $3 " " $2}'
        problem "DEGRADED VOLUME: $VOLUME has $RUNNING/$WANTED replicas and nothing is rebuilding it"
    fi
done

# Longhorn will not place a replica on a node without room, and it fails silently
# and permanently. This is where "why won't it rebuild" gets answered.
#
# The number that matters is storageAvailable minus the reservation, not raw free
# disk. Longhorn holds back a percentage of each disk (25% by default) and will
# not schedule into it. So a node can look half empty in df and still refuse a
# replica.
#
# Ask for the fields by path. Grepping the JSON would depend on how it happens to
# be formatted, which is not something to rely on. Sizes come back in bytes.
echo
echo "Longhorn node capacity:"
printf "  %-12s %10s %10s %10s  %s\n" "NODE" "FREE" "RESERVED" "USABLE" "SCHEDULING"

for NODE in $(kubectl -n longhorn-system get nodes.longhorn.io -o name | cut -d/ -f2); do

    ALLOWED=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.spec.allowScheduling}')

    # A node can have several disks, so these come back space separated. These
    # homelab nodes have one each.
    AVAILABLE=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.status.diskStatus.*.storageAvailable}')
    MAXIMUM=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.status.diskStatus.*.storageMaximum}')
    RESERVED=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.spec.disks.*.storageReserved}')

    # Usable space is what Longhorn will actually schedule into.
    echo "$AVAILABLE $RESERVED" | awk -v node="$NODE" -v sched="$ALLOWED" '{
        gb = 1073741824
        usable = ($1 - $2) / gb
        if (usable < 0) usable = 0
        printf "  %-12s %9.1fG %9.1fG %9.1fG  %s\n", node, $1 / gb, $2 / gb, usable, sched
    }'

    if [ "$ALLOWED" != "true" ]; then
        problem "Longhorn scheduling disabled on $NODE"
    fi
done

# Can the biggest volume find a home? Longhorn insists each replica sits on a
# different node, so with three workers and three replicas there is no slack:
# every worker must be able to hold every volume.
echo
echo "can every node hold the largest volume?"

LARGEST=$(kubectl -n longhorn-system get volumes \
    -o custom-columns=SIZE:.spec.size --no-headers \
    | sort -n | tail -1)

LARGEST_GB=$(echo "$LARGEST" | awk '{printf "%.1f", $1 / 1073741824}')
echo "  largest volume: ${LARGEST_GB}G"

for NODE in $(kubectl -n longhorn-system get nodes.longhorn.io -o name | cut -d/ -f2); do

    AVAILABLE=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.status.diskStatus.*.storageAvailable}')
    RESERVED=$(kubectl -n longhorn-system get nodes.longhorn.io "$NODE" \
        -o jsonpath='{.spec.disks.*.storageReserved}')

    FITS=$(echo "$AVAILABLE $RESERVED $LARGEST" | awk '{
        if (($1 - $2) > $3) print "yes"; else print "no"
    }')

    if [ "$FITS" = "yes" ]; then
        echo "  $NODE: yes"
    else
        echo "  ${RED}$NODE: NO - not enough usable space${RESET}"
        problem "$NODE cannot fit a ${LARGEST_GB}G replica - this is why rebuilds stall"
    fi
done

# The engine image runs the volume. If it is not deployed on a node, volumes
# cannot attach there, and the error returned says nothing about engine images.
echo
echo "engine images:"
kubectl -n longhorn-system get engineimages.longhorn.io \
    -o custom-columns=NAME:.metadata.name,STATE:.status.state,REFS:.status.refCount \
    --no-headers | sed 's/^/  /'

BAD_ENGINE=$(kubectl -n longhorn-system get engineimages.longhorn.io \
    -o custom-columns=NAME:.metadata.name,STATE:.status.state --no-headers \
    | awk '$2 != "deployed" {print $1}')

for IMAGE in $BAD_ENGINE; do
    problem "engine image not deployed: $IMAGE (volumes cannot attach without it)"
done

echo
echo "recurring jobs:"
kubectl -n longhorn-system get recurringjobs.longhorn.io \
    -o custom-columns=NAME:.metadata.name,TASK:.spec.task,CRON:.spec.cron,RETAIN:.spec.retain \
    --no-headers 2>/dev/null | sed 's/^/  /'

# The jobs run as CronJobs, so their pods carry the result. A Failed pod in the
# last day means snapshots are not being taken.
FAILED_JOBS=$(kubectl -n longhorn-system get pods \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers \
    | awk '$2 == "Failed" {print $1}')

for JOB in $FAILED_JOBS; do
    problem "recurring job pod failed: $JOB (snapshots may not be running)"
done

# No backup target means no offsite copy. Replication is not backup: it protects
# against a disk dying, not against deleting the wrong thing.
BACKUP_TARGET=$(kubectl -n longhorn-system get settings.longhorn.io backup-target \
    -o jsonpath='{.value}' 2>/dev/null)

echo
if [ -z "$BACKUP_TARGET" ]; then
    echo "backup target: ${YELLOW}not set${RESET}"
    problem "Longhorn backup target is unset - no backups exist"
else
    echo "backup target: $BACKUP_TARGET"
fi


echo
echo "=== PodDisruptionBudgets ==="
kubectl get pdb -A | sed 's/^/  /'

# A PDB showing 0 allowed disruptions blocks eviction, for two very different
# reasons that are dangerous to confuse:
#
#   WAIT   Longhorn creates the instance-manager and csi-* PDBs itself and
#          removes them once volumes detach. They correctly show 0 allowed while
#          volumes are attached. Force-deleting those pods rips volumes out from
#          under running workloads. Wait them out.
#
#   FAIL   minAvailable >= the number of pods that exist. Nothing satisfies it,
#          so waiting never helps and the drain retries forever. Fix the PDB.
#
# The numbers cannot tell them apart - both can read minAvailable=1 against a
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

echo
echo "PDBs blocking eviction:"

# Clear the scratch file in case a previous run died before cleaning up.
rm -f /tmp/k3s-diag-broken-pdbs

# Column 5 is ALLOWED DISRUPTIONS.
BLOCKED=$(kubectl get pdb -A --no-headers | awk '$5 == 0 {print $1, $2, $3}')

if [ -z "$BLOCKED" ]; then
    echo "  none"
else
    echo "$BLOCKED" | while read -r NAMESPACE NAME MIN_AVAILABLE; do
        if is_longhorn_managed "$NAME"; then
            echo "  ${YELLOW}WAIT${RESET}  $NAMESPACE/$NAME - Longhorn-managed, clears when volumes detach"
        else
            EXPECTED=$(kubectl -n "$NAMESPACE" get pdb "$NAME" -o jsonpath='{.status.expectedPods}')

            if [ "$MIN_AVAILABLE" != "N/A" ] && [ "$MIN_AVAILABLE" -ge "$EXPECTED" ]; then
                echo "  ${RED}BROKEN${RESET}  $NAMESPACE/$NAME - minAvailable=$MIN_AVAILABLE but only $EXPECTED pod(s) exist"
                echo "$NAMESPACE/$NAME" >> /tmp/k3s-diag-broken-pdbs
            else
                echo "  ${YELLOW}WAIT${RESET}  $NAMESPACE/$NAME - 0 allowed now, should clear on its own"
            fi
        fi
    done

    # The while loop above ran in a subshell (because of the pipe), so it could
    # not add to PROBLEMS directly. Collect what it wrote to disk instead.
    if [ -f /tmp/k3s-diag-broken-pdbs ]; then
        while read -r PDB; do
            problem "unsatisfiable PDB: $PDB (blocks every drain forever)"
        done < /tmp/k3s-diag-broken-pdbs
        rm -f /tmp/k3s-diag-broken-pdbs
    fi
fi


echo
echo "=== Network ==="

echo "CoreDNS:"
kubectl -n kube-system get pods -l k8s-app=kube-dns | sed 's/^/  /'

# Count the pods whose phase is actually Running, rather than grepping the table
# (which would also match a pod whose NAME happened to contain the word).
COREDNS_READY=$(kubectl -n kube-system get pods -l k8s-app=kube-dns \
    -o custom-columns=PHASE:.status.phase --no-headers \
    | grep -c Running)

[ "$COREDNS_READY" -eq 0 ] && problem "no CoreDNS pods running - cluster DNS is down"

echo
echo "LoadBalancer services:"
kubectl get svc -A --field-selector spec.type=LoadBalancer | sed 's/^/  /'

# A LoadBalancer with no external IP means MetalLB never gave it one, usually
# because the address pool is exhausted. Ask for the field directly: an
# unassigned service simply has nothing under status.loadBalancer, which
# custom-columns renders as <none>.
PENDING_LB=$(kubectl get svc -A --field-selector spec.type=LoadBalancer \
    -o custom-columns=\
NS:.metadata.namespace,\
NAME:.metadata.name,\
IP:.status.loadBalancer.ingress[0].ip \
    --no-headers \
    | awk '$3 == "<none>" {print $1"/"$2}')

for SVC in $PENDING_LB; do
    problem "LoadBalancer has no external IP: $SVC"
done

echo
echo "ingresses:"
kubectl get ingress -A | sed 's/^/  /'

# Zero NetworkPolicies means every pod can reach every other pod. Worth knowing
# even if we decided to live with it for now.
NETPOL_COUNT=$(kubectl get networkpolicy -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo
echo "network policies: $NETPOL_COUNT"
[ "$NETPOL_COUNT" -eq 0 ] && problem "zero NetworkPolicies - all pod-to-pod traffic is allowed"


echo
echo "=== Certificates ==="

kubectl get certificates -A | sed 's/^/  /'

# A cert that is not Ready will not renew.
# Read the Ready condition by name rather than by column position.
NOT_READY_CERTS=$(kubectl get certificates -A \
    -o custom-columns=\
NS:.metadata.namespace,\
NAME:.metadata.name,\
"READY:.status.conditions[?(@.type=='Ready')].status" \
    --no-headers \
    | awk '$3 != "True" {print $1"/"$2}')

for CERT in $NOT_READY_CERTS; do
    problem "certificate not Ready: $CERT"
done


echo
echo "=== Recent warnings ==="

WARNINGS=$(kubectl get events -A --field-selector type=Warning --no-headers 2>/dev/null \
    | sort -rn -k2 | head -10)

if [ -z "$WARNINGS" ]; then
    echo "  none"
else
    echo "$WARNINGS" | sed 's/^/  /'
fi


echo
echo "=== Helm releases ==="
helm list -A 2>/dev/null | sed 's/^/  /'

FAILED_RELEASES=$(helm list -A --failed --pending --no-headers 2>/dev/null | awk '{print $1}')

for RELEASE in $FAILED_RELEASES; do
    problem "Helm release not deployed: $RELEASE"
done


echo
echo "========================================"
echo "SUMMARY"
echo "========================================"

if [ ${#PROBLEMS[@]} -eq 0 ]; then
    echo "No problems found."
    exit 0
fi

echo
for ISSUE in "${PROBLEMS[@]}"; do
    echo "  - $ISSUE"
done

echo
echo "${#PROBLEMS[@]} problem(s) found."
exit 1
