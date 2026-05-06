# shellcheck shell=bash

log() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log_err() {
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

emit_summary() {
	echo "demo1_hpa_scale_up_observed=${demo1_hpa_scale_up_observed:-false}"
	echo "demo1_hpa_scale_down_observed=${demo1_hpa_scale_down_observed:-false}"
	echo "demo2_keda_lag_scale_up_observed=${demo2_keda_lag_scale_up_observed:-false}"
	echo "demo2_keda_scale_down_observed=${demo2_keda_scale_down_observed:-false}"
}
