# shellcheck shell=bash

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
