#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"

log() {
  printf '[uninstall] %s\n' "$*"
}

die() {
  printf '[uninstall] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_yes() {
  case "$1" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

list_instances() {
  local instance state
  while IFS= read -r instance; do
    state="$(instance_state "${instance}")"
    [[ "${state}" == "deleted-local-config-only" ]] && continue
    printf '%s\n' "${instance}"
  done < <(find "${INSTANCES_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort)
}

load_instance() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  [[ -f "${values_file}" ]] || die "Missing instance config: ${values_file}"
  # shellcheck disable=SC1090
  source "${values_file}"
  : "${INSTANCE_NAME:?INSTANCE_NAME is required}"
  : "${NAMESPACE:?NAMESPACE is required}"
  : "${DATA_PATH:?DATA_PATH is required}"
}

resource_exists() {
  local kind="$1"
  local name="$2"
  kubectl -n "${NAMESPACE}" get "${kind}" "${name}" >/dev/null 2>&1
}

pv_exists() {
  kubectl get pv "minecraft-${INSTANCE_NAME}-pv" >/dev/null 2>&1
}

instance_state() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  (
    NAMESPACE="apps"
    INSTANCE_NAME="${instance}"
    [[ -f "${values_file}" ]] && source "${values_file}"
    if kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1 || \
       kubectl -n "${NAMESPACE}" get service "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1 || \
       kubectl -n "${NAMESPACE}" get pvc "minecraft-${INSTANCE_NAME}-data" >/dev/null 2>&1; then
      printf 'installed'
    elif kubectl get pv "minecraft-${INSTANCE_NAME}-pv" >/dev/null 2>&1; then
      printf 'deleted-pv-retained'
    else
      printf 'deleted-local-config-only'
    fi
  )
}

instance_summary() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  (
    PORT="?"
    NAMESPACE="?"
    SUBDOMAIN=""
    DATA_PATH=""
    [[ -f "${values_file}" ]] && source "${values_file}"
    state="$(instance_state "${instance}")"
    printf '%-24s status=%-24s port=%-6s namespace=%-12s subdomain=%s data=%s\n' \
      "${instance}" "${state}" "${PORT:-?}" "${NAMESPACE:-?}" "${SUBDOMAIN:-}" "${DATA_PATH:-}"
  )
}

select_instance() {
  local selection
  instances=()
  while IFS= read -r instance; do
    instances+=("${instance}")
  done < <(list_instances)
  (( ${#instances[@]} > 0 )) || die "No instances found in ${INSTANCES_DIR}"

  printf 'Instances:\n' >&2
  local i
  for i in "${!instances[@]}"; do
    printf '  %d) ' "$((i + 1))" >&2
    instance_summary "${instances[$i]}" >&2
  done

  read -r -p "Select instance number: " selection
  [[ "${selection}" =~ ^[0-9]+$ ]] || die "Selection must be a number."
  (( selection >= 1 && selection <= ${#instances[@]} )) || die "Selection out of range."
  printf '%s\n' "${instances[$((selection - 1))]}"
}

delete_namespaced_if_exists() {
  local kind="$1"
  local name="$2"
  if kubectl -n "${NAMESPACE}" get "${kind}" "${name}" >/dev/null 2>&1; then
    log "Deleting ${kind}/${name}"
    kubectl -n "${NAMESPACE}" delete "${kind}" "${name}" --wait=true
  else
    log "${kind}/${name} does not exist; skipping"
  fi
}

delete_pv_if_exists() {
  local name="minecraft-${INSTANCE_NAME}-pv"
  if kubectl get pv "${name}" >/dev/null 2>&1; then
    log "Deleting persistentvolume/${name}"
    kubectl delete pv "${name}" --wait=true
  else
    log "persistentvolume/${name} does not exist; skipping"
  fi
}

delete_local_config() {
  local instance_dir="${INSTANCES_DIR}/${INSTANCE_TO_DELETE}"
  if [[ -d "${instance_dir}" ]]; then
    log "Deleting local instance config ${instance_dir}"
    rm -rf "${instance_dir}"
  else
    log "Local instance config ${instance_dir} does not exist; skipping"
  fi
}

wait_for_pod_success() {
  local pod_name="$1"
  local phase
  local i
  for i in {1..180}; do
    phase="$(kubectl -n "${NAMESPACE}" get pod "${pod_name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Succeeded) return 0 ;;
      Failed) return 1 ;;
    esac
    sleep 1
  done
  return 1
}

cleanup_host_data() {
  local cleanup_pod="minecraft-${INSTANCE_NAME}-host-cleanup-$(date +%Y%m%dt%H%M%S)"
  local data_parent
  local data_base

  [[ "${DATA_PATH}" == /data/minecraft/* ]] || die "Refusing to delete unexpected DATA_PATH: ${DATA_PATH}"
  data_parent="$(dirname "${DATA_PATH}")"
  data_base="$(basename "${DATA_PATH}")"
  [[ -n "${data_base}" && "${data_base}" != "." && "${data_base}" != "/" ]] || die "Invalid DATA_PATH basename: ${DATA_PATH}"

  log "Deleting host data ${DATA_PATH} using temporary cleanup pod ${cleanup_pod}"
  kubectl -n "${NAMESPACE}" run "${cleanup_pod}" \
    --image=busybox:1.36 \
    --restart=Never \
    --overrides="$(
      cat <<JSON
{
  "apiVersion": "v1",
  "spec": {
    "nodeSelector": {
      "${NODE_LABEL:-minecraft}": "true"
    },
    "containers": [
      {
        "name": "cleanup",
        "image": "busybox:1.36",
        "command": ["sh", "-ec"],
        "args": ["target=/host-data/${data_base}; if [ -e \"\$target\" ]; then rm -rf -- \"\$target\"; fi"],
        "volumeMounts": [
          { "name": "host-data", "mountPath": "/host-data" }
        ]
      }
    ],
    "volumes": [
      {
        "name": "host-data",
        "hostPath": {
          "path": "${data_parent}",
          "type": "DirectoryOrCreate"
        }
      }
    ],
    "restartPolicy": "Never"
  }
}
JSON
    )"
  kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${cleanup_pod}" --timeout=180s || true
  kubectl -n "${NAMESPACE}" wait --for=condition=Succeeded "pod/${cleanup_pod}" --timeout=180s
  kubectl -n "${NAMESPACE}" logs "${cleanup_pod}" || true
  kubectl -n "${NAMESPACE}" delete pod "${cleanup_pod}" --wait=true
  log "Deleted host data ${DATA_PATH}"
}

storage_objects_gone() {
  ! kubectl -n "${NAMESPACE}" get pvc "minecraft-${INSTANCE_NAME}-data" >/dev/null 2>&1 && \
    ! kubectl get pv "minecraft-${INSTANCE_NAME}-pv" >/dev/null 2>&1
}

cleanup_local_config_if_storage_gone() {
  if storage_objects_gone; then
    log "PVC and PV are gone; removing local config so ${INSTANCE_NAME} no longer appears in this menu."
    delete_local_config
  else
    log "Storage object remains; keeping local config so ${INSTANCE_NAME} can still be managed."
  fi
}

require_cmd kubectl

INSTANCE_TO_DELETE="$(select_instance)"
load_instance "${INSTANCE_TO_DELETE}"

printf '\nSelected instance: %s\n' "${INSTANCE_NAME}"
printf 'Current status: %s\n' "$(instance_state "${INSTANCE_TO_DELETE}")"
printf 'Host data path: %s\n' "${DATA_PATH}"
printf '\nThis can delete Kubernetes resources and local instance config. It will not delete host files at %s.\n' "${DATA_PATH}"
read -r -p "Type '${INSTANCE_NAME}' to continue: " confirmation
[[ "${confirmation}" == "${INSTANCE_NAME}" ]] || die "Confirmation did not match; aborting."

read -r -p "Delete Deployment and Service if present? [yes]: " delete_workload
if [[ -z "${delete_workload}" ]] || is_yes "${delete_workload}"; then
  delete_namespaced_if_exists deployment "minecraft-${INSTANCE_NAME}"
  delete_namespaced_if_exists service "minecraft-${INSTANCE_NAME}"
else
  log "Keeping Deployment and Service."
fi

read -r -p "Delete PVC minecraft-${INSTANCE_NAME}-data if present? [yes]: " delete_pvc
if [[ -z "${delete_pvc}" ]] || is_yes "${delete_pvc}"; then
  delete_namespaced_if_exists pvc "minecraft-${INSTANCE_NAME}-data"
else
  log "Keeping PVC minecraft-${INSTANCE_NAME}-data."
fi

read -r -p "Delete PV minecraft-${INSTANCE_NAME}-pv? This removes the Kubernetes PV object but keeps hostPath files. [no]: " delete_pv
if is_yes "${delete_pv}"; then
  delete_pv_if_exists
else
  log "Keeping PersistentVolume minecraft-${INSTANCE_NAME}-pv."
fi

cleanup_local_config_if_storage_gone

read -r -p "Delete host data files at ${DATA_PATH}? This permanently removes the world files from the storage node. [no]: " delete_host_data
if is_yes "${delete_host_data}"; then
  cleanup_host_data
else
  log "Host data remains at ${DATA_PATH}."
fi

log "Uninstall complete"
