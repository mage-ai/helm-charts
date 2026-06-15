# Summary

Adds AWS EKS deployment configuration for the OpenSearch-backed log search feature (OpenSearch + Fluent Bit) on a Mage Pro deployment.

## Update: Refactored as chart-native feature

Refactored log search from an example-only overlay into a first-class chart feature, addressing the reviewer's feedback that "the core support should live in the Helm chart itself."

**Chart changes (`charts/mageai/`):**
- Added `logSearch.*` values block to `values.yaml` — `enabled`, `opensearch.*`, `persistence.*`, `fluentBit.*`, `setupJob.*` — all off by default
- `deployment.yaml` now renders OpenSearch env vars (`OPENSEARCH_HOST`, `OPENSEARCH_PORT`, `USE_OPENSEARCH_FOR_LOGS`, `MAGE_DATA_DIR`), the Fluent Bit sidecar, and shared volumes natively when `logSearch.enabled: true`
- New `templates/log-search-job.yaml` renders the OpenSearch index setup Job as a Helm post-install/post-upgrade hook when `logSearch.setupJob.enabled: true`

**Examples (`examples/aws-eks/`):**
- `values-log-search.yaml` rewritten to use `logSearch.*` chart values instead of raw `extraVolumes`/`extraContainers`
- `values-log-search-staging.yaml` reduced to just the two staging-specific overrides (`existingClaim`, `subPath`) — production deploys via a separate `values-log-search-prod.yaml` overlay
- Added `opensearch-values.yaml` for the OpenSearch Helm release (previously lived only on a local machine)
- Removed `opensearch-setup-job.yaml` — superseded by the chart-rendered setup Job
- `README.md` updated to use `$ENV_OVERLAY` variable so a single `helm upgrade` command covers both staging and production
