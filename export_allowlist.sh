#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/clusters.sh"

log() {
  printf '[export-allowlist] %s\n' "$*"
}

die() {
  printf '[export-allowlist] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./export_allowlist.sh [--cluster <name>] <instance-name> <output-json>

Examples:
  ./export_allowlist.sh test ./whitelist-test.json
  ./export_allowlist.sh minecraft1 /Users/verma/backups/minecraft1-whitelist.json

The output path must:
  - end with .json
  - have an existing parent directory
  - not already exist

The script reads /data/whitelist.json from the running Minecraft pod.
If the file is missing, it exports an empty JSON array: []

Requires kubectl access to the target cluster. Source ../noami-k3s/profile.sh first if needed.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

load_instance() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  [[ -f "${values_file}" ]] || die "Missing instance config: ${values_file}"
  # shellcheck disable=SC1090
  source "${values_file}"
  : "${INSTANCE_NAME:?INSTANCE_NAME is required}"
  : "${NAMESPACE:?NAMESPACE is required}"
}

absolute_output_path() {
  local output_path="$1"
  local parent_dir
  parent_dir="$(dirname "${output_path}")"
  [[ -d "${parent_dir}" ]] || die "Output parent directory does not exist: ${parent_dir}"
  parent_dir="$(cd "${parent_dir}" && pwd -P)"
  printf '%s/%s\n' "${parent_dir}" "$(basename "${output_path}")"
}

validate_output_path() {
  local output_path="$1"
  [[ "${output_path}" == *.json ]] || die "Output path must end with .json: ${output_path}"
  [[ ! -d "${output_path}" ]] || die "Output path is a directory: ${output_path}"
  [[ ! -e "${output_path}" ]] || die "Output file already exists: ${output_path}"
  [[ -w "$(dirname "${output_path}")" ]] || die "Output parent directory is not writable: $(dirname "${output_path}")"
}

CLUSTER_NAME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      [[ $# -ge 2 ]] || die "--cluster requires a value"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ -z "${CLUSTER_NAME}" ]]; then
  CLUSTER_NAME="$(resolved_cluster_from_context || true)"
fi
if [[ -n "${CLUSTER_NAME}" ]]; then
  cluster_name_is_valid "${CLUSTER_NAME}" || die "Invalid cluster name: ${CLUSTER_NAME}"
  INSTANCES_DIR="$(instances_dir_for_cluster "${CLUSTER_NAME}")"
  KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(cluster_kubeconfig_file "${CLUSTER_NAME}")}"
else
  INSTANCES_DIR="${ROOT_DIR}/instances"
  KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
fi

KUBECONFIG_PATH="$(resolve_kubeconfig_path "${KUBECONFIG_PATH}")"
if [[ -n "${KUBECONFIG_PATH}" ]]; then
  export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_PATH}}"
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

[[ $# -eq 2 ]] || { usage >&2; exit 1; }

INSTANCE_ARG="$1"
OUTPUT_ARG="$2"

require_cmd kubectl
load_instance "${INSTANCE_ARG}"
OUTPUT_PATH="$(absolute_output_path "${OUTPUT_ARG}")"
validate_output_path "${OUTPUT_PATH}"

log "Instance: ${INSTANCE_NAME}"
if [[ -n "${CLUSTER_NAME}" ]]; then
  log "Cluster: ${CLUSTER_NAME}"
fi
log "Namespace: ${NAMESPACE}"
log "Output: ${OUTPUT_PATH}"

if ! kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1; then
  die "Deployment not found: ${NAMESPACE}/minecraft-${INSTANCE_NAME}"
fi

if ! kubectl -n "${NAMESPACE}" exec "deployment/minecraft-${INSTANCE_NAME}" -- sh -lc 'test -f /data/whitelist.json' >/dev/null 2>&1; then
  printf '[]\n' > "${OUTPUT_PATH}"
  log "whitelist.json was missing; wrote empty whitelist."
else
  kubectl -n "${NAMESPACE}" exec "deployment/minecraft-${INSTANCE_NAME}" -- cat /data/whitelist.json > "${OUTPUT_PATH}"
  log "Exported whitelist."
fi

log "Wrote ${OUTPUT_PATH}"
