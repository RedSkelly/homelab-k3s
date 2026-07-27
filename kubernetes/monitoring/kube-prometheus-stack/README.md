# kube-prometheus-stack

Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics.

## What belongs here

- `values.yaml`: Helm chart values (hand-authored, not a state dump)
- `secrets.values.yaml`: SOPS-encrypted overlay (Alertmanager Slack webhook, Grafana admin password)
- The Argo CD Application lives in `bootstrap/argocd/applications/kps.yaml`
- `dashboards/`: Custom Grafana dashboard JSON files (if any)
- `rules/`: Custom PrometheusRule CRs (if any)

## Design notes

- Current version: app v0.88.0 (chart 81.0.0), managed by Argo CD (migrated from Helmfile 2026-07-26)
- Chart: `prometheus-community/kube-prometheus-stack`, release name pinned to `kps`
- The Application is multi-source: `values.yaml` and the SOPS-encrypted `secrets.values.yaml` in this directory are referenced by path via a `$values` source-ref, with the overlay decrypted by helm-secrets wrapper mode on the repo-server
- Two settings must not be reverted without reading why first: `prometheusOperator.admissionWebhooks.certManager.enabled` and the pinned `grafana.adminPassword`. See CLAUDE.md, Known Open Items
- Grafana storage uses a Longhorn PVC for dashboard persistence
- Resource requests/limits are currently missing (known open item)
