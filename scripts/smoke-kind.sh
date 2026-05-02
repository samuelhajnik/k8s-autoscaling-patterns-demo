#!/usr/bin/env bash
# Optional local smoke: deploy demo images to a kind cluster and hit HTTP endpoints.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-k8s-autoscaling-patterns-demo}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
RUN_KEDA_SMOKE="${RUN_KEDA_SMOKE:-false}"

PORT_FORWARD_PIDS=()
CREATED_CLUSTER=""

require_cmd() {
	local name="$1"
	if ! command -v "$name" >/dev/null 2>&1; then
		echo "required command not found: $name" >&2
		exit 1
	fi
}

cluster_exists() {
	kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

wait_for_http() {
	local url="$1"
	local max_attempts="${2:-40}"
	local i=0
	while (( i < max_attempts )); do
		if curl -sf --max-time 3 "$url" >/dev/null; then
			return 0
		fi
		sleep 2
		i=$((i + 1))
	done
	echo "timeout waiting for HTTP: $url" >&2
	return 1
}

cleanup() {
	for pid in "${PORT_FORWARD_PIDS[@]}"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
			wait "$pid" 2>/dev/null || true
		fi
	done
	if [[ "$CREATED_CLUSTER" == "1" ]] && [[ "$KEEP_CLUSTER" != "true" ]]; then
		echo "==> Deleting kind cluster ${CLUSTER_NAME} (created by this script)"
		kind delete cluster --name "$CLUSTER_NAME" || true
	fi
}

trap cleanup EXIT

require_cmd kind
require_cmd kubectl
require_cmd docker
require_cmd curl

echo "==> Kind smoke test (cluster=${CLUSTER_NAME}, RUN_KEDA_SMOKE=${RUN_KEDA_SMOKE})"

if cluster_exists; then
	echo "==> Cluster ${CLUSTER_NAME} already exists; reusing"
else
	echo "==> Creating kind cluster ${CLUSTER_NAME}"
	kind create cluster --name "$CLUSTER_NAME"
	CREATED_CLUSTER="1"
fi

echo "==> Building and loading Demo 1 image (demo-1-cpu-hpa:latest)"
docker build -t demo-1-cpu-hpa:latest -f demo-1-cpu-hpa/Dockerfile demo-1-cpu-hpa
kind load docker-image demo-1-cpu-hpa:latest --name "$CLUSTER_NAME"

kubectl cluster-info

echo "==> Applying Demo 1 manifests"
kubectl apply -f demo-1-cpu-hpa/k8s/deployment.yaml
kubectl apply -f demo-1-cpu-hpa/k8s/service.yaml
kubectl apply -f demo-1-cpu-hpa/k8s/hpa.yaml

echo "==> Waiting for Demo 1 rollout"
kubectl rollout status deployment/demo-1-cpu-hpa --timeout=180s

PF_PORT="18081"
kubectl port-forward "svc/demo-1-cpu-hpa" "${PF_PORT}:80" &
PORT_FORWARD_PIDS+=("$!")

BASE="http://127.0.0.1:${PF_PORT}"
echo "==> Waiting for Demo 1 HTTP (${BASE})"
wait_for_http "${BASE}/health"

echo "==> GET /health"
curl -sf "${BASE}/health" >/dev/null

echo "==> POST /work"
curl -sf -X POST "${BASE}/work" -H 'Content-Type: application/json' -d '{"workUnits":1}' >/dev/null

echo "==> GET /stats"
stats_body="$(curl -sf "${BASE}/stats")"
echo "$stats_body"
recv="$(echo "$stats_body" | sed -n 's/.*"requestsReceived":\([0-9][0-9]*\).*/\1/p')"
if [[ -z "$recv" ]] || (( recv < 1 )); then
	echo "expected stats.requestsReceived >= 1, got: ${stats_body}" >&2
	exit 1
fi

echo "==> Demo 1 smoke checks passed"

if [[ "$RUN_KEDA_SMOKE" != "true" ]]; then
	echo "==> RUN_KEDA_SMOKE is not true; skipping Demo 2 runtime smoke"
	exit 0
fi

echo "==> Demo 2 runtime smoke: build producer and consumer images"
docker build -t demo-2-producer:latest -f demo-2-redpanda-keda/Dockerfile.producer demo-2-redpanda-keda
docker build -t demo-2-consumer:latest -f demo-2-redpanda-keda/Dockerfile.consumer demo-2-redpanda-keda
kind load docker-image demo-2-producer:latest --name "$CLUSTER_NAME"
kind load docker-image demo-2-consumer:latest --name "$CLUSTER_NAME"

NS="demo-2-redpanda-keda"
echo "==> Applying Demo 2 namespace and workloads"
kubectl apply -f demo-2-redpanda-keda/k8s/namespace.yaml
kubectl apply -f demo-2-redpanda-keda/k8s/redpanda-deployment.yaml
kubectl apply -f demo-2-redpanda-keda/k8s/redpanda-service.yaml
kubectl apply -f demo-2-redpanda-keda/k8s/producer-deployment.yaml
kubectl apply -f demo-2-redpanda-keda/k8s/producer-service.yaml
kubectl apply -f demo-2-redpanda-keda/k8s/consumer-deployment.yaml

kubectl rollout status deployment/redpanda -n "$NS" --timeout=300s
kubectl rollout status deployment/producer -n "$NS" --timeout=180s
kubectl rollout status deployment/consumer -n "$NS" --timeout=180s

PF2_PORT="18082"
kubectl port-forward -n "$NS" svc/producer "${PF2_PORT}:8080" &
PORT_FORWARD_PIDS+=("$!")

PROD_BASE="http://127.0.0.1:${PF2_PORT}"
echo "==> Waiting for producer HTTP (${PROD_BASE})"
wait_for_http "${PROD_BASE}/health"

echo "==> GET producer /health"
curl -sf "${PROD_BASE}/health" >/dev/null

echo "==> POST producer /produce (optional, requires broker)"
set +e
prod_out="$(curl -sf --max-time 30 -X POST "${PROD_BASE}/produce" -H 'Content-Type: application/json' -d '{}' 2>&1)"
prod_rc=$?
set -e
if [[ "$prod_rc" -ne 0 ]]; then
	echo "WARN: POST /produce failed (rc=${prod_rc}); broker may still be settling. Output:" >&2
	echo "$prod_out" >&2
else
	echo "$prod_out"
fi

echo "==> Demo 2 smoke checks finished"
