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


## Deployment Instructions

See [log-search-deployment.md](log-search-deployment.md) for step-by-step
instructions to add OpenSearch-backed log search to an existing EKS deployment.
This is not a general Mage deployment guide — it covers only the log search feature.

## Log file path

Mage writes logs to `$MAGE_DATA_DIR/{repo_name}/pipelines/{pipeline}/.logs/...`.
The base values file sets `MAGE_DATA_DIR=/home/src/mage_data`. The env overlay
mounts the cluster PVC at `/home/src` so both the mageai container and the
Fluent Bit sidecar share the same log files via the same PVC.