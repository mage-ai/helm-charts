# Workspace Log Search Deployment on AWS EKS

Step-by-step guide for enabling OpenSearch-backed log search for Mage Pro workspaces on an existing staging cluster where pipeline-level log search is already installed and running.

This guide does **not** install a new OpenSearch release. It reuses the existing staging OpenSearch, Fluent Bit chart resources, auth/TLS Secrets, PVC, and `values-log-search*.yaml` overlays.

## Prerequisites

- `kubectl` is configured for the staging cluster.
- `helm` is installed and can access the staging Mage release.
- Pipeline-level OpenSearch log search is already installed and healthy.
- The Mage image tag includes the Mage Pro workspace log-search application changes.
- The Helm chart includes the workspace log-search chart changes:
  - `logSearch.workspace.enabled: true`
  - `WORKSPACE_USE_OPENSEARCH_FOR_LOGS`
  - `LOG_SEARCH_*` workspace bridge env vars
  - workspace mapping fields in `logSearch.setupJob.mapping`

Use the existing staging cluster, not the `log-search-workspaces` EKS agent dev slot.

## 1. Set Environment Variables

```bash
export HELM_CHART=/Users/yanhe/mage/helm-charts
export ENV_OVERLAY=$HELM_CHART/examples/aws-eks/values-log-search-staging.yaml
export MAGE_IMAGE_REPOSITORY=679849156117.dkr.ecr.us-west-2.amazonaws.com/mage-pro
export MAGE_IMAGE_TAG=<image-tag-with-workspace-log-search>
```

Replace `<image-tag-with-workspace-log-search>` with the Mage Pro image that contains the workspace log-search application changes.

## 2. Confirm Existing Staging Resources

Confirm you are pointed at the staging cluster:

```bash
kubectl config current-context
kubectl get ns mage mage-search
```

Confirm existing OpenSearch, Mage, Secrets, ConfigMaps, and PVCs are present:

```bash
kubectl -n mage-search get pods
kubectl -n mage get deploy mageai
kubectl -n mage get secret opensearch-auth opensearch-tls-ca
kubectl -n mage get configmap mageai-fluent-bit mageai-log-search-index
kubectl -n mage get pvc pvc-mageai-staging
```

Confirm the existing `mage_logs` index is present:

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- \
  /bin/bash -c "curl -sk -u 'admin:<password>' https://localhost:9200/_cat/indices/mage_logs?v"
```

## 3. Render Check the Workspace Env Bridge

Render the Mage deployment and verify both pipeline and workspace log-search env vars are present:

```bash
helm template mageai $HELM_CHART/charts/mageai \
  --show-only templates/deployment.yaml \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  | grep -nE "USE_OPENSEARCH_FOR_LOGS|WORKSPACE_USE_OPENSEARCH_FOR_LOGS|LOG_SEARCH_FLUENT_BIT_CONFIG_MAP|LOG_SEARCH_OPENSEARCH_AUTH_SECRET"
```

Expected output includes:

```text
USE_OPENSEARCH_FOR_LOGS
WORKSPACE_USE_OPENSEARCH_FOR_LOGS
LOG_SEARCH_FLUENT_BIT_CONFIG_MAP
LOG_SEARCH_OPENSEARCH_AUTH_SECRET
```

## 4. Render Check the Workspace Mapping Fields

Render the OpenSearch setup mapping and verify the workspace scope fields are present:

```bash
helm template mageai $HELM_CHART/charts/mageai \
  --show-only templates/log-search-index-setup.yaml \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  | grep -nE "project_uuid|workspace_uuid|workspace_name|repo_path_normalized"
```

Expected output includes:

```text
project_uuid
workspace_uuid
workspace_name
repo_path_normalized
```

## 5. Upgrade the Mage Helm Release

Upgrade only the Mage release. Do not install a new OpenSearch release and do not pass `opensearch.enabled=true` for this existing staging setup.

```bash
helm upgrade --install mageai $HELM_CHART/charts/mageai \
  --namespace mage --create-namespace \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  --set image.repository=$MAGE_IMAGE_REPOSITORY \
  --set image.tag=$MAGE_IMAGE_TAG \
  --reuse-values
```

`--reuse-values` keeps the existing release values and applies only the supplied values files and image overrides on top.

## 6. Update the Existing OpenSearch Mapping If Needed

The Helm setup Job creates the `mage_logs` index when it does not exist. On an existing staging cluster, the index may already exist, and the setup Job exits successfully without updating the mapping.

If the mapping does not already include the workspace fields, update it manually:

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- /bin/bash -c '
cat <<EOF >/tmp/workspace-log-mapping.json
{"properties":{"project_uuid":{"type":"keyword"},"workspace_uuid":{"type":"keyword"},"workspace_name":{"type":"keyword"},"repo_path_normalized":{"type":"keyword"}}}
EOF
curl -sk -u "admin:<password>" \
  -X PUT "https://localhost:9200/mage_logs/_mapping" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/workspace-log-mapping.json
'
```

Verify the mapping fields:

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- /bin/bash -c '
curl -sk -u "admin:<password>" \
  "https://localhost:9200/mage_logs/_mapping?pretty" \
  | grep -E "project_uuid|workspace_uuid|workspace_name|repo_path_normalized"
'
```

## 7. Verify the Mage Deployment

Confirm the Mage pod has the pipeline and workspace log-search env vars:

```bash
kubectl -n mage exec deploy/mageai -c mageai -- env \
  | grep -E "USE_OPENSEARCH_FOR_LOGS|WORKSPACE_USE_OPENSEARCH_FOR_LOGS|LOG_SEARCH_"
```

Expected output includes:

```text
USE_OPENSEARCH_FOR_LOGS=true
WORKSPACE_USE_OPENSEARCH_FOR_LOGS=true
LOG_SEARCH_FLUENT_BIT_CONFIG_MAP=...
LOG_SEARCH_FLUENT_BIT_PARSERS_CONFIG_MAP=...
LOG_SEARCH_OPENSEARCH_AUTH_SECRET=...
LOG_SEARCH_OPENSEARCH_TLS_SECRET=...
```

## 8. Restart or Recreate Workspace Pods

Workspace pods must be created or restarted after the Mage upgrade so the workspace workload manager can inject the Fluent Bit sidecar and workspace log-search volumes/env vars.

Use the normal staging workflow to restart or recreate a workspace, then identify the workspace pod:

```bash
kubectl -n mage get pods | grep workspace
```

Verify the workspace pod includes the Fluent Bit sidecar and workspace log-search env vars:

```bash
kubectl -n mage describe pod <workspace-pod-name> \
  | grep -E "fluent-bit|WORKSPACE_USE_OPENSEARCH_FOR_LOGS|LOG_SEARCH_"
```

Verify workspace Fluent Bit is running without auth, TLS, or path errors:

```bash
kubectl -n mage logs <workspace-pod-name> -c fluent-bit --tail=50
```

Healthy output should show Fluent Bit starting and flushing records without repeated OpenSearch connection/authentication errors.

## 9. Generate and Query Workspace Logs

Generate a workspace log event by opening or running a pipeline inside a workspace.

Then query OpenSearch for documents that include workspace scope:

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- /bin/bash -c '
cat <<EOF >/tmp/workspace-log-query.json
{"size":5,"query":{"exists":{"field":"workspace_uuid"}},"sort":[{"logged_at":{"order":"desc"}}]}
EOF
curl -sk -u "admin:<password>" \
  "https://localhost:9200/mage_logs/_search?pretty" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/workspace-log-query.json
'
```

Expected result: recent log documents with fields such as `workspace_uuid`, `workspace_name`, `project_uuid`, and `repo_path_normalized`.

## Troubleshooting

### `WORKSPACE_USE_OPENSEARCH_FOR_LOGS` Is Missing

Confirm the chart values render both the top-level and workspace log-search flags:

```bash
helm template mageai $HELM_CHART/charts/mageai \
  --show-only templates/deployment.yaml \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  | grep -nE "USE_OPENSEARCH_FOR_LOGS|WORKSPACE_USE_OPENSEARCH_FOR_LOGS"
```

If `USE_OPENSEARCH_FOR_LOGS` is missing, confirm `values-log-search.yaml` includes:

```yaml
logSearch:
  enabled: true
```

If `WORKSPACE_USE_OPENSEARCH_FOR_LOGS` is missing, confirm the chart has:

```yaml
logSearch:
  workspace:
    enabled: true
```

### Workspace Pod Has No Fluent Bit Sidecar

The workspace pod may have been created before the Mage deployment was upgraded. Restart or recreate the workspace, then check the pod again:

```bash
kubectl -n mage describe pod <workspace-pod-name> | grep fluent-bit
```

### Workspace Logs Reach OpenSearch But Search Returns No Results

Check the mapping fields:

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- /bin/bash -c '
curl -sk -u "admin:<password>" \
  "https://localhost:9200/mage_logs/_mapping?pretty" \
  | grep -E "project_uuid|workspace_uuid|workspace_name|repo_path_normalized"
'
```

If fields are missing, run the manual mapping update in step 6.

Also confirm the Mage image tag contains the workspace log-search application changes.

### Fluent Bit Has Auth or TLS Errors

Confirm the Mage pod receives the Secret names that the workspace manager will pass to workspace pods:

```bash
kubectl -n mage exec deploy/mageai -c mageai -- env \
  | grep -E "LOG_SEARCH_OPENSEARCH_AUTH_SECRET|LOG_SEARCH_OPENSEARCH_TLS_SECRET|OPENSEARCH_VERIFY_CERTS"
```

Confirm the referenced Secrets exist:

```bash
kubectl -n mage get secret opensearch-auth opensearch-tls-ca
```

## Validation Checklist

Run these local checks before deployment:

```bash
git diff --check
helm lint charts/mageai
```

Run these render checks before deployment:

```bash
helm template mageai charts/mageai \
  --show-only templates/deployment.yaml \
  --values examples/aws-eks/values-log-search.yaml \
  --values examples/aws-eks/values-log-search-staging.yaml \
  | grep -n "WORKSPACE_USE_OPENSEARCH_FOR_LOGS"

helm template mageai charts/mageai \
  --show-only templates/log-search-index-setup.yaml \
  --values examples/aws-eks/values-log-search.yaml \
  --values examples/aws-eks/values-log-search-staging.yaml \
  | grep -nE "project_uuid|workspace_uuid|workspace_name|repo_path_normalized"
```

If the Helm unittest plugin is installed, also run:

```bash
helm unittest charts/mageai
```
