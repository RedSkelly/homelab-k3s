# Manifest layout

Workload resources (ingress, PDBs, ServiceMonitors, NetworkPolicies) co-locate with their workload directory, not in central directories. Cluster-scoped resources that span workloads (PriorityClasses) live in `policies/`.
