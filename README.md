# Mage Helm charts

Helm charts for running [Mage](https://www.mage.ai/) on Kubernetes. The main
chart deploys Mage OSS or Mage Pro and can optionally deploy PostgreSQL, Redis,
OpenSearch, persistent storage, ingress, and separate web-server and scheduler
workloads.

## Charts

| Chart | Description | Source |
| --- | --- | --- |
| `mageai` | Mage application, service, optional dependencies, storage, and operational configuration | [`charts/mageai`](charts/mageai) |
| `mageai-ingress` | Standalone ingress configuration for an existing Mage service | [`charts/ingress`](charts/ingress) |

The chart repository is published at
<https://mage-ai.github.io/helm-charts/>.

## Prerequisites

- Kubernetes cluster access through `kubectl`.
- Helm 3.
- A storage plan for project code and Mage data. The default values contain a
  placeholder `hostPath`; replace it before deploying outside a local test.
- A PostgreSQL database for production workloads. The chart can deploy its
  bundled PostgreSQL dependency, or Mage can use an external database through
  `MAGE_DATABASE_CONNECTION_URL`.

## Install

Add and update the Mage chart repository:

```bash
helm repo add mageai https://mage-ai.github.io/helm-charts/
helm repo update
```

Create a values file for your environment. This minimal example runs the project
included in the image without mounting host storage and uses the bundled
PostgreSQL chart:

```yaml
# values.yaml
postgresql:
  enabled: true
  auth:
    username: mage
    password: replace-me
    database: mage

service:
  type: ClusterIP

extraVolumeMounts: []
extraVolumes: []
```

Install Mage:

```bash
helm upgrade --install mageai mageai/mageai \
  --namespace mageai \
  --create-namespace \
  --values values.yaml
```

For production, store credentials in Kubernetes Secrets or an external secret
manager rather than committing them to a values file.

Check the rollout:

```bash
helm status mageai --namespace mageai
kubectl get pods --namespace mageai
```

For a `ClusterIP` service, open Mage locally with port forwarding:

```bash
kubectl port-forward --namespace mageai service/mageai 6789:6789
```

Then visit <http://127.0.0.1:6789>.

## Common configuration

### Use a custom image

```yaml
image:
  repository: mageai/mageai
  tag: "0.9.79"
  pullPolicy: IfNotPresent
```

To pin the image by digest instead, set `image.digest`:

```yaml
image:
  repository: mageai/mageai
  digest: "sha256:0123456789abcdef..."
```

When `image.digest` is non-empty, it takes precedence over `image.tag` for the
combined Deployment and for both standalone web-server and scheduler
Deployments. The same selected image is used by dependency validation when it
is enabled.

For a private registry, set `image.repository` and configure
`imagePullSecrets` with Secrets that already exist in the release namespace.

### Configure project storage

Mount an existing claim at `/home/src`:

```yaml
extraVolumeMounts:
  - name: mage-fs
    mountPath: /home/src

extraVolumes:
  - name: mage-fs
    persistentVolumeClaim:
      claimName: mage-project
```

Use storage that supports the access pattern of your deployment. Multiple Mage
replicas or split web-server/scheduler deployments generally require storage
that can be mounted by every participating pod.

### Use an existing Secret

```yaml
existingSecret: mage-environment
```

The Secret keys are exposed as environment variables in the Mage container.
Use `config` for non-sensitive key-value configuration and `extraEnvs` for
entries that require `valueFrom`.

### Run separate web-server and scheduler workloads

```yaml
standaloneScheduler: true

webServer:
  replicaCount: 2

scheduler:
  replicaCount: 1
```

This creates independent Deployments so the web server and scheduler can be
scaled and resourced separately. Configure shared storage and a shared metadata
database before enabling this topology.

### Enable Redis

```yaml
redis:
  enabled: true
```

Redis is recommended when multiple Mage replicas need distributed locking or
caching. Set `redis.customRedisURL` instead to use an external Redis service.

### Expose Mage

The main chart supports `ClusterIP`, `NodePort`, and `LoadBalancer` Services. It
also retains an ingress configuration for backward compatibility, though a
separate ingress deployment is recommended for production.

```yaml
service:
  type: LoadBalancer
  port: 6789
```

The repository also includes the `mageai-ingress` chart for managing ingress
separately.

## Pause cleanup jobs

When the optional cleanup CronJob is enabled, set `cleanupJob.suspend` to
`true` to pause future runs while retaining the CronJob configuration. Set it
back to `false` when the Mage cluster resumes.

```yaml
cleanupJob:
  enabled: true
  suspend: true
```

## Validate dependencies before Mage starts

Dependency validation is enabled by default. The chart runs Mage's dependency
setup in an init container and starts the main container only after project
requirements install and the server and scheduler startup modules import
successfully. Set `dependencyValidation.enabled` to `false` to opt out. Releases
upgraded with `--reuse-values` from a version without `dependencyValidation`
remain disabled until the value is explicitly enabled.

```yaml
dependencyValidation:
  enabled: true
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 1Gi
```

The validator uses the Mage workload image and inherits `config`, the configured
Secret, `env` or `extraEnvs`, Redis/PostgreSQL connection variables, project
mounts, and enabled workspace or Kubernetes-executor configuration mounts. It
runs after the optional Redis and PostgreSQL readiness init containers. With
`standaloneScheduler: true`, both the web-server and scheduler Deployments
receive a validator with their corresponding `INSTANCE_TYPE`. Feature-specific
sidecar settings, such as OpenSearch TLS mounts, are not automatically copied to
the validator container.

The chart sets `MAGE_DATA_DIR` to an init-container-local path so Mage creates
the validator's managed virtual environment outside mounted project storage.
Installing or resolving dependencies during validation therefore cannot modify
the cached virtual environment used by pods from the existing release. The
isolated environment is discarded with the init container.

The default command:

1. Runs `/app/run_app.sh` to prepare the isolated Mage dependency environment.
2. Installs the project `requirements.txt` with fail-fast behavior.
3. Imports the Mage server module.
4. Imports the scheduler startup modules.

Any nonzero exit prevents the main Mage container from starting. During a
rolling deployment, existing ready pods remain available until the new pod
passes validation and readiness.

You can replace the complete validation command:

```yaml
dependencyValidation:
  enabled: true
  command:
    - /app/run_app.sh
    - /bin/bash
    - -ec
    - |
      python -c "import mage_ai.server.server"
      python -c "import mage_ai.server.scheduler_manager"
      python -c "import my_project.validation"
```

`command` replaces rather than extends the default. Keep `/app/run_app.sh` when
the check depends on Mage's managed dependency environment, and ensure custom
checks are read-only and return a nonzero exit when validation fails.

The init container and application container have separate writable image
layers, but project volumes remain shared. Custom validation commands should be
read-only and must not mutate project files or other mounted state. Mage still
performs its normal dependency setup when the main container starts, so
validation can add startup time and duplicate dependency work.

## Upgrade

Refresh repository metadata and upgrade with your existing values file:

```bash
helm repo update
helm upgrade mageai mageai/mageai \
  --namespace mageai \
  --values values.yaml \
  --atomic \
  --wait
```

Review the proposed change before applying it when the Helm diff plugin is
available:

```bash
helm diff upgrade mageai mageai/mageai \
  --namespace mageai \
  --values values.yaml
```

Pin chart and application image versions for repeatable production upgrades.
Use `helm history` and `helm rollback` to return to an earlier release revision.

Standalone releases now honor `image.digest` consistently with the combined
Deployment. When upgrading a standalone release that carries both `image.tag`
and a non-empty `image.digest`, verify that the digest identifies the intended
image: the digest will be selected and can cause the web-server and scheduler
pods to roll even when dependency validation is disabled.

## Uninstall

```bash
helm uninstall mageai --namespace mageai
```

PersistentVolumes, PersistentVolumeClaims, external databases, and external
Secrets may outlive the Helm release. Review and remove retained resources only
when their data is no longer needed.

## Examples and reference

- [`charts/mageai/values.yaml`](charts/mageai/values.yaml) documents all main
  chart values and defaults.
- [`examples/aws-eks`](examples/aws-eks) contains EKS storage and log-search
  examples.
- [`examples/local`](examples/local) contains local Kubernetes overrides.
- [Mage documentation](https://docs.mage.ai/) covers product configuration and
  deployment concepts beyond the chart itself.

## Contributing

Before opening a pull request, render and validate the affected chart:

```bash
helm dependency build charts/mageai
helm lint charts/mageai
helm unittest charts/mageai
helm template mageai charts/mageai --values your-values.yaml
```

Chart changes must increment the chart version in the corresponding
`Chart.yaml`. Pull requests run chart-testing and Kubernetes schema validation.

## License

This repository is licensed under the [Apache License 2.0](LICENSE).
