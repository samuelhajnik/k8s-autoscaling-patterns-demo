#!/usr/bin/env bash
# Lightweight manifest verification: YAML lint (optional), kubeconform, cross-reference checks.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YAMLLINT_RC='{extends: relaxed, rules: {line-length: disable, truthy: disable, new-line-at-end-of-file: disable}}'

echo "==> Repository root: ${ROOT}"

if ! command -v kubeconform >/dev/null 2>&1; then
  echo "kubeconform is not in PATH. Install a release from:" >&2
  echo "  https://github.com/yannh/kubeconform/releases" >&2
  echo "Example (macOS): brew install kubeconform" >&2
  exit 1
fi

# Standard Kubernetes resources only. keda.sh/v1alpha1 ScaledObject requires cluster CRD
# schemas; we validate that object separately via consistency checks.
STANDARD_MANIFESTS=(
  demo-1-cpu-hpa/k8s/deployment.yaml
  demo-1-cpu-hpa/k8s/service.yaml
  demo-1-cpu-hpa/k8s/hpa.yaml
  demo-2-redpanda-keda/k8s/namespace.yaml
  demo-2-redpanda-keda/k8s/consumer-deployment.yaml
  demo-2-redpanda-keda/k8s/producer-deployment.yaml
  demo-2-redpanda-keda/k8s/redpanda-deployment.yaml
  demo-2-redpanda-keda/k8s/producer-service.yaml
  demo-2-redpanda-keda/k8s/redpanda-service.yaml
)

echo "==> yamllint (optional)"
if command -v yamllint >/dev/null 2>&1; then
  yamllint -d "${YAMLLINT_RC}" demo-1-cpu-hpa/k8s
  yamllint -d "${YAMLLINT_RC}" demo-2-redpanda-keda/k8s
else
  echo "yamllint not found; skipping (CI installs it)."
fi

echo "==> kubeconform (strict, standard resources)"
kubeconform -strict -summary "${STANDARD_MANIFESTS[@]}"

echo "==> Cross-reference checks (HPA, Service selectors, ScaledObject targets)"
python3 "${ROOT}/scripts/check_manifest_consistency.py"

echo "==> All verification steps passed."
