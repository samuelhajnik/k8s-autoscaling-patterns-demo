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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_err() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

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

require_cmd() {
	local name="$1"
	if ! command -v "$name" >/dev/null 2>&1; then
		log_err "required command not found: $name"
		exit 1
	fi
}

run_with_timeout() {
	local timeout_sec="$1"
	shift

	if command -v timeout >/dev/null 2>&1; then
		timeout "$timeout_sec" "$@"
		return $?
	fi

	"$@" &
	local cmd_pid=$!
	local deadline=$((SECONDS + timeout_sec))

	while kill -0 "$cmd_pid" 2>/dev/null; do
		if ((SECONDS >= deadline)); then
			kill "$cmd_pid" 2>/dev/null || true
			wait "$cmd_pid" 2>/dev/null || true
			return 124
		fi
		sleep 1
	done

	wait "$cmd_pid"
}

kubectl_safe() {
	run_with_timeout "${KUBECTL_STEP_TIMEOUT:-30}" kubectl --request-timeout=10s "$@"
}

kubectl_safe_long() {
	run_with_timeout "${KUBECTL_LONG_TIMEOUT:-90}" kubectl --request-timeout=30s "$@"
}

preflight_cluster_health() {
	log "==> Checking cluster health"

	log "==> Nodes"
	kubectl_safe get nodes -o wide

	local deadline=$((SECONDS + CLUSTER_READY_TIMEOUT))
	local next_log=$SECONDS

	while ((SECONDS < deadline)); do
		if run_with_timeout 15 kubectl --request-timeout=10s wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
			log "==> all nodes are Ready"
			break
		fi

		if ((SECONDS >= next_log)); then
			log_err "==> Waiting for kind node readiness (~$((deadline - SECONDS))s left)"
			kubectl_safe get nodes -o wide >&2 || true
			kubectl_safe -n kube-system get pods -o wide >&2 || true
			kubectl_safe -n kube-system get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -30 >&2 || true
			next_log=$((SECONDS + 10))
		fi

		sleep 3
	done

	if ! run_with_timeout 15 kubectl --request-timeout=10s wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; then
		log_err "ERROR: not all nodes are Ready after ${CLUSTER_READY_TIMEOUT}s. The kind cluster is unhealthy."
		kubectl_safe get nodes -o wide >&2 || true
		kubectl_safe describe nodes >&2 || true
		kubectl_safe -n kube-system get pods -o wide >&2 || true
		kubectl_safe -n kube-system get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -50 >&2 || true
		return 1
	fi

	log "==> kube-system pods"
	kubectl_safe -n kube-system get pods -o wide

	return 0
}

metrics_api_unusable_msg() {
	log_err "ERROR: metrics API is not usable. The cluster may be overloaded or metrics-server is unhealthy. Try deleting/recreating the kind cluster."
}

cluster_exists() {
	kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

deployment_spec_replicas() {
	local deploy="$1"
	local ns="${2:-}"
	if [[ -n "$ns" ]]; then
		run_with_timeout 8 kubectl --request-timeout=5s get deploy "$deploy" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
	else
		run_with_timeout 8 kubectl --request-timeout=5s get deploy "$deploy" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
	fi
}

deployment_ready_replicas() {
	local deploy="$1"
	local ns="${2:-}"
	local out
	if [[ -n "$ns" ]]; then
		out=$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$deploy" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
	else
		out=$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$deploy" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
	fi
	echo "${out:-0}"
}

print_deployment_wait_diagnostics() {
	local name="$1"
	local ns="${2:-}"
	if [[ -n "$ns" ]]; then
		kubectl -n "$ns" get deploy "$name" -o wide >&2 || true
		kubectl -n "$ns" describe deploy "$name" >&2 || true
		kubectl -n "$ns" get rs -l "app=${name}" -o wide >&2 || true
		kubectl -n "$ns" describe rs -l "app=${name}" >&2 || true
		kubectl -n "$ns" get pods -l "app=${name}" -o wide >&2 || true
	else
		kubectl get deploy "$name" -o wide >&2 || true
		kubectl describe deploy "$name" >&2 || true
		kubectl get rs -l "app=${name}" -o wide >&2 || true
		kubectl describe rs -l "app=${name}" >&2 || true
		kubectl get pods -l "app=${name}" -o wide >&2 || true
	fi
}

# Extended diagnostics when wait_for_deployment_updated_and_available times out (includes events).
print_deployment_updated_timeout_diagnostics() {
	local name="$1"
	local ns="${2:-}"
	if [[ -n "$ns" ]]; then
		kubectl -n "$ns" get deploy "$name" -o wide >&2 || true
		kubectl -n "$ns" describe deploy "$name" >&2 || true
		kubectl -n "$ns" get rs -l "app=${name}" -o wide >&2 || true
		kubectl -n "$ns" describe rs -l "app=${name}" >&2 || true
		kubectl -n "$ns" get pods -l "app=${name}" -o wide >&2 || true
		kubectl -n "$ns" describe pods -l "app=${name}" >&2 || true
		kubectl -n "$ns" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -40 >&2 || true
	else
		kubectl get deploy "$name" -o wide >&2 || true
		kubectl describe deploy "$name" >&2 || true
		kubectl get rs -l "app=${name}" -o wide >&2 || true
		kubectl describe rs -l "app=${name}" >&2 || true
		kubectl get pods -l "app=${name}" -o wide >&2 || true
		kubectl describe pods -l "app=${name}" >&2 || true
		kubectl get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -40 >&2 || true
	fi
}

# Prints: desired updated ready available (normalized integers).
deployment_replica_counts() {
	local name="$1"
	local ns="${2:-}"
	local desired updated ready available
	if [[ -n "$ns" ]]; then
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		updated="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	else
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		updated="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	fi
	desired="${desired:-1}"
	updated="${updated:-0}"
	ready="${ready:-0}"
	available="${available:-0}"
	[[ "$desired" =~ ^[0-9]+$ ]] || desired=1
	[[ "$updated" =~ ^[0-9]+$ ]] || updated=0
	[[ "$ready" =~ ^[0-9]+$ ]] || ready=0
	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	echo "$desired $updated $ready $available"
}

print_rs_pods_progress_for_deploy() {
	local name="$1"
	local ns="${2:-}"
	if [[ -n "$ns" ]]; then
		kubectl -n "$ns" get rs -l "app=${name}" -o wide 2>&1 | cat >&2 || true
		kubectl -n "$ns" get pods -l "app=${name}" -o wide 2>&1 | cat >&2 || true
	else
		kubectl get rs -l "app=${name}" -o wide 2>&1 | cat >&2 || true
		kubectl get pods -l "app=${name}" -o wide 2>&1 | cat >&2 || true
	fi
}

deployment_available() {
	local name="$1"
	local ns="${2:-}"
	local desired ready available

	if [[ -n "$ns" ]]; then
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	else
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	fi

	desired="${desired:-1}"
	ready="${ready:-0}"
	available="${available:-0}"
	[[ "$desired" =~ ^[0-9]+$ ]] || desired=1
	[[ "$ready" =~ ^[0-9]+$ ]] || ready=0
	[[ "$available" =~ ^[0-9]+$ ]] || available=0

	((ready >= desired && available >= desired))
}

wait_for_deployment_available() {
	local name="$1"
	local ns="${2:-}"
	local timeout_sec="${3:-180}"
	local deadline=$((SECONDS + timeout_sec))
	local ns_display="${ns:-default}"
	local next_log=$SECONDS

	while ((SECONDS < deadline)); do
		if deployment_available "$name" "$ns"; then
			log "==> deployment/${name} is available"
			return 0
		fi
		if ((SECONDS >= next_log)); then
			local counts d _u r a
			counts=$(deployment_replica_counts "$name" "$ns")
			read -r d _u r a <<<"$counts"
			log_err "==> Waiting for deployment/${name} in namespace ${ns_display}: desired=${d} ready=${r} available=${a}"
			next_log=$((SECONDS + 10))
		fi
		sleep 3
	done

	log_err "ERROR: deployment/${name} did not become available within ${timeout_sec}s"
	print_deployment_wait_diagnostics "$name" "$ns"
	return 1
}

pods_all_unscheduled() {
	local ns="$1"
	local label="$2"
	local pc sched
	pc=$(run_with_timeout 12 kubectl --request-timeout=8s get pods -n "$ns" -l "$label" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')
	pc="${pc:-0}"
	[[ "$pc" -eq 0 ]] && return 1
	sched=$(run_with_timeout 12 kubectl --request-timeout=8s get pod -n "$ns" -l "$label" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | grep -cve '^$' || true)
	sched="${sched:-0}"
	[[ "$sched" -eq 0 ]]
}

any_pod_missing_nodeName() {
	local ns="$1"
	local label="$2"
	local lines
	lines=$(run_with_timeout 12 kubectl --request-timeout=8s get pod -n "$ns" -l "$label" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)
	[[ -z "$lines" ]] && return 1
	grep -q '^$' <<<"$lines"
}

print_pod_scheduling_fail_diagnostics() {
	local ns="$1"
	local label="$2"
	kubectl_safe get nodes -o wide >&2 || true
	kubectl_safe describe nodes >&2 || true
	kubectl_safe -n kube-system get pods -o wide >&2 || true
	kubectl_safe -n "$ns" describe pods -l "$label" >&2 || true
	kubectl_safe -n "$ns" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -50 >&2 || true
}

wait_for_pod_ready_by_label() {
	local ns="$1"
	local label="$2"
	local timeout_sec="${3:-120}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$SECONDS
	local wait_start=$SECONDS
	local warned_unsched=false

	while ((SECONDS < deadline)); do
		if run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" wait --for=condition=Ready pod -l "$label" --timeout=5s >/dev/null 2>&1; then
			log "==> Pod with label ${label} is Ready in namespace ${ns}"
			return 0
		fi

		if ((SECONDS >= wait_start + 60)); then
			if pods_all_unscheduled "$ns" "$label"; then
				log_err "ERROR: pod was not scheduled within 60s. This points to cluster/scheduler/node health, not the demo application."
				print_pod_scheduling_fail_diagnostics "$ns" "$label"
				return 1
			fi
		fi

		if ((SECONDS >= next_log)); then
			log_err "==> Waiting for pod readiness in namespace ${ns} (${label})"
			run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" get pod -l "$label" \
				-o jsonpath='{range .items[*]}{.metadata.name}{" phase="}{.status.phase}{" node="}{.spec.nodeName}{" reason="}{.status.reason}{"\n"}{end}' >&2 || true
			run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" get pods -l "$label" -o wide >&2 || true
			run_with_timeout 15 kubectl --request-timeout=10s -n "$ns" describe pods -l "$label" >&2 || true
			run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -30 >&2 || true
			next_log=$((SECONDS + 15))
		fi

		if ((SECONDS >= wait_start + 30)) && [[ "$warned_unsched" == "false" ]] && any_pod_missing_nodeName "$ns" "$label"; then
			log_err "WARN: pod is still unscheduled (nodeName is empty). This usually means the kind cluster scheduler/node is unhealthy or overloaded."
			kubectl_safe get nodes -o wide >&2 || true
			kubectl_safe -n kube-system get pods -o wide >&2 || true
			kubectl_safe -n "$ns" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -50 >&2 || true
			warned_unsched=true
		fi

		sleep 2
	done

	log_err "ERROR: pod with label ${label} did not become Ready within ${timeout_sec}s in namespace ${ns}"
	run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" get deploy,rs,pod -l "$label" -o wide >&2 || true
	run_with_timeout 15 kubectl --request-timeout=10s -n "$ns" describe pods -l "$label" >&2 || true
	run_with_timeout 12 kubectl --request-timeout=8s -n "$ns" get events --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -50 >&2 || true
	return 1
}

deployment_updated_and_available() {
	local name="$1"
	local ns="${2:-}"
	local desired updated ready available

	if [[ -n "$ns" ]]; then
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		updated="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	else
		desired="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
		updated="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.updatedReplicas}' 2>/dev/null || true)"
		ready="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
		available="$(run_with_timeout 8 kubectl --request-timeout=5s get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
	fi

	desired="${desired:-1}"
	updated="${updated:-0}"
	ready="${ready:-0}"
	available="${available:-0}"
	[[ "$desired" =~ ^[0-9]+$ ]] || desired=1
	[[ "$updated" =~ ^[0-9]+$ ]] || updated=0
	[[ "$ready" =~ ^[0-9]+$ ]] || ready=0
	[[ "$available" =~ ^[0-9]+$ ]] || available=0

	((updated >= desired && ready >= desired && available >= desired))
}

wait_for_deployment_updated_and_available() {
	local name="$1"
	local ns="${2:-}"
	local timeout_sec="${3:-180}"
	local deadline=$((SECONDS + timeout_sec))
	local ns_display="${ns:-default}"
	local next_progress=$SECONDS
	local next_rs_detail=$((SECONDS + 25))

	while ((SECONDS < deadline)); do
		if deployment_updated_and_available "$name" "$ns"; then
			log "==> deployment/${name} is updated and available"
			return 0
		fi
		if ((SECONDS >= next_progress)); then
			local counts d u r a
			counts=$(deployment_replica_counts "$name" "$ns")
			read -r d u r a <<<"$counts"
			log_err "==> Waiting for deployment/${name} update in namespace ${ns_display}: desired=${d} updated=${u} ready=${r} available=${a}"
			next_progress=$((SECONDS + 10))
		fi
		if ((SECONDS >= next_rs_detail)); then
			print_rs_pods_progress_for_deploy "$name" "$ns"
			next_rs_detail=$((SECONDS + 25))
		fi
		sleep 3
	done

	log_err "ERROR: deployment/${name} did not reach updated/ready/available replicas within ${timeout_sec}s"
	print_deployment_updated_timeout_diagnostics "$name" "$ns"
	return 1
}

wait_for_replicas_at_least() {
	local deploy="$1"
	local ns="${2:-}"
	local min="${3:?}"
	local timeout_sec="${4:?}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$((SECONDS + 20))
	local ns_display="${ns:-default}"

	while ((SECONDS < deadline)); do
		local spec ready
		spec=$(deployment_spec_replicas "$deploy" "$ns")
		ready=$(deployment_ready_replicas "$deploy" "$ns")
		if [[ "${spec:-0}" =~ ^[0-9]+$ ]] && [[ "${ready:-0}" =~ ^[0-9]+$ ]]; then
			if ((spec >= min && ready >= min)); then
				return 0
			fi
		fi

		if ((SECONDS >= next_log)); then
			log_err "==> wait_for_replicas_at_least: deployment=${deploy} namespace=${ns_display} desired=${spec:-?} ready=${ready:-?} minReplicas=${min} (~$((deadline - SECONDS))s remaining)"
			next_log=$((SECONDS + 20))
		fi

		sleep 4
	done
	return 1
}

print_demo1_hpa_periodic_diag() {
	local remain="${1:-?}"
	log_err "==> Demo 1: periodic HPA / CPU diagnostics (~${remain}s left on scale-up wait)"
	if [[ -n "${DEMO1_NS:-}" ]]; then
		kubectl -n "$DEMO1_NS" get hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" describe hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" top pods 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" get pods -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
	else
		kubectl get hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl describe hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl top pods 2>&1 | cat >&2 || true
		kubectl get pods -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
	fi
}

wait_for_demo1_scale_up() {
	local min="${1:?}"
	local timeout_sec="${2:?}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$((SECONDS + DEMO1_HPA_DIAG_INTERVAL))
	while ((SECONDS < deadline)); do
		local spec ready
		spec=$(deployment_spec_replicas "$DEMO1_DEPLOY" "${DEMO1_NS:-}")
		ready=$(deployment_ready_replicas "$DEMO1_DEPLOY" "${DEMO1_NS:-}")
		if [[ "${spec:-0}" =~ ^[0-9]+$ ]] && [[ "${ready:-0}" =~ ^[0-9]+$ ]]; then
			if ((spec >= min && ready >= min)); then
				return 0
			fi
		fi
		if ((SECONDS >= next_log)); then
			print_demo1_hpa_periodic_diag "$((deadline - SECONDS))"
			next_log=$((SECONDS + DEMO1_HPA_DIAG_INTERVAL))
		fi
		sleep 4
	done
	return 1
}

print_demo1_scale_up_failure_diagnostics() {
	log_err "==> Demo 1: scale-up failure diagnostics"
	if [[ -n "${DEMO1_NS:-}" ]]; then
		kubectl -n "$DEMO1_NS" get hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" describe hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" get deploy "$DEMO1_DEPLOY" -o yaml 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" get rs -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" get pods -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" describe pods -l "app=${DEMO1_DEPLOY}" 2>&1 | cat >&2 || true
		kubectl -n "$DEMO1_NS" top pods 2>&1 | cat >&2 || true
	else
		kubectl get hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl describe hpa "$DEMO1_DEPLOY" 2>&1 | cat >&2 || true
		kubectl get deploy "$DEMO1_DEPLOY" -o yaml 2>&1 | cat >&2 || true
		kubectl get rs -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
		kubectl get pods -l "app=${DEMO1_DEPLOY}" -o wide 2>&1 | cat >&2 || true
		kubectl describe pods -l "app=${DEMO1_DEPLOY}" 2>&1 | cat >&2 || true
		kubectl top pods 2>&1 | cat >&2 || true
	fi
	kubectl -n kube-system logs deploy/metrics-server --tail=100 2>&1 | cat >&2 || true
}

mr_fail_demo1_scale_up() {
	log_err "ERROR: $*"
	print_demo1_scale_up_failure_diagnostics
	print_diagnostics
	emit_summary
	exit 1
}

# Idempotent: prefer replace; add if field missing (kind/local validation runs must use loaded image, not Always pull).
ensure_demo1_image_pull_policy() {
	if ! kubectl_safe -n "$DEMO1_NS" patch deployment "$DEMO1_DEPLOY" --type='json' \
		-p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' 2>/dev/null; then
		kubectl_safe -n "$DEMO1_NS" patch deployment "$DEMO1_DEPLOY" --type='json' \
			-p='[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null 2>&1 || true
	fi
}

apply_demo1_validation_tuning() {
	log "==> Demo 1: applying validation overlay CPU/HPA tuning"
	kubectl_safe -n "$DEMO1_NS" set resources deployment "$DEMO1_DEPLOY" -c app \
		--requests=cpu=10m --limits=cpu=500m
	kubectl_safe -n "$DEMO1_NS" apply -f "${ROOT}/scripts/demo-overlays/demo-1-hpa-validation.yaml"
	log "==> Demo 1: waiting for tuned Deployment to become updated and available"
	if ! wait_for_deployment_updated_and_available "$DEMO1_DEPLOY" "$DEMO1_NS" 90; then
		exit 1
	fi
}

wait_until_replicas_match() {
	local deploy="$1"
	local ns="${2:-}"
	local want="${3:?}"
	local timeout_sec="${4:?}"
	local deadline=$((SECONDS + timeout_sec))
	while ((SECONDS < deadline)); do
		local spec ready
		spec=$(deployment_spec_replicas "$deploy" "$ns")
		ready=$(deployment_ready_replicas "$deploy" "$ns")
		if [[ "$spec" == "$want" ]] && [[ "$ready" == "$want" ]]; then
			return 0
		fi
		sleep 4
	done
	return 1
}

wait_for_hpa_metric_ready() {
	local deadline=$((SECONDS + 240))
	while ((SECONDS < deadline)); do
		if run_with_timeout 8 kubectl --request-timeout=5s top nodes >/dev/null 2>&1; then
			local util
			util=$(run_with_timeout 8 kubectl --request-timeout=5s -n "$DEMO1_NS" get hpa "$DEMO1_DEPLOY" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)
			if [[ -n "$util" ]] && [[ "$util" != "<unknown>" ]]; then
				return 0
			fi
		fi
		sleep 5
	done
	return 1
}

wait_for_scaledobject_ready() {
	local name="$1"
	local ns="${2:?}"
	local timeout_sec="${3:-240}"
	local progress_every="${4:-25}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$((SECONDS + progress_every))
	while ((SECONDS < deadline)); do
		local st
		st=$(run_with_timeout 8 kubectl --request-timeout=5s get scaledobject "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
		if [[ "$st" == "True" ]]; then
			return 0
		fi
		if ((SECONDS >= next_log)); then
			local remain=$((deadline - SECONDS))
			log_err "==> Demo 2: ScaledObject ${name} not Ready yet (~${remain}s left); conditions:"
			run_with_timeout 8 kubectl --request-timeout=5s get scaledobject "$name" -n "$ns" -o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {.message}{"\n"}{end}' 2>&1 | cat >&2 || true
			run_with_timeout 8 kubectl --request-timeout=5s get scaledobject "$name" -n "$ns" -o wide 2>&1 | cat >&2 || true
			next_log=$((SECONDS + progress_every))
		fi
		sleep 4
	done
	return 1
}

print_diagnostics() {
	log_err "==> Diagnostics (context for validation failure)"
	kubectl get pods -A 2>/dev/null || true
	log_err "---"
	kubectl get hpa -A 2>/dev/null || true
	log_err "---"
	kubectl get scaledobject -A 2>/dev/null || true
	log_err "---"
	kubectl get deploy -A 2>/dev/null || true
	log_err "--- recent events (last 40) ---"
	kubectl get events -A --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -40 || true
}

emit_summary() {
	echo "demo1_hpa_scale_up_observed=${demo1_hpa_scale_up_observed}"
	echo "demo1_hpa_scale_down_observed=${demo1_hpa_scale_down_observed}"
	echo "demo2_keda_lag_scale_up_observed=${demo2_keda_lag_scale_up_observed}"
	echo "demo2_keda_scale_down_observed=${demo2_keda_scale_down_observed}"
}

mr_fail() {
	log_err "ERROR: $*"
	print_diagnostics
	emit_summary
	exit 1
}

print_keda_diagnostics() {
	log_err "==> KEDA / Demo 2 diagnostics"
	log_err "--- namespace ${NS_DEMO2} pods ---"
	kubectl -n "$NS_DEMO2" get pods -o wide 2>&1 | cat >&2 || true
	log_err "--- namespace ${NS_DEMO2} deployments ---"
	kubectl -n "$NS_DEMO2" get deploy 2>&1 | cat >&2 || true
	log_err "--- namespace ${NS_DEMO2} hpa ---"
	kubectl -n "$NS_DEMO2" get hpa 2>&1 | cat >&2 || true
	log_err "--- namespace ${NS_DEMO2} scaledobjects ---"
	kubectl -n "$NS_DEMO2" get scaledobject 2>&1 | cat >&2 || true
	log_err "--- describe scaledobject consumer-kafka-lag ---"
	kubectl -n "$NS_DEMO2" describe scaledobject consumer-kafka-lag 2>&1 | cat >&2 || true
	log_err "--- describe hpa (all in namespace) ---"
	kubectl -n "$NS_DEMO2" describe hpa 2>&1 | cat >&2 || true
	log_err "--- logs redpanda ---"
	kubectl -n "$NS_DEMO2" logs deploy/redpanda --tail=100 2>&1 | cat >&2 || true
	log_err "--- logs producer ---"
	kubectl -n "$NS_DEMO2" logs deploy/producer --tail=100 2>&1 | cat >&2 || true
	log_err "--- logs consumer ---"
	kubectl -n "$NS_DEMO2" logs deploy/consumer --tail=100 2>&1 | cat >&2 || true
	log_err "--- keda-operator logs ---"
	kubectl -n keda logs deploy/keda-operator --tail=150 2>&1 | cat >&2 || true
	log_err "--- keda-metrics-apiserver logs ---"
	kubectl -n keda logs deploy/keda-metrics-apiserver --tail=150 2>&1 | cat >&2 || true
}

mr_fail_keda() {
	log_err "ERROR: $*"
	print_keda_diagnostics
	print_diagnostics
	emit_summary
	exit 1
}

create_demo2_topic_or_fail() {
	local out rc
	set +e
	out=$(kubectl_safe_long exec -n "$NS_DEMO2" deploy/redpanda -- \
		rpk topic create demo-work --partitions 5 --brokers redpanda:9092 2>&1)
	rc=$?
	set -e
	if [[ "$out" == *TOPIC_ALREADY_EXISTS* ]]; then
		log "==> Demo 2: topic demo-work already exists; continuing"
		return 0
	fi
	if [[ "$rc" -eq 0 ]]; then
		log "==> Demo 2: topic demo-work created"
		return 0
	fi
	log_err "ERROR: Demo 2 topic creation failed (exit ${rc}): ${out}"
	print_keda_diagnostics
	print_diagnostics
	emit_summary
	exit 1
}

stop_loadgen() {
	local old_opts
	old_opts="$(set +o)"
	set +u

	local pid
	for pid in "${LOADGEN_PIDS[@]}"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
		fi
	done

	for pid in "${LOADGEN_PIDS[@]}"; do
		if [[ -n "$pid" ]]; then
			wait "$pid" 2>/dev/null || true
		fi
	done

	LOADGEN_PIDS=()

	eval "$old_opts"
}

stop_port_forwards() {
	local old_opts
	old_opts="$(set +o)"
	set +u

	local pid
	for pid in "${PORT_FORWARD_PIDS[@]}"; do
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			kill "$pid" 2>/dev/null || true
		fi
	done

	for pid in "${PORT_FORWARD_PIDS[@]}"; do
		if [[ -n "$pid" ]]; then
			wait "$pid" 2>/dev/null || true
		fi
	done

	PORT_FORWARD_PIDS=()
	DEMO1_PF_PID=""
	DEMO2_PF_PID=""

	eval "$old_opts"
}

remove_pid_from_port_forwards() {
	local dead_pid="$1"
	local -a kept=()
	local p
	if [[ -z "$dead_pid" ]]; then
		return 0
	fi
	for p in "${PORT_FORWARD_PIDS[@]}"; do
		if [[ "$p" != "$dead_pid" ]]; then
			kept+=("$p")
		fi
	done
	PORT_FORWARD_PIDS=("${kept[@]}")
}

start_or_restart_demo1_port_forward() {
	if [[ -n "${DEMO1_PF_PID:-}" ]]; then
		if kill -0 "$DEMO1_PF_PID" 2>/dev/null; then
			kill "$DEMO1_PF_PID" 2>/dev/null || true
			wait "$DEMO1_PF_PID" 2>/dev/null || true
		fi
		remove_pid_from_port_forwards "$DEMO1_PF_PID"
	fi
	kubectl -n "$DEMO1_NS" port-forward "svc/${DEMO1_DEPLOY}" "${PF_PORT}:80" &
	DEMO1_PF_PID=$!
	PORT_FORWARD_PIDS+=("$DEMO1_PF_PID")
}

start_or_restart_demo2_port_forward() {
	if [[ -n "${DEMO2_PF_PID:-}" ]]; then
		if kill -0 "$DEMO2_PF_PID" 2>/dev/null; then
			kill "$DEMO2_PF_PID" 2>/dev/null || true
			wait "$DEMO2_PF_PID" 2>/dev/null || true
		fi
		remove_pid_from_port_forwards "$DEMO2_PF_PID"
	fi
	kubectl port-forward -n "$NS_DEMO2" svc/producer "${PF2_PORT}:8080" &
	DEMO2_PF_PID=$!
	PORT_FORWARD_PIDS+=("$DEMO2_PF_PID")
}

# Waits until URL responds, restarting the named port-forward if its process exits (e.g. rolling pod behind a Service).
# shellcheck disable=SC2310  # intentional: kill -0 status drives restart path
wait_for_http_with_port_forward_restart() {
	local url="$1"
	local overall_timeout_sec="$2"
	local which_pf="${3:?}"

	local deadline=$((SECONDS + overall_timeout_sec))

	while ((SECONDS < deadline)); do
		case "$which_pf" in
		demo1)
			if [[ -z "${DEMO1_PF_PID:-}" ]] || ! kill -0 "$DEMO1_PF_PID" 2>/dev/null; then
				log "==> Demo 1: port-forward missing or exited; restarting (kubectl port-forward svc/${DEMO1_DEPLOY})"
				start_or_restart_demo1_port_forward
				sleep 1
			fi
			;;
		demo2)
			if [[ -z "${DEMO2_PF_PID:-}" ]] || ! kill -0 "$DEMO2_PF_PID" 2>/dev/null; then
				log "==> Demo 2: port-forward missing or exited; restarting (kubectl port-forward svc/producer)"
				start_or_restart_demo2_port_forward
				sleep 1
			fi
			;;
		*)
			log_err "wait_for_http_with_port_forward_restart: unknown port-forward mode: ${which_pf}"
			return 1
			;;
		esac

		if curl -sf --max-time 3 "$url" >/dev/null; then
			return 0
		fi
		sleep 2
	done

	log_err "timeout waiting for HTTP: ${url} (overall limit ${overall_timeout_sec}s, port-forward restarts applied while waiting)"
	return 1
}

ensure_demo1_port_forward_running() {
	if [[ -z "${DEMO1_PF_PID:-}" ]] || ! kill -0 "$DEMO1_PF_PID" 2>/dev/null; then
		log "==> Demo 1: port-forward not running; restarting before continuing"
		start_or_restart_demo1_port_forward
	fi
}

ensure_demo2_port_forward_running() {
	if [[ -z "${DEMO2_PF_PID:-}" ]] || ! kill -0 "$DEMO2_PF_PID" 2>/dev/null; then
		log "==> Demo 2: port-forward not running; restarting before continuing"
		start_or_restart_demo2_port_forward
	fi
}

print_metrics_server_diagnostics() {
	log_err "==> Metrics Server diagnostics"
	log_err "--- kubectl -n kube-system get deployment metrics-server -o yaml ---"
	kubectl -n kube-system get deployment metrics-server -o yaml 2>&1 | cat >&2 || true
	log_err "--- kubectl -n kube-system get pods -l k8s-app=metrics-server -o wide ---"
	kubectl -n kube-system get pods -l k8s-app=metrics-server -o wide 2>&1 | cat >&2 || true
	log_err "--- kubectl -n kube-system describe deployment metrics-server ---"
	kubectl -n kube-system describe deployment metrics-server 2>&1 | cat >&2 || true
	log_err "--- kubectl -n kube-system describe pods -l k8s-app=metrics-server ---"
	kubectl -n kube-system describe pods -l k8s-app=metrics-server 2>&1 | cat >&2 || true
	log_err "--- kubectl -n kube-system logs -l k8s-app=metrics-server --tail=150 --all-containers=true --prefix=true ---"
	kubectl -n kube-system logs -l k8s-app=metrics-server --tail=150 --all-containers=true --prefix=true 2>&1 | cat >&2 || true
	log_err "--- kubectl get apiservice v1beta1.metrics.k8s.io -o yaml ---"
	kubectl get apiservice v1beta1.metrics.k8s.io -o yaml 2>&1 | cat >&2 || true
}

metrics_server_container_has_arg() {
	local needle="$1"
	local args
	args=$(kubectl_safe get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args[*]}' 2>/dev/null || true)
	[[ "$args" == *"$needle"* ]]
}

ensure_metrics_server_kind_args() {
	# Idempotent: append each flag only once if missing (kind TLS / kubelet addressing). No rollout wait here.
	local patched=false
	if ! metrics_server_container_has_arg "kubelet-insecure-tls"; then
		log "==> metrics-server: adding --kubelet-insecure-tls"
		kubectl_safe patch deployment metrics-server -n kube-system --type=json \
			-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
		patched=true
	fi
	# Re-read args after patch so the second check sees updated flags.
	if ! metrics_server_container_has_arg "kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"; then
		log "==> metrics-server: adding --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"
		kubectl_safe patch deployment metrics-server -n kube-system --type=json \
			-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname"}]'
		patched=true
	fi
	if [[ "$patched" == "true" ]]; then
		log "==> metrics-server: deployment patched (new rollout expected)"
	else
		log "==> metrics-server: kind-compatible args already present; skipping patch"
	fi
}

metrics_server_available() {
	local available ready desired
	available="$(run_with_timeout 8 kubectl --request-timeout=5s -n kube-system get deploy metrics-server -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
	ready="$(run_with_timeout 8 kubectl --request-timeout=5s -n kube-system get deploy metrics-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
	desired="$(run_with_timeout 8 kubectl --request-timeout=5s -n kube-system get deploy metrics-server -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"

	desired="${desired:-1}"
	ready="${ready:-0}"
	[[ "$desired" =~ ^[0-9]+$ ]] || desired=1
	[[ "$ready" =~ ^[0-9]+$ ]] || ready=0

	[[ "$available" == "True" ]] && ((ready >= desired))
}

wait_for_metrics_server_available() {
	local timeout_sec="${1:-180}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$SECONDS

	while ((SECONDS < deadline)); do
		if metrics_server_available; then
			log "==> metrics-server deployment is Available"
			return 0
		fi

		if ((SECONDS >= next_log)); then
			log_err "==> metrics-server deployment not Available yet (~$((deadline - SECONDS))s left)"
			run_with_timeout 15 kubectl --request-timeout=10s -n kube-system get deploy metrics-server -o wide 2>&1 | cat >&2 || true
			run_with_timeout 15 kubectl --request-timeout=10s -n kube-system get pods -l k8s-app=metrics-server -o wide 2>&1 | cat >&2 || true
			next_log=$((SECONDS + 10))
		fi

		sleep 3
	done
	log_err "ERROR: metrics-server deployment did not become Available within ${timeout_sec}s"
	print_metrics_server_diagnostics
	return 1
}

# Args: [timeout_sec] [skip_final_diag]. If skip_final_diag is "skip_final_diag", omit print_metrics_server_diagnostics on failure
# (first attempt in install_metrics_server_kind before deployment fallback).
wait_for_metrics_api_nodes() {
	log "==> Waiting until kubectl top nodes succeeds (metrics API usable by HPA)"
	local timeout_sec="${1:-120}"
	local skip_final_diag="${2:-}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$SECONDS

	while ((SECONDS < deadline)); do
		if run_with_timeout 8 kubectl --request-timeout=5s top nodes >/dev/null 2>&1; then
			log "==> metrics API OK (kubectl top nodes)"
			return 0
		fi

		if ((SECONDS >= next_log)); then
			log_err "==> metrics API not ready yet (~$((deadline - SECONDS))s left)"
			run_with_timeout 8 kubectl --request-timeout=5s get apiservice v1beta1.metrics.k8s.io 2>&1 | cat >&2 || true
			run_with_timeout 8 kubectl --request-timeout=5s -n kube-system get pods -l k8s-app=metrics-server -o wide 2>&1 | cat >&2 || true
			next_log=$((SECONDS + 15))
		fi

		sleep 3
	done

	log_err "ERROR: kubectl top nodes did not succeed within ${timeout_sec}s"
	if [[ "$skip_final_diag" != "skip_final_diag" ]]; then
		print_metrics_server_diagnostics
	fi
	return 1
}

install_metrics_server_kind() {
	log "==> Installing metrics-server (${METRICS_SERVER_VERSION}) for kind"

	if kubectl_safe -n kube-system get deployment metrics-server >/dev/null 2>&1; then
		log "==> metrics-server deployment already exists; reusing (not re-applying upstream manifest)"
	else
		local url="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
		if ! kubectl_safe_long apply -f "$url"; then
			log_err "ERROR: kubectl apply metrics-server failed"
			print_metrics_server_diagnostics
			metrics_api_unusable_msg
			exit 1
		fi
	fi

	ensure_metrics_server_kind_args

	if wait_for_metrics_api_nodes 120 skip_final_diag; then
		log "==> metrics-server is ready"
		return 0
	fi

	log_err "WARN: metrics API not ready yet; checking metrics-server deployment status"

	if ! wait_for_metrics_server_available 60; then
		print_metrics_server_diagnostics
		metrics_api_unusable_msg
		exit 1
	fi

	if ! wait_for_metrics_api_nodes 120; then
		print_metrics_server_diagnostics
		metrics_api_unusable_msg
		exit 1
	fi

	log "==> metrics-server is ready"
}

install_keda() {
	if kubectl_safe get deployment keda-operator -n keda >/dev/null 2>&1; then
		log "==> KEDA operator already present in namespace keda; skipping install"
		wait_for_deployment_available "keda-operator" "keda" 180
		return 0
	fi
	log "==> Installing KEDA (${KEDA_VERSION})"
	local url="https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
	if ! kubectl_safe_long apply --server-side -f "$url" 2>/dev/null; then
		if ! kubectl_safe_long apply -f "$url"; then
			log_err "ERROR: kubectl apply KEDA manifest failed"
			exit 1
		fi
	fi
	wait_for_deployment_available "keda-operator" "keda" 240
	wait_for_deployment_available "keda-metrics-apiserver" "keda" 240
}

# Invoked via `trap cleanup EXIT` (shellcheck cannot always trace trap callbacks).
# shellcheck disable=SC2329
cleanup() {
	local exit_code=$?
	stop_loadgen
	stop_port_forwards

	if [[ -n "${DEMO1_NS:-}" ]] && [[ "${DELETE_DEMO1_VALIDATION_NAMESPACE:-true}" != "false" ]]; then
		kubectl_safe delete namespace "$DEMO1_NS" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
	fi

	if [[ "${CREATED_CLUSTER:-}" == "1" ]] && [[ "${KEEP_CLUSTER:-}" != "true" ]]; then
		log "==> Deleting kind cluster ${CLUSTER_NAME} (created by this script)"
		kind delete cluster --name "${CLUSTER_NAME:-k8s-autoscaling-patterns-demo}" || true
	fi

	exit "$exit_code"
}

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
if wait_until_replicas_match "consumer" "$NS_DEMO2" 1 "$TIMEOUT_DEMO2_DOWN"; then
	demo2_keda_scale_down_observed=true
	log "==> Demo 2: scale-down observed (consumer replicas == 1)"
else
	mr_fail_keda "Demo 2 consumer did not scale down within ${TIMEOUT_DEMO2_DOWN}s"
fi

log "==> Autoscaling demo validation complete"
emit_summary
exit 0
