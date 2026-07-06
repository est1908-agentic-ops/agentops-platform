#!/usr/bin/env bash
#
# Configures Technitium DNS via its REST API so a hostname resolves inside
# the platform's internal zone — automates docs/DEPLOY.md's Phase 3.2
# "Configure Technitium DNS" manual step (creating the `lab` zone and an A
# record for `temporal.lab`).
#
# Idempotent: safe to re-run. Skips zone creation if the zone already
# exists, and skips/updates the A record so it always converges on
# --target-ip (uses Technitium's `overwrite=true` add-record option, so a
# stale IP from a previous run gets replaced rather than duplicated).
#
# Requires: curl, jq.
#
# API reference: https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md
#
# Usage:
#   kubectl port-forward -n technitium svc/technitium 5380:5380 &
#   TECHNITIUM_TOKEN=<token> ./scripts/configure-technitium-dns.sh --target-ip 10.0.0.5
#
#   # or authenticate with the admin password and mint a reusable token:
#   TECHNITIUM_USER=admin TECHNITIUM_PASSWORD=<password> \
#     ./scripts/configure-technitium-dns.sh --target-ip 10.0.0.5 --print-token
#
set -euo pipefail

readonly ZONE_TYPE="Primary"
readonly DEFAULT_URL="http://localhost:5380"
readonly DEFAULT_ZONE="lab"
readonly DEFAULT_RECORD="temporal.lab"
readonly DEFAULT_TTL="3600"
readonly DEFAULT_TOKEN_NAME="agentops-platform-dns-script"
readonly CURL_CONNECT_TIMEOUT="10"
readonly CURL_MAX_TIME="30"

TECHNITIUM_URL="${TECHNITIUM_URL:-${DEFAULT_URL}}"
ZONE="${ZONE:-${DEFAULT_ZONE}}"
RECORD_NAME="${RECORD_NAME:-${DEFAULT_RECORD}}"
TARGET_IP="${TARGET_IP:-}"
TTL="${TTL:-${DEFAULT_TTL}}"
TOKEN_NAME="${DEFAULT_TOKEN_NAME}"
PRINT_TOKEN=0
AUTH_TOKEN=""

log() {
  echo "[technitium-dns] $*" >&2
}

usage() {
  cat <<EOF
Usage: configure-technitium-dns.sh --target-ip <ip> [options]

Idempotently configures Technitium DNS: creates the target zone if it
doesn't exist, then creates/updates an A record so it points at --target-ip.

Options:
  --target-ip <ip>     IP address the record should point at (required).
                        Typically Traefik's external/node IP:
                          kubectl get svc -n kube-system traefik
  --zone <name>         Zone to create/use (default: ${DEFAULT_ZONE}).
  --record <fqdn>       Record name to create/update (default: ${DEFAULT_RECORD}).
  --url <url>           Technitium base URL (default: ${DEFAULT_URL}).
                        Requires a reachable API, e.g. via:
                          kubectl port-forward -n technitium svc/technitium 5380:5380
  --ttl <seconds>       TTL for the A record (default: ${DEFAULT_TTL}).
  --print-token         After authenticating with TECHNITIUM_USER/PASSWORD,
                        create and print a non-expiring API token (named
                        --token-name) so future runs can use TECHNITIUM_TOKEN
                        instead of the admin password.
  --token-name <name>   Name for the token created by --print-token
                        (default: ${DEFAULT_TOKEN_NAME}).
  -h, --help            Show this help.

Authentication (env vars only — never pass credentials as flags):
  TECHNITIUM_TOKEN      Pre-created non-expiring API token (preferred).
  TECHNITIUM_USER       Admin username (used if TECHNITIUM_TOKEN is unset).
  TECHNITIUM_PASSWORD   Admin password (used if TECHNITIUM_TOKEN is unset).
  TECHNITIUM_TOTP       Optional TOTP code, if 2FA is enabled on the account.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-ip)
      TARGET_IP="$2"
      shift 2
      ;;
    --zone)
      ZONE="$2"
      shift 2
      ;;
    --record)
      RECORD_NAME="$2"
      shift 2
      ;;
    --url)
      TECHNITIUM_URL="$2"
      shift 2
      ;;
    --ttl)
      TTL="$2"
      shift 2
      ;;
    --print-token)
      PRINT_TOKEN=1
      shift
      ;;
    --token-name)
      TOKEN_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

check_dependencies() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "ERROR: missing required commands: ${missing[*]}"
    exit 1
  fi
}

validate_inputs() {
  if [[ -z "${TARGET_IP}" ]]; then
    log "ERROR: --target-ip (or TARGET_IP env var) is required"
    usage >&2
    exit 1
  fi
  # Basic sanity check, not full RFC validation — just catches obvious typos
  # like passing a hostname instead of an IP.
  if ! [[ "${TARGET_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    log "ERROR: --target-ip '${TARGET_IP}' does not look like an IPv4 address"
    exit 1
  fi
  if [[ -z "${TECHNITIUM_TOKEN:-}" ]] && { [[ -z "${TECHNITIUM_USER:-}" ]] || [[ -z "${TECHNITIUM_PASSWORD:-}" ]]; }; then
    log "ERROR: set TECHNITIUM_TOKEN, or both TECHNITIUM_USER and TECHNITIUM_PASSWORD"
    exit 1
  fi
  case "${RECORD_NAME}" in
    "${ZONE}"|*".${ZONE}")
      ;;
    *)
      log "WARNING: record '${RECORD_NAME}' does not look like it belongs to zone '${ZONE}'"
      ;;
  esac
}

# URL-encodes the value of the named environment variable for use in an
# application/x-www-form-urlencoded request body. Takes the variable's NAME
# (e.g. "TECHNITIUM_PASSWORD"), not its value, and has jq read the actual
# value out of its own inherited environment (`env[$name]`) — so the secret
# itself never appears as a jq/curl process argument, where it would be
# visible to other users on the box via `ps`/`/proc/<pid>/cmdline`.
url_encode_env() {
  jq -rn --arg name "$1" '(env[$name] // "") | @uri'
}

# Performs a GET request against the Technitium API. Query params are passed
# as additional "key=value" arguments and URL-encoded by curl. Adds the
# Authorization header once AUTH_TOKEN has been set by authenticate().
#
# Not used for the login call: login credentials must never be passed as
# curl arguments (visible via `ps`) or as a GET query string (may be
# logged/cached by intermediaries) — see authenticate().
td_request() {
  local path="$1"
  shift
  local curl_args=(-sS -G --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" "${TECHNITIUM_URL}${path}")
  local kv
  for kv in "$@"; do
    curl_args+=(--data-urlencode "${kv}")
  done
  if [[ -n "${AUTH_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${AUTH_TOKEN}")
  fi
  curl "${curl_args[@]}"
}

# Checks a Technitium JSON response for status=="ok" (Technitium reports API
# errors as HTTP 200 with a JSON "status" field, not HTTP error codes) and
# exits with a clear error otherwise. On success, prints the raw response on
# stdout. Split out from td_call so authenticate() can reuse the same
# error-handling for its POST-based login request.
td_check_response() {
  local context="$1" response="$2"
  local status
  status="$(jq -r '.status // "unknown"' <<<"${response}" 2>/dev/null || echo "unknown")"
  if [[ "${status}" != "ok" ]]; then
    log "ERROR: ${context} failed (status=${status})"
    if [[ "${status}" == "2fa-required" ]]; then
      log "Account has 2FA enabled — pass TECHNITIUM_TOTP, or authenticate with TECHNITIUM_TOKEN instead"
    fi
    log "$(jq -r '.errorMessage // "(no errorMessage in response)"' <<<"${response}" 2>/dev/null || true)"
    log "Raw response: ${response}"
    exit 1
  fi
  printf '%s' "${response}"
}

# Wraps td_request with td_check_response's transport- and API-level error
# handling.
td_call() {
  local path="$1" context="$2"
  shift 2
  local response
  if ! response="$(td_request "${path}" "$@")"; then
    log "ERROR: request for ${context} failed (could not reach ${TECHNITIUM_URL}${path})"
    exit 1
  fi
  td_check_response "${context}" "${response}"
}

authenticate() {
  if [[ -n "${TECHNITIUM_TOKEN:-}" ]]; then
    log "Using TECHNITIUM_TOKEN for authentication"
    AUTH_TOKEN="${TECHNITIUM_TOKEN}"
    return
  fi

  log "Logging in to Technitium as '${TECHNITIUM_USER}' at ${TECHNITIUM_URL}"

  # Built and sent as a POST body over stdin (--data-binary @-), never as
  # curl arguments or a GET query string, so the password/TOTP never appear
  # in this process's argv or in any URL an intermediary might log or cache.
  local body
  body="user=$(url_encode_env TECHNITIUM_USER)&pass=$(url_encode_env TECHNITIUM_PASSWORD)"
  [[ -n "${TECHNITIUM_TOTP:-}" ]] && body+="&totp=$(url_encode_env TECHNITIUM_TOTP)"

  local response
  if ! response="$(printf '%s' "${body}" | curl -sS -X POST --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" --data-binary @- "${TECHNITIUM_URL}/api/user/login")"; then
    log "ERROR: request for login failed (could not reach ${TECHNITIUM_URL}/api/user/login)"
    exit 1
  fi
  response="$(td_check_response "login" "${response}")"

  AUTH_TOKEN="$(jq -r '.token // empty' <<<"${response}")"
  if [[ -z "${AUTH_TOKEN}" ]]; then
    log "ERROR: login succeeded but response contained no token"
    exit 1
  fi
  log "Authenticated as '${TECHNITIUM_USER}'"
}

create_persistent_token() {
  [[ "${PRINT_TOKEN}" -eq 1 ]] || return 0

  log "Creating persistent API token '${TOKEN_NAME}'"
  local response token
  response="$(td_call /api/user/createToken "create API token" "tokenName=${TOKEN_NAME}")"
  token="$(jq -r '.token // empty' <<<"${response}")"
  log "Created API token '${TOKEN_NAME}'. Store it, then reuse it instead of the admin password:"
  log "  export TECHNITIUM_TOKEN=${token}"
}

ensure_zone() {
  log "Checking whether zone '${ZONE}' exists"
  local response exists
  response="$(td_call /api/zones/list "list zones" "filterName=${ZONE}")"
  exists="$(jq -r --arg zone "${ZONE}" \
    '[.response.zones[]? | select(.name == $zone)] | length' <<<"${response}")"

  if [[ "${exists}" -gt 0 ]]; then
    log "Zone '${ZONE}' already exists, skipping creation"
    return
  fi

  log "Creating ${ZONE_TYPE} zone '${ZONE}'"
  td_call /api/zones/create "create zone" "zone=${ZONE}" "type=${ZONE_TYPE}" >/dev/null
  log "Zone '${ZONE}' created"
}

ensure_record() {
  log "Checking existing A records for '${RECORD_NAME}' in zone '${ZONE}'"
  local response already_correct
  response="$(td_call /api/zones/records/get "get records" \
    "domain=${RECORD_NAME}" "zone=${ZONE}")"
  already_correct="$(jq -r --arg ip "${TARGET_IP}" \
    '[.response.records[]? | select(.type == "A" and .rData.ipAddress == $ip)] | length' \
    <<<"${response}")"

  if [[ "${already_correct}" -gt 0 ]]; then
    log "A record ${RECORD_NAME} -> ${TARGET_IP} already present, skipping"
    return
  fi

  log "Setting A record ${RECORD_NAME} -> ${TARGET_IP} (ttl=${TTL})"
  # overwrite=true replaces the whole A record set for this name, so this
  # converges correctly even if a *different* stale IP was set previously.
  td_call /api/zones/records/add "add record" \
    "domain=${RECORD_NAME}" "zone=${ZONE}" "type=A" \
    "ipAddress=${TARGET_IP}" "ttl=${TTL}" "overwrite=true" >/dev/null
  log "A record ${RECORD_NAME} -> ${TARGET_IP} set"
}

main() {
  check_dependencies
  validate_inputs
  authenticate
  create_persistent_token
  ensure_zone
  ensure_record
  log "Done. '${RECORD_NAME}' resolves to ${TARGET_IP} via zone '${ZONE}' on ${TECHNITIUM_URL}."
  log "Point your workstation/router DNS at Technitium for '*.${ZONE}' if you haven't already (docs/BOOTSTRAP.md step 6)."
}

main "$@"
