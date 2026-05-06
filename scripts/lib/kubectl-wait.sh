# shellcheck shell=bash

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
