# MetalLB

Bare-metal LoadBalancer implementation. Allocates IPs for Services of type LoadBalancer.

## What belongs here

- `metallb-native.yaml` — MetalLB deployment manifest (currently installed via kubectl)
- `ipaddresspool.yaml` — IPAddressPool CR defining the allocatable IP range
- `l2advertisement.yaml` — L2Advertisement CR for ARP-based IP announcement
- `application.yaml` — Argo CD Application CRD (when migrated to Argo CD management)

## Design notes

- Current version: v0.14.5, installed via kubectl manifest
- Migration candidate: move from raw manifest to Helm chart under Argo CD management
- IP pool must not overlap with kube-vip VIP or node IPs on VLAN 10
- L2 mode only — no BGP peers in this network
