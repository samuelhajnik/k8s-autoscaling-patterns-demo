#!/usr/bin/env bash
# Local demo runner: deploy both demos to kind and validate live HPA + KEDA autoscaling; prints a stable key=value summary.
set -euo pipefail

# EXIT trap / cleanup must never hit unset vars under `set -u` — initialize before anything can fail.
declare -a PORT_FORWARD_PIDS=()
declare -a LOADGEN_PIDS=()
DEMO1_PF_PID=""
DEMO2_PF_PID=""
demo1_hpa_scale_up_observed=false
demo1_hpa_scale_down_observed=false
demo2_keda_lag_scale_up_observed=false
demo2_keda_scale_down_observed=false
CREATED_CLUSTER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/assertions.sh
source "${SCRIPT_DIR}/lib/assertions.sh"
# shellcheck source=scripts/lib/kind.sh
source "${SCRIPT_DIR}/lib/kind.sh"
# shellcheck source=scripts/lib/kubectl-wait.sh
source "${SCRIPT_DIR}/lib/kubectl-wait.sh"
# shellcheck source=scripts/lib/metrics-server.sh
source "${SCRIPT_DIR}/lib/metrics-server.sh"
# shellcheck source=scripts/lib/hpa-demo.sh
source "${SCRIPT_DIR}/lib/hpa-demo.sh"
# shellcheck source=scripts/lib/keda-demo.sh
source "${SCRIPT_DIR}/lib/keda-demo.sh"
# shellcheck source=scripts/lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"

CLUSTER_NAME="${CLUSTER_NAME:-k8s-autoscaling-patterns-demo}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
# Conservative default; override e.g. KIND_NODE_IMAGE=kindest/node:v1.32.0
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.4}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-v0.7.2}"
KEDA_VERSION="${KEDA_VERSION:-2.15.1}"

usage() {
	cat <<'EOF'
Usage: run-autoscaling-demo.sh [options]

  -h, --help           Show this help.

This script always runs the full automated validation: metrics-server, Demo 1 HPA
scale up/down, Demo 2 KEDA lag-driven scale up/down, then four key=value summary
lines.

Environment:
  CLUSTER_NAME          kind cluster name (default: k8s-autoscaling-patterns-demo)
  CLUSTER_READY_TIMEOUT Seconds to wait for fresh kind node readiness before failing preflight (default: 120)
  KIND_NODE_IMAGE       kindest/node image (default: kindest/node:v1.31.4)
  KEEP_CLUSTER=true     Do not delete the cluster created by this script on exit
  METRICS_SERVER_VERSION, KEDA_VERSION   Pin install manifests for metrics-server and KEDA
  DEMO1_WORK_UNITS      Per-request CPU work units for loadgen (default: 2000000)
  DEMO1_LOAD_CONCURRENCY Parallel load goroutines/curls (default: 8)
  DEMO1_HPA_DIAG_INTERVAL Seconds between HPA progress logs while scaling (default: 25)
  TIMEOUT_DEMO1_UP, TIMEOUT_DEMO1_DOWN  HPA scale up/down wait (defaults: 300s / 420s)
  NS_DEMO1_VALIDATION_PREFIX  Prefix for Demo 1 validation namespace (default: demo-1-hpa-validation)
  VALIDATION_RUN_ID         Optional run id suffix for validation namespace (default: current epoch seconds)
  DELETE_DEMO1_VALIDATION_NAMESPACE=false  Keep Demo 1 validation namespace after run for debugging
  TIMEOUT_DEMO2_UP, TIMEOUT_DEMO2_DOWN  KEDA scale up/down wait (defaults: 300s / 360s)
  DEMO2_SEED_BATCHES        Initial producer batch count for KEDA validation path (default: 6)
  DEMO2_SEED_COUNT          Messages per initial batch (default: 500)
  DEMO2_SEED_WORK_UNITS     Work units per seeded message (default: 15000)
  DEMO2_BACKGROUND_COUNT    Messages per background producer request (default: 250)
  DEMO2_BACKGROUND_WORK_UNITS Work units per background message (default: 15000)
  DEMO2_BACKGROUND_INTERVAL_SECONDS Delay between background producer requests (default: 0.2)
                        Increase seed/background values if local KEDA scale-up is not triggered reliably.
  HTTP_WAIT_OVERALL_TIMEOUT_DEMO1  Max seconds for Demo 1 /health via port-forward (default: 180)
  HTTP_WAIT_OVERALL_TIMEOUT_DEMO2  Max seconds for Demo 2 producer /health via port-forward (default: 180)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	*)
		log_err "unknown option: $1"
		usage >&2
		exit 1
		;;
	esac
done

NS_DEMO2="demo-2-redpanda-keda"
DEMO1_DEPLOY="demo-1-cpu-hpa"
NS_DEMO1_VALIDATION_PREFIX="${NS_DEMO1_VALIDATION_PREFIX:-demo-1-hpa-validation}"
VALIDATION_RUN_ID="${VALIDATION_RUN_ID:-$(date +%s)}"
DELETE_DEMO1_VALIDATION_NAMESPACE="${DELETE_DEMO1_VALIDATION_NAMESPACE:-true}"
# Demo 1 runs in a dedicated validation namespace per run (prefix + run id).
DEMO1_NS="${NS_DEMO1_VALIDATION_PREFIX}-${VALIDATION_RUN_ID}"
TIMEOUT_DEMO1_UP="${TIMEOUT_DEMO1_UP:-300}"
TIMEOUT_DEMO1_DOWN="${TIMEOUT_DEMO1_DOWN:-420}"
TIMEOUT_DEMO2_UP="${TIMEOUT_DEMO2_UP:-300}"
TIMEOUT_DEMO2_DOWN="${TIMEOUT_DEMO2_DOWN:-360}"
# Demo 1 HPA validation load (tuned patches + these)
DEMO1_WORK_UNITS="${DEMO1_WORK_UNITS:-2000000}"
DEMO1_LOAD_CONCURRENCY="${DEMO1_LOAD_CONCURRENCY:-8}"
DEMO1_HPA_DIAG_INTERVAL="${DEMO1_HPA_DIAG_INTERVAL:-25}"
# Demo 2 KEDA / Kafka lag defaults; all overrideable via env
DEMO2_SEED_BATCHES="${DEMO2_SEED_BATCHES:-6}"
DEMO2_SEED_COUNT="${DEMO2_SEED_COUNT:-500}"
DEMO2_SEED_WORK_UNITS="${DEMO2_SEED_WORK_UNITS:-15000}"
DEMO2_BACKGROUND_COUNT="${DEMO2_BACKGROUND_COUNT:-250}"
DEMO2_BACKGROUND_WORK_UNITS="${DEMO2_BACKGROUND_WORK_UNITS:-15000}"
DEMO2_BACKGROUND_INTERVAL_SECONDS="${DEMO2_BACKGROUND_INTERVAL_SECONDS:-0.2}"
CLUSTER_READY_TIMEOUT="${CLUSTER_READY_TIMEOUT:-120}"
HTTP_WAIT_OVERALL_TIMEOUT_DEMO1="${HTTP_WAIT_OVERALL_TIMEOUT_DEMO1:-180}"
HTTP_WAIT_OVERALL_TIMEOUT_DEMO2="${HTTP_WAIT_OVERALL_TIMEOUT_DEMO2:-180}"
PF_PORT="${PF_PORT:-18081}"
PF2_PORT="${PF2_PORT:-18082}"

trap cleanup EXIT

require_cmd kind
require_cmd kubectl
require_cmd docker
require_cmd curl

log "==> Local autoscaling demo (cluster=${CLUSTER_NAME}, node_image=${KIND_NODE_IMAGE}, full HPA + KEDA validation)"

if cluster_exists; then
	log "==> Cluster ${CLUSTER_NAME} already exists; reusing (node image not changed — delete cluster or set CLUSTER_NAME to use KIND_NODE_IMAGE)"
else
	log "==> Creating kind cluster ${CLUSTER_NAME} (image=${KIND_NODE_IMAGE})"
	kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE"
	CREATED_CLUSTER="1"
fi

if ! preflight_cluster_health; then
	log_err "Try: kind delete cluster --name ${CLUSTER_NAME}; colima restart; rerun ./scripts/run-autoscaling-demo.sh."
	exit 1
fi
install_metrics_server_kind

kubectl_safe cluster-info

log "==> Building and loading Demo 1 image (demo-1-cpu-hpa:latest)"
docker build -t demo-1-cpu-hpa:latest -f demo-1-cpu-hpa/Dockerfile demo-1-cpu-hpa
kind load docker-image demo-1-cpu-hpa:latest --name "$CLUSTER_NAME"

log "==> Demo 1: creating validation namespace ${DEMO1_NS}"
kubectl_safe create namespace "$DEMO1_NS"

log "==> Demo 1: applying Deployment in namespace ${DEMO1_NS}"
kubectl_safe apply -n "$DEMO1_NS" -f demo-1-cpu-hpa/k8s/deployment.yaml
log "==> Demo 1: ensuring imagePullPolicy IfNotPresent on Deployment ${DEMO1_DEPLOY}"
ensure_demo1_image_pull_policy
log "==> Demo 1: applying Service in namespace ${DEMO1_NS}"
kubectl_safe apply -n "$DEMO1_NS" -f demo-1-cpu-hpa/k8s/service.yaml
log "==> Demo 1: waiting for base pod to become Ready"
wait_for_pod_ready_by_label "$DEMO1_NS" "app=${DEMO1_DEPLOY}" 120
log "==> Demo 1: applying base HPA in namespace ${DEMO1_NS}"
kubectl_safe apply -n "$DEMO1_NS" -f demo-1-cpu-hpa/k8s/hpa.yaml
apply_demo1_validation_tuning

log "==> Demo 1: confirming rollout complete and pods Ready before port-forward"
if ! run_with_timeout 150 kubectl --request-timeout=60s rollout status deployment/"$DEMO1_DEPLOY" -n "$DEMO1_NS" --timeout=120s; then
	exit 1
fi
if ! wait_for_pod_ready_by_label "$DEMO1_NS" "app=${DEMO1_DEPLOY}" 120; then
	exit 1
fi

start_or_restart_demo1_port_forward

BASE="http://127.0.0.1:${PF_PORT}"
log "==> Waiting for Demo 1 HTTP (${BASE})"
wait_for_http_with_port_forward_restart "${BASE}/health" "$HTTP_WAIT_OVERALL_TIMEOUT_DEMO1" demo1

log "==> GET /health"
curl -sf "${BASE}/health" >/dev/null

log "==> POST /work"
curl -sf -X POST "${BASE}/work" -H 'Content-Type: application/json' -d '{"workUnits":1}' >/dev/null

log "==> GET /stats"
stats_body="$(curl -sf "${BASE}/stats")"
echo "$stats_body"
recv="$(echo "$stats_body" | sed -n 's/.*"requestsReceived":\([0-9][0-9]*\).*/\1/p')"
if [[ -z "$recv" ]] || ((recv < 1)); then
	log_err "expected stats.requestsReceived >= 1, got: ${stats_body}"
	exit 1
fi

log "==> Demo 1 basic HTTP checks passed"

ensure_demo1_port_forward_running

log "==> Demo 1: waiting for metrics-server metrics for HPA"
if ! wait_for_hpa_metric_ready; then
	print_demo1_scale_up_failure_diagnostics
	mr_fail "HPA CPU metrics not available in time"
fi

log "==> Demo 1: generating CPU load for scale-up (concurrency=${DEMO1_LOAD_CONCURRENCY}, workUnits=${DEMO1_WORK_UNITS})"
LOADGEN_PIDS=()
for _ in $(seq 1 "$DEMO1_LOAD_CONCURRENCY"); do
	(
		while true; do
			curl -sS -m 180 -X POST "${BASE}/work" -H 'Content-Type: application/json' \
				-d "{\"workUnits\":${DEMO1_WORK_UNITS}}" >/dev/null 2>&1 || sleep 0.2
		done
	) &
	LOADGEN_PIDS+=("$!")
done

if wait_for_demo1_scale_up 2 "$TIMEOUT_DEMO1_UP"; then
	demo1_hpa_scale_up_observed=true
	log "==> Demo 1: scale-up observed (replicas >= 2)"
else
	stop_loadgen
	mr_fail_demo1_scale_up "Demo 1 HPA did not scale up within ${TIMEOUT_DEMO1_UP}s"
fi

stop_loadgen
log "==> Demo 1: load generation stopped"
log "==> Demo 1: waiting for scale-down to minReplicas"
if wait_until_replicas_match "$DEMO1_DEPLOY" "$DEMO1_NS" 1 "$TIMEOUT_DEMO1_DOWN"; then
	demo1_hpa_scale_down_observed=true
	log "==> Demo 1: scale-down observed (replicas == 1)"
else
	print_demo1_scale_up_failure_diagnostics
	mr_fail "Demo 1 HPA did not scale down within ${TIMEOUT_DEMO1_DOWN}s"
fi

# Stop Demo 1 port-forward before Demo 2
stop_port_forwards

install_keda

log "==> Demo 2: deleting namespace ${NS_DEMO2} for a clean slate (non-blocking)"
kubectl_safe delete namespace "$NS_DEMO2" --ignore-not-found=true --wait=false

log "==> Demo 2: build producer and consumer images"
docker build -t demo-2-producer:latest -f demo-2-redpanda-keda/Dockerfile.producer demo-2-redpanda-keda
docker build -t demo-2-consumer:latest -f demo-2-redpanda-keda/Dockerfile.consumer demo-2-redpanda-keda
kind load docker-image demo-2-producer:latest --name "$CLUSTER_NAME"
kind load docker-image demo-2-consumer:latest --name "$CLUSTER_NAME"

log "==> Demo 2: applying namespace, Redpanda, and producer"
kubectl_safe apply -f demo-2-redpanda-keda/k8s/namespace.yaml
kubectl_safe_long apply -f demo-2-redpanda-keda/k8s/redpanda-deployment.yaml
kubectl_safe apply -f demo-2-redpanda-keda/k8s/redpanda-service.yaml
kubectl_safe apply -f demo-2-redpanda-keda/k8s/producer-deployment.yaml
kubectl_safe apply -f demo-2-redpanda-keda/k8s/producer-service.yaml

wait_for_deployment_available "redpanda" "$NS_DEMO2" 300
wait_for_deployment_available "producer" "$NS_DEMO2" 180

create_demo2_topic_or_fail

log "==> Demo 2: deploy consumer, scale to 0 (backlog accumulates before KEDA scales)"
kubectl_safe apply -f demo-2-redpanda-keda/k8s/consumer-deployment.yaml
kubectl_safe scale deployment consumer -n "$NS_DEMO2" --replicas=0
if ! wait_until_replicas_match "consumer" "$NS_DEMO2" 0 180; then
	mr_fail_keda "Demo 2: consumer did not reach 0 replicas"
fi

log "==> Demo 2: confirming producer rollout complete and pod Ready before port-forward"
if ! run_with_timeout 150 kubectl --request-timeout=60s rollout status deployment/producer -n "$NS_DEMO2" --timeout=120s; then
	mr_fail_keda "Demo 2: producer rollout did not complete"
fi
if ! wait_for_pod_ready_by_label "$NS_DEMO2" "app=producer" 180; then
	mr_fail_keda "Demo 2: producer pod not Ready before port-forward"
fi

start_or_restart_demo2_port_forward

PROD_BASE="http://127.0.0.1:${PF2_PORT}"
log "==> Waiting for producer HTTP (${PROD_BASE})"
wait_for_http_with_port_forward_restart "${PROD_BASE}/health" "$HTTP_WAIT_OVERALL_TIMEOUT_DEMO2" demo2

ensure_demo2_port_forward_running

log "==> Demo 2: seeding finite backlog (${DEMO2_SEED_BATCHES} batches, count=${DEMO2_SEED_COUNT}, workUnits=${DEMO2_SEED_WORK_UNITS}; consumer replicas=0)"
for _b in $(seq 1 "$DEMO2_SEED_BATCHES"); do
	curl -sf -m 120 -X POST "${PROD_BASE}/produce" -H 'Content-Type: application/json' \
		-d "{\"count\":${DEMO2_SEED_COUNT},\"workUnits\":${DEMO2_SEED_WORK_UNITS}}" >/dev/null || true
done

log "==> Demo 2: applying KEDA ScaledObject"
kubectl_safe apply -f demo-2-redpanda-keda/k8s/keda-scaledobject.yaml

log "==> Demo 2: waiting for KEDA ScaledObject to become Ready"
if ! wait_for_scaledobject_ready "consumer-kafka-lag" "$NS_DEMO2" 240; then
	mr_fail_keda "ScaledObject did not become Ready within 240s"
fi

log "==> Demo 2: maintaining backlog until consumer scales out (background producer: count=${DEMO2_BACKGROUND_COUNT}, workUnits=${DEMO2_BACKGROUND_WORK_UNITS}, interval=${DEMO2_BACKGROUND_INTERVAL_SECONDS}s)"
LOADGEN_PIDS=()
(
	while true; do
		curl -sS -m 120 -X POST "${PROD_BASE}/produce" -H 'Content-Type: application/json' \
			-d "{\"count\":${DEMO2_BACKGROUND_COUNT},\"workUnits\":${DEMO2_BACKGROUND_WORK_UNITS}}" >/dev/null 2>&1 || true
		sleep "$DEMO2_BACKGROUND_INTERVAL_SECONDS"
	done
) &
LOADGEN_PIDS+=("$!")

if wait_for_replicas_at_least "consumer" "$NS_DEMO2" 2 "$TIMEOUT_DEMO2_UP"; then
	demo2_keda_lag_scale_up_observed=true
	log "==> Demo 2: lag-driven scale-up observed (consumer replicas >= 2)"
else
	stop_loadgen
	mr_fail_keda "Demo 2 consumer did not scale up within ${TIMEOUT_DEMO2_UP}s"
fi

stop_loadgen

log "==> Demo 2: background producer stopped; waiting for backlog drain and scale-down"
if wait_for_demo2_scale_down "$TIMEOUT_DEMO2_DOWN"; then
	demo2_keda_scale_down_observed=true
	log "==> Demo 2: scale-down observed (consumer replicas == 1)"
else
	mr_fail_keda "Demo 2 consumer did not scale down within ${TIMEOUT_DEMO2_DOWN}s"
fi

log "==> Autoscaling demo validation complete"
emit_summary
exit 0
