# shellcheck shell=bash

metrics_api_unusable_msg() {
	log_err "ERROR: metrics API is not usable. The cluster may be overloaded or metrics-server is unhealthy. Try deleting/recreating the kind cluster."
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
	local patched=false
	if ! metrics_server_container_has_arg "kubelet-insecure-tls"; then
		log "==> metrics-server: adding --kubelet-insecure-tls"
		kubectl_safe patch deployment metrics-server -n kube-system --type=json \
			-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
		patched=true
	fi
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
