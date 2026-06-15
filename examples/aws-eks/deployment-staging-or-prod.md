# Deploying Mage Pro with Log Search (Staging or Production)

Step-by-step instructions to deploy Mage Pro on an AWS EKS cluster using the
chart-native `logSearch.*` feature.

> **Full step-by-step instructions** are also in the Log Search Tech Design doc
> (Section 14.3 Production Deployment).

## Prerequisites

- `kubectl` configured and authenticated against the target cluster
- `helm` installed
- AWS ECR credentials available (`aws ecr get-login-password ...`)

---

## Steps

### 1. Set environment variables

```bash
export HELM_CHART=~/mage/helm-charts        # path to this helm-charts repo
export MAGE_PRO=~/mage/mage-pro             # path to mage-pro repo

# IMPORTANT: set ENV_OVERLAY to the overlay file for your target environment.
# - Staging:    values-log-search-staging.yaml  (uses pvc-mageai-staging)
# - Production: values-log-search-prod.yaml     (must define logSearch.persistence.existingClaim
#                                                and logSearch.persistence.subPath for the
#                                                production cluster's PVC)
export ENV_OVERLAY=$HELM_CHART/examples/aws-eks/values-log-search-staging.yaml
```

### 2. Deploy OpenSearch (skip if already deployed)

```bash
helm repo add opensearch https://opensearch-project.github.io/helm-charts
helm install opensearch opensearch/opensearch \
  --namespace mage-search --create-namespace \
  --values $HELM_CHART/examples/aws-eks/opensearch-values.yaml \
  --set persistence.size=30Gi \
  --set persistence.storageClass=gp2 \
  --set "extraEnvs[0].value=<your-opensearch-admin-password>"
```

### 3. Create the log data PVC (skip if reusing an existing PVC)

Edit `mage-data-pvc.yaml` to set the correct `storageClass` and `size` first, then:

```bash
kubectl apply -f $HELM_CHART/examples/aws-eks/mage-data-pvc.yaml
```

### 4. Fetch chart dependencies (safe to re-run if already built)

```bash
helm dependency build $HELM_CHART/charts/mageai
```

### 5. Create prerequisite ConfigMaps (skip each if it already exists)

```bash
# Check what already exists
kubectl -n mage get configmap fluent-bit-config fluent-bit-parsers opensearch-setup-script

# Create only the missing ones
# Note: use fluent-bit-prod.conf (K8s service DNS host), not fluent-bit.conf (Docker host)
kubectl -n mage create configmap fluent-bit-config \
  --from-file=fluent-bit.conf=$MAGE_PRO/fluent-bit-prod.conf

kubectl -n mage create configmap fluent-bit-parsers \
  --from-file=parsers.conf=$MAGE_PRO/fluent-bit-parsers.conf

# The chart renders a post-install Job from this when logSearch.setupJob.enabled=true
kubectl -n mage create configmap opensearch-setup-script \
  --from-file=opensearch_setup.py=$MAGE_PRO/scripts/opensearch_setup.py
```

### 6. Run helm upgrade

```bash
helm upgrade --install mageai $HELM_CHART/charts/mageai \
  --namespace mage --create-namespace \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  --set image.repository=679849156117.dkr.ecr.us-west-2.amazonaws.com/mage-pro \
  --set image.tag=<image-tag> \
  --reuse-values
```

`--reuse-values` tells Helm to carry forward all values from the previous release as
the base, then apply the new `--values` files and `--set` flags on top. This means
you only need to specify what changes (image tag, log search config) without having
to repeat every value that was set in earlier upgrades (e.g. resource limits,
service type, replica count). Without it, any value not explicitly provided would
fall back to the chart's defaults, which could inadvertently reset settings that
were previously customized.

### 7. Verify the rollout

```bash
# Watch pod status — expect mageai pod to restart with 2 containers (mageai + fluent-bit)
kubectl -n mage get pods -w

# Confirm both containers are running — READY should show 2/2
kubectl -n mage get pod -l app.kubernetes.io/name=mageai

# Check the setup Job — if it ran and succeeded it will already be deleted (expected).
# "No resources found" after a few minutes means it completed and was cleaned up.
kubectl -n mage get jobs | grep log-search-setup

# Confirm the mage_logs index was created and is receiving data
kubectl -n mage-search get pods   # get the actual OpenSearch pod name first
kubectl -n mage-search exec -it <opensearch-pod-name> -- curl -s localhost:9200/_cat/indices
# Look for a "mage_logs" entry with a growing document count
```

---

## Notes

- The Fluent Bit sidecar and all volumes are rendered directly by the chart from
  `logSearch.*` values — no need to manage `extraContainers`/`extraVolumes` manually.
- The OpenSearch index setup Job runs automatically as a Helm post-install/post-upgrade
  hook. This means Helm triggers the Job after every `helm upgrade` or `helm install`
  completes — no manual `kubectl apply` needed. The Job spins up a `python:3.11-slim`
  container, installs `opensearch-py`, and runs `opensearch_setup.py` to create the
  `mage_logs` index. It is idempotent (safe to re-run if the index already exists)
  and self-cleaning — Helm deletes the Job pod automatically 5 minutes after it
  succeeds (`ttlSecondsAfterFinished: 300`). To disable it after the first successful
  run, set `logSearch.setupJob.enabled: false` in your env overlay.
- For a new production cluster, create `examples/aws-eks/values-log-search-prod.yaml`
  with the production PVC name and subPath before running step 6.
