#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${ROOT_DIR}/lib/clusters.sh"

log_error() {
  printf '[status] ERROR: %s\n' "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "Required command not found: $1"
    exit 1
  }
}

list_instances() {
  find "${INSTANCES_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
}

load_instance() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  [[ -f "${values_file}" ]] || return 1

  unset INSTANCE_NAME JAVA_PORT BEDROCK_PORT PORT SUBDOMAIN NODE_LABEL STORAGE DATA_PATH NAMESPACE SERVER_NAME
  # shellcheck disable=SC1090
  source "${values_file}"

  : "${INSTANCE_NAME:?INSTANCE_NAME is required}"
  : "${DATA_PATH:?DATA_PATH is required}"
  : "${NAMESPACE:?NAMESPACE is required}"

  JAVA_PORT="${JAVA_PORT:-25565}"
  BEDROCK_PORT="${BEDROCK_PORT:-${PORT:-19132}}"
}

kubectl_ok() {
  kubectl version --request-timeout=5s >/dev/null 2>&1
}

deployment_exists() {
  kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1
}

service_exists() {
  kubectl -n "${NAMESPACE}" get service "minecraft-${INSTANCE_NAME}" >/dev/null 2>&1
}

pvc_exists() {
  kubectl -n "${NAMESPACE}" get pvc "minecraft-${INSTANCE_NAME}-data" >/dev/null 2>&1
}

pv_exists() {
  kubectl get pv "minecraft-${INSTANCE_NAME}-pv" >/dev/null 2>&1
}

instance_state() {
  if ! kubectl_ok; then
    printf 'cluster-unreachable'
  elif deployment_exists || service_exists || pvc_exists; then
    printf 'installed'
  elif pv_exists; then
    printf 'deleted-pv-retained'
  else
    printf 'config-only'
  fi
}

deployment_replicas() {
  kubectl -n "${NAMESPACE}" get deployment "minecraft-${INSTANCE_NAME}" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null
}

pod_summary() {
  kubectl -n "${NAMESPACE}" get pods \
    -l "app.kubernetes.io/instance=${INSTANCE_NAME}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" phase="}{.status.phase}{" ready="}{range .status.containerStatuses[*]}{.ready}{end}{" restarts="}{range .status.containerStatuses[*]}{.restartCount}{end}{" node="}{.spec.nodeName}{"\n"}{end}' \
    2>/dev/null
}

service_ports() {
  kubectl -n "${NAMESPACE}" get service "minecraft-${INSTANCE_NAME}" \
    -o jsonpath='{range .spec.ports[*]}{.name}{"="}{.protocol}{":"}{.port}{"->"}{.targetPort}{" "}{end}{"external="}{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' \
    2>/dev/null
}

pvc_status() {
  kubectl -n "${NAMESPACE}" get pvc "minecraft-${INSTANCE_NAME}-data" \
    -o jsonpath='{.status.phase}{" volume="}{.spec.volumeName}{" size="}{.status.capacity.storage}' \
    2>/dev/null
}

pv_status() {
  kubectl get pv "minecraft-${INSTANCE_NAME}-pv" \
    -o jsonpath='{.status.phase}{" reclaim="}{.spec.persistentVolumeReclaimPolicy}{" hostPath="}{.spec.hostPath.path}' \
    2>/dev/null
}

print_instance() {
  local instance="$1"
  if ! load_instance "${instance}"; then
    printf '%s\n' "Instance: ${instance}"
    printf '  status: missing-config\n'
    printf '\n'
    return
  fi

  printf '%s\n' "Instance: ${INSTANCE_NAME}"
  printf '%s\n' "  namespace: ${NAMESPACE}"
  printf '%s\n' "  server name: ${SERVER_NAME:-${INSTANCE_NAME}}"
  printf '%s\n' "  java port: ${JAVA_PORT}/tcp"
  printf '%s\n' "  bedrock port: ${BEDROCK_PORT}/udp"
  printf '%s\n' "  subdomain: ${SUBDOMAIN:-<unset>}"
  printf '%s\n' "  node label: ${NODE_LABEL:-<unset>}=true"
  printf '%s\n' "  data path: ${DATA_PATH}"
  printf '%s\n' "  configured storage: ${STORAGE:-<unset>}"
  printf '%s\n' "  status: $(instance_state)"

  if ! kubectl_ok; then
    printf '  cluster: kubectl unavailable or cluster unreachable\n'
    printf '\n'
    return
  fi

  if deployment_exists; then
    printf '%s\n' "  deployment: $(deployment_replicas)"
  else
    printf '  deployment: missing\n'
  fi

  if service_exists; then
    printf '%s\n' "  service: $(service_ports)"
  else
    printf '  service: missing\n'
  fi

  if pvc_exists; then
    printf '%s\n' "  pvc: $(pvc_status)"
  else
    printf '  pvc: missing\n'
  fi

  if pv_exists; then
    printf '%s\n' "  pv: $(pv_status)"
  else
    printf '  pv: missing\n'
  fi

  local pods
  pods="$(pod_summary)"
  if [[ -n "${pods}" ]]; then
    printf '  pods:\n'
    while IFS= read -r line; do
      [[ -n "${line}" ]] && printf '    %s\n' "${line}"
    done <<< "${pods}"
  else
    printf '  pods: none\n'
  fi

  printf '\n'
}

print_usage() {
  cat <<EOF
Usage:
  ./status.sh [--cluster <name>]

Print configured Minecraft instances from instances/*/values.env and show their live Kubernetes status.
EOF
}

main() {
  local cluster_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster)
        [[ $# -ge 2 ]] || { print_usage >&2; exit 1; }
        cluster_name="$2"
        shift 2
        ;;
      *)
        print_usage >&2
        exit 1
        ;;
    esac
  done

  if [[ -z "${cluster_name}" ]]; then
    cluster_name="$(resolved_cluster_from_context || true)"
  fi
  if [[ -n "${cluster_name}" ]]; then
    cluster_name_is_valid "${cluster_name}" || { log_error "Invalid cluster name: ${cluster_name}"; exit 1; }
    INSTANCES_DIR="$(instances_dir_for_cluster "${cluster_name}")"
    KUBECONFIG_PATH="${KUBECONFIG_PATH:-$(cluster_kubeconfig_file "${cluster_name}")}"
  else
    INSTANCES_DIR="${ROOT_DIR}/instances"
    KUBECONFIG_PATH="${KUBECONFIG_PATH:-}"
  fi

  KUBECONFIG_PATH="$(resolve_kubeconfig_path "${KUBECONFIG_PATH}")"
  if [[ -n "${KUBECONFIG_PATH}" ]]; then
    export KUBECONFIG="${KUBECONFIG:-${KUBECONFIG_PATH}}"
  fi

  require_cmd kubectl

  printf 'Configured instances directory: %s\n' "${INSTANCES_DIR}"
  if [[ -n "${cluster_name}" ]]; then
    printf 'Cluster: %s\n' "${cluster_name}"
  fi
  printf 'Current kubectl context: %s\n' "$(kubectl config current-context 2>/dev/null || printf '<unset>')"
  printf '\n'

  local instances=()
  while IFS= read -r instance; do
    instances+=("${instance}")
  done < <(list_instances)

  if (( ${#instances[@]} == 0 )); then
    printf 'No configured instances found under %s\n' "${INSTANCES_DIR}"
    exit 0
  fi

  local instance
  for instance in "${instances[@]}"; do
    print_instance "${instance}"
  done
}

main "$@"
