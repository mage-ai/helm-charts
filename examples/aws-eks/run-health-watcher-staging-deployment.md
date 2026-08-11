# Run Health Watcher Staging Deployment on AWS EKS

Step-by-step guide for deploying the Mage Pro run-health watcher to an existing
workspace-mode staging EKS deployment using the chart-native
`runHealthWatcher.*` values. This is not a general Mage deployment guide — it
covers only deploying and verifying the dedicated run-health watcher workload for
stuck/runaway diagnosis, recovery, and scheduled-trigger impact alerts.

The run-health watcher is a separate Kubernetes `Deployment`, not a sidecar and
not a background process inside the Mage web/scheduler pod.

## Prerequisites

- `kubectl` configured and authenticated against the target EKS cluster
- `helm` installed
- AWS ECR access for the Mage Pro image repository
- A pushed Mage Pro feature image containing the run-health code
- A Helm chart branch that includes the `runHealthWatcher` templates and tests

For the staging validation described here, the target was:

```text
AWS account: 679849156117
AWS region: us-west-2
EKS cluster: mage-pro-staging
Mage namespace: mage
Helm release: mageai
Mage image repository: 679849156117.dkr.ecr.us-west-2.amazonaws.com/mage-pro
Mage image tag: 20280806-stuck-run-health-diagnosis-recovery-alerts-py3.12
```

## 1. Set Environment Variables

Run these commands from the Helm chart worktree:

```bash
cd /Users/yanhe/mage/helm-charts-stuck-run-health-diagnosis-recovery-alerts

export HELM_CHART=/Users/yanhe/mage/helm-charts-stuck-run-health-diagnosis-recovery-alerts
export AWS_REGION=us-west-2
export STAGING_CONTEXT=arn:aws:eks:us-west-2:679849156117:cluster/mage-pro-staging
export MAGE_NAMESPACE=mage
export MAGE_RELEASE=mageai
export MAGE_IMAGE_REPOSITORY=679849156117.dkr.ecr.us-west-2.amazonaws.com/mage-pro
export MAGE_IMAGE_TAG=20280806-stuck-run-health-diagnosis-recovery-alerts-py3.12
export RUN_HEALTH_VALUES=/tmp/run-health-watcher-staging-values.yaml
```

Refresh kubeconfig and confirm access:

```bash
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name mage-pro-staging

kubectl config use-context "$STAGING_CONTEXT"
kubectl get ns
```

If `kubectl get ns` returns `Unauthorized`, refresh kubeconfig again and confirm
the active AWS identity with:

```bash
aws sts get-caller-identity
```

Do not run Helm until `kubectl get ns` succeeds.

## 2. Confirm The Mage Pro Image Exists

```bash
aws ecr describe-images \
  --region "$AWS_REGION" \
  --repository-name mage-pro \
  --image-ids imageTag="$MAGE_IMAGE_TAG"
```

Expected:

- the image tag exists;
- `imageStatus` is `ACTIVE`;
- the image digest is returned.

For the staging validation described here:

```text
imageDigest: sha256:f382916e7399c18e195ef209bf23a4cb83a6e3333b59cd84fe1d5f5f03cda37d
imageStatus: ACTIVE
```

## 3. Snapshot Current Staging Values And Manifest

Preserve the live staging release values before adding run-health watcher
overrides:

```bash
helm -n "$MAGE_NAMESPACE" get values "$MAGE_RELEASE" -o yaml \
  > /tmp/mageai-staging-current-values.yaml

helm -n "$MAGE_NAMESPACE" get values "$MAGE_RELEASE" --all -o yaml \
  > /tmp/mageai-staging-all-values.yaml

helm -n "$MAGE_NAMESPACE" get manifest "$MAGE_RELEASE" \
  > /tmp/mageai-staging-current-manifest.yaml
```

Inspect workspace-mode signals:

```bash
rg -n "PROJECT_TYPE|CLUSTER_TYPE|KUBE_NAMESPACE|WORKSPACE_|MAGE_BASE_PATH|replicas:" \
  /tmp/mageai-staging-current-manifest.yaml
```

Expected workspace-mode signal:

```yaml
- name: PROJECT_TYPE
  value: main
```

The staging release may have `workspaceConfig.enabled: false` in Helm values while
still running product workspace mode through env vars. Treat `PROJECT_TYPE=main`
as the stronger signal for this validation.

## 4. Inspect Current Kubernetes State

```bash
kubectl -n "$MAGE_NAMESPACE" get deploy,sts,pods,svc,pvc -o wide
```

In the staging validation described here, `deployment/mageai` was scaled to
`0/0` even though the rendered Helm manifest had `replicas: 1`. A real
`helm upgrade` with the current values will scale it back to `1`.

Confirm whether waking the staging release is acceptable before applying.

## 5. Create The Run Health Watcher Staging Overlay

Create a temporary local values file:

```bash
cat > "$RUN_HEALTH_VALUES" <<'EOF'
runHealthWatcher:
  enabled: true
  replicaCount: 1

  env:
    - name: MAGE_RUN_HEALTH_WATCHER_ENABLED
      value: "true"
    - name: MAGE_RUN_HEALTH_WATCHER_AUTO_TERMINATE_ENABLED
      value: "false"
    - name: MAGE_RUN_HEALTH_WATCHER_AUTO_TERMINATE_MAX_ACTIONS_PER_SCAN
      value: "0"
    - name: MAGE_RUN_HEALTH_WATCHER_CADENCE_SECONDS
      value: "60"
    - name: MAGE_RUN_HEALTH_WATCHER_LEASE_TTL_SECONDS
      value: "120"
    - name: MAGE_RUN_HEALTH_WATCHER_LONG_RUNNING_MINUTES
      value: "120"
    - name: MAGE_RUN_HEALTH_WATCHER_MINIMUM_IMPACT_COUNT
      value: "1"
    - name: MAGE_RUN_HEALTH_WATCHER_NO_PROGRESS_MINUTES
      value: "30"
    - name: MAGE_RUN_HEALTH_WATCHER_NOTIFICATION_COOLDOWN_MINUTES
      value: "60"
    - name: MAGE_RUN_HEALTH_WATCHER_OLD_ACTIVE_BACKFILL_LIMIT
      value: "25"
    - name: MAGE_RUN_HEALTH_WATCHER_SCAN_WINDOW_MINUTES
      value: "1440"
    - name: MAGE_RUN_HEALTH_WATCHER_SCHEDULER_HEARTBEAT_STALE_MINUTES
      value: "10"
EOF
```

Verify the file:

```bash
cat "$RUN_HEALTH_VALUES"
```

YAML permits an indentless sequence under `env`, but the indented style above is
easier to read and review.

## 6. Test And Render The Helm Chart

Run Helm unit tests:

```bash
helm unittest "$HELM_CHART/charts/mageai"
```

Expected:

```text
Charts:      1 passed, 1 total
Test Suites: 3 passed, 3 total
Tests:       16 passed, 16 total
```

Run lint:

```bash
helm lint "$HELM_CHART/charts/mageai" \
  --values "$RUN_HEALTH_VALUES"
```

Render the chart with current staging values plus the run-health overlay:

```bash
helm template "$MAGE_RELEASE" "$HELM_CHART/charts/mageai" \
  --namespace "$MAGE_NAMESPACE" \
  --values /tmp/mageai-staging-current-values.yaml \
  --values "$RUN_HEALTH_VALUES" \
  --set image.repository="$MAGE_IMAGE_REPOSITORY" \
  --set image.tag="$MAGE_IMAGE_TAG" \
  > /tmp/run-health-staging-rendered.yaml
```

Inspect the rendered watcher resources:

```bash
rg -n "run-health-watcher|MAGE_RUN_HEALTH_WATCHER" \
  /tmp/run-health-staging-rendered.yaml
```

Expected:

- `ServiceAccount/run-health-watcher`;
- `Role/run-health-watcher`;
- `RoleBinding/run-health-watcher`;
- `Deployment/run-health-watcher`;
- `serviceAccountName: run-health-watcher`;
- all `MAGE_RUN_HEALTH_WATCHER_*` env vars.

Confirm no Kubernetes `Service` is created for the watcher:

```bash
awk '
  /^kind: Service$/ { in_service=1; block=$0 "\n"; next }
  /^---$/ && in_service { print block; in_service=0; block=""; next }
  in_service { block=block $0 "\n" }
  END { if (in_service) print block }
' /tmp/run-health-staging-rendered.yaml
```

Expected: the only Service is the normal Mage service, `metadata.name: mageai`.

## 7. Dry-Run The Staging Upgrade

```bash
helm upgrade --install "$MAGE_RELEASE" "$HELM_CHART/charts/mageai" \
  --namespace "$MAGE_NAMESPACE" \
  --values /tmp/mageai-staging-current-values.yaml \
  --values "$RUN_HEALTH_VALUES" \
  --set image.repository="$MAGE_IMAGE_REPOSITORY" \
  --set image.tag="$MAGE_IMAGE_TAG" \
  --dry-run=client --debug \
  > /tmp/run-health-staging-dry-run.yaml
```

Inspect the risky parts:

```bash
rg -n "kind: Deployment|name: mageai|name: run-health-watcher|replicas:|image:|serviceAccountName:|MAGE_RUN_HEALTH_WATCHER|PROJECT_TYPE|WORKSPACE_" \
  /tmp/run-health-staging-dry-run.yaml
```

Confirm:

- `Deployment/mageai` renders with `replicas: 1`;
- `Deployment/mageai` uses the PR image tag;
- `Deployment/run-health-watcher` renders with `replicas: 1`;
- `Deployment/run-health-watcher` uses the same PR image tag;
- `run-health-watcher` uses `serviceAccountName: run-health-watcher`;
- watcher env vars are present;
- workspace env vars such as `PROJECT_TYPE=main` are preserved.

Inspect RBAC:

```bash
sed -n '715,790p' /tmp/run-health-staging-dry-run.yaml
```

Confirm:

- namespace-scoped `Role`, not `ClusterRole`;
- no broad secret access;
- no `pods/log` permission unless intentionally added later.

Inspect the watcher Deployment:

```bash
rg -n "kind: Deployment|name: run-health-watcher|log-search-pvc|volumes:|volumeMounts:" \
  /tmp/run-health-staging-dry-run.yaml -C 3
```

For staging with log search enabled and project logs mounted from
`pvc-mageai-staging`, the watcher must have both:

```yaml
volumeMounts:
  - name: log-search-pvc
    mountPath: /home/src
    subPath: mage_pro/mageai-staging-test
volumes:
  - name: log-search-pvc
    persistentVolumeClaim:
      claimName: pvc-mageai-staging
```

If the watcher has the `log-search-pvc` volumeMount but not the matching volume,
the apply will fail with:

```text
volumeMounts[0].name: Not found: "log-search-pvc"
```

Use a Helm chart branch that includes the fix for this companion volume.

## 8. Apply To Staging

Only apply after dry-run review and after confirming it is acceptable to scale
`deployment/mageai` from `0` to `1` if the staging release is currently asleep.

```bash
helm upgrade --install "$MAGE_RELEASE" "$HELM_CHART/charts/mageai" \
  --namespace "$MAGE_NAMESPACE" \
  --values /tmp/mageai-staging-current-values.yaml \
  --values "$RUN_HEALTH_VALUES" \
  --set image.repository="$MAGE_IMAGE_REPOSITORY" \
  --set image.tag="$MAGE_IMAGE_TAG" \
  --force-conflicts \
  --wait --timeout 10m
```

`--force-conflicts` is required when previous staging edits used manual
server-side apply managers such as `kubectl-patch` or `kubectl-set`.
For example, this staging release had conflicts on:

```text
.spec.template.spec.containers[name="mageai"].livenessProbe.initialDelaySeconds
.spec.template.spec.containers[name="mageai"].readinessProbe.initialDelaySeconds
.spec.template.spec.containers[name="mageai"].readinessProbe.timeoutSeconds
.spec.template.spec.containers[name="mageai"].image
```

Do not use `--force-replace` for these field ownership conflicts.

Successful output:

```text
Release "mageai" has been upgraded. Happy Helming!
STATUS: deployed
DESCRIPTION: Upgrade complete
```

## 9. Verify The Rollout

```bash
kubectl -n "$MAGE_NAMESPACE" get deploy mageai run-health-watcher

kubectl -n "$MAGE_NAMESPACE" rollout status deploy/mageai --timeout=10m
kubectl -n "$MAGE_NAMESPACE" rollout status deploy/run-health-watcher --timeout=10m

kubectl -n "$MAGE_NAMESPACE" get pods -o wide
```

Expected:

```text
deployment/mageai              1/1
deployment/run-health-watcher  1/1
```

Verify watcher env:

```bash
WATCHER_POD="$(kubectl -n "$MAGE_NAMESPACE" get pods \
  -l app.kubernetes.io/component=run-health-watcher \
  -o jsonpath='{.items[0].metadata.name}')"

echo "$WATCHER_POD"

kubectl -n "$MAGE_NAMESPACE" exec "$WATCHER_POD" -- \
  printenv | grep MAGE_RUN_HEALTH_WATCHER
```

Verify watcher logs:

```bash
kubectl -n "$MAGE_NAMESPACE" logs "$WATCHER_POD" --tail=100
```

The watcher may log Alembic/PostgreSQL startup and then remain quiet between
successful scans. Use the database heartbeat as the authoritative proof when
available from the app environment.

## 10. Get The Staging App URL

```bash
export SERVICE_IP=$(kubectl get svc --namespace "$MAGE_NAMESPACE" mageai \
  --template "{{ range (index .status.loadBalancer.ingress 0) }}{{.}}{{ end }}")

echo "http://$SERVICE_IP:6789"
```

Open:

```text
http://<SERVICE_IP>:6789/manage
```

Expected:

- Mage Pro management UI loads;
- workspace mode is available;
- child workspaces can be created and opened.

## 11. Workspace-Mode Feature Verification

Use the Mage Pro workspace-mode QA guide from the feature PR as the detailed UI
test checklist. The high-level staging checks are:

1. Create or open a child workspace from `/manage`.
2. Create a stuck sleep test pipeline inside the child workspace.
3. Confirm a non-healthy run-health panel appears after the configured threshold.
4. Confirm `Terminate run` appears only for authorized users while the run is active.
5. Confirm manual termination cancels the active run.
6. Create a healthy long-running pipeline with measurable progress and confirm it
   does not show a false stuck/runaway diagnosis.
7. Create a scheduled-trigger blocked pipeline with per-trigger concurrency `1`
   and skip-on-limit behavior.
8. Confirm the trigger detail page shows `Stuck run blocking scheduled triggers`
   and deep-links to the blocking run.

For staging-like thresholds in this guide, expect slower detection than QA-fast
dev-slot settings:

```text
MAGE_RUN_HEALTH_WATCHER_CADENCE_SECONDS=60
MAGE_RUN_HEALTH_WATCHER_NO_PROGRESS_MINUTES=30
MAGE_RUN_HEALTH_WATCHER_LONG_RUNNING_MINUTES=120
```

For faster manual validation, temporarily override these values in
`$RUN_HEALTH_VALUES` before applying, then restore production-like values after
the test.

## Troubleshooting

### `kubectl` Unauthorized

Refresh kubeconfig and verify the active AWS identity:

```bash
aws sts get-caller-identity
aws eks update-kubeconfig --region "$AWS_REGION" --name mage-pro-staging
kubectl config use-context "$STAGING_CONTEXT"
kubectl get ns
```

Only run Helm after `kubectl get ns` succeeds.

### Server-Side Apply Conflicts

If Helm fails with conflicts owned by `kubectl-patch` or `kubectl-set`, rerun the
same upgrade with:

```bash
--force-conflicts
```

This transfers field ownership back to Helm for the rendered release fields.

### Missing `log-search-pvc` Volume

If apply fails with:

```text
Deployment.apps "run-health-watcher" is invalid:
spec.template.spec.containers[0].volumeMounts[0].name: Not found: "log-search-pvc"
```

Use a Helm chart branch that renders `mageai.logSearch.volumes` in
`templates/run-health-watcher-deployment.yaml`, then rerender and retry.

### Rollout Timeout

Do not rerun blindly. Inspect:

```bash
kubectl -n "$MAGE_NAMESPACE" describe deploy mageai
kubectl -n "$MAGE_NAMESPACE" describe deploy run-health-watcher
kubectl -n "$MAGE_NAMESPACE" get events --sort-by=.lastTimestamp | tail -50
kubectl -n "$MAGE_NAMESPACE" get pods -o wide
```

Common causes include image pull failures, missing PVCs, missing Secrets, probe
failures, and expired Kubernetes credentials.

## Rollback

Disable only the watcher while leaving the Mage image in place:

```bash
helm upgrade "$MAGE_RELEASE" "$HELM_CHART/charts/mageai" \
  --namespace "$MAGE_NAMESPACE" \
  --reuse-values \
  --set runHealthWatcher.enabled=false \
  --wait --timeout 10m
```

Rollback the full Helm release:

```bash
helm -n "$MAGE_NAMESPACE" history "$MAGE_RELEASE"
helm -n "$MAGE_NAMESPACE" rollback "$MAGE_RELEASE" <previous-revision> --wait --timeout 10m
```

If staging was intentionally asleep before the test, scale it back down after
validation if instructed by the staging owner:

```bash
kubectl -n "$MAGE_NAMESPACE" scale deploy/mageai --replicas=0
```
