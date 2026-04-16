#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${ROOT_DIR}/templates"
INSTANCES_DIR="${ROOT_DIR}/instances"

log() {
  printf '[install] %s\n' "$*"
}

die() {
  printf '[install] ERROR: %s\n' "$*" >&2
  exit 1
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
  : "${PORT:?PORT is required}"
  : "${DATA_PATH:?DATA_PATH is required}"
  : "${NODE_LABEL:?NODE_LABEL is required}"
  : "${STORAGE:?STORAGE is required}"
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

validate_instance_arg() {
  [[ $# -eq 1 ]] || die "Usage: ./install.sh <instance-name>"
}

apply_template() {
  local template="$1"
  log "Applying ${template}"
  envsubst < "${TEMPLATES_DIR}/${template}" | kubectl apply -f -
}

print_access_instructions() {
  cat <<EOF

Minecraft Bedrock is exposed directly with a k3s LoadBalancer Service:

  service/minecraft-${INSTANCE_NAME} UDP ${PORT} -> pod UDP 19132

Bedrock does not support host or subdomain routing. Use the DNS name only as documentation and connect with the unique port. Your router/firewall must forward this UDP port to a k3s node or stable ServiceLB/VIP address:

  ${SUBDOMAIN:-<your-hostname>}:${PORT}

The hostPath directory must exist on a node labeled:

  ${NODE_LABEL}=true

Create it on the selected node before first start:

  sudo mkdir -p ${DATA_PATH}
  sudo chown -R 1000:1000 ${DATA_PATH}

Label the storage node if needed:

  kubectl label node <node-name> ${NODE_LABEL}=true --overwrite

EOF
}

validate_instance_arg "$@"
require_cmd kubectl
require_cmd envsubst

load_instance "$1"

log "Installing ${INSTANCE_NAME} in namespace ${NAMESPACE}"
log "Persistent data path: ${DATA_PATH}"

apply_template namespace.yaml
apply_template pv.yaml
apply_template pvc.yaml
apply_template deployment.yaml
apply_template service.yaml

log "Waiting for deployment rollout"
kubectl -n "${NAMESPACE}" rollout status "deployment/minecraft-${INSTANCE_NAME}" --timeout=180s

print_access_instructions
log "Install complete"
