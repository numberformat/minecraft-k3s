#!/usr/bin/env bash

if [[ -z "${ROOT_DIR:-}" ]]; then
  echo "ROOT_DIR must be set before sourcing lib/clusters.sh" >&2
  return 1 2>/dev/null || exit 1
fi

NOAMI_K3S_ROOT="${ROOT_DIR}/../noami-k3s"
NOAMI_K3S_CLUSTERS_DIR="${NOAMI_K3S_ROOT}/clusters"
NOAMI_K3S_ARTIFACTS_DIR="${NOAMI_K3S_ROOT}/artifacts"
NOAMI_K3S_CURRENT_CLUSTER_FILE="${NOAMI_K3S_ROOT}/.current-cluster"
CLUSTERS_DIR="${ROOT_DIR}/clusters"
LEGACY_INSTANCES_DIR="${ROOT_DIR}/instances"

cluster_name_is_valid() {
  local cluster_name="$1"
  [[ "${cluster_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

list_cluster_names() {
  {
    if [[ -d "${NOAMI_K3S_CLUSTERS_DIR}" ]]; then
      while IFS= read -r path; do
        local cluster_name=""
        cluster_name="$(basename "${path}")"
        if cluster_name_is_valid "${cluster_name}"; then
          printf '%s\n' "${cluster_name}"
        fi
      done < <(find "${NOAMI_K3S_CLUSTERS_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
    fi
    if [[ -d "${NOAMI_K3S_ARTIFACTS_DIR}" ]]; then
      while IFS= read -r path; do
        local cluster_name=""
        cluster_name="$(basename "${path}")"
        if cluster_name_is_valid "${cluster_name}"; then
          printf '%s\n' "${cluster_name}"
        fi
      done < <(find "${NOAMI_K3S_ARTIFACTS_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
    fi
  } | awk 'NF' | sort -u
}

count_clusters() {
  local count="0"
  while IFS= read -r _cluster_name; do
    count=$((count + 1))
  done < <(list_cluster_names)
  printf '%s\n' "${count}"
}

current_cluster_from_file() {
  if [[ -f "${NOAMI_K3S_CURRENT_CLUSTER_FILE}" ]]; then
    awk '/^[A-Za-z0-9][A-Za-z0-9._-]*$/ { value = $0 } END { if (value != "") print value }' "${NOAMI_K3S_CURRENT_CLUSTER_FILE}"
  fi
}

resolved_cluster_from_context() {
  local cluster_count=""
  if [[ -n "${CLUSTER_NAME:-}" ]]; then
    printf '%s\n' "${CLUSTER_NAME}"
    return
  fi
  if [[ -n "${MINECRAFT_CLUSTER:-}" ]]; then
    printf '%s\n' "${MINECRAFT_CLUSTER}"
    return
  fi
  if [[ -n "$(current_cluster_from_file)" ]]; then
    current_cluster_from_file
    return
  fi
  cluster_count="$(count_clusters)"
  if [[ "${cluster_count}" == "1" ]]; then
    list_cluster_names | head -n 1
  fi
}

cluster_dir() {
  local cluster_name="$1"
  printf '%s/%s\n' "${CLUSTERS_DIR}" "${cluster_name}"
}

cluster_instances_dir() {
  local cluster_name="$1"
  printf '%s/instances\n' "$(cluster_dir "${cluster_name}")"
}

cluster_kubeconfig_file() {
  local cluster_name="$1"
  printf '%s/%s/kubeconfig-%s.yaml\n' "${NOAMI_K3S_ARTIFACTS_DIR}" "${cluster_name}" "${cluster_name}"
}

resolve_kubeconfig_path() {
  local path_value="$1"
  if [[ -z "${path_value}" ]]; then
    printf '\n'
  elif [[ "${path_value}" = /* ]]; then
    printf '%s\n' "${path_value}"
  else
    printf '%s/%s\n' "${ROOT_DIR}" "${path_value}"
  fi
}

instances_dir_for_cluster() {
  local cluster_name="$1"
  local cluster_instances=""
  cluster_instances="$(cluster_instances_dir "${cluster_name}")"
  if [[ -d "${cluster_instances}" ]]; then
    printf '%s\n' "${cluster_instances}"
  elif [[ -d "${LEGACY_INSTANCES_DIR}" ]]; then
    printf '%s\n' "${LEGACY_INSTANCES_DIR}"
  else
    printf '%s\n' "${cluster_instances}"
  fi
}

ensure_cluster_instances_dir() {
  local cluster_name="$1"
  mkdir -p "$(cluster_instances_dir "${cluster_name}")"
}
