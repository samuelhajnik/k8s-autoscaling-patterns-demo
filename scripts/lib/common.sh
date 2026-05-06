# shellcheck shell=bash

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
