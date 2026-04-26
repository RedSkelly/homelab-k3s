# kube-prometheus-stack

Full monitoring stack: Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics.

## What belongs here

- `values.yaml` — Helm chart values (hand-authored, not a state dump)
- `application.yaml` — Argo CD Application CRD
- `dashboards/` — Custom Grafana dashboard JSON files (if any)
- `rules/` — Custom PrometheusRule CRs (if any)

## Design notes

- Current version: v81.0.0, installed via Helm (29 revisions — needs cleanup)
- Chart: `prometheus-community/kube-prometheus-stack`
- **Known issue:** 29 Helm revisions accumulated — set `HELM_MAX_HISTORY=5` going forward
- When migrating to Argo CD, the existing Helm release needs to be adopted or recreated
- Grafana storage should use Longhorn PVC for dashboard persistence
- Resource requests/limits are currently missing (known open item)
