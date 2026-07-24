# kube-prometheus-stack

Full monitoring stack: Prometheus, Grafana, Alertmanager, node-exporter, and kube-state-metrics.

## What belongs here

- `values.yaml` — Helm chart values (hand-authored, not a state dump)
- `application.yaml` — Argo CD Application CRD
- `dashboards/` — Custom Grafana dashboard JSON files (if any)
- `rules/` — Custom PrometheusRule CRs (if any)

## Design notes

- Current version: app v0.88.0 (chart 81.0.0), installed via Helm
- Chart: `prometheus-community/kube-prometheus-stack`
- Helm history is capped at 5 (`HELM_MAX_HISTORY=5`)
- When migrating to Argo CD, the existing Helm release needs to be adopted or recreated
- Grafana storage should use Longhorn PVC for dashboard persistence
- Resource requests/limits are currently missing (known open item)
