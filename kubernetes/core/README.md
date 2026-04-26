# Core Platform Services

Foundational cluster infrastructure that all other workloads depend on. These deploy first (after Argo CD) and have strict ordering requirements.

## Deployment order

1. **kube-vip** — Control plane VIP (static pod, not managed by Argo CD)
2. **MetalLB** — LoadBalancer IP allocation for services
3. **Longhorn** — Distributed storage (sole default StorageClass)
4. **cert-manager** — TLS certificate automation
5. **ingress-nginx** — Ingress controller
6. **external-secrets** — Secrets management (future — Vault + External Secrets Operator)

## What each component directory contains

- `values.yaml` — Helm chart values (hand-authored, intent-based)
- `application.yaml` — Argo CD Application CRD
- `network-policy.yaml` — NetworkPolicy for the component's namespace (co-located, not centralized)
- Raw manifests where applicable (kube-vip static pod, MetalLB config)
- `secrets.sops.yaml` — SOPS-encrypted secrets (if needed)
