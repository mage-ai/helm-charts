#!/usr/bin/env bash
helm repo add bitnami https://charts.bitnami.com/bitnami
ct lint --validate-maintainers=false --all --chart-dirs charts
