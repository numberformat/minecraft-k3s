#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"

log() {
  printf '[backup] %s\n' "$*"
}

die() {
  printf '[backup] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_env() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Environment variable ${name} is required."
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

  export INSTANCE_NAME
  export PORT
  export SUBDOMAIN
  export DATA_PATH
  export NODE_LABEL
  export STORAGE
  SERVER_NAME="${SERVER_NAME:-${INSTANCE_NAME}}"
  GAMEMODE="${GAMEMODE:-survival}"
  DIFFICULTY="${DIFFICULTY:-easy}"
  DEFAULT_PLAYER_PERMISSION_LEVEL="${DEFAULT_PLAYER_PERMISSION_LEVEL:-member}"
  LEVEL_NAME="${LEVEL_NAME:-${INSTANCE_NAME}}"
  LEVEL_SEED="${LEVEL_SEED:-}"
  LEVEL_TYPE="${LEVEL_TYPE:-DEFAULT}"
  ALLOW_CHEATS="${ALLOW_CHEATS:-false}"
  MAX_PLAYERS="${MAX_PLAYERS:-10}"
  PLAYER_IDLE_TIMEOUT="${PLAYER_IDLE_TIMEOUT:-30}"
  TEXTUREPACK_REQUIRED="${TEXTUREPACK_REQUIRED:-false}"
  ONLINE_MODE="${ONLINE_MODE:-true}"
  WHITE_LIST="${WHITE_LIST:-false}"
  VIEW_DISTANCE="${VIEW_DISTANCE:-10}"
  TICK_DISTANCE="${TICK_DISTANCE:-4}"
  MAX_THREADS="${MAX_THREADS:-8}"

  export NAMESPACE
  export SERVER_NAME
  export GAMEMODE
  export DIFFICULTY
  export DEFAULT_PLAYER_PERMISSION_LEVEL
  export LEVEL_NAME
  export LEVEL_SEED
  export LEVEL_TYPE
  export ALLOW_CHEATS
  export MAX_PLAYERS
  export PLAYER_IDLE_TIMEOUT
  export TEXTUREPACK_REQUIRED
  export ONLINE_MODE
  export WHITE_LIST
  export VIEW_DISTANCE
  export TICK_DISTANCE
  export MAX_THREADS
}

backup_instance() {
  local instance="$1"
  local timestamp pod_timestamp object pod_name secret_name

  load_instance "${instance}"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  pod_timestamp="$(date -u +%Y%m%dt%H%M%Sz)"
  object="world-${INSTANCE_NAME}-${timestamp}.tar.gz"
  pod_name="minecraft-${INSTANCE_NAME}-backup-${pod_timestamp}"
  secret_name="minecraft-${INSTANCE_NAME}-backup-env"

  log "Scaling minecraft-${INSTANCE_NAME} to 0"
  kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=0
  kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
  kubectl -n "${NAMESPACE}" wait pod -l "app.kubernetes.io/instance=${INSTANCE_NAME}" --for=delete --timeout=180s || true

  log "Streaming ${INSTANCE_NAME} backup to ${MINIO_BUCKET}/${object}"
  kubectl -n "${NAMESPACE}" delete secret "${secret_name}" --ignore-not-found=true
  kubectl -n "${NAMESPACE}" create secret generic "${secret_name}" \
    --from-literal=MINIO_ENDPOINT="${MINIO_ENDPOINT}" \
    --from-literal=MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY}" \
    --from-literal=MINIO_SECRET_KEY="${MINIO_SECRET_KEY}" \
    --from-literal=MINIO_BUCKET="${MINIO_BUCKET}"

  if ! kubectl -n "${NAMESPACE}" run "${pod_name}" \
    --image=minio/mc:latest \
    --restart=Never \
    --overrides="$(
      cat <<JSON
{
  "apiVersion": "v1",
  "spec": {
    "containers": [
      {
        "name": "${pod_name}",
        "image": "minio/mc:latest",
        "command": ["/bin/sh", "-ec"],
        "args": [
          "mc alias set backup \"\${MINIO_ENDPOINT}\" \"\${MINIO_ACCESS_KEY}\" \"\${MINIO_SECRET_KEY}\" >/dev/null; tar -C /data -czf - . | mc pipe backup/\"\${MINIO_BUCKET}\"/${object}"
        ],
        "envFrom": [
          {
            "secretRef": {
              "name": "${secret_name}"
            }
          }
        ],
        "volumeMounts": [
          { "name": "data", "mountPath": "/data", "readOnly": true }
        ]
      }
    ],
    "restartPolicy": "Never",
    "volumes": [
      {
        "name": "data",
        "persistentVolumeClaim": {
          "claimName": "minecraft-${INSTANCE_NAME}-data"
        }
      }
    ]
  }
}
JSON
    )" \
    --attach=true \
    --rm=true; then
    log "Backup failed for ${INSTANCE_NAME}; scaling deployment back to 1"
    kubectl -n "${NAMESPACE}" delete secret "${secret_name}" --ignore-not-found=true
    kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=1
    kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
    die "Backup failed for ${INSTANCE_NAME}"
  fi
  kubectl -n "${NAMESPACE}" delete secret "${secret_name}" --ignore-not-found=true

  log "Scaling minecraft-${INSTANCE_NAME} back to 1"
  kubectl -n "${NAMESPACE}" scale deployment "minecraft-${INSTANCE_NAME}" --replicas=1
  kubectl -n "${NAMESPACE}" rollout status deployment "minecraft-${INSTANCE_NAME}" --timeout=180s
}

require_cmd kubectl
require_env MINIO_ENDPOINT
require_env MINIO_ACCESS_KEY
require_env MINIO_SECRET_KEY
require_env MINIO_BUCKET

instances=()
while IFS= read -r instance; do
  instances+=("${instance}")
done < <(list_instances)
(( ${#instances[@]} > 0 )) || die "No instances found in ${INSTANCES_DIR}"

for instance in "${instances[@]}"; do
  backup_instance "${instance}"
done

log "All backups complete"
