#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/clusters.sh"

log() {
  printf '[import-allowlist] %s\n' "$*"
}

die() {
  printf '[import-allowlist] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./import_allowlist.sh [--cluster <name>] <instance-name> <source-json>

Examples:
  ./import_allowlist.sh test ./whitelist-test.json
  ./import_allowlist.sh minecraft1 /Users/verma/backups/minecraft1-whitelist.json

The source file must be a readable .json file containing a Java whitelist array.
Example:
  [
    {
      "uuid": "00000000-0000-0000-0000-000000000000",
      "name": "PlayerName"
    }
  ]

The script validates the JSON, scales the instance down, replaces /data/whitelist.json,
and restores the previous replica count.

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

absolute_source_path() {
  local source_path="$1"
  [[ -f "${source_path}" ]] || die "Source file does not exist: ${source_path}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "${source_path}"
  else
    local parent_dir
    parent_dir="$(dirname "${source_path}")"
    (cd "${parent_dir}" && printf '%s/%s\n' "$(pwd -P)" "$(basename "${source_path}")")
  fi
}

validate_source_file() {
  local source_path="$1"
  [[ "${source_path}" == *.json ]] || die "Source file must end with .json: ${source_path}"
  [[ -r "${source_path}" ]] || die "Source file is not readable: ${source_path}"

  ruby -rjson -e '
    path = ARGV.fetch(0)
    begin
      data = JSON.parse(File.read(path))
      raise "whitelist must be a JSON array" unless data.is_a?(Array)
      data.each_with_index do |entry, idx|
        raise "whitelist entry #{idx} must be an object" unless entry.is_a?(Hash)
        has_name = entry.key?("name") && entry["name"].is_a?(String) && !entry["name"].empty?
        has_uuid = entry.key?("uuid") && entry["uuid"].is_a?(String) && !entry["uuid"].empty?
        raise "whitelist entry #{idx} must include non-empty name and uuid fields" unless has_name && has_uuid
      end
    rescue => e
      warn e.message
      exit 1
    end
  ' "${source_path}" || die "Invalid whitelist JSON: ${source_path}"
}

current_replicas() {
  kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" -o jsonpath='{.spec.replicas}'
}

create_import_pod() {
  kubectl -n "${NAMESPACE}" run "${IMPORT_POD}" \
    --image=busybox:1.36 \
    --restart=Never \
    --overrides="$(
      cat <<JSON
{
  "apiVersion": "v1",
  "spec": {
    "containers": [
      {
        "name": "importer",
        "image": "busybox:1.36",
        "command": ["sh", "-c", "sleep 3600"],
        "volumeMounts": [
          { "name": "data", "mountPath": "/data" }
        ]
      }
    ],
    "volumes": [
      {
        "name": "data",
        "persistentVolumeClaim": {
          "claimName": "minecraft-${INSTANCE_NAME}-data"
        }
      }
    ],
    "restartPolicy": "Never"
  }
}
JSON
    )"
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${IMPORT_POD}" --timeout=180s
}

cleanup() {
  if [[ -n "${IMPORT_POD:-}" && -n "${NAMESPACE:-}" ]]; then
    kubectl -n "${NAMESPACE}" delete pod "${IMPORT_POD}" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
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
SOURCE_ARG="$2"

require_cmd kubectl
require_cmd ruby

load_instance "${INSTANCE_ARG}"
SOURCE_PATH="$(absolute_source_path "${SOURCE_ARG}")"
validate_source_file "${SOURCE_PATH}"

IMPORT_POD="minecraft-${INSTANCE_NAME}-whitelist-$(date +%Y%m%dt%H%M%S)"
ORIGINAL_REPLICAS="$(current_replicas)"
trap 'cleanup; restore_replicas' EXIT

log "Instance: ${INSTANCE_NAME}"
if [[ -n "${CLUSTER_NAME}" ]]; then
  log "Cluster: ${CLUSTER_NAME}"
fi
log "Namespace: ${NAMESPACE}"
log "Source: ${SOURCE_PATH}"
log "Original replicas: ${ORIGINAL_REPLICAS}"

log "Scaling minecraft-${INSTANCE_NAME} to 0"
kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=0
kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
kubectl -n "${NAMESPACE}" wait pod -l "app.kubernetes.io/instance=${INSTANCE_NAME}" --for=delete --timeout=180s || true

log "Creating temporary import pod ${IMPORT_POD}"
create_import_pod

log "Replacing /data/whitelist.json"
kubectl -n "${NAMESPACE}" exec -i "${IMPORT_POD}" -- sh -lc 'cat > /data/whitelist.json && chmod 664 /data/whitelist.json && chown 1000:100 /data/whitelist.json 2>/dev/null || true' < "${SOURCE_PATH}"
kubectl -n "${NAMESPACE}" exec "${IMPORT_POD}" -- sh -lc 'ls -l /data/whitelist.json; cat /data/whitelist.json'

cleanup
trap - EXIT
restore_replicas

log "Import complete"
