#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"

log() {
  printf '[import] %s\n' "$*"
}

die() {
  printf '[import] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  ./import_world.sh <instance-name> <source-path-or-tar.gz>

Examples:
  ./import_world.sh test /Users/verma/data/minecraft_server
  ./import_world.sh test "/Users/verma/data/minecraft_server/worlds/Bedrock level"
  ./import_world.sh test /Users/verma/backups/minecraft-test-20260416.tar.gz

Source can be either a directory or a .tar.gz archive. Accepted layouts:
  1. Full Bedrock server data containing server.properties and worlds/
     This replaces the instance PVC /data contents.

  2. A single Bedrock world containing db/, level.dat, and levelname.txt
     This imports the world into /data/worlds/<source-directory-or-archive-name>.

For .tar.gz files, the files must be at the archive root, like archives created by export_world.sh.

The script will:
  - validate the instance and source path
  - scale minecraft-<instance> to 0
  - mount the instance PVC in a temporary pod
  - stream files with tar, without temp archive files
  - fix Bedrock binary execute permissions when importing a full data directory
  - scale minecraft-<instance> back to 1

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
  : "${DATA_PATH:?DATA_PATH is required}"
}

real_source_path() {
  local source_path="$1"
  [[ -e "${source_path}" ]] || die "Source path does not exist: ${source_path}"
  if command -v realpath >/dev/null 2>&1; then
    realpath "${source_path}"
  else
    local parent_dir
    parent_dir="$(dirname "${source_path}")"
    (cd "${parent_dir}" && printf '%s/%s\n' "$(pwd -P)" "$(basename "${source_path}")")
  fi
}

archive_has_root_path() {
  local archive_path="$1"
  local wanted="$2"
  tar -tzf "${archive_path}" | awk -v wanted="${wanted}" '
    {
      path=$0
      sub(/^\.\//, "", path)
      sub(/\/$/, "", path)
      if (path == wanted || index(path, wanted "/") == 1) found=1
    }
    END { exit found ? 0 : 1 }
  '
}

archive_basename_without_tar_gz() {
  local archive_path="$1"
  local name
  name="$(basename "${archive_path}")"
  name="${name%.tar.gz}"
  printf '%s\n' "${name}"
}

validate_archive_source() {
  local source_path="$1"
  [[ -f "${source_path}" ]] || die "Archive source is not a file: ${source_path}"
  [[ -r "${source_path}" ]] || die "Archive source is not readable: ${source_path}"
  [[ "${source_path}" == *.tar.gz ]] || die "Archive source must end with .tar.gz: ${source_path}"
  tar -tzf "${source_path}" >/dev/null || die "Archive is not a readable tar.gz file: ${source_path}"

  if archive_has_root_path "${source_path}" server.properties && archive_has_root_path "${source_path}" worlds; then
    SOURCE_KIND="archive"
    IMPORT_MODE="server-data"
    IMPORT_TARGET="/data"
    return 0
  fi

  if archive_has_root_path "${source_path}" db && archive_has_root_path "${source_path}" level.dat && archive_has_root_path "${source_path}" levelname.txt; then
    SOURCE_KIND="archive"
    IMPORT_MODE="single-world"
    WORLD_NAME="$(archive_basename_without_tar_gz "${source_path}")"
    [[ -n "${WORLD_NAME}" ]] || die "Could not determine world name from archive filename."
    IMPORT_TARGET="/data/worlds/${WORLD_NAME}"
    return 0
  fi

  die "Archive does not contain accepted Bedrock data at its root. Run ./import_world.sh with no args for accepted layouts."
}

validate_directory_source() {
  local source_path="$1"
  [[ -d "${source_path}" ]] || die "Directory source is not a directory: ${source_path}"
  [[ -r "${source_path}" ]] || die "Directory source is not readable: ${source_path}"

  if [[ -f "${source_path}/server.properties" && -d "${source_path}/worlds" ]]; then
    SOURCE_KIND="directory"
    IMPORT_MODE="server-data"
    IMPORT_TARGET="/data"
    return 0
  fi

  if [[ -d "${source_path}/db" && -f "${source_path}/level.dat" && -f "${source_path}/levelname.txt" ]]; then
    SOURCE_KIND="directory"
    IMPORT_MODE="single-world"
    WORLD_NAME="$(basename "${source_path}")"
    [[ -n "${WORLD_NAME}" && "${WORLD_NAME}" != "." && "${WORLD_NAME}" != "/" ]] || die "Could not determine world directory name."
    IMPORT_TARGET="/data/worlds/${WORLD_NAME}"
    return 0
  fi

  die "Directory does not look like Bedrock server data or a single Bedrock world directory. Run ./import_world.sh with no args for accepted layouts."
}

validate_source_path() {
  local source_path="$1"
  if [[ -d "${source_path}" ]]; then
    validate_directory_source "${source_path}"
  elif [[ -f "${source_path}" ]]; then
    validate_archive_source "${source_path}"
  else
    die "Source path is neither a directory nor a file: ${source_path}"
  fi
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

import_server_data() {
  log "Clearing current /data contents"
  kubectl -n "${NAMESPACE}" exec "${IMPORT_POD}" -- sh -lc 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'

  log "Streaming full server data from ${SOURCE_PATH} into /data"
  if [[ "${SOURCE_KIND}" == "archive" ]]; then
    cat "${SOURCE_PATH}" | kubectl -n "${NAMESPACE}" exec -i "${IMPORT_POD}" -- tar -C /data -xzf -
  else
    COPYFILE_DISABLE=1 tar --no-xattrs -C "${SOURCE_PATH}" -czf - . | kubectl -n "${NAMESPACE}" exec -i "${IMPORT_POD}" -- tar -C /data -xzf -
  fi

  log "Fixing Bedrock binary execute permissions"
  kubectl -n "${NAMESPACE}" exec "${IMPORT_POD}" -- sh -lc 'chmod +x /data/bedrock_server* 2>/dev/null || true'
}

import_single_world() {
  log "Importing single world into ${IMPORT_TARGET}"
  kubectl -n "${NAMESPACE}" exec "${IMPORT_POD}" -- sh -lc "rm -rf \"${IMPORT_TARGET}\" && mkdir -p \"${IMPORT_TARGET}\""
  if [[ "${SOURCE_KIND}" == "archive" ]]; then
    cat "${SOURCE_PATH}" | kubectl -n "${NAMESPACE}" exec -i "${IMPORT_POD}" -- tar -C "${IMPORT_TARGET}" -xzf -
  else
    COPYFILE_DISABLE=1 tar --no-xattrs -C "${SOURCE_PATH}" -czf - . | kubectl -n "${NAMESPACE}" exec -i "${IMPORT_POD}" -- tar -C "${IMPORT_TARGET}" -xzf -
  fi
}

print_import_summary() {
  kubectl -n "${NAMESPACE}" exec "${IMPORT_POD}" -- sh -lc '
    echo "--- /data ---"
    ls -la /data | sed -n "1,80p"
    echo "--- worlds ---"
    find /data/worlds -maxdepth 2 -type d 2>/dev/null | sed -n "1,80p"
  '
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

[[ $# -eq 2 ]] || { usage >&2; exit 1; }

INSTANCE_ARG="$1"
SOURCE_ARG="$2"

require_cmd kubectl
require_cmd tar

load_instance "${INSTANCE_ARG}"
SOURCE_PATH="$(real_source_path "${SOURCE_ARG}")"
validate_source_path "${SOURCE_PATH}"

IMPORT_POD="minecraft-${INSTANCE_NAME}-import-$(date +%Y%m%dt%H%M%S)"
trap cleanup EXIT

log "Instance: ${INSTANCE_NAME}"
log "Namespace: ${NAMESPACE}"
log "Source: ${SOURCE_PATH}"
log "Source kind: ${SOURCE_KIND}"
log "Import mode: ${IMPORT_MODE}"

log "Scaling minecraft-${INSTANCE_NAME} to 0"
kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=0
kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
kubectl -n "${NAMESPACE}" wait pod -l "app.kubernetes.io/instance=${INSTANCE_NAME}" --for=delete --timeout=180s || true

log "Creating temporary import pod ${IMPORT_POD}"
create_import_pod

if [[ "${IMPORT_MODE}" == "server-data" ]]; then
  import_server_data
else
  import_single_world
fi

print_import_summary
cleanup
trap - EXIT

log "Scaling minecraft-${INSTANCE_NAME} back to 1"
kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=1
kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=240s
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${INSTANCE_NAME}" -o wide

log "Import complete"
