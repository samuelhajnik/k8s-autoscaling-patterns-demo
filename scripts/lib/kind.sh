# shellcheck shell=bash

cluster_exists() {
	kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}
