# AWS EKS — Log Search Deployment

This directory contains the Kubernetes manifests and Helm values override needed
to deploy the Mage Pro **log search** feature (OpenSearch + Fluent Bit) on AWS EKS.

## Files


| File                                | Purpose                                                                                    |
| ----------------------------------- | ------------------------------------------------------------------------------------------ |
| `values-log-search.yaml`            | Shared Helm values — enables logSearch feature, sets OpenSearch host/port                  |
| `values-log-search-staging.yaml`    | Staging overlay — cluster-specific PVC name and subPath                                    |
| `opensearch-values.yaml`            | Values for the OpenSearch Helm chart (separate release in mage-search namespace)           |
| `mage-data-pvc.yaml`                | Reference PVC manifest (skip if reusing an existing PVC)                                   |


## Quick-start

See [deployment-staging-or-prod.md](../../deployment-staging-or-prod.md) for full
step-by-step deployment instructions covering both staging and production.

## Log file path

Mage writes logs to `$MAGE_DATA_DIR/{repo_name}/pipelines/{pipeline}/.logs/...`.
The base values file sets `MAGE_DATA_DIR=/home/src/mage_data`. The env overlay
mounts the cluster PVC at `/home/src` so both the mageai container and the
Fluent Bit sidecar share the same log files via the same PVC.