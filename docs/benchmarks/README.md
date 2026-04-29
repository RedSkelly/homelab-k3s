# Benchmarks

Baseline performance measurements for the homelab platform. Re-run after significant infrastructure changes to detect regressions.

## Index

| Benchmark | What It Measures | Last Run |
|-----------|-----------------|----------|
| [storage-replication](storage-replication/) | VLAN 20 network throughput (iperf3) + Longhorn replicated I/O (fio) | 2026-04-29 |

## When to Re-run

- Longhorn version upgrade
- Kernel upgrade on worker nodes
- NIC driver or firmware update (Mellanox)
- MikroTik switch configuration change (MTU, VLAN, QoS)
- Longhorn replica count or StorageClass parameter change
- After enabling jumbo frames on VLAN 20

## How Results Are Stored

Each benchmark directory contains:

- `prompt.md` — the Claude Code prompt used to run the benchmark
- `YYYY-MM-DD-results.md` — results from each run, dated for comparison over time

Keep previous results files when re-running so regressions are visible in git history.
