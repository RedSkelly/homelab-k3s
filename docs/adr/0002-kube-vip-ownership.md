# ADR 0002: kube-vip ownership

## Status

Proposed, 2026-10-06. Decides which tool owns kube-vip, the API server VIP. Migration steps are out of scope.

## Current state

Verified 2026-10-06 with kubectl and SSH to each server.

- kube-vip v0.8.2 runs as the DaemonSet `kube-vip` in `kube-system`, one pod per control-plane node, and holds the API VIP 10.0.10.49 by ARP with leader election. Its settings are listed in `kubernetes/core/kube-vip/README.md`.
- k3s applies the DaemonSet from `/var/lib/rancher/k3s/server/manifests/kube-vip.yaml` (AddOn `kube-vip`). Which servers hold that file was not checked. No copy is in Git.
- Field managers on the DaemonSet: `kubectl` client-side apply on 2026-01-08, `kubectl patch` on 2026-01-09, `k3s` on 2026-07-14. Whether the node file includes the 2026-01-09 patch is unknown.
- k3s-cp-02, k3s-cp-03, and all three workers joined through `https://10.0.10.50:6443` (k3s-cp-01), not through the VIP.
- Control-plane nodes carry the `node-role.kubernetes.io/control-plane:NoSchedule` taint, and every Argo CD pod runs on a worker. All Argo CD Applications target `https://kubernetes.default.svc`, not the VIP.
- The workstation kubeconfig points at `https://10.0.10.49:6443`, and each server's `config.yaml` lists 10.0.10.49 under `tls-san`.

## Options considered

- Ansible places a static pod or the k3s auto-deploy file. Either brings the VIP up before Argo CD exists, which is needed only when nodes join through the VIP. They do not, and Ansible does not exist yet.
- Helmfile. Reserved for bootstrap and break-glass; kube-vip does not need to precede Argo CD.
- No change. The configuration stays only on a node, so a rebuild from the repo has no kube-vip.
- Argo CD (proposed). It runs today, reports drift, and gives Renovate a pinned version to bump. Neither depends on the other at runtime: the DaemonSet keeps running if Argo CD fails, and Argo CD does not use the VIP.

## Proposed target state

- An Argo CD Application owns kube-vip from Git, with a pinned version and the settings in `kubernetes/core/kube-vip/README.md`. `svc_enable` stays unset (ADR 0001).
- No server holds a kube-vip manifest in its k3s auto-deploy directory, so only Argo CD applies it.
- Ansible, when built, handles kube-vip only through the `tls-san: 10.0.10.49` entry in the k3s server config.

## Constraint

**While Argo CD owns kube-vip, nodes must join through a server address, never through the VIP.** A rebuild would otherwise stall: workers wait for the VIP, the VIP waits for Argo CD, and Argo CD runs only on workers.

Joins currently use the fixed address of k3s-cp-01, so no new node can join while it is down. Ansible should select a live server address at join time.

## Handover prerequisites

- Read the auto-deploy file on each server and reconcile it with the live DaemonSet before writing the Git version.
- Deleting an auto-deploy file does not delete the cluster resources, so removing it does not drop the VIP. k3s does not sync these files between servers, so every copy must be removed [1].

## Sequencing

- Independent of ADR 0001.
- Before the Ansible k3s server role, so that role never carries a kube-vip manifest.

## References

1. k3s docs, Packaged Components (auto-deploying manifests): https://docs.k3s.io/installation/packaged-components
