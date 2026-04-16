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

list_instances() {
  find "${INSTANCES_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
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

instance_summary() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  (
    PORT="?"
    NAMESPACE="?"
    SUBDOMAIN=""
    DATA_PATH=""
    [[ -f "${values_file}" ]] && source "${values_file}"
    printf '%-24s port=%-6s namespace=%-12s subdomain=%s data=%s\n' \
      "${instance}" "${PORT:-?}" "${NAMESPACE:-?}" "${SUBDOMAIN:-}" "${DATA_PATH:-}"
  )
}

select_instance() {
  local selection
  instances=()
  while IFS= read -r instance; do
    instances+=("${instance}")
  done < <(list_instances)
  (( ${#instances[@]} > 0 )) || die "No instances found in ${INSTANCES_DIR}"

  printf 'Available instances:\n' >&2
  local i
  for i in "${!instances[@]}"; do
    printf '  %d) ' "$((i + 1))" >&2
    instance_summary "${instances[$i]}" >&2
  done

  read -r -p "Select instance number to uninstall: " selection
  [[ "${selection}" =~ ^[0-9]+$ ]] || die "Selection must be a number."
  (( selection >= 1 && selection <= ${#instances[@]} )) || die "Selection out of range."
  printf '%s\n' "${instances[$((selection - 1))]}"
}

delete_if_exists() {
  local kind="$1"
  local name="$2"
  if kubectl -n "${NAMESPACE}" get "${kind}" "${name}" >/dev/null 2>&1; then
    log "Deleting ${kind}/${name}"
    kubectl -n "${NAMESPACE}" delete "${kind}" "${name}" --wait=true
  else
    log "${kind}/${name} does not exist; skipping"
  fi
}

require_cmd kubectl

INSTANCE_TO_DELETE="$(select_instance)"
load_instance "${INSTANCE_TO_DELETE}"

printf '\nThis will delete Kubernetes resources for %s, but it will not delete host data at %s.\n' "${INSTANCE_NAME}" "${DATA_PATH}"
read -r -p "Type '${INSTANCE_NAME}' to confirm: " confirmation
[[ "${confirmation}" == "${INSTANCE_NAME}" ]] || die "Confirmation did not match; aborting."

delete_if_exists deployment "minecraft-${INSTANCE_NAME}"
delete_if_exists service "minecraft-${INSTANCE_NAME}"
delete_if_exists pvc "minecraft-${INSTANCE_NAME}-data"

log "Keeping PersistentVolume minecraft-${INSTANCE_NAME}-pv because reclaim policy is Retain."
log "Keeping host data at ${DATA_PATH}."
log "Uninstall complete"
