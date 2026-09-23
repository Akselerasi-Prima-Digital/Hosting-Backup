#!/usr/bin/env bash
# =============================================================================
# Hosting User Backup Script (cPanel & DirectAdmin -> Remote Storage)
# =============================================================================
# Automated user-level backup script for cPanel (via UAPI) and DirectAdmin.
# Generates a full account backup, uploads to remote storage (S3, FTP/FTPS, SFTP),
# removes local temporary archives to save disk space, and sends Telegram alerts.
#
# Usage:
#   ./backup.sh              Run backup with default .env configuration
#   ./backup.sh --dry-run    Test configuration and panel detection without backing up
#   ./backup.sh --help       Show usage instructions
#
# Security notes:
#   - FTP/SFTP/DA credentials go to curl via a 0600 netrc file (removed on
#     exit), so they never appear in `ps`. S3 signing passes only hex-encoded
#     intermediate keys to openssl's argv (never the raw secret); on a shared
#     host, other local users can still observe process arguments while
#     signing runs. Run this on a trusted host.
#   - SFTP uploads use --insecure (no host-key check) - see SFTP_INSECURE.
#   - Local archive is deleted after upload ONLY if the uploaded byte count
#     matches the local file size.
#
# Requirements: bash 4+, curl, openssl, stat, find, od, date, awk, base64,
#               sed, tail, tr (standard on Linux hosting)
# =============================================================================

set -Eeuo pipefail

# Requires Bash 4.0+ (associative-free but uses [[ ]], arrays, ${var,,} etc.)
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'ERROR: bash 4.0 or newer is required (found %s).\n' "${BASH_VERSION}" >&2
  exit 1
fi
# Propagate command-substitution failures inside assignments (Bash 4.4+)
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
  shopt -s inherit_errexit
fi

# Color Definitions (disabled when stdout is not a TTY, e.g. cron, or NO_COLOR set)
# NOTE: every variable must be assigned in BOTH branches (set -u safety).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  MAGENTA='\033[0;35m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' CYAN='' MAGENTA='' BOLD='' NC=''
fi
readonly RED GREEN YELLOW CYAN MAGENTA BOLD NC

# Base Directory & Identity (readonly constants)
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
readonly SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# Globals (mutable runtime state)
DRY_RUN="false"
DESTINATION_STR=""
BACKUP_FILE_PATH=""
BACKUP_FILE_NAME=""
BACKUP_FILE_SIZE="0"
NETRC_FILE=""
readonly SCRIPT_START_EPOCH="$(date +%s)"
readonly BACKUP_DATE="$(date +%F)"

# Load Configuration (.env / config.env)
# Safe loader: no word splitting, no glob expansion, no GNU-xargs dependency.
load_env_file() {
  local env_file="$1"
  [ -f "${env_file}" ] || return 0

  local line key value
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    case "${line}" in ''|\#*) continue ;; esac

    case "${line}" in 'export '*) line="${line#export }" ;; esac

    key="${line%%=*}"
    value="${line#*=}"

    [ "${key}" != "${line}" ] || continue

    key="${key%"${key##*[![:space:]]}"}"

    if ! [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      printf "WARNING: skipping invalid entry in %s: %s\n" "${env_file}" "${key}" >&2
      continue
    fi

    case "${value}" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    export "${key}=${value}"
  done < "${env_file}"
}

ENV_FILE="${SCRIPT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  load_env_file "${ENV_FILE}"
else
  load_env_file "${SCRIPT_DIR}/config.env"
fi

# Warn if the config file holding credentials is readable by group/others.
# Defined here, called after the logging functions are available.
check_env_permissions() {
  local _env_path="${ENV_FILE}"
  [ -f "${_env_path}" ] || _env_path="${SCRIPT_DIR}/config.env"
  [ -f "${_env_path}" ] || return 0

  local _env_perm
  _env_perm="$(stat -c '%a' "${_env_path}" 2>/dev/null || stat -f '%Lp' "${_env_path}" 2>/dev/null || echo '?')"
  case "${_env_perm}" in
    600|400|200|'?') : ;;
    *)
      log_warn "Configuration file ${_env_path} is readable by group/others (perms ${_env_perm}). Consider 'chmod 600 ${_env_path}' - it contains credentials."
      ;;
  esac
}

# Helpers: Validation
is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# Configuration Variables with Defaults
USERNAME="${PANEL_USERNAME:-$(id -un 2>/dev/null || whoami)}"
USER_HOME="${PANEL_HOME_DIR:-${HOME:-/home/${USERNAME}}}"
PANEL_TYPE="${PANEL_TYPE:-auto}" # auto | cpanel | directadmin
BACKUP_TIMEOUT="${BACKUP_TIMEOUT_SECONDS:-600}"
POLL_INTERVAL="${BACKUP_POLL_INTERVAL_SECONDS:-3}"
DELETE_LOCAL="${DELETE_LOCAL_AFTER_UPLOAD:-true}"
STABLE_CHECKS="${BACKUP_STABLE_CHECKS:-2}"

is_uint "${BACKUP_TIMEOUT}"  || BACKUP_TIMEOUT=600
is_uint "${POLL_INTERVAL}"   || POLL_INTERVAL=3
is_uint "${STABLE_CHECKS}"   || STABLE_CHECKS=2
[ "${STABLE_CHECKS}" -ge 1 ] || STABLE_CHECKS=1

# Retention: delete remote backups older than RETENTION_DAYS days. 0 = disabled.
RETENTION_DAYS="${RETENTION_DAYS:-0}"
is_uint "${RETENTION_DAYS}" || RETENTION_DAYS=0

# Storage Configuration
# Supported remote STORAGE_TYPE: 's3', 'ftp', 'ftps', 'sftp'
STORAGE_TYPE="${STORAGE_TYPE:-s3}"

# Curl transfer hardening
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-30}"
CURL_STALL_TIMEOUT="${CURL_STALL_TIMEOUT:-300}"
CURL_RETRIES="${CURL_RETRIES:-2}"

# Common curl upload flags (array => no word-splitting surprises)
CURL_OPTS=(
  --connect-timeout "${CURL_CONNECT_TIMEOUT}"
  --speed-time "${CURL_STALL_TIMEOUT}"
  --speed-limit 1024
  --retry "${CURL_RETRIES}"
  --retry-delay 5
)

# S3 Configuration (when STORAGE_TYPE=s3)
S3_PROTOCOL="${S3_PROTOCOL:-${S3PROTOCOL:-https}}"
S3_ENDPOINT="${S3_ENDPOINT:-${S3ENDPOINT:-${S3ENDPOIN:-storage.yourserver.com}}}"
S3_KEY="${S3_KEY:-${S3KEY:-}}"
S3_SECRET="${S3_SECRET:-${S3SECRET:-}}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PATH_PREFIX="${S3_PATH:-/${USERNAME}/${BACKUP_DATE}/}"
S3_USE_PATH_STYLE="${S3_USE_PATH_STYLE:-false}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_SIGN_VERSION="${S3_SIGN_VERSION:-v4}"

# FTP / FTPS Configuration (when STORAGE_TYPE=ftp or ftps)
FTP_HOST="${FTP_HOST:-}"
FTP_PORT="${FTP_PORT:-21}"
FTP_USERNAME="${FTP_USERNAME:-}"
FTP_PASSWORD="${FTP_PASSWORD:-}"
FTP_PATH="${FTP_PATH:-/backups/${USERNAME}/${BACKUP_DATE}/}"
FTP_SSL="${FTP_SSL:-false}"

# SFTP Configuration (when STORAGE_TYPE=sftp)
SFTP_HOST="${SFTP_HOST:-}"
SFTP_PORT="${SFTP_PORT:-22}"
SFTP_USERNAME="${SFTP_USERNAME:-}"
SFTP_PASSWORD="${SFTP_PASSWORD:-}"
SFTP_PATH="${SFTP_PATH:-/backups/${USERNAME}/${BACKUP_DATE}/}"
# Disable SSH host-key verification for SFTP uploads. Defaults to true to
# preserve current behavior; set SFTP_INSECURE=false to enforce host-key
# checking (requires the host in ~/.ssh/known_hosts). MITM risk when true.
SFTP_INSECURE="${SFTP_INSECURE:-true}"

# DirectAdmin API Configuration (optional for remote/API trigger)
DA_HOST="${DA_HOST:-127.0.0.1}"
DA_PORT="${DA_PORT:-2222}"
DA_SSL="${DA_SSL:-true}"
DA_PASSWORD="${DA_PASSWORD:-${PANEL_PASSWORD:-}}"

# Telegram Notification (optional)
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Logging
LOG_FILE="${LOG_FILE:-}"

is_uint "${FTP_PORT}"  || FTP_PORT=21
is_uint "${SFTP_PORT}" || SFTP_PORT=22
is_uint "${DA_PORT}"   || DA_PORT=2222

# Logging Functions
log() {
  local level="$1"
  local color="$2"
  local message="$3"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  printf "%b[%s] [%s] %b%b\n" "${color}" "${timestamp}" "${level}" "${message}" "${NC}"

  if [ -n "${LOG_FILE}" ]; then
    mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
    # Strip ANSI escape codes when writing to log file
    printf "[%s] [%s] %s\n" "${timestamp}" "${level}" "$(printf "%b" "${message}" | sed -E 's/\x1B\[[0-9;]*[mK]//g')" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

log_info()    { log "INFO"  "${CYAN}"    "$1"; }
log_success() { log "OK"    "${GREEN}"   "$1"; }
log_warn()    { log "WARN"  "${YELLOW}"  "$1"; }
log_error()   { log "ERROR" "${RED}"     "$1"; }
log_debug() {
  if [ "${DEBUG:-0}" = "1" ]; then
    log "DEBUG" "${MAGENTA}" "$1"
  fi
}

# Config permission audit (needs logging functions above)
check_env_permissions

# =============================================================================
# Traps & Error Handling (must come after logging functions)
# =============================================================================

# EXIT handler: remove sensitive temporary resources and report abnormal
# termination. Runs on normal exit, errors, and signals alike.
cleanup() {
  local exit_code="$?"

  if [ -n "${NETRC_FILE}" ]; then
    rm -f -- "${NETRC_FILE}" 2>/dev/null || true
    NETRC_FILE=""
  fi

  if [ "${exit_code}" -ne 0 ]; then
    log_error "Backup run aborted (exit code ${exit_code})."
  fi
}
trap cleanup EXIT

# ERR handler: report the failing command with function/line context.
# With `set -E` this trap is inherited by all functions. Commands guarded by
# `|| ...` or `if !` never trigger it, so it only fires on *unhandled* errors.
on_error() {
  local exit_code="$?"
  local frame="${FUNCNAME[1]:-main}"
  local line_no="${BASH_LINENO[0]}"
  log_error "Unhandled error (exit ${exit_code}) in ${frame} at ${SCRIPT_NAME}:${line_no}: ${BASH_COMMAND}"
}
trap on_error ERR

# Signal handlers: log, then exit so the EXIT trap performs cleanup.
on_signal() {
  local signal="$1"
  local exit_code="$2"
  log_error "Received ${signal}, aborting and cleaning up..."
  exit "${exit_code}"
}
trap 'on_signal SIGINT 130'  SIGINT
trap 'on_signal SIGTERM 143' SIGTERM
trap 'on_signal SIGHUP 129'  SIGHUP

# Dependency Check
check_dependencies() {
  local -a required=(curl openssl stat find od date awk base64 sed tail tr)
  local -a missing=()
  local cmd
  for cmd in "${required[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "Missing required commands: ${missing[*]}"
    return 1
  fi
  return 0
}

# Banner
print_banner() {
  printf "${BOLD}${MAGENTA}\n"
  printf " ╔══════════════════════════════════════════════════╗\n"
  printf " ║       Hosting User Backup Tool (cPanel / DA)    ║\n"
  printf " ║       User:    %-34s║\n" "${USERNAME}"
  printf " ║       Storage: %-34s║\n" "${STORAGE_TYPE^^}"
  printf " ║       Date:    %-34s║\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  printf " ╚══════════════════════════════════════════════════╝\n"
  printf "${NC}\n"
}

# Help Message
print_help() {
  cat << EOF
Hosting User Backup Script (cPanel & DirectAdmin -> Remote Storage)

Usage:
  ./backup.sh [options]

Options:
  --dry-run      Check configuration and detect panel without running backup
  --help         Show this help message

Debugging:
  DEBUG=1 ./backup.sh    Enable DEBUG-level log output (verbose polling info)

Supported Panels:
  • cPanel (UAPI Backup::fullbackup_to_homedir)
  • DirectAdmin (CMD_API_SITE_BACKUP & CLI)

Supported Remote Storages (STORAGE_TYPE):
  • s3     : S3 & S3-Compatible (Jagoan Storage, AWS, Cloudflare R2, Wasabi, MinIO, etc.)
             Signing: AWS Signature V4 by default (S3_SIGN_VERSION=v4; region S3_REGION).
             Set S3_SIGN_VERSION=v2 only for legacy providers that reject V4.
  • ftp    : FTP & FTPS remote server
  • sftp   : SSH / SFTP remote server

Security-related settings:
  S3_SIGN_VERSION        v4 (default) or v2 (legacy HMAC-SHA1)
  S3_REGION              SigV4 region (default us-east-1)
  CURL_CONNECT_TIMEOUT / CURL_STALL_TIMEOUT / CURL_RETRIES  Transfer hardening

Transfer integrity:
  Uploads are verified by comparing uploaded byte count with the local file
  size. The local archive is only deleted when DELETE_LOCAL=true AND the
  upload was verified.

Retention (RETENTION_DAYS):
  After a successful upload, remote backup folders older than RETENTION_DAYS
  days are deleted (0 = disabled). Date is inferred from the YYYY-MM-DD segment
  in the remote path. Supported for s3 (requires S3_SIGN_VERSION=v4), ftp and
  ftps. SFTP retention is not supported (curl cannot delete SFTP files).

Cron Example (Daily at 2:00 AM):
  0 2 * * * /bin/bash ${SCRIPT_DIR}/backup.sh >> ${USER_HOME}/backup_cron.log 2>&1
EOF
}

# Format Bytes
format_bytes() {
  local bytes="$1"
  if ! is_uint "${bytes}"; then
    printf "%s" "${bytes}"
    return 0
  fi
  if [ "${bytes}" -ge 1073741824 ]; then
    awk -v b="${bytes}" 'BEGIN {printf "%.2f GB", b/1073741824}'
  elif [ "${bytes}" -ge 1048576 ]; then
    awk -v b="${bytes}" 'BEGIN {printf "%.2f MB", b/1048576}'
  elif [ "${bytes}" -ge 1024 ]; then
    awk -v b="${bytes}" 'BEGIN {printf "%.2f KB", b/1024}'
  else
    printf "%d B" "${bytes}"
  fi
}

# Format Duration
format_duration() {
  local total_seconds="$1"
  is_uint "${total_seconds}" || total_seconds=0
  local minutes=$((total_seconds / 60))
  local seconds=$((total_seconds % 60))
  if [ "${minutes}" -gt 0 ]; then
    printf "%dm %ds" "${minutes}" "${seconds}"
  else
    printf "%ds" "${seconds}"
  fi
}

# Get File Size (portable: GNU stat, BSD stat, wc fallback)
get_file_size() {
  local f="$1"
  stat -c '%s' "${f}" 2>/dev/null || stat -f '%z' "${f}" 2>/dev/null || wc -c < "${f}" 2>/dev/null || printf '0'
}

# Get File Mtime as epoch seconds (portable)
get_file_mtime() {
  local f="$1"
  stat -c '%Y' "${f}" 2>/dev/null || stat -f '%m' "${f}" 2>/dev/null || printf '0'
}

# Find Newest Backup Candidate Created During This Run
# Only considers files whose mtime is >= SCRIPT_START_EPOCH, so archives left
# over from previous runs are NEVER picked up (prevents stale-upload race).
# Usage: find_newest_backup <dir> <pattern> [<pattern>...]
find_newest_backup() {
  local dir="$1"
  shift
  local -a names=("$@")
  local -a preds=()
  local i
  for i in "${!names[@]}"; do
    if [ "${i}" -gt 0 ]; then
      preds+=(-o)
    fi
    preds+=(-name "${names[${i}]}")
  done

  local f newest="" newest_m=-1 m
  local tmp
  tmp="$(mktemp)" || return 1
  # Self-clearing trap: fire once for this function, then remove itself so it
  # cannot leak into later function returns (where ${tmp} no longer exists).
  trap 'rm -f -- "${tmp}"; trap - RETURN' RETURN

  # Use a temp file instead of process substitution so this works on systems
  # without /dev/fd (e.g. some containers/restricted shells).
  find "${dir}" -maxdepth 1 -type f \( "${preds[@]}" \) -print0 2>/dev/null > "${tmp}" || true

  while IFS= read -r -d '' f; do
    m="$(get_file_mtime "${f}")"
    if [ "${m}" -ge "${SCRIPT_START_EPOCH}" ] && [ "${m}" -gt "${newest_m}" ]; then
      newest="${f}"
      newest_m="${m}"
    fi
  done < "${tmp}"

  printf '%s' "${newest}"
}

# Temporary netrc Helper (keeps credentials out of `ps`)
make_netrc() {
  local machine="$1"
  local login="$2"
  local pass="$3"

  case "${machine}${login}${pass}" in
    *[[:space:]]*)
      log_error "Credentials contain whitespace, which netrc cannot represent. Use a password without spaces/tabs/newlines."
      return 1
      ;;
  esac

  # Remove previous netrc if any
  if [ -n "${NETRC_FILE}" ]; then
    rm -f -- "${NETRC_FILE}" 2>/dev/null || true
    NETRC_FILE=""
  fi

  NETRC_FILE="$(mktemp "${TMPDIR:-/tmp}/backup-netrc.XXXXXX")" || {
    log_error "Failed to create temporary netrc file."
    return 1
  }
  chmod 600 "${NETRC_FILE}" 2>/dev/null || true
  printf 'machine %s login %s password %s\n' "${machine}" "${login}" "${pass}" > "${NETRC_FILE}"
  return 0
}

# Detect Panel Type
detect_panel() {
  if [ "${PANEL_TYPE}" != "auto" ]; then
    echo "${PANEL_TYPE}"
    return 0
  fi

  if command -v uapi >/dev/null 2>&1 || [ -d "/usr/local/cpanel" ]; then
    echo "cpanel"
  elif [ -d "/usr/local/directadmin" ] || command -v directadmin >/dev/null 2>&1 || command -v da >/dev/null 2>&1; then
    echo "directadmin"
  else
    echo "unknown"
  fi
}

# Validate Storage Config
validate_storage_config() {
  case "${STORAGE_TYPE}" in
    s3)
      if [ -z "${S3_KEY}" ] || [ -z "${S3_SECRET}" ] || [ -z "${S3_BUCKET}" ]; then
        log_error "S3 Credentials missing! Please set S3_KEY, S3_SECRET, and S3_BUCKET in .env"
        return 1
      fi
      case "${S3_SIGN_VERSION}" in
        v2|v4) : ;;
        *)
          log_error "Unsupported S3_SIGN_VERSION '${S3_SIGN_VERSION}'. Supported: v2, v4."
          return 1
          ;;
      esac
      ;;
    ftp|ftps)
      if [ -z "${FTP_HOST}" ] || [ -z "${FTP_USERNAME}" ] || [ -z "${FTP_PASSWORD}" ]; then
        log_error "FTP Credentials missing! Please set FTP_HOST, FTP_USERNAME, and FTP_PASSWORD in .env"
        return 1
      fi
      ;;
    sftp)
      if [ -z "${SFTP_HOST}" ] || [ -z "${SFTP_USERNAME}" ] || [ -z "${SFTP_PASSWORD}" ]; then
        log_error "SFTP Credentials missing! Please set SFTP_HOST, SFTP_USERNAME, and SFTP_PASSWORD in .env"
        return 1
      fi
      ;;
    *)
      log_error "Unsupported STORAGE_TYPE: ${STORAGE_TYPE}. Supported: s3, ftp, ftps, sftp."
      return 1
      ;;
  esac
  return 0
}

# Crypto helpers (OpenSSL based, no plaintext secrets in argv beyond
# hex-encoded intermediate keys during subsecond signing calls)

_od_hex() { od -An -tx1 | tr -d ' \n'; }

sha256_hex() { # stdout: hex digest of stdin
  openssl dgst -sha256 | sed 's/^[^ ]* //'
}

hmac_sha256_bin() { # $1=key(hex) -> binary HMAC-SHA256 of stdin, printed as hex
  local key_hex="$1"
  openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" -binary | _od_hex
}

hmac_sha256_hex() { # $1=key(hex) -> hex HMAC-SHA256 of stdin
  local key_hex="$1"
  openssl dgst -sha256 -mac HMAC -macopt "hexkey:${key_hex}" | sed 's/^[^ ]* //'
}

hmac_sha1_base64() { # $1=key(hex) -> base64 HMAC-SHA1 of stdin (legacy SigV2)
  local key_hex="$1"
  openssl dgst -sha1 -mac HMAC -macopt "hexkey:${key_hex}" -binary | base64
}

str_to_hexkey() { # raw string -> hex (for use as -macopt hexkey)
  printf '%s' "$1" | _od_hex
}

# URI-encode for S3 object keys ('/' preserved as segment separator)
s3_uri_encode() {
  local input="$1"
  local out="" i c enc
  local len=${#input}
  for (( i=0; i<len; i++ )); do
    c="${input:i:1}"
    case "${c}" in
      [A-Za-z0-9._~-]) out+="${c}" ;;
      '/')             out+='/' ;;
      *)
        enc="$(printf '%%%02X' "'${c}")"
        out+="${enc}"
        ;;
    esac
  done
  printf '%s' "${out}"
}

# Parse "<body>\n<meta line>" curl output. Sets PARSED_META array.
# Usage: response="<...>"; parse_curl_meta "${response}"; then use
# "${PARSED_META[0]}", "${PARSED_META[1]}" ...
parse_curl_meta() {
  local response="$1"
  local meta_line
  meta_line="$(printf '%s\n' "${response}" | tail -n 1)"
  # Keep only digits/separators so stray output can never inject globs
  meta_line="$(printf '%s' "${meta_line}" | tr -cd '0-9 \t')"
  # shellcheck disable=SC2206
  PARSED_META=(${meta_line})
}

# Translate common curl exit codes into actionable messages.
describe_curl_exit() {
  case "$1" in
    6)  printf 'could not resolve host' ;;
    7)  printf 'could not connect to server (check host/port/firewall)' ;;
    28) printf 'operation timed out (transfer stalled below 1 KB/s for CURL_STALL_TIMEOUT seconds - raise CURL_STALL_TIMEOUT for large files on slow links)' ;;
    35) printf 'SSL/TLS handshake failure' ;;
    45) printf 'FTP access denied (check credentials/permissions)' ;;
    55) printf 'send error (connection lost mid-transfer)' ;;
    56) printf 'recv error (connection reset by server)' ;;
    60) printf 'SSL certificate problem' ;;
    67) printf 'login denied (wrong username/password)' ;;
    *)  printf 'curl error %s (see curl.se/libcurl/c/libcurl-errors.html)' "$1" ;;
  esac
}

# Percentage helper for progress messages.
pct() { # pct <part> <total>
  awk -v a="$1" -v b="$2" 'BEGIN { if (b+0 > 0) printf "%d%%", a*100/b; else printf "?" }'
}

# Extract Content-Length from an HTTP-style header block (used by the FTP/SFTP
# remote-size verifiers; curl maps FTP SIZE / SFTP stat to Content-Length).
extract_content_length() {
  printf '%s' "$1" | tr -d '\r' | awk 'tolower($1)=="content-length:" {print $2}' | tail -n1
}

# Storage Driver: S3 (SigV4 default, SigV2 legacy)
backup_to_s3() {
  local local_path="$1"
  local file_name="$2"
  local s3_prefix="$3"
  local bucket="$4"
  local expected_size="$5"

  [[ "${s3_prefix}" != /* ]] && s3_prefix="/${s3_prefix}"
  [[ "${s3_prefix}" != */ ]] && s3_prefix="${s3_prefix}/"

  local object_key="${s3_prefix#/}${file_name}" # no leading slash
  local encoded_key
  encoded_key="$(s3_uri_encode "${object_key}")"

  local upload_url
  local host
  local canonical_uri
  if [ "${S3_USE_PATH_STYLE}" = "true" ]; then
    host="${S3_ENDPOINT}"
    canonical_uri="/$(s3_uri_encode "${bucket}")/${encoded_key}"
    upload_url="${S3_PROTOCOL}://${S3_ENDPOINT}/${bucket}/${encoded_key}"
  else
    host="${bucket}.${S3_ENDPOINT}"
    canonical_uri="/${encoded_key}"
    upload_url="${S3_PROTOCOL}://${bucket}.${S3_ENDPOINT}/${encoded_key}"
  fi

  DESTINATION_STR="${upload_url}"
  log_info "Uploading to S3 (${S3_SIGN_VERSION}): ${upload_url}"

  local auth_header
  local cfg
  local rc=0
  local response
  local http_code="" up_bytes=""

  if [ "${S3_SIGN_VERSION}" = "v4" ]; then
    local amz_date date_stamp scope payload_hash signed_headers
    amz_date="$(date -u '+%Y%m%dT%H%M%SZ')"
    date_stamp="${amz_date:0:8}"
    scope="${date_stamp}/${S3_REGION}/s3/aws4_request"
    payload_hash="UNSIGNED-PAYLOAD"
    signed_headers="host;x-amz-content-sha256;x-amz-date"

    local canonical_request string_to_sign
    canonical_request="$(printf 'PUT\n%s\n\nhost:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n\n%s\n%s' \
      "${canonical_uri}" "${host}" "${payload_hash}" "${amz_date}" "${signed_headers}" "${payload_hash}")"
    string_to_sign="$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' \
      "${amz_date}" "${scope}" "$(printf '%s' "${canonical_request}" | sha256_hex)")"

    local k_date k_region k_service k_signing
    k_date="$(hmac_sha256_bin "$(str_to_hexkey "AWS4${S3_SECRET}")" "${date_stamp}")"
    k_region="$(hmac_sha256_bin "${k_date}" "${S3_REGION}")"
    k_service="$(hmac_sha256_bin "${k_region}" "s3")"
    k_signing="$(hmac_sha256_bin "${k_service}" "aws4_request")"

    local signature
    signature="$(printf '%s' "${string_to_sign}" | hmac_sha256_hex "${k_signing}")"

    auth_header="AWS4-HMAC-SHA256 Credential=${S3_KEY}/${scope}, SignedHeaders=${signed_headers}, Signature=${signature}"
    cfg="$(printf 'header = "Authorization: %s"\nheader = "x-amz-date: %s"\nheader = "x-amz-content-sha256: %s"\n' \
      "${auth_header}" "${amz_date}" "${payload_hash}")"
  else
    # Legacy Signature V2 (HMAC-SHA1)
    local date_header
    date_header="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S GMT')"
    local content_type="application/x-compressed-tar"
    local string_to_sign="PUT\n\n${content_type}\n${date_header}\n${canonical_uri}"
    local signature
    signature="$(printf '%s' "${string_to_sign}" | hmac_sha1_base64 "$(str_to_hexkey "${S3_SECRET}")")"
    auth_header="AWS ${S3_KEY}:${signature}"
    cfg="$(printf 'header = "Authorization: %s"\nheader = "Date: %s"\nheader = "Content-Type: %s"\n' \
      "${auth_header}" "${date_header}" "${content_type}")"
  fi

  response="$(printf '%s' "${cfg}" | curl -s -w '\n%{http_code} %{size_upload}' \
    "${CURL_OPTS[@]}" \
    -X PUT -T "${local_path}" \
    --config - \
    "${upload_url}" 2>&1)" || rc=$?

  # Parse progress even on failure so logs show how far the upload got
  parse_curl_meta "${response}"
  http_code="${PARSED_META[0]:-0}"
  up_bytes="${PARSED_META[1]:-0}"

  if [ "${rc}" -ne 0 ]; then
    # Transfer reached 100% but stalled before the HTTP response arrived
    # (slow server post-processing, connection drop, etc.). The object may
    # be complete - verify it via a signed HEAD request before failing.
    if [ "${up_bytes}" = "${expected_size}" ]; then
      log_warn "Transfer reached 100% but the connection stalled before the HTTP response - verifying remote object..."
      if s3_verify_object "${object_key}" "${expected_size}"; then
        log_success "Upload to S3 verified on remote server ($(format_bytes "${expected_size}")) despite stalled connection."
        return 0
      fi
      log_warn "Remote size verification failed - treating upload as incomplete."
    fi
    log_error "Upload to S3 failed at $(format_bytes "${up_bytes}") of $(format_bytes "${expected_size}") ($(pct "${up_bytes}" "${expected_size}")) - $(describe_curl_exit "${rc}")."
    return 1
  fi

  if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]] && [ "${up_bytes}" = "${expected_size}" ]; then
    log_success "Upload to S3 completed successfully (HTTP ${http_code}, verified ${up_bytes} bytes)."
    return 0
  fi

  log_error "Upload to S3 failed or incomplete (HTTP ${http_code}, uploaded ${up_bytes} of ${expected_size} bytes - $(pct "${up_bytes}" "${expected_size}"))."
  local response_body
  response_body="$(printf '%s\n' "${response}" | sed '$d')"
  if [ -n "${response_body}" ]; then
    log_error "S3 Response: ${response_body}"
  fi
  return 1
}

# Verify a complete S3 object via signed HEAD request (SigV4).
# Returns 0 only when the object exists and its Content-Length matches.
s3_verify_object() {
  local key="$1"
  local expected="$2"
  local host canonical_uri
  if [ "${S3_USE_PATH_STYLE}" = "true" ]; then
    host="${S3_ENDPOINT}"
    canonical_uri="/$(s3_uri_encode "${S3_BUCKET}")/$(s3_uri_encode "${key}")"
  else
    host="${S3_BUCKET}.${S3_ENDPOINT}"
    canonical_uri="/$(s3_uri_encode "${key}")"
  fi

  # --head makes curl send HEAD without waiting for a body
  local resp code headers remote_size
  resp="$(s3_signed_request HEAD "${canonical_uri}" "" "${host}" --head)" || true
  code="$(printf '%s\n' "${resp}" | tail -n1)"
  [[ "${code}" =~ ^2[0-9][0-9]$ ]] || return 1

  headers="$(printf '%s\n' "${resp}" | sed '$d')"
  remote_size="$(extract_content_length "${headers}")"
  is_uint "${remote_size}" || return 1
  [ "${remote_size}" = "${expected}" ]
}

# Verify remote file size on FTP/FTPS via HEAD (curl maps SIZE -> Content-Length).
verify_remote_size_ftp() {
  local remote_path="$1"
  local expected="$2"
  local proto="ftp"
  local -a ssl_args=()
  if [ "${STORAGE_TYPE}" = "ftps" ] || [ "${FTP_SSL}" = "true" ]; then
    ssl_args+=(--ssl --tls-max 1.2)
  fi

  local headers remote_size
  headers="$(curl -sI \
    "${ssl_args[@]}" \
    --netrc-file "${NETRC_FILE}" \
    --ftp-pasv \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    "${proto}://${FTP_HOST}:${FTP_PORT}${remote_path}" 2>/dev/null)" || true
  remote_size="$(extract_content_length "${headers}")"
  is_uint "${remote_size}" || return 1
  [ "${remote_size}" = "${expected}" ]
}

# Verify remote file size on SFTP via HEAD (curl maps stat -> Content-Length).
verify_remote_size_sftp() {
  local remote_path="$1"
  local expected="$2"

  local -a insecure_args=()
  if [ "${SFTP_INSECURE}" = "true" ]; then
    insecure_args+=(--insecure)
  fi

  local headers remote_size
  headers="$(curl -sI \
    "${insecure_args[@]}" \
    --netrc-file "${NETRC_FILE}" \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
    "sftp://${SFTP_HOST}:${SFTP_PORT}${remote_path}" 2>/dev/null)" || true
  remote_size="$(extract_content_length "${headers}")"
  is_uint "${remote_size}" || return 1
  [ "${remote_size}" = "${expected}" ]
}

# Storage Driver: FTP / FTPS Upload
backup_to_ftp() {
  local local_path="$1"
  local file_name="$2"
  local expected_size="$3"
  local ftp_path="${FTP_PATH}"

  [[ "${ftp_path}" != /* ]] && ftp_path="/${ftp_path}"
  [[ "${ftp_path}" != */ ]] && ftp_path="${ftp_path}/"

  local proto="ftp"
  local -a ssl_args=()
  if [ "${STORAGE_TYPE}" = "ftps" ] || [ "${FTP_SSL}" = "true" ]; then
    ssl_args+=(--ssl --tls-max 1.2)
  fi

  if ! make_netrc "${FTP_HOST}" "${FTP_USERNAME}" "${FTP_PASSWORD}"; then
    return 1
  fi

  DESTINATION_STR="${proto}://${FTP_HOST}:${FTP_PORT}${ftp_path}${file_name}"
  log_info "Uploading to FTP: ${DESTINATION_STR}"

  local rc=0
  local output
  local up_bytes=""

  output="$(curl -s -w '\n%{size_upload}' \
    "${ssl_args[@]}" \
    --netrc-file "${NETRC_FILE}" \
    --ftp-create-dirs \
    --ftp-pasv \
    "${CURL_OPTS[@]}" \
    -T "${local_path}" \
    "${proto}://${FTP_HOST}:${FTP_PORT}${ftp_path}${file_name}" 2>&1)" || rc=$?

  # Parse progress even on failure so logs show how far the upload got
  parse_curl_meta "${output}"
  up_bytes="${PARSED_META[0]:-0}"

  if [ "${rc}" -ne 0 ]; then
    # Transfer reached 100% but stalled before the server's final "226"
    # confirmation (common on FTPS: NAT/firewall drops the idle control
    # connection, slow TLS shutdown, etc.). The data is likely on the server,
    # so verify the remote size and only then accept the upload.
    if [ "${up_bytes}" = "${expected_size}" ]; then
      log_warn "Transfer reached 100% but the connection stalled before server confirmation - verifying remote file size..."
      if verify_remote_size_ftp "${ftp_path}${file_name}" "${expected_size}"; then
        log_success "Upload to FTP verified on remote server ($(format_bytes "${expected_size}")) despite stalled connection."
        return 0
      fi
      log_warn "Remote size verification failed - treating upload as incomplete."
    fi
    log_error "Upload to FTP failed at $(format_bytes "${up_bytes}") of $(format_bytes "${expected_size}") ($(pct "${up_bytes}" "${expected_size}")) - $(describe_curl_exit "${rc}")."
    return 1
  fi

  if [ "${up_bytes}" = "${expected_size}" ]; then
    log_success "Upload to FTP completed successfully (verified ${up_bytes} bytes)."
    return 0
  fi

  log_error "Upload to FTP incomplete (uploaded ${up_bytes} of ${expected_size} bytes - $(pct "${up_bytes}" "${expected_size}"))."
  return 1
}

# Storage Driver: SFTP Upload
backup_to_sftp() {
  local local_path="$1"
  local file_name="$2"
  local expected_size="$3"
  local sftp_path="${SFTP_PATH}"

  [[ "${sftp_path}" != /* ]] && sftp_path="/${sftp_path}"
  [[ "${sftp_path}" != */ ]] && sftp_path="${sftp_path}/"

  local sftp_url="sftp://${SFTP_HOST}:${SFTP_PORT}${sftp_path}${file_name}"
  DESTINATION_STR="${sftp_url}"

  if ! make_netrc "${SFTP_HOST}" "${SFTP_USERNAME}" "${SFTP_PASSWORD}"; then
    return 1
  fi

  log_info "Uploading to SFTP: ${sftp_url}"

  local -a insecure_args=()
  if [ "${SFTP_INSECURE}" = "true" ]; then
    log_warn "SFTP host-key verification DISABLED (SFTP_INSECURE=true) - connection is vulnerable to man-in-the-middle attacks."
    insecure_args+=(--insecure)
  fi

  local rc=0
  local output
  local up_bytes=""

  output="$(curl -s -w '\n%{size_upload}' \
    "${insecure_args[@]}" \
    --netrc-file "${NETRC_FILE}" \
    --ftp-create-dirs \
    "${CURL_OPTS[@]}" \
    -T "${local_path}" \
    "${sftp_url}" 2>&1)" || rc=$?

  # Parse progress even on failure so logs show how far the upload got
  parse_curl_meta "${output}"
  up_bytes="${PARSED_META[0]:-0}"

  if [ "${rc}" -ne 0 ]; then
    # Same 100%-but-stalled recovery as the FTP driver
    if [ "${up_bytes}" = "${expected_size}" ]; then
      log_warn "Transfer reached 100% but the connection stalled before server confirmation - verifying remote file size..."
      if verify_remote_size_sftp "${sftp_path}${file_name}" "${expected_size}"; then
        log_success "Upload to SFTP verified on remote server ($(format_bytes "${expected_size}")) despite stalled connection."
        return 0
      fi
      log_warn "Remote size verification failed - treating upload as incomplete."
    fi
    log_error "Upload to SFTP failed at $(format_bytes "${up_bytes}") of $(format_bytes "${expected_size}") ($(pct "${up_bytes}" "${expected_size}")) - $(describe_curl_exit "${rc}")."
    return 1
  fi

  if [ "${up_bytes}" = "${expected_size}" ]; then
    log_success "Upload to SFTP completed successfully (verified ${up_bytes} bytes)."
    return 0
  fi

  log_error "Upload to SFTP incomplete (uploaded ${up_bytes} of ${expected_size} bytes - $(pct "${up_bytes}" "${expected_size}"))."
  return 1
}

# =============================================================================
# Retention (RETENTION_DAYS): delete remote YYYY-MM-DD folders older than N days.
# Supported: s3 (v4), ftp, ftps. SFTP unsupported (curl cannot delete SFTP files).
# =============================================================================

# Strip the trailing YYYY-MM-DD segment from a remote path. Returns 1 if absent.
remote_parent() {
  local p="$1"
  p="${p#/}"
  p="${p%/}"
  if [[ "${p}" =~ ^(.*/)?[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Extract a YYYY-MM-DD date from any string (or empty). Always returns 0 so
# callers using plain assignment are safe under set -e / pipefail.
extract_remote_date() {
  printf '%s' "$1" | { grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n1 || true; }
}

# Generic signed S3 request (SigV4 only). Prints raw body + "\nHTTP_CODE".
# Usage: s3_signed_request METHOD CANONICAL_URI QUERY HOST [curl args...]
s3_signed_request() {
  local method="$1" canonical_uri="$2" query="$3" host="$4"
  shift 4
  local -a curl_extra=("$@")

  local amz_date date_stamp scope payload_hash signed_headers
  amz_date="$(date -u '+%Y%m%dT%H%M%SZ')"
  date_stamp="${amz_date:0:8}"
  scope="${date_stamp}/${S3_REGION}/s3/aws4_request"
  payload_hash="UNSIGNED-PAYLOAD"
  signed_headers="host;x-amz-content-sha256;x-amz-date"

  local canonical_request string_to_sign
  canonical_request="$(printf '%s\n%s\n%s\nhost:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n\n%s\n%s' \
    "${method}" "${canonical_uri}" "${query}" "${host}" "${payload_hash}" "${amz_date}" "${signed_headers}" "${payload_hash}")"
  string_to_sign="$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' \
    "${amz_date}" "${scope}" "$(printf '%s' "${canonical_request}" | sha256_hex)")"

  local k_date k_region k_service k_signing signature auth_header
  k_date="$(hmac_sha256_bin "$(str_to_hexkey "AWS4${S3_SECRET}")" "${date_stamp}")"
  k_region="$(hmac_sha256_bin "${k_date}" "${S3_REGION}")"
  k_service="$(hmac_sha256_bin "${k_region}" "s3")"
  k_signing="$(hmac_sha256_bin "${k_service}" "aws4_request")"
  signature="$(printf '%s' "${string_to_sign}" | hmac_sha256_hex "${k_signing}")"
  auth_header="AWS4-HMAC-SHA256 Credential=${S3_KEY}/${scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

  local cfg
  cfg="$(printf 'header = "Authorization: %s"\nheader = "x-amz-date: %s"\nheader = "x-amz-content-sha256: %s"\n' \
    "${auth_header}" "${amz_date}" "${payload_hash}")"

  local url
  if [ "${S3_USE_PATH_STYLE}" = "true" ]; then
    url="${S3_PROTOCOL}://${S3_ENDPOINT}${canonical_uri}"
  else
    url="${S3_PROTOCOL}://${host}${canonical_uri}"
  fi
  [ -n "${query}" ] && url="${url}?${query}"

  printf '%s' "${cfg}" | curl -s \
    "${CURL_OPTS[@]}" \
    -X "${method}" \
    --config - \
    "${curl_extra[@]}" \
    -w '\n%{http_code}' \
    "${url}" 2>&1
}

# Delete a single S3 object by key. Returns 0 on success (2xx).
s3_delete_key() {
  local key="$1"
  local host canonical_uri
  if [ "${S3_USE_PATH_STYLE}" = "true" ]; then
    host="${S3_ENDPOINT}"
    canonical_uri="/$(s3_uri_encode "${S3_BUCKET}")/$(s3_uri_encode "${key}")"
  else
    host="${S3_BUCKET}.${S3_ENDPOINT}"
    canonical_uri="/$(s3_uri_encode "${key}")"
  fi
  local resp code
  resp="$(s3_signed_request DELETE "${canonical_uri}" "" "${host}")" || true
  code="$(printf '%s\n' "${resp}" | tail -n1)"
  [[ "${code}" =~ ^2[0-9][0-9]$ ]]
}

# S3 retention: list objects under the parent prefix and delete any whose
# date segment (YYYY-MM-DD) is older than the cutoff.
retention_s3() {
  local cutoff_epoch="$1"
  [ "${S3_SIGN_VERSION}" = "v4" ] || {
    log_warn "S3 retention (RETENTION_DAYS) requires S3_SIGN_VERSION=v4; skipping retention."
    return 0
  }

  local parent
  parent="$(remote_parent "${S3_PATH_PREFIX}")"
  if [ -z "${parent}" ]; then
    log_warn "S3_PATH_PREFIX has no date segment (YYYY-MM-DD); cannot apply retention."
    return 0
  fi

  parent="${parent#/}"

  local host canonical
  if [ "${S3_USE_PATH_STYLE}" = "true" ]; then
    host="${S3_ENDPOINT}"
    canonical="/$(s3_uri_encode "${S3_BUCKET}")/"
  else
    host="${S3_BUCKET}.${S3_ENDPOINT}"
    canonical="/"
  fi

  local key date_str m matched=0 deleted=0 failed=0
  local query resp code body is_truncated continuation_token
  continuation_token=""

  while true; do
    # SigV4 requires query params in alphabetical order (continuation-token first)
    query="list-type=2&prefix=$(s3_uri_encode "${parent}")"
    [ -n "${continuation_token}" ] && query="continuation-token=$(s3_uri_encode "${continuation_token}")&${query}"

    resp="$(s3_signed_request GET "${canonical}" "${query}" "${host}")" || true
    code="$(printf '%s\n' "${resp}" | tail -n1)"
    body="$(printf '%s\n' "${resp}" | sed '$d')"

    if [[ ! "${code}" =~ ^2[0-9][0-9]$ ]]; then
      log_warn "S3 retention: list failed (HTTP ${code}); skipping retention."
      return 0
    fi

    while IFS= read -r key; do
      [ -z "${key}" ] && continue
      date_str="$(extract_remote_date "${key}")"
      [ -n "${date_str}" ] || continue
      matched=$((matched + 1))
      m="$(date -d "${date_str}" +%s 2>/dev/null || true)"
      if [ -z "${m}" ]; then
        log_warn "  Retention: could not parse date '${date_str}' from key '${key}'; skipping."
        continue
      fi
      if [ "${m}" -lt "${cutoff_epoch}" ]; then
        if s3_delete_key "${key}"; then
          deleted=$((deleted + 1))
          log_info "  Retention: deleted ${key} (${date_str})"
        else
          failed=$((failed + 1))
          log_warn "  Retention: failed to delete ${key}"
        fi
      fi
    done < <(printf '%s\n' "${body}" | grep -oE '<Key>[^<]*</Key>' | sed -E 's#</?Key>##g')

    # Pagination: continue only when the response signals there are more pages
    is_truncated="$(printf '%s\n' "${body}" | grep -oE '<IsTruncated>[^<]*</IsTruncated>' | sed -E 's#</?IsTruncated>##g' | tr '[:upper:]' '[:lower:]')"
    [ "${is_truncated}" = "true" ] || break
    continuation_token="$(printf '%s\n' "${body}" | grep -oE '<NextContinuationToken>[^<]*</NextContinuationToken>' | sed -E 's#</?NextContinuationToken>##g')"
    [ -n "${continuation_token}" ] || break
  done

  if [ "${matched}" -eq 0 ]; then
    log_warn "S3 retention: no objects found under prefix '${parent}' - nothing to clean (check S3_PATH_PREFIX)."
  else
    log_info "S3 retention summary: ${deleted} deleted, ${failed} failed, ${matched} matched under '${parent}'."
  fi
}

# FTP helpers (shared by ftp/ftps retention)

# Recursively remove a remote FTP directory (delete files then RMD the dir).
# Returns 0 only if the final RMD succeeded.
ftp_rm_r() {
  local dir="$1"
  dir="${dir#/}"
  local proto="ftp"
  local -a ssl_args=()
  if [ "${STORAGE_TYPE}" = "ftps" ] || [ "${FTP_SSL}" = "true" ]; then
    ssl_args+=(--ssl --tls-max 1.2)
  fi

  local files f
  files="$(curl -sS "${ssl_args[@]}" --netrc-file "${NETRC_FILE}" --ftp-pasv \
    "${proto}://${FTP_HOST}:${FTP_PORT}/${dir}/" || true)"
  while IFS= read -r f; do
    f="${f%$'\r'}"
    [ -z "${f}" ] && continue
    f="${f##* }"
    [ -z "${f}" ] && continue
    case "${f}" in
      .|..) continue ;;
    esac
    curl -s "${ssl_args[@]}" --netrc-file "${NETRC_FILE}" --ftp-pasv \
      -Q "DELE /${dir}/${f}" "${proto}://${FTP_HOST}:${FTP_PORT}/" >/dev/null 2>&1 || true
  done <<< "${files}"
  curl -s "${ssl_args[@]}" --netrc-file "${NETRC_FILE}" --ftp-pasv \
    -Q "RMD /${dir}" "${proto}://${FTP_HOST}:${FTP_PORT}/" >/dev/null 2>&1
}

# Delete a single remote FTP file via DELE. Returns 0 on success.
ftp_delete_file() {
  local file="$1"
  file="${file#/}"
  local proto="ftp"
  local -a ssl_args=()
  if [ "${STORAGE_TYPE}" = "ftps" ] || [ "${FTP_SSL}" = "true" ]; then
    ssl_args+=(--ssl --tls-max 1.2)
  fi

  curl -s "${ssl_args[@]}" --netrc-file "${NETRC_FILE}" --ftp-pasv \
    -Q "DELE /${file}" "${proto}://${FTP_HOST}:${FTP_PORT}/" >/dev/null 2>&1
}

# FTP/FTPS retention: list date dirs under the parent and remove older ones.
retention_ftp() {
  local cutoff_epoch="$1"
  local parent
  parent="$(remote_parent "${FTP_PATH}")"
  if [ -z "${parent}" ]; then
    log_warn "FTP_PATH has no date segment (YYYY-MM-DD); cannot apply retention."
    return 0
  fi

  parent="${parent#/}"
  parent="${parent%/}"

  local proto="ftp"
  local -a ssl_args=()
  if [ "${STORAGE_TYPE}" = "ftps" ] || [ "${FTP_SSL}" = "true" ]; then
    ssl_args+=(--ssl --tls-max 1.2)
  fi

  local listing
  listing="$(curl -sS "${ssl_args[@]}" --netrc-file "${NETRC_FILE}" --ftp-pasv \
    "${proto}://${FTP_HOST}:${FTP_PORT}/${parent}/" || true)"

  # curl FTP listings carry CRLF line endings; log raw output when debugging
  if [ "${DEBUG:-0}" = "1" ]; then
    log_debug "FTP retention raw listing of /${parent}/:"
    while IFS= read -r dbg_line; do
      log_debug "    | ${dbg_line}"
    done <<< "${listing}"
  fi

  if [ -z "${listing}" ]; then
    log_warn "FTP retention: directory listing of /${parent}/ is empty - nothing to clean (check FTP server permissions or SSL settings)."
    return 0
  fi

  local name basename_name date_str m
  local matched=0 failed=0
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [ -z "${name}" ] && continue
    basename_name="${name##* }"
    [ -z "${basename_name}" ] && continue
    case "${basename_name}" in
      .|..) continue ;;
    esac
    date_str="$(extract_remote_date "${basename_name}")"
    [ -n "${date_str}" ] || continue
    matched=$((matched + 1))
    m="$(date -d "${date_str}" +%s 2>/dev/null || true)"
    if [ -z "${m}" ]; then
      log_warn "  Retention: could not parse date '${date_str}' from '${basename_name}'; skipping."
      continue
    fi
    if [ "${m}" -lt "${cutoff_epoch}" ]; then
      local del_ok=0
      case "${name}" in
        d*)
          # Directory: remove contents then RMD
          if ftp_rm_r "${parent}/${basename_name}"; then
            del_ok=1
          fi
          ;;
        *)
          # Regular file: single DELE
          if ftp_delete_file "${parent}/${basename_name}"; then
            del_ok=1
          fi
          ;;
      esac
      if [ "${del_ok}" -eq 1 ]; then
        log_info "  Retention: deleted /${parent}/${basename_name} (${date_str})"
      else
        failed=$((failed + 1))
        log_warn "  Retention: failed to delete /${parent}/${basename_name}"
      fi
    fi
  done <<< "${listing}"

  if [ "${matched}" -eq 0 ]; then
    log_warn "FTP retention: no YYYY-MM-DD folders found in /${parent}/ listing - nothing to clean."
  fi
}

# Retention dispatcher.
apply_retention() {
  local days="$1"
  local cutoff_epoch=$(( $(date +%s) - days * 86400 ))
  case "${STORAGE_TYPE}" in
    s3)
      retention_s3 "${cutoff_epoch}"
      ;;
    ftp|ftps)
      retention_ftp "${cutoff_epoch}"
      ;;
    sftp)
      log_warn "SFTP retention (RETENTION_DAYS) is not supported (curl cannot delete SFTP files); skipping."
      ;;
  esac
}

# Storage Dispatcher
upload_backup() {
  local local_path="$1"
  local file_name="$2"

  case "${STORAGE_TYPE}" in
    s3)
      backup_to_s3 "${local_path}" "${file_name}" "${S3_PATH_PREFIX}" "${S3_BUCKET}" "${BACKUP_FILE_SIZE}"
      ;;
    ftp|ftps)
      backup_to_ftp "${local_path}" "${file_name}" "${BACKUP_FILE_SIZE}"
      ;;
    sftp)
      backup_to_sftp "${local_path}" "${file_name}" "${BACKUP_FILE_SIZE}"
      ;;
    *)
      log_error "Unknown storage type: ${STORAGE_TYPE}"
      return 1
      ;;
  esac
}

# Send Telegram Notification
send_telegram() {
  local status="$1"
  local panel="$2"
  local file_name="$3"
  local file_size="$4"
  local duration="$5"
  local error_msg="${6:-}"

  if [ -z "${TELEGRAM_BOT_TOKEN}" ] || [ -z "${TELEGRAM_CHAT_ID}" ]; then
    return 0
  fi

  local icon="✅"
  local status_text="Berhasil"
  if [ "${status}" != "success" ]; then
    icon="❌"
    status_text="Gagal"
  fi

  local hostname
  hostname="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "Unknown")"
  local date_str
  date_str="$(date '+%Y-%m-%d %H:%M:%S')"

  local nl=$'\n'
  local message="━━━━━━━━━━━━━━━━━━━━━━━${nl}"
  message="${message}📦 <b>Hosting Backup Report</b>${nl}"
  message="${message}━━━━━━━━━━━━━━━━━━━━━━━${nl}"
  message="${message}📅 <b>Waktu:</b> ${date_str}${nl}"
  message="${message}🖥️ <b>Server:</b> ${hostname}${nl}"
  message="${message}👤 <b>User:</b> ${USERNAME}${nl}"
  message="${message}⚙️ <b>Panel:</b> ${panel}${nl}"
  message="${message}📊 <b>Status:</b> ${icon} ${status_text}${nl}"

  if [ "${status}" = "success" ]; then
    message="${message}📁 <b>File:</b> ${file_name}${nl}"
    message="${message}💾 <b>Ukuran:</b> ${file_size}${nl}"
    message="${message}☁️ <b>Storage:</b> ${STORAGE_TYPE^^}${nl}"
    message="${message}⏱️ <b>Durasi:</b> ${duration}${nl}"
  else
    message="${message}⚠️ <b>Error:</b> ${error_msg}${nl}"
    message="${message}⏱️ <b>Durasi:</b> ${duration}${nl}"
  fi
  message="${message}━━━━━━━━━━━━━━━━━━━━━━━"

  curl -s --connect-timeout 15 --max-time 30 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}" \
    -d "parse_mode=HTML" >/dev/null 2>&1 || true
}

# Wait Loop Shared Logic
# Polls for a backup archive created during THIS run, waits until its size is
# stable for STABLE_CHECKS consecutive polls, and sets BACKUP_FILE_* globals.
# Usage: wait_for_backup_archive <dir> <label> <guard_fn> <pattern>...
#   guard_fn: name of a function receiving the candidate path; returning 0
#             means "keep waiting" (e.g. cPanel still packaging). Pass "" for none.
wait_for_backup_archive() {
  local watch_dir="$1"
  local label="$2"
  local guard_fn="$3"
  shift 3
  local -a patterns=("$@")

  log_info "Waiting for backup archive in ${watch_dir}..."

  local start_time
  start_time="$(date +%s)"
  local deadline=$((start_time + BACKUP_TIMEOUT))
  local found_file=""
  local previous_size=-1
  local stable_count=0

  while [ "$(date +%s)" -lt "${deadline}" ]; do
    local candidate
    # Never fatal: a failed poll (e.g. mktemp failure) just skips this cycle
    candidate="$(find_newest_backup "${watch_dir}" "${patterns[@]}")" || true
    log_debug "Poll candidate: ${candidate:-<none>}"

    if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
      # Optional panel-specific "not ready yet" check (e.g. still packaging)
      if [ -n "${guard_fn}" ] && "${guard_fn}" "${candidate}"; then
        sleep "${POLL_INTERVAL}"
        continue
      fi

      local current_size
      current_size="$(get_file_size "${candidate}")"

      if ! is_uint "${current_size}"; then
        current_size=0
      fi

      if [ "${current_size}" -gt 0 ]; then
        if [ "${current_size}" -eq "${previous_size}" ]; then
          stable_count=$((stable_count + 1))
          log_info "  Archive size stable ($(format_bytes "${current_size}"), check ${stable_count}/${STABLE_CHECKS})..."
          if [ "${stable_count}" -ge "${STABLE_CHECKS}" ]; then
            found_file="${candidate}"
            break
          fi
        else
          stable_count=0
          log_info "  Writing backup archive: $(basename "${candidate}") ($(format_bytes "${current_size}"))..."
        fi
        previous_size="${current_size}"
      fi
    else
      log_info "  Waiting for ${label} to appear..."
    fi

    sleep "${POLL_INTERVAL}"
  done

  if [ -z "${found_file}" ] || [ ! -f "${found_file}" ]; then
    log_error "Backup timed out after ${BACKUP_TIMEOUT} seconds!"
    return 1
  fi

  # Final sanity: size must be readable and non-zero right before we proceed
  BACKUP_FILE_PATH="${found_file}"
  BACKUP_FILE_NAME="$(basename "${found_file}")"
  BACKUP_FILE_SIZE="$(get_file_size "${found_file}")"

  if ! is_uint "${BACKUP_FILE_SIZE}" || [ "${BACKUP_FILE_SIZE}" -le 0 ]; then
    log_error "Backup archive exists but has invalid size: ${BACKUP_FILE_PATH}"
    return 1
  fi

  log_success "Backup complete: ${BACKUP_FILE_NAME} ($(format_bytes "${BACKUP_FILE_SIZE}"))"
  return 0
}

# Guard callback for wait_for_backup_archive: cPanel keeps a directory next to
# the archive while packaging; while it exists the archive is not complete.
# Returns 0 (= keep waiting) while packaging, 1 when ready.
cpanel_still_packaging() {
  local candidate="$1"
  local file_base
  file_base="$(basename "${candidate}" .tar.gz)"

  if [ -d "${USER_HOME}/${file_base}" ]; then
    local current_size
    current_size="$(get_file_size "${candidate}")"
    log_info "  cPanel is still packaging backup directory (${file_base})... Size: $(format_bytes "${current_size}")"
    return 0
  fi
  return 1
}

# cPanel Backup Routine
run_cpanel_backup() {
  if ! command -v uapi >/dev/null 2>&1; then
    log_error "cPanel selected but 'uapi' command not found. Set PANEL_TYPE=cpanel/directadmin manually or run on the correct server."
    return 1
  fi

  log_info "Triggering cPanel backup via UAPI (Backup::fullbackup_to_homedir)..."

  local uapi_output
  uapi_output="$(uapi Backup fullbackup_to_homedir 2>&1)" || true
  log_info "cPanel response: ${uapi_output}"

  log_info "Waiting for cPanel backup archive to finish packaging in ${USER_HOME}..."

  # Poll using shared logic; cPanel creates a temp dir named like the archive
  # while packaging, which the guard + size-stability check handle naturally
  # because the .tar.gz only appears once packaging completes.
  wait_for_backup_archive "${USER_HOME}" "cPanel backup archive" cpanel_still_packaging \
    'backup-*.tar.gz' "*${USERNAME}*.tar.gz"
}

# DirectAdmin Backup Routine
run_directadmin_backup() {
  log_info "Triggering DirectAdmin user backup..."

  local backups_dir="${USER_HOME}/backups"
  mkdir -p "${backups_dir}" 2>/dev/null || true

  local da_triggered=false

  if [ -n "${DA_PASSWORD}" ]; then
    local scheme="https"
    [ "${DA_SSL}" = "false" ] && scheme="http"
    local da_url="${scheme}://${DA_HOST}:${DA_PORT}/CMD_API_SITE_BACKUP"

    if make_netrc "${DA_HOST}" "${USERNAME}" "${DA_PASSWORD}"; then
      log_info "Calling DirectAdmin API: ${da_url}"
      local da_response
      da_response="$(curl -s --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --netrc-file "${NETRC_FILE}" \
        -X POST "${da_url}" \
        -d "action=backup&select0=domain&select1=subdomain&select2=email&select3=forwarder&select4=autoresponder&select5=vacation&select6=list&select7=emailsettings&select8=ftp&select9=ftpsettings&select10=database&type=all" 2>&1)" || true

      log_info "DirectAdmin API Response: ${da_response}"
      da_triggered=true
    else
      log_warn "Could not prepare DirectAdmin API credentials, falling back to CLI."
    fi
  fi

  if [ "${da_triggered}" = "false" ]; then
    if command -v directadmin >/dev/null 2>&1; then
      log_info "Running DirectAdmin CLI command..."
      directadmin --backup 2>&1 || true
      da_triggered=true
    elif command -v da >/dev/null 2>&1; then
      log_info "Running 'da backup' command..."
      da backup 2>&1 || true
      da_triggered=true
    else
      log_error "No DirectAdmin trigger available: set DA_PASSWORD in .env or install the 'da'/'directadmin' CLI."
      return 1
    fi
  fi

  wait_for_backup_archive "${backups_dir}" "DirectAdmin backup archive" "" \
    'backup-*.tar.gz' 'backup-*.tar.zst' 'backup-*.tar.bz2' '*.tar.gz'
}

# Main Backup Process
main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        print_help
        exit 0
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      *)
        echo "Unknown option: $1" >&2
        print_help
        exit 1
        ;;
    esac
  done

  print_banner

  # Dependency check (also validates dry-run claims)
  check_dependencies || exit 1

  # Validate Storage Config
  validate_storage_config || exit 1

  # Detect Panel
  local detected_panel
  detected_panel="$(detect_panel)"

  if [ "${detected_panel}" != "cpanel" ] && [ "${detected_panel}" != "directadmin" ]; then
    log_error "Could not detect hosting panel (checked cPanel UAPI and DirectAdmin)."
    log_error "Set PANEL_TYPE=cpanel or PANEL_TYPE=directadmin explicitly in .env."
    exit 1
  fi

  log_info "Detected Panel: ${BOLD}${detected_panel^^}${NC}"
  log_info "User:           ${USERNAME}"
  log_info "Home Directory: ${USER_HOME}"
  log_info "Storage Type:   ${BOLD}${STORAGE_TYPE^^}${NC}"

  case "${STORAGE_TYPE}" in
    s3)
      log_info "S3 Endpoint:    ${S3_ENDPOINT}"
      log_info "S3 Bucket:      ${S3_BUCKET}"
      log_info "S3 Path:        ${S3_PATH_PREFIX}"
      log_info "S3 Signing:     ${S3_SIGN_VERSION^^} (region: ${S3_REGION})"
      ;;
    ftp|ftps)
      log_info "FTP Server:     ${FTP_HOST}:${FTP_PORT}"
      log_info "FTP Path:       ${FTP_PATH}"
      ;;
    sftp)
      log_info "SFTP Server:    ${SFTP_HOST}:${SFTP_PORT}"
      log_info "SFTP Path:      ${SFTP_PATH}"
      ;;
  esac

  # Dry Run Check
  if [ "${DRY_RUN}" = "true" ]; then
    log_success "Dry run completed successfully. Dependencies and configuration are valid."
    exit 0
  fi

  local overall_start_time
  overall_start_time="$(date +%s)"

  # Step 1: Execute Backup based on panel
  local backup_status=0
  if [ "${detected_panel}" = "directadmin" ]; then
    run_directadmin_backup || backup_status=1
  else
    run_cpanel_backup || backup_status=1
  fi

  if [ "${backup_status}" -ne 0 ]; then
    local duration=$(( $(date +%s) - overall_start_time ))
    log_error "Backup creation failed!"
    send_telegram "failed" "${detected_panel^^}" "" "" "$(format_duration "${duration}")" "Backup creation failed on panel."
    exit 1
  fi

  # Step 2: Upload / Transfer to Destination Remote Storage
  local upload_status=0
  upload_backup "${BACKUP_FILE_PATH}" "${BACKUP_FILE_NAME}" || upload_status=1

  if [ "${upload_status}" -ne 0 ]; then
    local duration=$(( $(date +%s) - overall_start_time ))
    log_error "Upload to storage (${STORAGE_TYPE^^}) failed!"
    send_telegram "failed" "${detected_panel^^}" "${BACKUP_FILE_NAME}" "$(format_bytes "${BACKUP_FILE_SIZE}")" "$(format_duration "${duration}")" "Storage upload failed."
    exit 1
  fi

  # Step 3: Retention cleanup (delete remote backups older than RETENTION_DAYS)
  if [ "${RETENTION_DAYS}" -gt 0 ]; then
    log_info "Applying retention: keeping backups newer than ${RETENTION_DAYS} day(s)."
    apply_retention "${RETENTION_DAYS}"
  fi

  # Step 4: Remove Local Backup Archive (only after VERIFIED upload)
  if [ "${DELETE_LOCAL}" = "true" ]; then
    log_info "Removing local temporary backup file to save disk space: ${BACKUP_FILE_PATH}"
    if rm -f -- "${BACKUP_FILE_PATH}"; then
      log_success "Local temporary backup file deleted."
    else
      log_warn "Could not delete local backup file (disk space will be reused later): ${BACKUP_FILE_PATH}"
    fi
  else
    log_info "Keeping local archive (DELETE_LOCAL=false): ${BACKUP_FILE_PATH}"
  fi

  # Step 5: Final Summary & Notification
  local total_duration=$(( $(date +%s) - overall_start_time ))
  local formatted_duration
  formatted_duration="$(format_duration "${total_duration}")"
  local formatted_size
  formatted_size="$(format_bytes "${BACKUP_FILE_SIZE}")"

  printf "\n${BOLD}${GREEN}====================================================${NC}\n"
  printf "${BOLD}${GREEN}       BACKUP COMPLETED SUCCESSFULLY!              ${NC}\n"
  printf "${BOLD}${GREEN}====================================================${NC}\n"
  printf "  • Panel:       %s\n" "${detected_panel^^}"
  printf "  • User:        %s\n" "${USERNAME}"
  printf "  • Storage:     %s\n" "${STORAGE_TYPE^^}"
  printf "  • File:        %s\n" "${BACKUP_FILE_NAME}"
  printf "  • Size:        %s\n" "${formatted_size}"
  printf "  • Destination: %s\n" "${DESTINATION_STR}"
  printf "  • Duration:    %s\n" "${formatted_duration}"
  printf "${BOLD}${GREEN}====================================================${NC}\n\n"

  send_telegram "success" "${detected_panel^^}" "${BACKUP_FILE_NAME}" "${formatted_size}" "${formatted_duration}"

  exit 0
}

# Only run when executed directly (allows sourcing for tests)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
