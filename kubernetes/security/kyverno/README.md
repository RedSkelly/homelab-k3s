# Kyverno

Policy engine for Kubernetes — enforces and mutates resource configuration via admission control.

## What belongs here

- `values.yaml` — Helm chart values
- `application.yaml` — Argo CD Application CRD
- `policies/` — ClusterPolicy CRs organized by concern

## Planned policies

| Policy                    | Type       | Purpose                                    |
|---------------------------|------------|--------------------------------------------|
| Require resource limits   | Validate   | Block pods without requests/limits          |
| Default resource limits   | Mutate     | Inject sane defaults when limits are missing|
| Require labels            | Validate   | Enforce standard labels (app, component)    |
| Restrict image registries | Validate   | Only allow images from trusted registries   |

## Design notes

- **Roadmap item #4** — not yet implemented
- Chart: `kyverno/kyverno` from `https://kyverno.github.io/kyverno`
- Start with `Audit` mode, switch to `Enforce` after validating policies don't break existing workloads
- Addresses two known open items: missing resource limits and missing NetworkPolicies
