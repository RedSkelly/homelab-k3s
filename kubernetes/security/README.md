# Security and Policy

Policy enforcement and supply chain security.

## Components

| Component         | Purpose                              | Status  |
|-------------------|--------------------------------------|---------|
| Kyverno           | Policy enforcement (resource limits, labels) | Planned |
| Harbor + Trivy    | Container registry + vulnerability scanning  | Planned |

## NetworkPolicies

NetworkPolicies are **co-located with the workloads they protect**, not centralized here. Each component directory (e.g., `kubernetes/core/longhorn/`, `kubernetes/monitoring/kube-prometheus-stack/`) owns its own `network-policy.yaml`.

**Why co-location over centralization:**

- **Ownership** — the person writing a component's values file understands its traffic patterns and is best positioned to write its network policy
- **Lifecycle coupling** — when a component is added, updated, or removed, its network policy moves with it rather than requiring a coordinated change in a separate directory
- **Review clarity** — PRs that change a component include its policy change in the same diff, making it obvious when traffic rules drift from the actual workload
- **Argo CD alignment** — each component's Application CRD syncs its own network policy alongside its other manifests, keeping the sync unit self-contained

Kyverno can enforce that every namespace has a default-deny policy, closing the gap if a component ships without one.

## Design notes

- The cluster currently has zero NetworkPolicies — a known open item
- K3s ships with Flannel CNI, which does not enforce NetworkPolicies by default
- A NetworkPolicy-capable CNI (Calico or Cilium) must be evaluated before writing policies
- Kyverno addresses missing resource limits with policy-as-code (mutating and validating admission)
- Harbor + Trivy become relevant when custom container images exist
