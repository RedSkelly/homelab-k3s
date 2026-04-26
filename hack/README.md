# Hack — Utility Scripts

Operational scripts and helpers that don't fit neatly into Terraform, Ansible, or Kubernetes manifests.

## What belongs here

| Script                   | Purpose                                                    |
|--------------------------|------------------------------------------------------------|
| `kubeconfig-fix.sh`      | Fix kube-vip VIP address in kubeconfig after K3s restart   |
| `etcd-health.sh`         | Check etcd cluster health across all CP nodes              |
| `longhorn-health.sh`     | Verify Longhorn volume/replica health before drain         |
| `rolling-reboot.sh`      | Orchestrated node reboot with health gates                 |
| `helm-cleanup.sh`        | Purge old Helm release revisions (HELM_MAX_HISTORY)        |

## Design notes

- Scripts here are operational helpers, not deployment tools
- As the IaC stack matures, many of these should migrate into Ansible playbooks or CI pipelines
- All scripts should be idempotent and safe to run repeatedly
- Include usage comments and validation (check prereqs before executing)
