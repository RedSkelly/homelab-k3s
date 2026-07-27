# Security and Policy

Policy enforcement and supply chain security.

## Components

| Component         | Purpose                              | Status  |
|-------------------|--------------------------------------|---------|
| Kyverno           | Policy enforcement (resource limits, labels) | Planned |
| Harbor + Trivy    | Container registry + vulnerability scanning  | Planned |

## NetworkPolicies

NetworkPolicies are co-located with the workloads they protect, not centralized here. Each component directory (e.g. `kubernetes/core/longhorn/`, `kubernetes/monitoring/kube-prometheus-stack/`) owns its own `network-policy.yaml`, so a component's policy is added, reviewed, and removed in the same diff and the same Argo CD sync unit as the workload itself.

Kyverno can enforce that every namespace has a default-deny policy, closing the gap if a component ships without one.

## Design notes

- The cluster currently has zero NetworkPolicies (known open item)
- K3s ships with Flannel CNI, which does not enforce NetworkPolicies by default
- A NetworkPolicy-capable CNI (Calico or Cilium) must be evaluated before writing policies
- Kyverno addresses missing resource limits with policy-as-code (mutating and validating admission)
- Harbor + Trivy become relevant when custom container images exist
