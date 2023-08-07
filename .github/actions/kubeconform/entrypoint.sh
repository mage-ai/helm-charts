#!/usr/bin/env bash
cd "$CHART_PATH"

curl https://github.com/yannh/kubeconform/releases/download/v0.6.3/kubeconform-linux-amd64.tar.gz --output /tmp/kubeconform.tar.gz --location
tar xfz /tmp/kubeconform.tar.gz -C /usr/bin/

find . -maxdepth 1 -type f -iname "values*.yaml" -exec helm template --values {} . \; | kubeconform -strict -verbose
