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

> **Full step-by-step instructions** are in Log Search Tech Design [https://docs.google.com/document/d/1smez-Xkm1HIIu1IvMTDRBUq_8Pwrx7qKAlQD0q49OjU/edit?usp=sharing](https://docs.google.com/document/d/1smez-Xkm1HIIu1IvMTDRBUq_8Pwrx7qKAlQD0q49OjU/edit?usp=sharing) (Section 14.3 Production Deployment (AWS EKS / Kubernetes))

```bash
MAGE_PRO={path-to-mage-pro}          # path to the mage-pro repo
HELM_CHART={path-to-helm-charts}     # path to this repo
ENV_OVERLAY=$HELM_CHART/examples/aws-eks/values-log-search-staging.yaml   # or values-log-search-prod.yaml

# 1. Deploy OpenSearch
helm repo add opensearch https://opensearch-project.github.io/helm-charts
helm install opensearch opensearch/opensearch \
  --namespace mage-search --create-namespace \
  --values $HELM_CHART/examples/aws-eks/opensearch-values.yaml \
  --set persistence.size=30Gi \
  --set persistence.storageClass=gp2 \
  --set "extraEnvs[0].value=<your-opensearch-admin-password>"

# 2. Create the log data PVC (skip if reusing an existing PVC)
#    Edit mage-data-pvc.yaml to set the correct storageClass and size first.
kubectl apply -f $HELM_CHART/examples/aws-eks/mage-data-pvc.yaml

# 3. Create Fluent Bit ConfigMaps from the mage-pro repo
#    Note: use fluent-bit-prod.conf (K8s host), not fluent-bit.conf (Docker host)
kubectl -n mage create configmap fluent-bit-config \
  --from-file=fluent-bit.conf=$MAGE_PRO/fluent-bit-prod.conf
kubectl -n mage create configmap fluent-bit-parsers \
  --from-file=parsers.conf=$MAGE_PRO/fluent-bit-parsers.conf

# 4. Create the opensearch-setup-script ConfigMap
#    The chart renders a post-install Job from this when logSearch.setupJob.enabled=true.
kubectl -n mage create configmap opensearch-setup-script \
  --from-file=opensearch_setup.py=$MAGE_PRO/scripts/opensearch_setup.py

# 5. Install / upgrade Mage with log search enabled
#    Pass the shared values file first, then the env-specific overlay ($ENV_OVERLAY).
#    (second --values file wins on conflicts — sets PVC name and subPath)
helm upgrade --install mageai $HELM_CHART/charts/mageai \
  --namespace mage --create-namespace \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  --reuse-values
```

## Log file path

Mage writes logs to `$MAGE_DATA_DIR/{repo_name}/pipelines/{pipeline}/.logs/...`.
The base values file sets `MAGE_DATA_DIR=/home/src/mage_data`. The env overlay
mounts the cluster PVC at `/home/src` so both the mageai container and the
Fluent Bit sidecar share the same log files via the same PVC.