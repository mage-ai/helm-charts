# Log Search Deployment on AWS EKS (OpenSearch + Fluent Bit)

Step-by-step guide for adding OpenSearch-backed log search to an existing Mage Pro
EKS deployment using the chart-native `logSearch.*` values. This is not a general
Mage deployment guide — it covers only the log search feature.

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

> **Changing `plugins.security.disabled`**: `opensearch-values.yaml` ships with
> `plugins.security.disabled: false` (security enabled) to simulate production auth.
> If you previously ran OpenSearch with this set to `true`, simply restarting the pod
> is not enough — you must upgrade the OpenSearch Helm release for the config change
> to take effect:
>
> ```bash
> helm upgrade opensearch opensearch/opensearch \
>   --namespace mage-search \
>   --values $HELM_CHART/examples/aws-eks/opensearch-values.yaml \
>   --set persistence.size=30Gi \
>   --set persistence.storageClass=gp2 \
>   --set "extraEnvs[0].value=<your-opensearch-admin-password>" \
>   --reuse-values
> ```
>
> After the upgrade, OpenSearch will require username/password authentication. Ensure
> the `opensearch-auth` Secret (step 5) exists **before** running the Mage `helm upgrade`
> (step 7) — otherwise the Mage pod will fail to start because `secretKeyRef` cannot
> be resolved.

### 3. Create the log data PVC (skip if reusing an existing PVC)

Edit `mage-data-pvc.yaml` to set the correct `storageClass` and `size` first, then:

```bash
kubectl apply -f $HELM_CHART/examples/aws-eks/mage-data-pvc.yaml
```

### 4. Fetch chart dependencies (safe to re-run if already built)

```bash
helm dependency build $HELM_CHART/charts/mageai
```

### 5. Create the OpenSearch auth Secret (production or auth simulation in staging)

Skip this step if `logSearch.opensearch.auth.enabled` is `false` in your overlay.

```bash
kubectl -n mage create secret generic opensearch-auth \
  --from-literal=OPENSEARCH_USERNAME=<username> \
  --from-literal=OPENSEARCH_PASSWORD=<password>
```

Then set in your env overlay (`values-log-search-staging.yaml` or `values-log-search-prod.yaml`):

```yaml
logSearch:
  opensearch:
    auth:
      enabled: true
      existingSecret: opensearch-auth
```

### 6. Review chart-rendered log search resources

No Fluent Bit or OpenSearch setup ConfigMaps are required when using the default
`logSearch.*` values. The chart renders:

- `mageai-fluent-bit` ConfigMap from `logSearch.fluentBit.config` and `logSearch.fluentBit.parsers`
- `mageai-log-search-index` ConfigMap from `logSearch.setupJob.mapping`
- a Helm hook Job that creates the `mage_logs` index from the rendered mapping

Only security-sensitive resources, such as OpenSearch credentials and TLS certificates,
should remain externally managed Secrets.

### 7. Run helm upgrade

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

### 8. Verify the rollout

```bash
# Watch pod status — expect mageai pod to restart with 2 containers (mageai + fluent-bit)
kubectl -n mage get pods -w

# Confirm both containers are running — READY should show 2/2
kubectl -n mage get pod -l app.kubernetes.io/name=mageai

# Check the setup Job — if it ran and succeeded it will already be deleted (expected).
# "No resources found" after a few minutes means it completed and was cleaned up.
kubectl -n mage get jobs | grep log-search-index

# Confirm the mage_logs index was created and is receiving data
kubectl -n mage-search get pods   # get the actual OpenSearch pod name first
kubectl -n mage-search exec -it <opensearch-pod-name> -- curl -s localhost:9200/_cat/indices
# Look for a "mage_logs" entry with a growing document count
```

---

## Full deployment verification

Run these commands at any time to confirm all required resources are in place and healthy.

### Secrets and ConfigMaps

```bash
# mage namespace — auth secret and TLS CA
kubectl -n mage get secret opensearch-auth opensearch-tls-ca
kubectl -n mage get configmap mageai-fluent-bit mageai-log-search-index

# mage-search namespace — TLS cert/key for the OpenSearch pod
kubectl -n mage-search get secret opensearch-tls
```

Expected output: all resources listed with an `AGE` — no "not found" errors.

### Pod health

```bash
# Mage pod — READY should show 2/2 (mageai + fluent-bit sidecar)
kubectl -n mage get pods -l app.kubernetes.io/name=mageai

# OpenSearch pod — READY should show 1/1
kubectl -n mage-search get pods
```

### OpenSearch index and document count

```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- \
  /bin/bash -c "curl -sk -u 'admin:<password>' https://localhost:9200/_cat/indices/mage_logs?v"
```

Look for the `mage_logs` index with a non-zero and growing `docs.count`.

### Fluent Bit log shipping

```bash
kubectl -n mage logs -l app.kubernetes.io/name=mageai -c fluent-bit --tail=20
```

Healthy output shows `flush chunk ... succeeded` lines. Errors like `error scanning path`
or `connection refused` indicate a path or connectivity issue — see the Troubleshooting
section for fixes.

---

## Notes

- The Fluent Bit sidecar and all volumes are rendered directly by the chart from
  `logSearch.*` values — no need to manage `extraContainers`/`extraVolumes` manually.
- The OpenSearch index setup Job runs automatically as a Helm post-install/post-upgrade
  hook. This means Helm triggers the Job after every `helm upgrade` or `helm install`
  completes — no manual `kubectl apply` needed. The Job runs a lightweight curl image
  and applies the chart-rendered `logSearch.setupJob.mapping` to create the `mage_logs`
  index. It is idempotent (safe to re-run if the index already exists)
  and self-cleaning — Helm deletes the Job pod automatically 5 minutes after it
  succeeds (`ttlSecondsAfterFinished: 300`). To disable it after the first successful
  run, set `logSearch.setupJob.enabled: false` in your env overlay.
- For a new production cluster, create `examples/aws-eks/values-log-search-prod.yaml`
  with the production PVC name and subPath before running step 6.
- For secured bundled OpenSearch, keep username/password and TLS certificate material
  in externally managed Secrets. If you enable the OpenSearch security plugin with
  custom security config, bootstrap the security index with `securityadmin.sh` before
  relying on the chart's log-search index setup hook.

---

## Authentication and TLS

### Traffic paths

There are three distinct traffic paths to consider:

| Path | Description | TLS controlled by |
|------|-------------|-------------------|
| **Mage → OpenSearch** | Mage reads/writes log data and queries the index | `logSearch.opensearch.tls` in chart values |
| **Fluent Bit → OpenSearch** | Fluent Bit sidecar ships log files to OpenSearch | `tls` settings in `fluent-bit.conf` ConfigMap OUTPUT section |
| **External client → OpenSearch** | Developer or dashboard tool querying OpenSearch directly | Not applicable — OpenSearch is a `ClusterIP` service, not reachable from outside the cluster |

Fluent Bit does not accept inbound connections in this setup — it reads log files from the shared PVC and sends them outbound to OpenSearch only. There is no "client → Fluent Bit" traffic path.

---

### Staging (current setup)

Authentication and TLS are both enabled using self-signed certificates. OpenSearch enforces credentials and encrypts traffic. Because the certs are self-signed, hostname verification is skipped (`verify: false`) on the Mage side.

**`opensearch-values.yaml`** — security plugin enabled, HTTP TLS on, certs mounted from Secret:
```yaml
secretMounts:
  - name: opensearch-tls
    secretName: opensearch-tls       # contains tls.crt, tls.key, ca.crt
    path: /usr/share/opensearch/config/certs
config:
  opensearch.yml: |
    plugins.security.disabled: false
    plugins.security.ssl.http.enabled: true
    plugins.security.ssl.http.pemcert_filepath: certs/tls.crt
    plugins.security.ssl.http.pemkey_filepath:  certs/tls.key
    plugins.security.ssl.http.pemtrustedcas_filepath: certs/ca.crt
    plugins.security.ssl.transport.pemcert_filepath: certs/tls.crt
    plugins.security.ssl.transport.pemkey_filepath:  certs/tls.key
    plugins.security.ssl.transport.pemtrustedcas_filepath: certs/ca.crt
    plugins.security.ssl.transport.enforce_hostname_verification: false
    plugins.security.allow_default_init_securityindex: true
```

**`values-log-search-staging.yaml`** — auth enabled, TLS enabled, hostname verification off:
```yaml
logSearch:
  opensearch:
    auth:
      enabled: true
      existingSecret: opensearch-auth     # contains OPENSEARCH_USERNAME / OPENSEARCH_PASSWORD
    tls:
      enabled: true
      existingSecret: opensearch-tls-ca  # contains ca.crt
      verify: false                       # self-signed cert — skip hostname verification
```

---

### Production (recommended setup)

Both authentication and TLS should be enabled. TLS encrypts traffic between Mage/Fluent Bit and OpenSearch, which is important when the cluster network is shared or when compliance requires encryption in transit.

**Step 1 — Store the CA certificate in a Secret:**
```bash
kubectl -n mage create secret generic opensearch-tls-ca \
  --from-file=ca.crt=<path-to-ca.crt>
```

**Step 2 — Enable TLS in `opensearch-values.yaml`** by configuring `plugins.security.ssl.*`
(see OpenSearch documentation for certificate generation and `opensearch.yml` TLS settings).

**Step 3 — Enable in your production env overlay (`values-log-search-prod.yaml`):**
```yaml
logSearch:
  opensearch:
    auth:
      enabled: true
      existingSecret: opensearch-auth
    tls:
      enabled: true
      existingSecret: opensearch-tls-ca   # Secret containing ca.crt
      verify: true
```

The chart automatically mounts the CA cert into both the Mage container and the Fluent Bit sidecar at `/etc/ssl/opensearch` when `tls.enabled: true` — no extra volume configuration needed.

**Step 4 — Fluent Bit TLS**

The default chart-rendered Fluent Bit config reads `logSearch.opensearch.tls` and
sets the OpenSearch output TLS options automatically. If you override
`logSearch.fluentBit.config`, keep these lines in the `[OUTPUT]` section:
```ini
[OUTPUT]
    Name        opensearch
    tls         On
    tls.verify  On
    tls.ca_file /etc/ssl/opensearch/ca.crt
```

> Note: the chart mounts the CA cert into Fluent Bit automatically when
> `logSearch.opensearch.tls.existingSecret` is set.

---

### Provisioning self-signed TLS certificates (staging)

Run these steps **before** `helm upgrade opensearch` when enabling TLS for the first time.

**1. Generate CA and node certificates:**
```bash
# CA key and cert
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -days 3650 -key ca-key.pem -out ca.pem -subj "/CN=opensearch-ca"

# Node key and CSR
openssl genrsa -out node-key.pem 2048
openssl req -new -key node-key.pem -out node.csr -subj "/CN=opensearch-cluster-master"

# Sign node cert with CA — include in-cluster DNS SANs
openssl x509 -req -days 3650 -in node.csr -CA ca.pem -CAkey ca-key.pem \
  -CAcreateserial -out node.pem \
  -extfile <(echo "subjectAltName=DNS:opensearch-cluster-master,DNS:opensearch-cluster-master.mage-search.svc.cluster.local")
```

**2. Create Kubernetes Secrets:**
```bash
# TLS cert + key for OpenSearch pod (in mage-search namespace)
kubectl -n mage-search create secret generic opensearch-tls \
  --from-file=tls.crt=node.pem \
  --from-file=tls.key=node-key.pem \
  --from-file=ca.crt=ca.pem

# CA cert for Mage and Fluent Bit to trust OpenSearch (in mage namespace)
kubectl -n mage create secret generic opensearch-tls-ca \
  --from-file=ca.crt=ca.pem
```

**3. Upgrade OpenSearch with TLS config:**
```bash
helm upgrade opensearch opensearch/opensearch \
  --namespace mage-search \
  --values $HELM_CHART/examples/aws-eks/opensearch-values.yaml \
  --set persistence.size=30Gi \
  --set persistence.storageClass=gp2 \
  --set-string 'extraEnvs[0].value=<your-opensearch-admin-password>' \
  --reuse-values
```

**4. Create the Mage auth Secret (if not already exists):**
```bash
kubectl -n mage create secret generic opensearch-auth \
  --from-literal=OPENSEARCH_USERNAME=admin \
  --from-literal=OPENSEARCH_PASSWORD=<your-opensearch-admin-password>
```

**5. Confirm Fluent Bit TLS config**

The default chart-rendered Fluent Bit config enables TLS from
`logSearch.opensearch.tls`. If you override `logSearch.fluentBit.config`, make sure
the `[OUTPUT]` section includes:
```ini
[OUTPUT]
    Name        opensearch
    tls         On
    tls.verify  Off
    tls.ca_file /etc/ssl/opensearch/ca.crt
```

**6. Upgrade Mage:**
```bash
helm upgrade --install mageai $HELM_CHART/charts/mageai \
  --namespace mage --create-namespace \
  --values $HELM_CHART/examples/aws-eks/values-log-search.yaml \
  --values $ENV_OVERLAY \
  --set image.repository=679849156117.dkr.ecr.us-west-2.amazonaws.com/mage-pro \
  --set image.tag=<image-tag> \
  --reuse-values
```

---

## Troubleshooting

### 1. OpenSearch crashes immediately after enabling security plugin

**Symptom:** OpenSearch pod goes into `CrashLoopBackOff`. Logs show:
```
OpenSearchException[No SSL configuration found]
```

**Cause:** `plugins.security.disabled: false` requires TLS to be configured on both
HTTP and transport layers. OpenSearch refuses to start if the security plugin is enabled
but no certificates are provided.

**Fix:** Provision TLS certificates and mount them before enabling security. Follow the
"Provisioning self-signed TLS certificates (staging)" steps above, then re-run
`helm upgrade opensearch` with the full `plugins.security.ssl.*` block in `opensearch.yml`.

---

### 2. Password with special characters fails in `--set`

**Symptom:** `helm upgrade` accepts the command but OpenSearch rejects the password at
runtime. The password contains special characters such as `$` or `!`.

**Cause:** `--set` interpolates `$` as a shell variable, silently truncating or corrupting
the value before it reaches Helm.

**Fix:** Use `--set-string` instead of `--set` for password values:
```bash
--set-string 'extraEnvs[0].value=MyP@ss$word!'
```

---

### 3. OpenSearch rejects credentials even though `OPENSEARCH_INITIAL_ADMIN_PASSWORD` was set

**Symptom:** `curl -u 'admin:<your-password>'` returns `Unauthorized`. The password was
passed via `--set-string extraEnvs[0].value=<password>` during `helm install`.

**Cause:** OpenSearch's demo security installer sets the `admin` user's password from
`OPENSEARCH_INITIAL_ADMIN_PASSWORD` only on the **first** start. If the security index
was already initialized (e.g., from a prior run with a different password or with
`plugins.security.disabled: true`), the env var is ignored on subsequent starts and the
password stays as the original demo default (`admin`).

**Fix:** Use the actual demo password (`admin`) to authenticate, or re-initialize the
security index. For staging, the simplest fix is to update the `opensearch-auth` Secret
to use the real admin credentials:
```bash
kubectl -n mage delete secret opensearch-auth
kubectl -n mage create secret generic opensearch-auth \
  --from-literal=OPENSEARCH_USERNAME=admin \
  --from-literal=OPENSEARCH_PASSWORD=admin
kubectl -n mage rollout restart deployment/mageai
```

To confirm the actual password before updating the Secret:
```bash
kubectl -n mage-search exec -it opensearch-cluster-master-0 -- \
  /bin/bash -c "curl -sk -u 'admin:admin' https://localhost:9200/_cat/indices?v"
```

---

### 4. Helm upgrade hangs and times out on the setup Job

**Symptom:** `helm upgrade` blocks for several minutes then fails with:
```
Error: context deadline exceeded
```
The log-search-setup Job pod does not appear in `kubectl -n mage get pods`.

**Cause:** The Helm hook Job runs after every `helm upgrade`. If the Job takes longer
than Helm's default wait timeout (usually 5 minutes) — for example, due to slow
TLS handshake setup or image pull on first run — Helm times out even though the Job
may complete successfully on its own.

**Fix:** If the `mage_logs` index already exists (check with `_cat/indices`), skip the
Job entirely for this upgrade:
```bash
helm upgrade ... --set logSearch.setupJob.enabled=false
```
Once confirmed the index exists and is healthy, add `logSearch.setupJob.enabled: false`
to your env overlay so it is skipped permanently.

---

### 5. Fluent Bit cannot find log files — "error scanning path"

**Symptom:** Fluent Bit logs show repeated errors:
```
[error] [input:tail:tail.0] read error, check permissions: /home/mage_data/*/pipelines/*/.logs/*/*/*log
[warn]  [input:tail:tail.0] error scanning path: /home/mage_data/*/pipelines/*/.logs/*/*/*log
```
No documents are being shipped to OpenSearch.

**Cause:** The Fluent Bit `Path` glob uses `/home/mage_data/` as the base, which is the
path Mage uses in Docker. In Kubernetes, the EFS PVC is mounted at `/home/src`, so Mage
writes logs under `/home/src/mage_data/` instead. The path `/home/mage_data/` does not
exist in the container.

**Diagnosis:** Confirm the actual path by checking inside the Mage container:
```bash
kubectl -n mage exec -it <mageai-pod> -c mageai -- \
  find /home/src -name "*.log" -path "*/.logs/*" 2>/dev/null | head -5
```
This will show paths like `/home/src/mage_data/default_repo/pipelines/...`.

**Fix:** Override `logSearch.fluentBit.config` and set the `Path` in the `[INPUT]`
section:
```ini
[INPUT]
    Path   /home/src/mage_data/*/pipelines/*/.logs/*/*/*log
```
Then run `helm upgrade` again. If you are using an existing Fluent Bit ConfigMap
through `logSearch.fluentBit.existingConfigMap`, recreate that ConfigMap and restart
the pod:
```bash
kubectl -n mage delete configmap fluent-bit-config
kubectl -n mage create configmap fluent-bit-config \
  --from-file=fluent-bit.conf=$MAGE_PRO/fluent-bit-prod.conf
kubectl -n mage rollout restart deployment/mageai
```
