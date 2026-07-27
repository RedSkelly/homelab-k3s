# Monitoring and Observability

Metrics, logging, and alerting for the cluster and workloads.

## Components

| Component              | Purpose                        | Status      |
|------------------------|--------------------------------|-------------|
| kube-prometheus-stack   | Metrics, alerting, dashboards  | Deployed    |
| Loki                   | Log aggregation                | Planned     |

## Design notes

- kube-prometheus-stack provides Prometheus, Grafana, and Alertmanager in a single Helm release
- Loki adds logs alongside metrics in Grafana
