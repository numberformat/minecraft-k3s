#!/usr/bin/env bash
set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="${ROOT_DIR}/instances"
DEFAULT_PORT=19132
DEFAULT_NODE_LABEL="minecraft"
DEFAULT_STORAGE="10Gi"
DEFAULT_NAMESPACE="apps"
DEFAULT_GAMEMODE="survival"
DEFAULT_DIFFICULTY="easy"
DEFAULT_PERMISSION_LEVEL="member"
DEFAULT_LEVEL_TYPE="DEFAULT"
DEFAULT_ALLOW_CHEATS="false"
DEFAULT_MAX_PLAYERS="10"
DEFAULT_PLAYER_IDLE_TIMEOUT="30"
DEFAULT_TEXTUREPACK_REQUIRED="false"
DEFAULT_ONLINE_MODE="true"
DEFAULT_WHITE_LIST="false"
DEFAULT_VIEW_DISTANCE="10"
DEFAULT_TICK_DISTANCE="4"
DEFAULT_MAX_THREADS="8"

log() {
  printf '[setup] %s\n' "$*"
}

die() {
  printf '[setup] ERROR: %s\n' "$*" >&2
  exit 1
}

list_instances() {
  find "${INSTANCES_DIR}" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort
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

port_in_use() {
  local port="$1"
  local env_file
  while IFS= read -r env_file; do
    if (
      # shellcheck disable=SC1090
      source "${env_file}"
      [[ "${PORT:-}" == "${port}" ]]
    ); then
      return 0
    fi
  done < <(find "${INSTANCES_DIR}" -mindepth 2 -maxdepth 2 -name values.env 2>/dev/null)
  return 1
}

next_available_port() {
  local port="${DEFAULT_PORT}"
  while port_in_use "${port}"; do
    port=$((port + 1))
  done
  printf '%s\n' "${port}"
}

write_values_env() {
  local file="$1"
  {
    write_env_line INSTANCE_NAME
    write_env_line PORT
    write_env_line SUBDOMAIN
    write_env_line NODE_LABEL
    write_env_line STORAGE
    write_env_line DATA_PATH
    write_env_line NAMESPACE
    write_env_line SERVER_NAME
    write_env_line GAMEMODE
    write_env_line DIFFICULTY
    write_env_line DEFAULT_PLAYER_PERMISSION_LEVEL
    write_env_line LEVEL_NAME
    write_env_line LEVEL_SEED
    write_env_line LEVEL_TYPE
    write_env_line ALLOW_CHEATS
    write_env_line MAX_PLAYERS
    write_env_line PLAYER_IDLE_TIMEOUT
    write_env_line TEXTUREPACK_REQUIRED
    write_env_line ONLINE_MODE
    write_env_line WHITE_LIST
    write_env_line VIEW_DISTANCE
    write_env_line TICK_DISTANCE
    write_env_line MAX_THREADS
  } > "${file}"
}

mkdir -p "${INSTANCES_DIR}"

suggested_port="$(next_available_port)"

read -r -p "Instance name: " INSTANCE_NAME
[[ -n "${INSTANCE_NAME}" ]] || die "Instance name is required."
validate_instance_name "${INSTANCE_NAME}"

INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_NAME}"
[[ ! -e "${INSTANCE_DIR}" ]] || die "Instance '${INSTANCE_NAME}' already exists."

read -r -p "External UDP port [${suggested_port}]: " PORT
PORT="${PORT:-${suggested_port}}"
validate_port "${PORT}"
if port_in_use "${PORT}"; then
  die "Port ${PORT} is already used by another instance."
fi

read -r -p "Optional subdomain, stored for documentation only: " SUBDOMAIN
validate_subdomain "${SUBDOMAIN}"

read -r -p "Node label key [${DEFAULT_NODE_LABEL}]: " NODE_LABEL
NODE_LABEL="${NODE_LABEL:-${DEFAULT_NODE_LABEL}}"
validate_label_key "${NODE_LABEL}"

read -r -p "Storage size [${DEFAULT_STORAGE}]: " STORAGE
STORAGE="${STORAGE:-${DEFAULT_STORAGE}}"
[[ "${STORAGE}" =~ ^[0-9]+(Mi|Gi|Ti)$ ]] || die "Storage must look like 10Gi, 500Mi, or 1Ti."

printf '\nMinecraft server settings\n'
SERVER_NAME="$(read_with_default "Server name" "${INSTANCE_NAME}")"
validate_text_value "Server name" "${SERVER_NAME}"

GAMEMODE="$(read_with_default "Game mode: survival, creative, or adventure" "${DEFAULT_GAMEMODE}")"
validate_choice "Game mode" "${GAMEMODE}" survival creative adventure

DIFFICULTY="$(read_with_default "Difficulty: peaceful, easy, normal, or hard" "${DEFAULT_DIFFICULTY}")"
validate_choice "Difficulty" "${DIFFICULTY}" peaceful easy normal hard

DEFAULT_PLAYER_PERMISSION_LEVEL="$(read_with_default "Default player permission: visitor, member, or operator" "${DEFAULT_PERMISSION_LEVEL}")"
validate_choice "Default player permission" "${DEFAULT_PLAYER_PERMISSION_LEVEL}" visitor member operator

LEVEL_NAME="$(read_with_default "Level/world name" "${INSTANCE_NAME}")"
validate_text_value "Level name" "${LEVEL_NAME}"

read -r -p "Level seed, optional: " LEVEL_SEED
validate_text_value "Level seed" "${LEVEL_SEED}"

LEVEL_TYPE="$(read_with_default "Level type: DEFAULT, FLAT, or LEGACY" "${DEFAULT_LEVEL_TYPE}")"
validate_choice "Level type" "${LEVEL_TYPE}" DEFAULT FLAT LEGACY

ALLOW_CHEATS="$(read_with_default "Allow cheats: true or false" "${DEFAULT_ALLOW_CHEATS}")"
validate_bool "Allow cheats" "${ALLOW_CHEATS}"

MAX_PLAYERS="$(read_with_default "Max players" "${DEFAULT_MAX_PLAYERS}")"
validate_positive_int "Max players" "${MAX_PLAYERS}"
(( MAX_PLAYERS >= 1 )) || die "Max players must be at least 1."

PLAYER_IDLE_TIMEOUT="$(read_with_default "Player idle timeout in minutes" "${DEFAULT_PLAYER_IDLE_TIMEOUT}")"
validate_positive_int "Player idle timeout" "${PLAYER_IDLE_TIMEOUT}"

TEXTUREPACK_REQUIRED="$(read_with_default "Require texture pack: true or false" "${DEFAULT_TEXTUREPACK_REQUIRED}")"
validate_bool "Require texture pack" "${TEXTUREPACK_REQUIRED}"

ONLINE_MODE="$(read_with_default "Require Xbox Live online mode: true or false" "${DEFAULT_ONLINE_MODE}")"
validate_bool "Online mode" "${ONLINE_MODE}"

WHITE_LIST="$(read_with_default "Enable allowlist/whitelist: true or false" "${DEFAULT_WHITE_LIST}")"
validate_bool "Whitelist" "${WHITE_LIST}"

printf '\nPerformance settings\n'
VIEW_DISTANCE="$(read_with_default "View distance" "${DEFAULT_VIEW_DISTANCE}")"
validate_positive_int "View distance" "${VIEW_DISTANCE}"

TICK_DISTANCE="$(read_with_default "Tick distance" "${DEFAULT_TICK_DISTANCE}")"
validate_positive_int "Tick distance" "${TICK_DISTANCE}"

MAX_THREADS="$(read_with_default "Max server threads" "${DEFAULT_MAX_THREADS}")"
validate_positive_int "Max server threads" "${MAX_THREADS}"

NAMESPACE="${DEFAULT_NAMESPACE}"
DATA_PATH="/data/minecraft/${INSTANCE_NAME}"

mkdir -p "${INSTANCE_DIR}"
write_values_env "${INSTANCE_DIR}/values.env"

log "Created ${INSTANCE_DIR}/values.env"
log "Subdomain is stored only for documentation; Bedrock UDP routing uses the unique external port."
printf '\nRun ./install.sh %s\n' "${INSTANCE_NAME}"
