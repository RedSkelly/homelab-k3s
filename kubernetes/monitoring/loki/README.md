# Loki

Log aggregation. Ships logs to Grafana alongside Prometheus metrics.

## What belongs here

- `values.yaml`: Helm chart values
- `application.yaml`: Argo CD Application CRD

## Design notes

- **Roadmap item #3**, not yet implemented
- Chart: `grafana/loki` from `https://grafana.github.io/helm-charts`
- Deploy alongside Promtail (or Grafana Alloy) as the log shipper
- Use Longhorn PVC for log storage, with retention sized to available disk
- Single-binary mode is sufficient at homelab scale; microservices mode is not needed
- Grafana datasource configuration should be added to kube-prometheus-stack values to auto-register Loki
