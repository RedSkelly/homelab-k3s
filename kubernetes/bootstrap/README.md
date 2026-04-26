# Bootstrap

Components that must exist before Argo CD can manage the cluster. Deployed manually via Helmfile or kubectl, then Argo CD takes over its own management (app-of-apps pattern).

## Deployment flow

1. Helmfile deploys Argo CD from this directory
2. Argo CD `Application` resources (app-of-apps) are applied, pointing to `kubernetes/core/`, `kubernetes/monitoring/`, etc.
3. Argo CD begins reconciling all downstream components
4. Argo CD manages its own upgrades from this point forward (self-managed)

## What belongs here

- Argo CD Helm values and Application manifests
- The root `Application` or `ApplicationSet` that discovers all other components
