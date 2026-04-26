# Documentation

Architecture docs, decision records, and operational runbooks. Supplements inline README files in each component directory.

## What belongs here

| Document                     | Purpose                                                  |
|------------------------------|----------------------------------------------------------|
| `architecture.md`           | Network topology, cluster layout, data flow diagrams      |
| `adr/`                      | Architecture Decision Records (numbered, immutable)       |
| `runbooks/`                 | Step-by-step procedures for operational tasks              |
| `disaster-recovery.md`      | Rebuild-from-scratch procedure using this repo             |

## Architecture Decision Records (ADRs)

Use ADRs to document significant choices:

- Why Argo CD over Flux
- Why embedded etcd over external datastore
- Why Longhorn over Ceph/NFS
- Why SOPS+age over Sealed Secrets
- Why kube-vip over keepalived

## Runbooks

Step-by-step procedures for:

- Node drain/reboot (CP vs worker sequences)
- K3s version upgrade
- etcd backup and restore
- Longhorn volume recovery
- Certificate renewal
