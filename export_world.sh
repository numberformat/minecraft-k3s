#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"

log() {
  printf '[export] %s\n' "$*"
}

die() {
  printf '[export] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./export_world.sh <instance-name> <output-tar.gz>

Examples:
  ./export_world.sh test /Users/verma/backups/minecraft-test-YYYYMMDD.tar.gz
  ./export_world.sh minecraft1 ./exports/minecraft1-world.tar.gz

The output path must:
  - end with .tar.gz
  - have an existing parent directory
  - not already exist
  - not be a directory

The script exports the instance PVC /data directory as a tar.gz archive. It will:
  - validate the instance and output path
  - scale minecraft-<instance> to 0 for a consistent snapshot
  - mount the instance PVC in a temporary read-only pod
  - stream /data to the requested local tar.gz file
  - restore the deployment to its previous replica count

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
  [[ "${output_path}" == *.tar.gz ]] || die "Output path must end with .tar.gz: ${output_path}"
  [[ ! -d "${output_path}" ]] || die "Output path is a directory: ${output_path}"
  [[ ! -e "${output_path}" ]] || die "Output file already exists: ${output_path}"
  [[ -w "$(dirname "${output_path}")" ]] || die "Output parent directory is not writable: $(dirname "${output_path}")"
}

current_replicas() {
  kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" -o jsonpath='{.spec.replicas}'
}

create_export_pod() {
  kubectl -n "${NAMESPACE}" run "${EXPORT_POD}" \
    --image=busybox:1.36 \
    --restart=Never \
    --overrides="$(
      cat <<JSON
{
  "apiVersion": "v1",
  "spec": {
    "containers": [
      {
        "name": "exporter",
        "image": "busybox:1.36",
        "command": ["sh", "-c", "sleep 3600"],
        "volumeMounts": [
          { "name": "data", "mountPath": "/data", "readOnly": true }
        ]
      }
    ],
    "volumes": [
      {
        "name": "data",
        "persistentVolumeClaim": {
          "claimName": "minecraft-${INSTANCE_NAME}-data",
          "readOnly": true
        }
      }
    ],
    "restartPolicy": "Never"
  }
}
JSON
    )"
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${EXPORT_POD}" --timeout=180s
}

cleanup() {
  if [[ -n "${EXPORT_POD:-}" && -n "${NAMESPACE:-}" ]]; then
    kubectl -n "${NAMESPACE}" delete pod "${EXPORT_POD}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  fi
}

restore_replicas() {
  if [[ -n "${ORIGINAL_REPLICAS:-}" && -n "${NAMESPACE:-}" && -n "${INSTANCE_NAME:-}" ]]; then
    log "Restoring minecraft-${INSTANCE_NAME} to ${ORIGINAL_REPLICAS} replica(s)"
    kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas="${ORIGINAL_REPLICAS}" >/dev/null
    if (( ORIGINAL_REPLICAS > 0 )); then
      kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=240s
    fi
  fi
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

[[ $# -eq 2 ]] || { usage >&2; exit 1; }

INSTANCE_ARG="$1"
OUTPUT_ARG="$2"

require_cmd kubectl
require_cmd tar

load_instance "${INSTANCE_ARG}"
OUTPUT_PATH="$(absolute_output_path "${OUTPUT_ARG}")"
validate_output_path "${OUTPUT_PATH}"

EXPORT_POD="minecraft-${INSTANCE_NAME}-export-$(date +%Y%m%dt%H%M%S)"
ORIGINAL_REPLICAS="$(current_replicas)"
trap 'cleanup; restore_replicas' EXIT

log "Instance: ${INSTANCE_NAME}"
log "Namespace: ${NAMESPACE}"
log "Output: ${OUTPUT_PATH}"
log "Original replicas: ${ORIGINAL_REPLICAS}"

log "Scaling minecraft-${INSTANCE_NAME} to 0"
kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=0
kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
kubectl -n "${NAMESPACE}" wait pod -l "app.kubernetes.io/instance=${INSTANCE_NAME}" --for=delete --timeout=180s || true

log "Creating temporary export pod ${EXPORT_POD}"
create_export_pod

log "Streaming /data to ${OUTPUT_PATH}"
kubectl -n "${NAMESPACE}" exec "${EXPORT_POD}" -- tar -C /data -czf - . > "${OUTPUT_PATH}"

log "Wrote $(ls -lh "${OUTPUT_PATH}" | awk '{print $5}') to ${OUTPUT_PATH}"
cleanup
trap - EXIT
restore_replicas

log "Export complete"
