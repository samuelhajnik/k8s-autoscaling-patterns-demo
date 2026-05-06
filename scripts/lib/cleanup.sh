# shellcheck shell=bash

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
