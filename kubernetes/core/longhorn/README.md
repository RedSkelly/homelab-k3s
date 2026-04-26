# Longhorn

Distributed block storage providing the sole default StorageClass for the cluster.

## What belongs here

- `values.yaml` — Helm chart values (when migrated from kubectl manifest to Helm)
- `application.yaml` — Argo CD Application CRD
- `storageclass.yaml` — StorageClass definition (if overriding defaults)

## Design notes

- Current version: v1.6.2, installed via kubectl manifest
- **Migration candidate:** move from raw manifest to Helm chart under Helmfile/Argo CD
- Sole default StorageClass — nothing else provides PVs
- Backup target is currently unconfigured (known open item)
- Replica count should respect cluster size (3 workers = max 3 replicas)
- Longhorn replica health is a hard gate for node drain/reboot operations
- Worker nodes need `open-iscsi` and `nfs-common` packages (handled by Ansible `longhorn` role)
