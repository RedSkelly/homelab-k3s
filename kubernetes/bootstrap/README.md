# Bootstrap

Components that must exist before Argo CD can manage the cluster. Deployed manually via Helmfile or kubectl, then Argo CD takes over its own management (app-of-apps pattern).

## Deployment flow

1. Scale the packaged CoreDNS to 2 replicas (see [CoreDNS replicas](#coredns-replicas))
2. Helmfile deploys Argo CD from this directory
3. Argo CD `Application` resources (app-of-apps) are applied, pointing to `kubernetes/core/`, `kubernetes/monitoring/`, etc.
4. Argo CD begins reconciling all downstream components
5. Argo CD manages its own upgrades from this point forward (self-managed)

## CoreDNS replicas

The k3s CoreDNS addon runs 1 replica. `coredns-pdb` (`kubernetes/core/policies/pdb-kube-system.yaml`) sets `minAvailable: 1`, so at 1 replica it allows 0 disruptions and `kubectl drain` retries forever on the node running CoreDNS. Run once after k3s install:

```sh
kubectl -n kube-system scale deploy coredns --replicas=2
```

k3s re-applies the addon on every server start without a `replicas` field, so the scaled value survives restarts. Interim until it is declared in code; see Known Open Items in `CLAUDE.md`.

## What belongs here

- Argo CD Helm values and Application manifests
- The root `Application` or `ApplicationSet` that discovers all other components
