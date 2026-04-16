#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"

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
  ./export_allowlist.sh <instance-name> <output-json>

Examples:
  ./export_allowlist.sh test ./allowlist-test.json
  ./export_allowlist.sh minecraft1 /Users/verma/backups/minecraft1-allowlist.json

The output path must:
  - end with .json
  - have an existing parent directory
  - not already exist

The script reads /data/allowlist.json from the running Minecraft pod.
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
log "Namespace: ${NAMESPACE}"
log "Output: ${OUTPUT_PATH}"

if ! kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1; then
  die "Deployment not found: ${NAMESPACE}/minecraft-${INSTANCE_NAME}"
fi

if ! kubectl -n "${NAMESPACE}" exec "deployment/minecraft-${INSTANCE_NAME}" -- sh -lc 'test -f /data/allowlist.json' >/dev/null 2>&1; then
  printf '[]\n' > "${OUTPUT_PATH}"
  log "allowlist.json was missing; wrote empty allowlist."
else
  kubectl -n "${NAMESPACE}" exec "deployment/minecraft-${INSTANCE_NAME}" -- cat /data/allowlist.json > "${OUTPUT_PATH}"
  log "Exported allowlist."
fi

log "Wrote ${OUTPUT_PATH}"
