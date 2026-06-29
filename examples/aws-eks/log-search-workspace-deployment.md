# Workspace Log Search Deployment on AWS EKS

Step-by-step guide for enabling OpenSearch-backed log search for Mage Pro workspaces on an existing staging cluster where pipeline-level log search is already installed and running.

This guide does **not** install a new OpenSearch release. It reuses the existing staging OpenSearch, Fluent Bit chart resources, auth/TLS Secrets, PVC, and `values-log-search*.yaml` overlays.

## Prerequisites

- `kubectl` is configured for the staging cluster.
- `helm` is installed and can access the staging Mage release.
- Pipeline-level OpenSearch log search is already installed and healthy.
- The Mage image tag includes the Mage Pro workspace log-search application changes.
- Workspace storage is ready for new workspace PVCs. Workspace log search can create or restart workspace StatefulSets, so verify the workspace StorageClass exists and, for dynamic EFS, that the EFS CSI controller has IAM permissions to create access points.
- Fluent Bit has enough memory for workspace and Mage log tailing. The default sidecar memory can be too small on staging clusters; this guide includes an override in the Helm command.
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

Confirm workspace storage prerequisites before creating or restarting workspaces:

```bash
kubectl get storageclass
kubectl -n mage get pvc
kubectl -n kube-system get pods | grep efs
kubectl -n kube-system get sa efs-csi-controller-sa -o yaml
```

If workspace PVCs use dynamic EFS provisioning, the EFS CSI controller service account must have AWS permissions, usually through IRSA or EKS Pod Identity with the AWS managed policy `AmazonEFSCSIDriverPolicy`. A missing or incorrect role can leave workspace PVCs Pending with `Access Denied` provisioning errors.

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
  --set logSearch.fluentBit.resources.requests.cpu=100m \
  --set logSearch.fluentBit.resources.requests.memory=256Mi \
  --set logSearch.fluentBit.resources.limits.cpu=500m \
  --set logSearch.fluentBit.resources.limits.memory=512Mi \
  --reset-then-reuse-values
```

`--reset-then-reuse-values` avoids carrying stale chart defaults while preserving existing release values that are not overridden by the supplied values files and flags. The Fluent Bit resource override prevents low default memory limits, such as 128Mi, from OOM-killing the sidecar during startup log tailing.

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

Confirm the Mage deployment rolled out and both containers are healthy:

```bash
kubectl -n mage rollout status deployment/mageai
kubectl -n mage get pods
POD=$(kubectl -n mage get pod -l app.kubernetes.io/instance=mageai -o jsonpath='{.items[0].metadata.name}')
kubectl -n mage get pod "$POD" \
  -o jsonpath='{range .status.containerStatuses[*]}{.name}{" ready="}{.ready}{" restarts="}{.restartCount}{" last="}{.lastState.terminated.reason}{" exit="}{.lastState.terminated.exitCode}{"\n"}{end}'
```

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

Use the normal staging workflow to restart or recreate a workspace, then identify the workspace pod and its PVC:

```bash
kubectl -n mage get pods | grep workspace
kubectl -n mage get pvc | grep workspace
```

The workspace pod must not remain Pending. If it does, describe the pod and PVC before debugging Mage application behavior:

```bash
kubectl -n mage describe pod <workspace-pod-name>
kubectl -n mage describe pvc <workspace-pvc-name>
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

Generate a workspace log event by running a pipeline **through the scheduler**, not via the `mage run` CLI. A bare `mage run <project> <pipeline>` invocation only writes a flat `.logs/pipeline.log` file, which does not match Fluent Bit's tail glob (`.logs/*/*/*log`, two nested levels) and will not be shipped to OpenSearch. To get the nested per-run/per-block log structure the sidecar actually watches, trigger the pipeline through the UI's Run button, an existing trigger, or the API's pipeline-run-under-schedule flow (`POST /api/pipeline_schedules/<id>/pipeline_runs`), so the in-process scheduler executes it.

The relevant validation surface for this feature is the pipeline's **Logs tab** inside the workspace (Pipelines → select pipeline → Observability → Logs), not the `/manage` page's "Open"/"Manage" links, which are unrelated workspace-lifecycle controls. If the workspace has no Ingress configured, the `/manage` "Open" link and direct NodePort/port-forward access will fail to render the frontend (asset 404s from the `MAGE_REQUESTS_BASE_PATH` prefix mismatch) even though the backend and Fluent Bit sidecar work correctly. In that case, validate via direct API calls instead — see the Appendix below for the auth recipe.

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


### Mage Pod Fluent Bit Sidecar Is OOMKilled

If the Mage pod shows `fluent-bit` as `OOMKilled` or `exit=137`, inspect the container resources:

```bash
POD=$(kubectl -n mage get pod -l app.kubernetes.io/instance=mageai -o jsonpath='{.items[0].metadata.name}')
kubectl -n mage get pod "$POD" \
  -o jsonpath='{range .spec.containers[*]}{.name}{" requests="}{.resources.requests}{" limits="}{.resources.limits}{"\n"}{end}'
```

Increase `logSearch.fluentBit.resources` in the Helm upgrade. On staging, start with requests of `100m` CPU and `256Mi` memory and limits of `500m` CPU and `512Mi` memory. If it still OOMs, temporarily raise the memory limit to confirm whether the failure is memory pressure or a Fluent Bit configuration loop.

### Workspace Pod Pending With Unbound PVC

If the workspace pod is Pending and `kubectl describe pod` reports `pod has unbound immediate PersistentVolumeClaims`, inspect the PVC and StorageClass:

```bash
kubectl -n mage describe pvc <workspace-pvc-name>
kubectl get storageclass
kubectl -n mage get statefulset <workspace-statefulset-name> \
  -o jsonpath='{range .spec.volumeClaimTemplates[*]}{.metadata.name}{" storageClass="}{.spec.storageClassName}{"\n"}{end}'
```

If the PVC references a StorageClass that does not exist, either update the workspace provisioning source to use an existing class or create a carefully matched StorageClass alias. For dynamic EFS, the alias must include the same `parameters` as the working dynamic class, including `provisioningMode`, `fileSystemId`, and `directoryPerms`.

### EFS Dynamic Provisioning Fails With Access Denied

If the PVC events include `Access Denied`, the EFS CSI controller is running but lacks AWS permissions for dynamic access point provisioning:

```bash
kubectl -n kube-system get pods | grep efs
kubectl -n kube-system get sa efs-csi-controller-sa -o yaml
kubectl -n kube-system logs deployment/efs-csi-controller -c efs-plugin --tail=100
```

The controller service account usually needs IRSA or EKS Pod Identity with `AmazonEFSCSIDriverPolicy`. This is a cluster/IAM prerequisite, not a Mage Helm value issue. Ask an AWS admin to attach or restore an IAM role for `kube-system/efs-csi-controller-sa`, then restart the EFS CSI controller.

#### Workaround While the IAM Fix Is Pending

If a workspace PVC needs to be unblocked before the IAM fix lands, a static PV on the same EFS filesystem avoids the `CreateAccessPoint` call entirely (static mounts only need basic NFS mount permissions, not access-point creation permissions).

1. Find the real EFS filesystem ID and the **subPath** the main Mage pod uses. Do not assume the main pod's `/home/src` maps to the filesystem root:

   ```bash
   kubectl -n mage get pv <existing-working-pv-name> -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
   kubectl -n mage get deploy mageai -o jsonpath='{range .spec.template.spec.containers[?(@.name=="mageai")].volumeMounts[*]}{.name}{" subPath="}{.subPath}{"\n"}{end}'
   ```

   If the working PV's `volumeHandle` is a bare filesystem ID (e.g. `fs-xxxxxxxx`, no path suffix) and the Mage container mount has a non-empty `subPath`, the real EFS root is one level up from what the main app sees at `/home/src`.

2. Create a workspace-specific directory inside that subPath (not at the apparent root) by `exec`-ing into the Mage pod:

   ```bash
   kubectl -n mage exec deploy/mageai -c mageai -- mkdir -p /home/src/workspaces/<workspace-name>
   ```

3. Create a static PV whose `csi.volumeHandle` is `<fileSystemId>:<subPath>/workspaces/<workspace-name>` (include the subPath prefix found in step 1), with a `claimRef` pointing at the workspace's existing PVC by name/namespace. Apply it, then delete the workspace's pod so the StatefulSet retries the mount.

4. If `kubectl delete pv <name>` hangs in `Terminating`, the `pv-protection` finalizer is waiting for the bound PVC to release. It's safe to force-clear the finalizer on a PV that never had a working mount: `kubectl patch pv <name> -p '{"metadata":{"finalizers":null}}' --type=merge`. After replacing a PV that a PVC was already bound to, the PVC itself will show `Lost` — delete and let the StatefulSet recreate the PVC (it rebinds to the new PV by name) rather than trying to repair the existing PVC object.

This is a per-workspace workaround, not a fix — new workspaces will still hit `Access Denied` until the EFS CSI controller's IAM role is actually fixed.

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

## Appendix: Authenticating Directly Against a Workspace API

Use this when the workspace has no working Ingress and the `/manage` "Open" link or direct port-forward won't render the frontend, but you still need to trigger a pipeline and confirm logs without the UI.

Port-forward to the workspace pod, then log in to get a session:

```bash
kubectl -n mage port-forward pod/<workspace-pod-name> 6789:6789
```

Find the workspace's real `api_key` (the `oauth2_application.client_id` in its own SQLite DB — do not reuse a value from frontend mock data):

```bash
kubectl -n mage exec <workspace-pod-name> -c <workspace-container> -- find /home/src -maxdepth 4 -iname "*.sqlite3" -o -iname "*.db"
kubectl -n mage exec <workspace-pod-name> -c <workspace-container> -- python3 -c "
import sqlite3
conn = sqlite3.connect('<db-path-from-above>')
print(conn.cursor().execute('SELECT client_id FROM oauth2_application LIMIT 5').fetchall())
"
```

Log in (the API key must be passed via the `X-API-KEY` header for POST requests — passing it as a query param only works for GET):

```bash
curl -s -X POST "http://localhost:6789/api/sessions" \
  -H "X-API-KEY: <client_id>" \
  -H "Content-Type: application/json" \
  -d '{"session": {"email": "<email>", "password": "<password>"}}'
```

The response's `session.token` is itself a JWT wrapper, not the raw bearer token. Decode it to extract the inner `token` field before using it as `Authorization: Bearer`:

```bash
python3 -c "
import base64, json
jwt_token = '<session.token from response>'
payload = jwt_token.split('.')[1]
payload += '=' * (-len(payload) % 4)
print(json.loads(base64.urlsafe_b64decode(payload)))
"
```

Trigger a real (scheduler-executed) pipeline run, which is required to get the nested log structure Fluent Bit watches:

```bash
# 1. Create a one-time trigger nested under the pipeline (not bare /api/pipeline_schedules)
curl -s -X POST "http://localhost:6789/api/pipelines/<pipeline_uuid>/pipeline_schedules" \
  -H "X-API-KEY: <client_id>" -H "Authorization: Bearer <raw_token>" \
  -H "Content-Type: application/json" \
  -d '{"pipeline_schedule": {"name": "manual-log-search-test"}}'

# 2. Activate it with a one-time interval so the scheduler picks it up
curl -s -X PUT "http://localhost:6789/api/pipeline_schedules/<schedule_id>" \
  -H "X-API-KEY: <client_id>" -H "Authorization: Bearer <raw_token>" \
  -H "Content-Type: application/json" \
  -d '{"pipeline_schedule": {"schedule_interval": "@once", "status": "active"}}'

# 3. Create the run nested under the schedule (not bare /api/pipeline_runs)
curl -s -X POST "http://localhost:6789/api/pipeline_schedules/<schedule_id>/pipeline_runs" \
  -H "X-API-KEY: <client_id>" -H "Authorization: Bearer <raw_token>" \
  -H "Content-Type: application/json" \
  -d '{"pipeline_run": {"variables": {}}}'
```

The in-process scheduler picks up the run within a few seconds. Confirm with `kubectl logs <workspace-pod-name> -c <workspace-container> | grep "Active pipeline runs"`.

## Appendix: Local AWS Credential Environment Setup

The deployment commands in this guide require a shell that can authenticate to AWS and to the EKS cluster. On this workstation, interactive terminal shells and Codex-launched `zsh -lc` shells may read different startup files, so credentials that exist only in `~/.zshrc` may not be visible to automation or helper commands.

Use short-lived AWS credentials when possible. Do not commit these values, paste them into tracked files, or echo secret values into shared logs.

### Required Shell Variables

At minimum, the deployment shell must have AWS credentials and region available:

```bash
export AWS_ACCESS_KEY_ID=<access-key-id>
export AWS_SECRET_ACCESS_KEY=<secret-access-key>
export AWS_SESSION_TOKEN=<session-token>
export AWS_DEFAULT_REGION=us-west-2
export AWS_REGION=us-west-2
```

If your workflow obtains credentials as a JSON object, save it only to a local shell variable and export the individual fields from it. For example:

```bash
export CREDS='<temporary-aws-credential-json>'
export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | jq -r '.AccessKeyId // .Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | jq -r '.SecretAccessKey // .Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | jq -r '.SessionToken // .Credentials.SessionToken')
export AWS_DEFAULT_REGION=us-west-2
export AWS_REGION=us-west-2
unset CREDS
```

### Make Credentials Visible To Codex Shells

If commands launched from Codex cannot see the variables even though your terminal can, mirror the exports into `~/.zshenv` as well as `~/.zshrc`. `~/.zshenv` is read by non-interactive zsh shells, which is why it matters for `zsh -lc` command execution.

Add only local, untracked exports. Keep file permissions restricted:

```bash
chmod 600 ~/.zshenv ~/.zshrc
```

Do not print secret values while verifying. Check only whether variables are set:

```bash
zsh -lc 'for key in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION; do if [ -n "${(P)key}" ]; then echo "$key=set"; else echo "$key=missing"; fi; done'
```

### Confirm AWS And Kubernetes Access

Before running Helm or `kubectl` deployment commands, confirm identity and cluster context:

```bash
aws sts get-caller-identity
kubectl config current-context
kubectl get ns mage mage-search
```

For the staging workspace log-search deployment, the expected context is the `mage-pro-staging` EKS cluster in `us-west-2`:

```text
arn:aws:eks:us-west-2:679849156117:cluster/mage-pro-staging
```

### EFS CSI IAM Caveat

These shell credentials let you run `kubectl`, Helm, and AWS inspection commands as your user. They do not automatically grant the EFS CSI controller permission to dynamically provision EFS access points. If workspace PVC provisioning fails with `Access Denied`, an AWS admin must attach or restore IAM permissions for the Kubernetes service account `kube-system/efs-csi-controller-sa`, usually with `AmazonEFSCSIDriverPolicy` through IRSA or EKS Pod Identity.

