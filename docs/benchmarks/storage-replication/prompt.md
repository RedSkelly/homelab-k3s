# Claude Code Prompt — Test East-West Storage Replication Speed

**Target:** Claude Code | Optimized for agentic SSH-based benchmarking across a known cluster topology with explicit stop conditions and non-destructive constraints.

---

## Context (carry forward)

- K3s v1.34 cluster: 3 control plane + 3 worker nodes on VLAN 10
- Workers: k3s-wk-01, k3s-wk-02, k3s-wk-03 (2 vCPU / 12GB RAM / 64GB OS disk on NVMe, Longhorn storage on 1TB SATA SSD)
- Longhorn v1.6.2 is the sole default StorageClass with replica count of 3
- Storage replication traffic runs on **VLAN 20** over a dedicated MikroTik CRS305 access switch — isolated east-west, not routed through OPNsense
- All nodes have **Mellanox dual 10GbE SFP+** NICs
- SSH user: `k3s` (passwordless sudo on all nodes)
- Kubeconfig context: `homelab`, pointing at kube-vip VIP
- Management host has kubectl, helm, jq installed
- This is a homelab — do not assume unlimited resources. Keep test PVCs small (1–2Gi max)

---

## Objective

Benchmark both the raw VLAN 20 network speed between worker nodes (iperf3) and the effective Longhorn storage replication throughput (fio). Produce a clear summary that separates network performance from storage performance so the bottleneck is identifiable.

## Steps

1. **Pre-flight checks:**
   - Verify all 3 worker nodes are `Ready` and schedulable.
   - Verify Longhorn is healthy: `kubectl -n longhorn-system get pods` — all pods Running.
   - Check current Longhorn default replica count (`kubectl get storageclass longhorn -o yaml`).
   - Report node names, Longhorn health, and replica count before proceeding.
   - Checkpoint: Output pre-flight summary.

2. **Benchmark raw VLAN 20 network speed (iperf3):**
   - SSH to the worker nodes and identify the VLAN 20 interface and its IP on each worker. Longhorn's storage network setting or the node's interface list (`ip -br addr`) will show which interface carries VLAN 20 traffic. Report the interface name and IP for each worker.
   - Run `iperf3` between worker node pairs using the VLAN 20 IPs specifically (NOT the VLAN 10 / primary IPs). If iperf3 is not installed, install it temporarily (`sudo apt-get install -y iperf3`) — this is the ONE exception to the no-host-install rule, and it MUST be removed in cleanup.
   - Test all 3 pairs: wk-01↔wk-02, wk-01↔wk-03, wk-02↔wk-03.
   - For each pair run: `iperf3 -c <VLAN20_IP> -t 10 -P 4 --json` (10 seconds, 4 parallel streams).
   - Parse JSON output. Extract: total bandwidth (Gbps), retransmits.
   - Checkpoint: Output a table of network bandwidth per worker pair. Flag if any pair is significantly below 9 Gbps (expected for 10GbE with overhead).

3. **Create a test namespace and PVC:**
   - Create namespace `storage-bench` (or reuse if it exists).
   - Create a 2Gi PVC using the `longhorn` StorageClass.
   - Wait for the PVC to be Bound (timeout: 120s).
   - Checkpoint: Confirm PVC is Bound and report which node the volume is attached to.

4. **Deploy a benchmark pod:**
   - Deploy a pod (use `ubuntu:24.04` or `alpine` image) that mounts the PVC at `/data`.
   - Install `fio` inside the pod (apt-get or apk).
   - The pod MUST run on a **worker node** (use nodeSelector `node-role.kubernetes.io/worker` or match worker hostnames).
   - Wait for the pod to be Running (timeout: 120s).
   - Checkpoint: Confirm pod is Running and which worker node it landed on.

5. **Run fio benchmarks (sequential and random):**
   - **Sequential write:** `fio --name=seq-write --ioengine=libaio --direct=1 --bs=1M --size=1G --numjobs=1 --rw=write --group_reporting --output-format=json --filename=/data/seq-test.dat`
   - **Sequential read:** `fio --name=seq-read --ioengine=libaio --direct=1 --bs=1M --size=1G --numjobs=1 --rw=read --group_reporting --output-format=json --filename=/data/seq-test.dat`
   - **Random write (4K):** `fio --name=rand-write --ioengine=libaio --direct=1 --bs=4k --size=256M --numjobs=4 --iodepth=32 --rw=randwrite --group_reporting --output-format=json --filename=/data/rand-test.dat`
   - **Random read (4K):** `fio --name=rand-read --ioengine=libaio --direct=1 --bs=4k --size=256M --numjobs=4 --iodepth=32 --rw=randread --group_reporting --output-format=json --filename=/data/rand-test.dat`
   - Parse JSON output from each run. Extract: bandwidth (MB/s), IOPS, average latency (usec), p99 latency.
   - Checkpoint: Output a formatted results table after all 4 tests complete.

6. **Check replica placement:**
   - Use `kubectl -n longhorn-system get replicas.longhorn.io` (or the Longhorn API) to identify which nodes hold replicas of the test volume.
   - Report replica placement — this confirms replication actually crossed VLAN 20.
   - Checkpoint: Output replica node list.

7. **Produce summary:**
   - Print two tables: (1) iperf3 network bandwidth per worker pair, and (2) fio storage benchmarks (bandwidth, IOPS, avg latency, p99 latency).
   - Note the replica count and which nodes held replicas.
   - Compare: iperf3 bandwidth (raw VLAN 20 capacity) vs fio sequential write throughput (Longhorn end-to-end) vs SATA SSD theoretical max (~500 MB/s). This isolates whether the bottleneck is network, disk, or Longhorn overhead.
   - Flag any anomalies (iperf3 retransmits, latency spikes, unexpectedly low throughput on any leg).

8. **Cleanup:**
   - Delete the benchmark pod.
   - Delete the PVC.
   - Delete the `storage-bench` namespace.
   - Remove iperf3 from all worker nodes if it was installed: `sudo apt-get remove -y iperf3 && sudo apt-get autoremove -y`.
   - Checkpoint: Confirm all test resources and packages are removed.

## Allowed Actions

- Run kubectl commands against context `homelab`
- Create and delete resources ONLY in the `storage-bench` namespace
- SSH to nodes via `ssh k3s@<hostname>` for read-only inspection if needed (e.g., checking VLAN 20 interface stats)
- Install packages inside the benchmark pod only
- Install iperf3 temporarily on worker nodes via SSH for network testing — MUST be removed in cleanup

## Forbidden Actions

- Do NOT modify any existing Longhorn settings, StorageClasses, or volumes
- Do NOT create resources outside the `storage-bench` namespace
- Do NOT drain, cordon, or reboot any node
- Do NOT install anything on the host nodes except iperf3 (temporary, removed in cleanup)
- Do NOT modify Helm releases or cluster-level configuration
- Do NOT push to git

## Stop Conditions

Pause and ask for human review when:
- Any worker node is NotReady or has scheduling issues
- Longhorn reports degraded volumes or unhealthy pods
- PVC does not bind within 120s
- fio reports errors or the pod crashes during benchmarking
- An error cannot be resolved in 2 attempts
- Any action would need to touch resources outside `storage-bench` namespace
