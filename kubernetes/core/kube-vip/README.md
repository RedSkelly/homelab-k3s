# kube-vip

Provides the control plane floating VIP via ARP. Runs as a static pod on each control plane node.

## What belongs here

- `kube-vip.yaml` — Static pod manifest (deployed to `/etc/kubernetes/manifests/` on each CP node via Ansible)

## Design notes

- **Not managed by Argo CD** — static pods are managed by the kubelet, not the API server
- Ansible is responsible for placing and updating the manifest on CP nodes
- VIP: floating on VLAN 10, one pod per CP node
- Current version: v0.8.2
- The manifest here is the source of truth; Ansible copies it to each CP node
