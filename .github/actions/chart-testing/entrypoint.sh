#!/usr/bin/env bash
set -euo pipefail

helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add opensearch https://opensearch-project.github.io/helm-charts
helm plugin install https://github.com/helm-unittest/helm-unittest.git --version v0.4.1
for chart in charts/*; do
  if [ -d "$chart/tests" ]; then
    helm unittest "$chart"
  fi
done
ct lint --validate-maintainers=false --all --chart-dirs charts
