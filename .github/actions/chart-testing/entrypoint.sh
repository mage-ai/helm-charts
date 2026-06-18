#!/usr/bin/env bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add opensearch https://opensearch-project.github.io/helm-charts
ct lint --validate-maintainers=false --all --chart-dirs charts
