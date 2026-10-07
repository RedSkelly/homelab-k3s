# ADR 0004: Backup and restore

## Status

Proposed, 2026-10-07. Decides what is backed up, by which mechanism, and how restores are proven. Target storage is not yet chosen (see Open decisions). ADR 0003 has Git rebuild every layer; this record covers the data Git cannot hold.

## Current state

Verified 2026-10-06 and 2026-10-07 with kubectl and SSH to each server.

- Each server takes an etcd snapshot every 6 hours and keeps 30 (`config.yaml`). No `etcd-s3` settings exist, and every `ETCDSnapshotFile` record points to a local file. The newest snapshots are 25-33 MiB.
- Longhorn `backup-target` is empty. The only recurring job, `hourly-snapshots`, takes snapshots (not backups) every hour and keeps 24; snapshots live on the same disks as the volume's replicas.
- Longhorn holds three volumes, 45 GiB provisioned: Prometheus 30 GiB, Grafana 10 GiB, Alertmanager 5 GiB. Prometheus reports 57.1 GiB actual size, above its provisioned size, because Longhorn's actual size counts retained snapshots.
- The age private key exists on each workstation and as the `argocd/sops-age` Secret. No offline copy is recorded.
- The k3s server token is in the `k3s.service` unit on k3s-cp-02 and k3s-cp-03. No copy is in Git.
- No process in this repo backs up OPNsense or MikroTik configuration.

## Decision

Backups use built-in mechanisms only:

| Data | Mechanism | Owner |
|---|---|---|
| Longhorn volume data | Longhorn backup target and a recurring backup job | Argo CD (Longhorn settings) |
| etcd | k3s `etcd-s3` settings, alongside the local snapshots | Ansible (server `config.yaml`) |
| OPNsense and MikroTik configuration | Scheduled exports, kept out of Git because they are state | Ansible playbook |
| age private key | A second `.sops.yaml` recipient whose private key is kept offline | Operator |
| k3s server token | SOPS file in Git, current and retired values | Ansible reads it |

- **Without the age private key, no secret in Git can be decrypted and a rebuild cannot complete.** The offline recipient makes the loss of the working key recoverable.
- Restoring an etcd snapshot requires the server token in use when it was taken [1]. A token rotation (ADR 0003) keeps the retired value in SOPS while snapshots taken under it remain.
- A rebuild from Git does not need etcd. etcd backups serve faster or partial recovery and any object not yet in Git.
- Alerts fire when the newest etcd snapshot or Longhorn backup is older than its schedule allows.
- `docs/disaster-recovery.md` (planned) records the restore order: hosts, guests, OS and k3s, bootstrap, Argo CD, volume restores.

## Targets

Leaning, not decided:

- Longhorn to an external HDD. Longhorn writes backups over NFS, SMB, or S3, so the disk needs a host that serves one of them. The disk can move to another host if its host fails, but volume data then has no off-site copy.
- etcd to S3-compatible object storage. At 25-33 MiB per snapshot, an off-site copy is small.

Any target sits outside the failure domain it protects: never on a k3s node, and for etcd not on a Proxmox host.

## Not adopted

| Option | Reason |
|---|---|
| Velero | Git holds the Kubernetes resources and Longhorn backs up the volumes; Velero would duplicate both. |
| Longhorn snapshots as backups | They live on the same disks as the replicas they protect. |

## Verification

- A Longhorn backup restored into a new volume, with its data read back.
- An etcd snapshot restored into a single-node k3s outside the cluster (a workstation VM), using the token from SOPS.
- A SOPS file decrypted with the offline recovery key alone.
- Each test repeated after a change of target.

## Sequencing

- First in ADR 0003's adoption order. ADR 0001 waits on the etcd target and the age recovery key.
- The etcd target needs the narrow first Ansible role (ADR 0003). The Longhorn target and the age recipient need no new tooling.

## Open decisions

1. Longhorn target: whether the external HDD is chosen, which host serves it and over which protocol, and whether volume data needs an off-site copy.
2. etcd target: whether S3 is chosen, and which provider.
3. Which volumes are backed up. Prometheus is 30 GiB provisioned and holds metrics history; Grafana and Alertmanager hold 0.76 GiB combined.
4. Longhorn backup schedule and retention.
5. Where network device exports are stored.

## References

1. k3s docs, Backup and Restore: https://docs.k3s.io/datastore/backup-restore
