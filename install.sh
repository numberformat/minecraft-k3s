#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${ROOT_DIR}/k8s"
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

to_upper_bool() {
  case "$1" in
    true|TRUE) printf 'TRUE' ;;
    false|FALSE) printf 'FALSE' ;;
    *) die "Expected boolean true/false value, got: $1" ;;
  esac
}

load_instance() {
  local instance="$1"
  local values_file="${INSTANCES_DIR}/${instance}/values.env"
  [[ -f "${values_file}" ]] || die "Missing instance config: ${values_file}"
  # shellcheck disable=SC1090
  source "${values_file}"

  : "${INSTANCE_NAME:?INSTANCE_NAME is required}"
  : "${DATA_PATH:?DATA_PATH is required}"
  : "${NODE_LABEL:?NODE_LABEL is required}"
  : "${STORAGE:?STORAGE is required}"
  : "${NAMESPACE:?NAMESPACE is required}"

  JAVA_PORT="${JAVA_PORT:-25565}"
  BEDROCK_PORT="${BEDROCK_PORT:-${PORT:-19132}}"
  TYPE="${TYPE:-PAPER}"
  VERSION="${VERSION:-1.21.11}"
  SERVER_NAME="${SERVER_NAME:-${INSTANCE_NAME}}"
  MODE="${MODE:-${GAMEMODE:-survival}}"
  DIFFICULTY="${DIFFICULTY:-normal}"
  LEVEL="${LEVEL:-${LEVEL_NAME:-${INSTANCE_NAME}}}"
  SEED="${SEED:-${LEVEL_SEED:-}}"
  LEVEL_TYPE="${LEVEL_TYPE:-default}"
  MAX_PLAYERS="${MAX_PLAYERS:-10}"
  PLAYER_IDLE_TIMEOUT="${PLAYER_IDLE_TIMEOUT:-30}"
  VIEW_DISTANCE="${VIEW_DISTANCE:-10}"
  SIMULATION_DISTANCE="${SIMULATION_DISTANCE:-${TICK_DISTANCE:-4}}"
  MEMORY="${MEMORY:-4G}"
  TYPE="${TYPE^^}"
  ONLINE_MODE="$(to_upper_bool "${ONLINE_MODE:-false}")"
  ENABLE_RCON="$(to_upper_bool "${ENABLE_RCON:-true}")"
  PVP="$(to_upper_bool "${PVP:-true}")"
  ENABLE_WHITELIST="$(to_upper_bool "${ENABLE_WHITELIST:-${WHITE_LIST:-false}}")"

  export INSTANCE_NAME
  export JAVA_PORT
  export BEDROCK_PORT
  export SUBDOMAIN
  export DATA_PATH
  export NODE_LABEL
  export STORAGE
  export NAMESPACE
  export TYPE
  export VERSION
  export SERVER_NAME
  export MODE
  export DIFFICULTY
  export LEVEL
  export SEED
  export LEVEL_TYPE
  export MAX_PLAYERS
  export PLAYER_IDLE_TIMEOUT
  export VIEW_DISTANCE
  export SIMULATION_DISTANCE
  export MEMORY
  export ONLINE_MODE
  export ENABLE_RCON
  export PVP
  export ENABLE_WHITELIST
}

validate_instance_arg() {
  [[ $# -eq 1 ]] || die "Usage: ./install.sh <instance-name>"
}

apply_template() {
  local template="$1"
  log "Applying ${template}"
  envsubst < "${K8S_DIR}/${template}" | kubectl apply -f -
}

print_access_instructions() {
  cat <<EOF

Minecraft Java + Bedrock compatibility is exposed directly with one k3s LoadBalancer Service:

  service/minecraft-${INSTANCE_NAME} TCP ${JAVA_PORT} -> pod TCP 25565
  service/minecraft-${INSTANCE_NAME} UDP ${BEDROCK_PORT} -> pod UDP 19132

Java clients connect to:

  ${SUBDOMAIN:-<your-hostname>}:${JAVA_PORT}

Bedrock clients connect to:

  ${SUBDOMAIN:-<your-hostname>}:${BEDROCK_PORT}

Java and Bedrock do not share the same protocol:
- Java Edition talks to Paper on TCP 25565
- Bedrock Edition talks to Geyser on UDP 19132, which then bridges into Paper

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
log "Java port: ${JAVA_PORT}/tcp"
log "Bedrock port: ${BEDROCK_PORT}/udp"

apply_template namespace.yaml
apply_template pv.yaml
apply_template pvc.yaml
apply_template deployment.yaml
apply_template service.yaml

log "Waiting for deployment rollout"
kubectl -n "${NAMESPACE}" rollout status "deployment/minecraft-${INSTANCE_NAME}" --timeout=300s

print_access_instructions
log "Install complete"
