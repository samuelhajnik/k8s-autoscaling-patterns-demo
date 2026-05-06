# shellcheck shell=bash

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

wait_for_demo2_scale_down() {
	local timeout_sec="${1:?}"
	local deadline=$((SECONDS + timeout_sec))
	local next_log=$SECONDS

	while ((SECONDS < deadline)); do
		local spec ready
		spec=$(deployment_spec_replicas "consumer" "$NS_DEMO2")
		ready=$(deployment_ready_replicas "consumer" "$NS_DEMO2")
		if [[ "$spec" == "1" ]] && [[ "$ready" == "1" ]]; then
			return 0
		fi

		if ((SECONDS >= next_log)); then
			local so_ready so_active hpa_current hpa_desired remain
			so_ready="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$NS_DEMO2" get scaledobject consumer-kafka-lag -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
			so_active="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$NS_DEMO2" get scaledobject consumer-kafka-lag -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)"
			hpa_current="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$NS_DEMO2" get hpa keda-hpa-consumer-kafka-lag -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)"
			hpa_desired="$(run_with_timeout 8 kubectl --request-timeout=5s -n "$NS_DEMO2" get hpa keda-hpa-consumer-kafka-lag -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)"
			remain=$((deadline - SECONDS))
			log_err "==> Demo 2 scale-down wait: consumer spec=${spec:-?} ready=${ready:-?} target=1 hpa=${hpa_current:-?}->${hpa_desired:-?} scaledobject Ready=${so_ready:-?} Active=${so_active:-?} (~${remain}s left)"
			next_log=$((SECONDS + 20))
		fi

		sleep 4
	done

	log_err "==> Demo 2 scale-down timeout diagnostics"
	run_with_timeout 10 kubectl --request-timeout=8s -n "$NS_DEMO2" get deploy consumer -o wide 2>&1 | cat >&2 || true
	run_with_timeout 10 kubectl --request-timeout=8s -n "$NS_DEMO2" get hpa keda-hpa-consumer-kafka-lag -o wide 2>&1 | cat >&2 || true
	run_with_timeout 10 kubectl --request-timeout=8s -n "$NS_DEMO2" get scaledobject consumer-kafka-lag -o wide 2>&1 | cat >&2 || true
	run_with_timeout 10 kubectl --request-timeout=8s -n "$NS_DEMO2" get scaledobject consumer-kafka-lag \
		-o jsonpath='{range .status.conditions[*]}{.type}={.status} reason={.reason} {.message}{"\n"}{end}' 2>&1 | cat >&2 || true
	return 1
}
