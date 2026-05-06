# shellcheck shell=bash

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

mr_fail() {
	log_err "ERROR: $*"
	print_diagnostics
	emit_summary
	exit 1
}
