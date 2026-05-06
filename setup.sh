#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"
DEFAULT_JAVA_PORT=25565
DEFAULT_BEDROCK_PORT=19132
DEFAULT_NODE_LABEL="minecraft"
DEFAULT_STORAGE="10Gi"
DEFAULT_NAMESPACE="apps"
DEFAULT_TYPE="PAPER"
DEFAULT_VERSION="stable"
DEFAULT_MODE="survival"
DEFAULT_DIFFICULTY="normal"
DEFAULT_MAX_PLAYERS="10"
DEFAULT_PLAYER_IDLE_TIMEOUT="30"
DEFAULT_VIEW_DISTANCE="10"
DEFAULT_SIMULATION_DISTANCE="4"
DEFAULT_MEMORY="4G"
DEFAULT_ONLINE_MODE="false"
DEFAULT_ENABLE_RCON="true"
DEFAULT_PVP="true"
DEFAULT_ENABLE_WHITELIST="false"

log() {
  printf '[setup] %s\n' "$*"
}

die() {
  printf '[setup] ERROR: %s\n' "$*" >&2
  exit 1
}

validate_instance_name() {
  local name="$1"
  [[ "${name}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Instance name must be a DNS-safe name: lowercase letters, numbers, and hyphens."
  [[ "${#name}" -le 50 ]] || die "Instance name must be 50 characters or fewer."
}

validate_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || die "Port must be a number."
  (( port >= 1 && port <= 65535 )) || die "Port must be between 1 and 65535."
}

validate_label_key() {
  local label="$1"
  [[ "${label}" =~ ^([A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?/)?[A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?$ ]] || die "Node label must be a valid Kubernetes label key."
}

validate_subdomain() {
  local subdomain="$1"
  [[ -z "${subdomain}" || "${subdomain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Subdomain must be empty or a DNS-style name."
}

validate_text_value() {
  local label="$1"
  local value="$2"
  [[ "${value}" != *$'\n'* ]] || die "${label} must not contain newlines."
  [[ "${value}" != *'"'* && "${value}" != *'\\'* ]] || die "${label} must not contain double quotes or backslashes."
}

validate_choice() {
  local label="$1"
  local value="$2"
  shift 2
  local choice
  for choice in "$@"; do
    [[ "${value}" == "${choice}" ]] && return 0
  done
  die "${label} must be one of: $*"
}

validate_bool() {
  local label="$1"
  local value="$2"
  validate_choice "${label}" "${value}" true false
}

validate_positive_int() {
  local label="$1"
  local value="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${label} must be a whole number."
  (( value >= 0 )) || die "${label} must be zero or greater."
}

validate_memory() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+(%|[kKmMgG])$ ]] || die "Memory must look like 4G, 4096M, or 50%."
}

read_with_default() {
  local prompt="$1"
  local default_value="$2"
  local result
  read -r -p "${prompt} [${default_value}]: " result
  printf '%s\n' "${result:-${default_value}}"
}

write_env_line() {
  local key="$1"
  printf '%s=%q\n' "${key}" "${!key}"
}

java_port_in_use() {
  local port="$1"
  local env_file
  while IFS= read -r env_file; do
    if (
      # shellcheck disable=SC1090
      source "${env_file}"
      [[ "${JAVA_PORT:-}" == "${port}" ]]
    ); then
      return 0
    fi
  done < <(find "${INSTANCES_DIR}" -mindepth 2 -maxdepth 2 -name values.env 2>/dev/null)
  return 1
}

bedrock_port_in_use() {
  local port="$1"
  local env_file
  while IFS= read -r env_file; do
    if (
      # shellcheck disable=SC1090
      source "${env_file}"
      [[ "${BEDROCK_PORT:-${PORT:-}}" == "${port}" ]]
    ); then
      return 0
    fi
  done < <(find "${INSTANCES_DIR}" -mindepth 2 -maxdepth 2 -name values.env 2>/dev/null)
  return 1
}

next_available_port() {
  local start_port="$1"
  local checker="$2"
  local port="${start_port}"
  while "${checker}" "${port}"; do
    port=$((port + 1))
  done
  printf '%s\n' "${port}"
}

write_values_env() {
  local file="$1"
  {
    write_env_line INSTANCE_NAME
    write_env_line JAVA_PORT
    write_env_line BEDROCK_PORT
    write_env_line SUBDOMAIN
    write_env_line NODE_LABEL
    write_env_line STORAGE
    write_env_line DATA_PATH
    write_env_line NAMESPACE
    write_env_line TYPE
    write_env_line VERSION
    write_env_line SERVER_NAME
    write_env_line MODE
    write_env_line DIFFICULTY
    write_env_line LEVEL
    write_env_line SEED
    write_env_line LEVEL_TYPE
    write_env_line MAX_PLAYERS
    write_env_line PLAYER_IDLE_TIMEOUT
    write_env_line VIEW_DISTANCE
    write_env_line SIMULATION_DISTANCE
    write_env_line MEMORY
    write_env_line ONLINE_MODE
    write_env_line ENABLE_RCON
    write_env_line PVP
    write_env_line ENABLE_WHITELIST
  } > "${file}"
}

mkdir -p "${INSTANCES_DIR}"

suggested_java_port="$(next_available_port "${DEFAULT_JAVA_PORT}" java_port_in_use)"
suggested_bedrock_port="$(next_available_port "${DEFAULT_BEDROCK_PORT}" bedrock_port_in_use)"

read -r -p "Instance name: " INSTANCE_NAME
[[ -n "${INSTANCE_NAME}" ]] || die "Instance name is required."
validate_instance_name "${INSTANCE_NAME}"

INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_NAME}"
[[ ! -e "${INSTANCE_DIR}" ]] || die "Instance '${INSTANCE_NAME}' already exists."

read -r -p "External Java TCP port [${suggested_java_port}]: " JAVA_PORT
JAVA_PORT="${JAVA_PORT:-${suggested_java_port}}"
validate_port "${JAVA_PORT}"
if java_port_in_use "${JAVA_PORT}"; then
  die "Java port ${JAVA_PORT} is already used by another instance."
fi

read -r -p "External Bedrock UDP port [${suggested_bedrock_port}]: " BEDROCK_PORT
BEDROCK_PORT="${BEDROCK_PORT:-${suggested_bedrock_port}}"
validate_port "${BEDROCK_PORT}"
if bedrock_port_in_use "${BEDROCK_PORT}"; then
  die "Bedrock port ${BEDROCK_PORT} is already used by another instance."
fi

read -r -p "Optional subdomain, stored for documentation only: " SUBDOMAIN
validate_subdomain "${SUBDOMAIN}"

read -r -p "Node label key [${DEFAULT_NODE_LABEL}]: " NODE_LABEL
NODE_LABEL="${NODE_LABEL:-${DEFAULT_NODE_LABEL}}"
validate_label_key "${NODE_LABEL}"

read -r -p "Storage size [${DEFAULT_STORAGE}]: " STORAGE
STORAGE="${STORAGE:-${DEFAULT_STORAGE}}"
[[ "${STORAGE}" =~ ^[0-9]+(Mi|Gi|Ti)$ ]] || die "Storage must look like 10Gi, 500Mi, or 1Ti."

printf '\nMinecraft Java server settings\n'
TYPE="${DEFAULT_TYPE}"
VERSION="${DEFAULT_VERSION}"
SERVER_NAME="$(read_with_default "Server name / MOTD" "${INSTANCE_NAME}")"
validate_text_value "Server name / MOTD" "${SERVER_NAME}"

MODE="$(read_with_default "Game mode: survival, creative, adventure, or spectator" "${DEFAULT_MODE}")"
validate_choice "Game mode" "${MODE}" survival creative adventure spectator

DIFFICULTY="$(read_with_default "Difficulty: peaceful, easy, normal, or hard" "${DEFAULT_DIFFICULTY}")"
validate_choice "Difficulty" "${DIFFICULTY}" peaceful easy normal hard

LEVEL="$(read_with_default "Level/world name" "${INSTANCE_NAME}")"
validate_text_value "Level name" "${LEVEL}"

read -r -p "Level seed, optional: " SEED
validate_text_value "Level seed" "${SEED}"

LEVEL_TYPE="$(read_with_default "Level type" "default")"
validate_text_value "Level type" "${LEVEL_TYPE}"

MAX_PLAYERS="$(read_with_default "Max players" "${DEFAULT_MAX_PLAYERS}")"
validate_positive_int "Max players" "${MAX_PLAYERS}"
(( MAX_PLAYERS >= 1 )) || die "Max players must be at least 1."

PLAYER_IDLE_TIMEOUT="$(read_with_default "Player idle timeout in minutes" "${DEFAULT_PLAYER_IDLE_TIMEOUT}")"
validate_positive_int "Player idle timeout" "${PLAYER_IDLE_TIMEOUT}"

VIEW_DISTANCE="$(read_with_default "View distance" "${DEFAULT_VIEW_DISTANCE}")"
validate_positive_int "View distance" "${VIEW_DISTANCE}"

SIMULATION_DISTANCE="$(read_with_default "Simulation distance" "${DEFAULT_SIMULATION_DISTANCE}")"
validate_positive_int "Simulation distance" "${SIMULATION_DISTANCE}"

MEMORY="$(read_with_default "Java heap memory" "${DEFAULT_MEMORY}")"
validate_memory "${MEMORY}"

ONLINE_MODE="$(read_with_default "Online mode (must stay false for Floodgate)" "${DEFAULT_ONLINE_MODE}")"
validate_bool "Online mode" "${ONLINE_MODE}"

ENABLE_RCON="$(read_with_default "Enable RCON" "${DEFAULT_ENABLE_RCON}")"
validate_bool "Enable RCON" "${ENABLE_RCON}"

PVP="$(read_with_default "Enable PVP" "${DEFAULT_PVP}")"
validate_bool "Enable PVP" "${PVP}"

ENABLE_WHITELIST="$(read_with_default "Enable whitelist" "${DEFAULT_ENABLE_WHITELIST}")"
validate_bool "Enable whitelist" "${ENABLE_WHITELIST}"

NAMESPACE="${DEFAULT_NAMESPACE}"
DATA_PATH="/data/minecraft/${INSTANCE_NAME}"

mkdir -p "${INSTANCE_DIR}"
write_values_env "${INSTANCE_DIR}/values.env"

log "Created ${INSTANCE_DIR}/values.env"
log "Java clients connect on TCP ${JAVA_PORT}; Bedrock clients connect on UDP ${BEDROCK_PORT}."
log "Bedrock compatibility is provided by Geyser and Floodgate on top of the Paper server."
printf '\nRun ./install.sh %s\n' "${INSTANCE_NAME}"
