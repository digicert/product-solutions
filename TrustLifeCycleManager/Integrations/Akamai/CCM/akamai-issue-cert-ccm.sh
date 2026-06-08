#!/usr/bin/env bash

: <<'LEGAL_NOTICE'
Legal Notice (version January 1, 2026)
Copyright © 2026 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.
THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS,
REPRESENTATIONS AND WARRANTIES, INCLUDING ANY IMPLIED WARRANTY OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO
BE LEGALLY INVALID.
LEGAL_NOTICE

# ============================================================================
# LEGAL NOTICE ACCEPTANCE
# Set to "true" to accept the legal notice and allow script execution.
# ============================================================================
LEGAL_NOTICE_ACCEPT="true"

if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    echo "ERROR: Legal notice not accepted."
    echo "Set LEGAL_NOTICE_ACCEPT=\"true\" in this script to proceed."
    echo "Please review the legal notice at the top of the script before accepting."
    exit 1
fi

# =============================================================================
# akamai-ccm-issuance.sh  v1.1.6
#
# Full certificate lifecycle:
#   1. Generate CSR  →  POST /ccm/v1/certificates
#   2. Issue cert    →  POST TLM /mpki/api/v1/certificate
#   3. Validate      →  POST /ccm/v1/certificates/validate
#   4. Upload/ack    →  PUT  /ccm/v1/certificates/{id}
#
# Authentication: Akamai EdgeGrid via httpie-edgegrid.
#   All CCM calls use the colon-path shorthand  :/path
#   so httpie signs requests against the .edgerc host automatically.
#   The CCM API host IS the EdgeGrid host (akab-xxx.luna.akamaiapis.net),
#   NOT control.akamai.com (that is the browser UI only).
#
# Requires: httpie + httpie-edgegrid plugin, jq, curl
#   pip install httpie httpie-edgegrid   (or: pipx install httpie && pipx inject httpie httpie-edgegrid)
# =============================================================================

# set -euo pipefail
SCRIPT_VERSION="1.1.6"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

print_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" >&2; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_debug()   { echo -e "${BLUE}[DEBUG]${NC} $*"; }
print_header()  {
    echo
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
}
die() { print_error "$*"; exit 1; }

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in http jq curl; do
    command -v "$cmd" &>/dev/null || die \
        "'$cmd' is required but not installed.
  Install httpie:          pip install httpie   OR  pipx install httpie
  Install httpie-edgegrid: pip install httpie-edgegrid  OR  pipx inject httpie httpie-edgegrid
  Install jq:              brew install jq  (macOS)  or  apt install jq  (Linux)
  Install curl:            brew install curl (macOS)  or  apt install curl (Linux)"
done

# Verify httpie-edgegrid plugin is actually available
if ! http --help 2>&1 | grep -qi edgegrid && \
   ! python3 -c "import httpie_edgegrid" 2>/dev/null; then
    die "httpie-edgegrid plugin not found.
  Install with: pip install httpie-edgegrid
  Or with pipx: pipx inject httpie httpie-edgegrid"
fi

# ============================================================================
# DEFAULT CONFIGURATION
# Edit these values so you can press Enter through the prompts.
# Secrets marked <VALUE> will always require manual input.
# ============================================================================

# --- Akamai EdgeGrid ---
# IMPORTANT: host is your akab-xxxx.luna.akamaiapis.net value from Control Center.
# This IS the CCM API host. Do NOT use control.akamai.com here.
DEFAULT_EDGEGRID_HOST="<AKAMAI_EDGEGRID_HOST>"   # e.g. akab-z7o4fjt5s6vqcl4s-kqxpbtjcf5pqh6bm.luna.akamaiapis.net
DEFAULT_CLIENT_SECRET="<CLIENT_SECRET>"
DEFAULT_ACCESS_TOKEN="<ACCESS_TOKEN>"
DEFAULT_CLIENT_TOKEN="<CLIENT_TOKEN>"
DEFAULT_EDGERC_SECTION="default"

# --- Akamai CCM Account ---
DEFAULT_CONTRACT_ID="<CONTRACT_ID>"              # e.g. V-6DMZ2TY
DEFAULT_GROUP_ID="<GROUP_ID>"                    # e.g. 311210

# --- Certificate Subject ---
DEFAULT_CERT_CN="digicert-demo.com"
DEFAULT_CERT_ORG="DigiCert"
DEFAULT_CERT_OU="Product"
DEFAULT_CERT_LOCALITY="Lehi"
DEFAULT_CERT_STATE="Utah"
DEFAULT_CERT_COUNTRY="US"

# --- Akamai CCM Certificate Options ---
DEFAULT_KEY_TYPE="RSA"
DEFAULT_KEY_SIZE="2048"
DEFAULT_SECURE_NETWORK="ENHANCED_TLS"

# --- DigiCert TLM ---
DEFAULT_TLM_BASE_URL="https://one.digicert.com"
DEFAULT_TLM_API_KEY="<TLM_API_KEY>"
DEFAULT_TLM_PROFILE_ID="<PROFILE_UUID>"          # e.g. 72f452d4-f266-4bee-b6d3-e03f8c6c807f
DEFAULT_TLM_SEAT_ID=""                           # defaults to CN if blank

# --- Storage ---
DEFAULT_CERT_DIR="$HOME/akamai-ccm-certs"

# ============================================================================
# END OF DEFAULT CONFIGURATION
# ============================================================================

# ── Prompt helpers ────────────────────────────────────────────────────────────
prompt_with_default() {
    local label="$1" default="$2" input
    # If default starts with < it's a placeholder — treat as no default
    if [ -n "$default" ] && [[ "$default" != "<"* ]]; then
        read -r -p "$(echo -e "${BOLD}${label}${NC} [${default}]: ")" input
        echo "${input:-$default}"
    else
        local val=""
        while [ -z "$val" ]; do
            read -r -p "$(echo -e "${BOLD}${label}${NC}: ")" val
            [ -z "$val" ] && print_warning "This field is required."
        done
        echo "$val"
    fi
}

prompt_secret() {
    local label="$1" val=""
    while [ -z "$val" ]; do
        printf "%b" "${BOLD}${label}${NC}: " >&2
        IFS= read -r -s val
        printf '\n' >&2
        [ -z "$val" ] && print_warning "This field is required."
    done
    printf '%s' "$val"
}

# ── akamai_http: wrapper for all CCM API calls ────────────────────────────────
# Uses the httpie-edgegrid colon-path shorthand so the host is always taken
# from .edgerc and the signature is computed against it correctly.
#
# Usage: akamai_http <METHOD> <PATH> [extra httpie args...]
#   PATH must start with /  e.g.  /ccm/v1/certificates
#
akamai_http() {
    local method="$1"
    local path="$2"
    shift 2
    # :/path  =  colon-path shorthand: httpie fills in https://<edgerc_host>
    http --auth-type edgegrid -a "${EDGERC_SECTION}": \
        "$method" ":${path}" \
        "$@"
}

normalize_base_url() {
    local url="$1"
    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done
    echo "$url"
}

tlm_request() {
    local method="$1"
    local url="$2"
    local body_file="$3"
    local response_file="$4"
    local stderr_file="$5"
    local meta_file="$6"
    local request_body=""
    local curl_args=(
        --location
        --silent
        --show-error
        --connect-timeout 15
        --max-time 60
        --write-out $'http_code=%{http_code}\nhttp_version=%{http_version}\nremote_ip=%{remote_ip}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nssl_verify_result=%{ssl_verify_result}\n'
        --output "$response_file"
        -H "Content-Type: application/json"
        -H "x-api-key: ${TLM_API_KEY}"
    )

    if [ -n "$body_file" ]; then
        request_body=$(< "$body_file")
        curl_args+=(--data "$request_body")
    else
        curl_args+=(-X "$method")
    fi

    curl "${curl_args[@]}" "$url" > "$meta_file" 2>"$stderr_file"
}

tlm_http_status() {
    awk -F= '$1 == "http_code" { print $2 }' "$1" 2>/dev/null
}

print_tlm_diagnostics() {
    local response_file="$1"
    local stderr_file="$2"
    local meta_file="$3"

    [ -s "$stderr_file" ] && { print_error "curl error:"; cat "$stderr_file" >&2; }
    [ -s "$meta_file" ] && { print_error "curl metadata:"; sed 's/^/  /' "$meta_file" >&2; }
    [ -s "$response_file" ] && { print_error "Response body:"; cat "$response_file" >&2; }
}

write_tlm_debug_artifacts() {
    local endpoint="$1"
    local request_file="$2"
    local replay_file="$3"
    local file_replay_file="$4"
    local summary_file="$5"
    local request_sha256="unavailable"
    local csr_sha256="unavailable"

    if command -v shasum &>/dev/null; then
        request_sha256=$(shasum -a 256 "$request_file" | awk '{print $1}')
        csr_sha256=$(jq -r '.csr // empty' "$request_file" | shasum -a 256 | awk '{print $1}')
    elif command -v sha256sum &>/dev/null; then
        request_sha256=$(sha256sum "$request_file" | awk '{print $1}')
        csr_sha256=$(jq -r '.csr // empty' "$request_file" | sha256sum | awk '{print $1}')
    fi

    jq \
        --arg endpoint "$endpoint" \
        --arg requestFile "$request_file" \
        --arg requestSha256 "$request_sha256" \
        --arg csrSha256 "$csr_sha256" \
        '{
            endpoint: $endpoint,
            request_file: $requestFile,
            request_sha256: $requestSha256,
            profile_id: .profile.id,
            seat_id: .seat.seat_id,
            subject_common_name: .attributes.subject.common_name,
            include_ca_chain: .include_ca_chain,
            include_ca_chain_type: (.include_ca_chain | type),
            csr_sha256: $csrSha256,
            csr_length: (.csr | length),
            csr_line_count: (.csr | split("\n") | length),
            csr_first_line: (.csr | split("\n")[0]),
            csr_last_non_empty_line: (.csr | split("\n") | map(select(length > 0)) | .[-1]),
            extensions: .attributes.extensions
        }' "$request_file" > "$summary_file"

    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo ': "${TLM_API_KEY:?Set TLM_API_KEY to replay this request}"'
        printf 'REQUEST_JSON=$(< %q)\n' "$request_file"
        printf 'curl --location %q \\\n' "$endpoint"
        echo "  --header 'Content-Type: application/json' \\"
        echo '  --header "x-api-key: ${TLM_API_KEY}" \'
        echo '  --data "$REQUEST_JSON"'
    } > "$replay_file"
    chmod 700 "$replay_file"

    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        echo ': "${TLM_API_KEY:?Set TLM_API_KEY to replay this request}"'
        printf 'curl --location %q \\\n' "$endpoint"
        echo "  --header 'Content-Type: application/json' \\"
        echo '  --header "x-api-key: ${TLM_API_KEY}" \'
        printf '  --data @%q\n' "$request_file"
    } > "$file_replay_file"
    chmod 700 "$file_replay_file"
}

print_tlm_request_summary() {
    local summary_file="$1"

    jq -r '
        "  endpoint            : \(.endpoint)",
        "  profile_id          : \(.profile_id)",
        "  seat_id             : \(.seat_id)",
        "  subject_common_name : \(.subject_common_name)",
        "  include_ca_chain    : \(.include_ca_chain) (\(.include_ca_chain_type))",
        "  csr_length          : \(.csr_length)",
        "  csr_line_count      : \(.csr_line_count)",
        "  csr_first_line      : \(.csr_first_line)",
        "  csr_last_line       : \(.csr_last_non_empty_line)",
        "  csr_sha256          : \(.csr_sha256)",
        "  request_sha256      : \(.request_sha256)"
    ' "$summary_file" 2>/dev/null || true
}

print_tlm_key_diagnostics() {
    local key="$1"
    local source="${2:-prompt}"
    local key_len=${#key}

    print_info "TLM API key accepted from ${source} (${key_len} characters, hidden)."

    if printf '%s' "$key" | LC_ALL=C grep -q '[[:space:]]'; then
        print_warning "TLM API key contains whitespace inside the value."
    fi

    case "$key" in
        \"*|*\"|\'*|*\')
            print_warning "TLM API key appears to include a quote character at the beginning or end."
            ;;
    esac
}

print_certificate_summary() {
    local cert_file="$1"
    local cert_name="$2"

    echo "  Certificate name : $cert_name"

    if command -v openssl &>/dev/null && [ -s "$cert_file" ]; then
        local subject issuer not_before not_after serial fingerprint

        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/^subject=//')
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
        not_before=$(openssl x509 -in "$cert_file" -noout -startdate 2>/dev/null | sed 's/^notBefore=//')
        not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
        serial=$(openssl x509 -in "$cert_file" -noout -serial 2>/dev/null | sed 's/^serial=//')
        fingerprint=$(openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//')

        echo "  Subject          : ${subject:-n/a}"
        echo "  Issuer           : ${issuer:-n/a}"
        echo "  Valid from       : ${not_before:-n/a}"
        echo "  Valid to         : ${not_after:-n/a}"
        echo "  Serial           : ${serial:-n/a}"
        echo "  SHA256 fingerprint: ${fingerprint:-n/a}"
    else
        jq -r '
            "  Serial           : \(.serial_number // "n/a")",
            "  Delivery format  : \(.delivery_format // "n/a")"
        ' "$TLM_RESPONSE_FILE" 2>/dev/null || true
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
clear
print_info "Akamai CCM Certificate Issuance Script v${SCRIPT_VERSION}"
echo

# ============================================================================
# STEP 1: Storage location
# ============================================================================
print_header "Storage Configuration"

CERT_STORAGE_DIR=$(prompt_with_default "Certificate storage directory" "$DEFAULT_CERT_DIR")
mkdir -p "$CERT_STORAGE_DIR"
print_info "Storage directory: $CERT_STORAGE_DIR"

# ============================================================================
# STEP 2: EdgeGrid credentials
# ============================================================================
print_header "Akamai EdgeGrid Credentials"

echo -e "${YELLOW}NOTE: The EdgeGrid host (akab-xxx.luna.akamaiapis.net) is the CCM API host.${NC}"
echo -e "${YELLOW}      Do NOT use control.akamai.com — that is the browser UI only.${NC}"
echo

EDGEGRID_HOST=$(prompt_with_default "Akamai EdgeGrid host (from .edgerc / API client)" "$DEFAULT_EDGEGRID_HOST")
CLIENT_SECRET=$(prompt_with_default  "client_secret"  "$DEFAULT_CLIENT_SECRET")
ACCESS_TOKEN=$(prompt_with_default   "access_token"   "$DEFAULT_ACCESS_TOKEN")
CLIENT_TOKEN=$(prompt_with_default   "client_token"   "$DEFAULT_CLIENT_TOKEN")
EDGERC_SECTION=$(prompt_with_default "EdgeGrid section name" "$DEFAULT_EDGERC_SECTION")

# Write .edgerc — remove existing section cleanly then append
EDGERC_PATH="$HOME/.edgerc"
print_info "Writing EdgeGrid config to $EDGERC_PATH (section: [${EDGERC_SECTION}])..."

if [ -f "$EDGERC_PATH" ]; then
    python3 - "$EDGERC_PATH" "$EDGERC_SECTION" <<'PY' 2>/dev/null || true
import sys, re
path, section = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
pattern = r'\[' + re.escape(section) + r'\][^\[]*'
content = re.sub(pattern, '', content, flags=re.DOTALL).strip()
with open(path, 'w') as f:
    f.write(content + '\n' if content else '')
PY
fi

cat >> "$EDGERC_PATH" << EOF

[${EDGERC_SECTION}]
client_secret = ${CLIENT_SECRET}
host = ${EDGEGRID_HOST}
access_token = ${ACCESS_TOKEN}
client_token = ${CLIENT_TOKEN}
EOF
chmod 600 "$EDGERC_PATH"
print_info "EdgeGrid configuration written."

echo
print_info "Verifying EdgeGrid authentication with a test call..."
TEST_RESPONSE_FILE="$CERT_STORAGE_DIR/auth_test.json"
if akamai_http GET "/identity-management/v3/user-profile" \
    --body > "$TEST_RESPONSE_FILE" 2>&1; then
    TEST_EMAIL=$(jq -r '.email // .login // empty' "$TEST_RESPONSE_FILE" 2>/dev/null || true)
    if [ -n "$TEST_EMAIL" ]; then
        print_info "✓ EdgeGrid auth verified — logged in as: $TEST_EMAIL"
    else
        print_info "✓ EdgeGrid auth call succeeded (200 OK)"
    fi
else
    print_warning "Auth test call returned non-200. Checking response..."
    if jq -e '.code' "$TEST_RESPONSE_FILE" &>/dev/null 2>&1; then
        TEST_ERR=$(jq -r '.title // .detail // .code' "$TEST_RESPONSE_FILE")
        print_warning "Response: $TEST_ERR"
        print_warning "Continuing anyway — this may fail if credentials are wrong."
    fi
fi

# CCM account settings
echo
CONTRACT_ID=$(prompt_with_default "Contract ID"  "$DEFAULT_CONTRACT_ID")
GROUP_ID=$(prompt_with_default    "Group ID"      "$DEFAULT_GROUP_ID")

# ============================================================================
# STEP 3: Certificate subject & options
# ============================================================================
print_header "Certificate Details"

CERT_CN=$(prompt_with_default       "Common Name (CN)"             "$DEFAULT_CERT_CN")
CERT_ORG=$(prompt_with_default      "Organization (O)"             "$DEFAULT_CERT_ORG")
CERT_OU=$(prompt_with_default       "Organizational Unit (OU)"     "$DEFAULT_CERT_OU")
CERT_LOCALITY=$(prompt_with_default "Locality / City (L)"          "$DEFAULT_CERT_LOCALITY")
CERT_STATE=$(prompt_with_default    "State (ST)"                   "$DEFAULT_CERT_STATE")
CERT_COUNTRY=$(prompt_with_default  "Country (2-letter, C)"        "$DEFAULT_CERT_COUNTRY")

echo
print_info "--- Subject Alternative Names ---"
print_info "The Common Name ($CERT_CN) is included automatically."
print_info "Enter additional SANs one per line. Press Enter on a blank line when done."
echo

SAN_LIST=("$CERT_CN")
SAN_INDEX=1
while true; do
    read -r -p "  SAN $SAN_INDEX (blank to finish): " san_entry
    san_entry=$(echo "$san_entry" | xargs 2>/dev/null || true)
    [ -z "$san_entry" ] && break
    [ "$san_entry" != "$CERT_CN" ] && SAN_LIST+=("$san_entry")
    SAN_INDEX=$((SAN_INDEX + 1))
done

print_info "SANs configured (${#SAN_LIST[@]}):"
for s in "${SAN_LIST[@]}"; do echo "   • $s"; done
echo

# Build JSON array of SANs — piped through jq so all chars are safely escaped
SANS_JSON=$(printf '%s\n' "${SAN_LIST[@]}" | jq -R . | jq -cs .)
print_debug "SANS_JSON: $SANS_JSON"

echo
print_info "--- Akamai CCM Certificate Options ---"
KEY_TYPE=$(prompt_with_default       "Key type"       "$DEFAULT_KEY_TYPE")
KEY_SIZE=$(prompt_with_default       "Key size"       "$DEFAULT_KEY_SIZE")
SECURE_NETWORK=$(prompt_with_default "Secure network" "$DEFAULT_SECURE_NETWORK")
default_cert_name="${CERT_CN//./-}"
CERT_NAME=$(prompt_with_default "Certificate name (CCM label)" "$default_cert_name")

# ============================================================================
# STEP 4: DigiCert TLM credentials
# ============================================================================
print_header "DigiCert TLM Credentials"

TLM_BASE_URL=$(prompt_with_default   "TLM base URL"        "$DEFAULT_TLM_BASE_URL")
TLM_BASE_URL=$(normalize_base_url "$TLM_BASE_URL")
if [ -n "${TLM_API_KEY:-}" ]; then
    TLM_API_KEY_SOURCE="environment"
    print_info "Using TLM x-api-key from environment (hidden)."
else
    TLM_API_KEY_SOURCE="prompt"
    TLM_API_KEY=$(prompt_secret                            "TLM x-api-key (hidden)")
fi
TLM_API_KEY_TRIMMED=$(printf '%s' "$TLM_API_KEY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ "$TLM_API_KEY" != "$TLM_API_KEY_TRIMMED" ]; then
    print_warning "Trimmed leading/trailing whitespace from TLM API key."
    TLM_API_KEY="$TLM_API_KEY_TRIMMED"
fi
print_tlm_key_diagnostics "$TLM_API_KEY" "$TLM_API_KEY_SOURCE"
TLM_PROFILE_ID=$(prompt_with_default "TLM Profile ID (UUID)" "$DEFAULT_TLM_PROFILE_ID")
default_seat="${DEFAULT_TLM_SEAT_ID:-$CERT_CN}"
TLM_SEAT_ID=$(prompt_with_default    "TLM Seat ID"          "$default_seat")
print_info "TLM base URL: $TLM_BASE_URL"

# ============================================================================
# STEP 5: Generate CSR in Akamai CCM
# ============================================================================
print_header "Step 1 — Generate CSR in Akamai CCM"

CSR_PAYLOAD=$(jq -n \
    --arg  certName      "$CERT_NAME" \
    --arg  keyType       "$KEY_TYPE" \
    --arg  keySize       "$KEY_SIZE" \
    --arg  secureNetwork "$SECURE_NETWORK" \
    --arg  cn            "$CERT_CN" \
    --arg  org           "$CERT_ORG" \
    --arg  ou            "$CERT_OU" \
    --arg  loc           "$CERT_LOCALITY" \
    --arg  st            "$CERT_STATE" \
    --arg  c             "$CERT_COUNTRY" \
    --argjson sans       "$SANS_JSON" \
    '{
        certificateName: $certName,
        certificateType: "THIRD_PARTY",
        keyType:         $keyType,
        keySize:         $keySize,
        secureNetwork:   $secureNetwork,
        sans:            $sans,
        subject: {
            commonName:         $cn,
            organization:       $org,
            organizationalUnit: $ou,
            locality:           $loc,
            state:              $st,
            country:            $c
        }
    }')

CSR_REQUEST_FILE="$CERT_STORAGE_DIR/${CERT_CN}_ccm_csr_request.json"
echo "$CSR_PAYLOAD" > "$CSR_REQUEST_FILE"
print_info "CSR request JSON saved: $CSR_REQUEST_FILE"
print_debug "Calling: POST /ccm/v1/certificates?contractId=${CONTRACT_ID}&groupId=${GROUP_ID}"

print_info "Submitting CSR creation request to Akamai CCM..."
CSR_RESPONSE_FILE="$CERT_STORAGE_DIR/${CERT_CN}_ccm_csr_response.json"

if ! akamai_http POST \
    "/ccm/v1/certificates?contractId=${CONTRACT_ID}&groupId=${GROUP_ID}" \
    Content-Type:'application/json' \
    < "$CSR_REQUEST_FILE" \
    --body > "$CSR_RESPONSE_FILE" 2>&1; then
    print_error "HTTPie returned non-zero. Response:"
    cat "$CSR_RESPONSE_FILE"
    die "CSR creation request failed."
fi

# API-level error check — CCM errors include a .code or .title field
if jq -e '.code // .type // .title' "$CSR_RESPONSE_FILE" &>/dev/null 2>&1; then
    ERROR_DETAIL=$(jq -r '.detail // .title // .code // "Unknown error"' "$CSR_RESPONSE_FILE")
    print_error "Full response:"
    cat "$CSR_RESPONSE_FILE"
    die "Akamai CCM returned an error: $ERROR_DETAIL"
fi

CERTIFICATE_ID=$(jq -r '.certificateId'     "$CSR_RESPONSE_FILE")
CSR_PEM=$(jq -r        '.csrPem'            "$CSR_RESPONSE_FILE")
CSR_STATUS=$(jq -r     '.certificateStatus' "$CSR_RESPONSE_FILE")

[ -z "$CERTIFICATE_ID" ] || [ "$CERTIFICATE_ID" = "null" ] && \
    die "Could not extract certificateId. Full response:\n$(cat "$CSR_RESPONSE_FILE")"

CSR_PEM_FILE="$CERT_STORAGE_DIR/${CERT_CN}_${CERTIFICATE_ID}.csr"
printf '%s' "$CSR_PEM" > "$CSR_PEM_FILE"
print_info "CSR PEM saved: $CSR_PEM_FILE"
print_info "✓ CSR generated — Certificate ID: ${CERTIFICATE_ID}, Status: ${CSR_STATUS}"
echo
echo "CSR preview:"
echo "  ─────────────────────────────────────────"
head -3 "$CSR_PEM_FILE" | sed 's/^/  /'
echo "  [...]"
tail -2 "$CSR_PEM_FILE" | sed 's/^/  /'
echo "  ─────────────────────────────────────────"
echo

# ============================================================================
# STEP 6: Issue certificate via DigiCert TLM
# ============================================================================
print_header "Step 2 — Issue Certificate via DigiCert TLM"

TLM_PAYLOAD=$(jq -n \
    --arg profileId "$TLM_PROFILE_ID" \
    --arg seatId    "$TLM_SEAT_ID" \
    --arg csr       "$CSR_PEM" \
    --arg cn        "$CERT_CN" \
    '{
        profile:          { id: $profileId },
        seat:             { seat_id: $seatId },
        csr:              $csr,
        include_ca_chain: "true",
        attributes: {
            subject:    { common_name: $cn },
            extensions: {}
        }
    }')

TLM_REQUEST_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_request.json"
echo "$TLM_PAYLOAD" > "$TLM_REQUEST_FILE"
print_info "TLM request JSON saved: $TLM_REQUEST_FILE"
TLM_ENDPOINT="${TLM_BASE_URL}/mpki/api/v1/certificate"
TLM_REPLAY_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_replay_inline_redacted.sh"
TLM_FILE_REPLAY_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_replay_file_redacted.sh"
TLM_SUMMARY_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_request_summary.json"
write_tlm_debug_artifacts "$TLM_ENDPOINT" "$TLM_REQUEST_FILE" "$TLM_REPLAY_FILE" "$TLM_FILE_REPLAY_FILE" "$TLM_SUMMARY_FILE"
print_info "TLM request summary:"
print_tlm_request_summary "$TLM_SUMMARY_FILE"
print_info "Redacted inline replay command saved: $TLM_REPLAY_FILE"
print_info "Redacted file replay command saved:   $TLM_FILE_REPLAY_FILE"
print_info "Submitting CSR to DigiCert TLM..."

TLM_RESPONSE_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_response.json"
TLM_STDERR_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_stderr.txt"
TLM_META_FILE="$CERT_STORAGE_DIR/${CERT_CN}_tlm_meta.txt"

tlm_request POST \
    "$TLM_ENDPOINT" \
    "$TLM_REQUEST_FILE" \
    "$TLM_RESPONSE_FILE" \
    "$TLM_STDERR_FILE" \
    "$TLM_META_FILE"
CURL_EXIT=$?
if [ "$CURL_EXIT" -ne 0 ]; then
    print_error "curl exited with code ${CURL_EXIT}"
    print_tlm_diagnostics "$TLM_RESPONSE_FILE" "$TLM_STDERR_FILE" "$TLM_META_FILE"
    print_error "TLM request JSON: $TLM_REQUEST_FILE"
    print_error "TLM request summary:"
    print_tlm_request_summary "$TLM_SUMMARY_FILE" >&2
    print_error "Redacted inline curl replay: $TLM_REPLAY_FILE"
    print_error "Redacted file curl replay: $TLM_FILE_REPLAY_FILE"
    if [ "${TLM_API_KEY_SOURCE:-prompt}" = "prompt" ]; then
        print_error "Replay uses TLM_API_KEY from the environment. If replay succeeds, rerun this script with TLM_API_KEY exported to bypass prompt/paste differences."
    fi
    die "TLM request failed (curl exit ${CURL_EXIT})."
fi

HTTP_STATUS=$(tlm_http_status "$TLM_META_FILE")
print_debug "TLM HTTP status: $HTTP_STATUS"
[ -s "$TLM_STDERR_FILE" ] && { print_warning "curl stderr:"; cat "$TLM_STDERR_FILE"; }

if grep -qi '<html\|Loading' "$TLM_RESPONSE_FILE" 2>/dev/null; then
    print_tlm_diagnostics "$TLM_RESPONSE_FILE" "$TLM_STDERR_FILE" "$TLM_META_FILE"
    die "TLM returned HTML instead of API JSON. Check the TLM base URL/region and whether a proxy or browser challenge is intercepting API calls."
fi

if [[ "$HTTP_STATUS" != 2* ]]; then
    print_error "TLM returned HTTP ${HTTP_STATUS:-unknown}."
    print_tlm_diagnostics "$TLM_RESPONSE_FILE" "$TLM_STDERR_FILE" "$TLM_META_FILE"
    print_error "TLM request JSON: $TLM_REQUEST_FILE"
    print_error "TLM request summary:"
    print_tlm_request_summary "$TLM_SUMMARY_FILE" >&2
    print_error "Redacted inline curl replay: $TLM_REPLAY_FILE"
    print_error "Redacted file curl replay: $TLM_FILE_REPLAY_FILE"
    if [ "${TLM_API_KEY_SOURCE:-prompt}" = "prompt" ]; then
        print_error "Replay uses TLM_API_KEY from the environment. If replay succeeds, rerun this script with TLM_API_KEY exported to bypass prompt/paste differences."
    fi
    die "TLM request failed with HTTP $HTTP_STATUS."
fi

TLM_ERRORS=$(jq -r '.errors[]?.message // empty' "$TLM_RESPONSE_FILE" 2>/dev/null || true)
[ -n "$TLM_ERRORS" ] && { print_error "TLM response:"; cat "$TLM_RESPONSE_FILE"; die "TLM errors: $TLM_ERRORS"; }

TLM_CERTS_JSON=$(jq -c '
    [
      ((.certificate // "" | gsub("\r"; "") | split("-----END CERTIFICATE-----"))
       | map(select(contains("-----BEGIN CERTIFICATE-----"))
             | "-----BEGIN CERTIFICATE-----" + (split("-----BEGIN CERTIFICATE-----")[-1]) + "-----END CERTIFICATE-----\n")
       | .[]),
      (.ca_certs[]?.pem // empty)
    ] | map(select(. != ""))
' "$TLM_RESPONSE_FILE" 2>/dev/null || echo '[]')

SIGNED_CERT=$(printf '%s\n' "$TLM_CERTS_JSON" | jq -r '.[0] // empty' 2>/dev/null)
[ -z "$SIGNED_CERT" ] && { print_error "TLM response:"; cat "$TLM_RESPONSE_FILE"; die "No certificate in TLM response."; }
TRUST_CHAIN_PEM=$(printf '%s\n' "$TLM_CERTS_JSON" | jq -r '.[1:] | join("")' 2>/dev/null || true)

SIGNED_CERT_FILE="$CERT_STORAGE_DIR/${CERT_CN}_${CERTIFICATE_ID}_signed.pem"
printf '%s\n' "$SIGNED_CERT" > "$SIGNED_CERT_FILE"
print_info "✓ Signed certificate saved: $SIGNED_CERT_FILE"

if [ -n "$TRUST_CHAIN_PEM" ]; then
    TRUST_CHAIN_FILE="$CERT_STORAGE_DIR/${CERT_CN}_${CERTIFICATE_ID}_chain.pem"
    printf '%s\n' "$TRUST_CHAIN_PEM" > "$TRUST_CHAIN_FILE"
    print_info "✓ Trust chain saved: $TRUST_CHAIN_FILE"
fi

if command -v openssl &>/dev/null; then
    echo
    print_info "Certificate details:"
    openssl x509 -in "$SIGNED_CERT_FILE" -noout \
        -subject -issuer -dates -serial 2>/dev/null | sed 's/^/  /' || true
fi
echo

# ============================================================================
# STEP 7: Validate certificate chain in Akamai CCM
# ============================================================================
print_header "Step 3 — Validate Certificate Chain in Akamai CCM"

# Build certs array: [leaf, ...chain_certs]
VALIDATE_CERTS_JSON="$TLM_CERTS_JSON"

VALIDATE_PAYLOAD=$(jq -n \
    --argjson certs   "$VALIDATE_CERTS_JSON" \
    --arg     keyType "$KEY_TYPE" \
    '{ certificates: $certs, keyType: $keyType }')

VALIDATE_REQUEST_FILE="$CERT_STORAGE_DIR/${CERT_CN}_validate_request.json"
echo "$VALIDATE_PAYLOAD" > "$VALIDATE_REQUEST_FILE"
print_info "Validating certificate chain..."

VALIDATE_RESPONSE_FILE="$CERT_STORAGE_DIR/${CERT_CN}_validate_response.json"
if ! akamai_http POST \
    "/ccm/v1/certificates/validate" \
    Content-Type:'application/json' \
    < "$VALIDATE_REQUEST_FILE" \
    --body > "$VALIDATE_RESPONSE_FILE" 2>&1; then
    print_warning "HTTPie returned non-zero on validation — checking response..."
fi

ACKNOWLEDGE_WARNINGS=false
VALIDATION_API_PROBLEM=$(jq -r '
    if ((.status? // 0) >= 400) then
        "HTTP \(.status): \(.title // .detail // .type // "unknown validation API error")"
    else
        empty
    end
' "$VALIDATE_RESPONSE_FILE" 2>/dev/null || true)

if [ -n "$VALIDATION_API_PROBLEM" ]; then
    print_warning "CCM validation endpoint did not return certificate validation results: $VALIDATION_API_PROBLEM"
    print_warning "Continuing to upload; the upload API will return any CCM certificate errors."
else
    ALL_ERRORS=$(jq -r '
        [ .validationResults.errors[]?,
          .signedCerts[]?.validationResults.errors[]?,
          .chainCerts[]?.validationResults.errors[]? ]
        | .[] | "  ✗ \(.code // ""): \(.message // .)"
    ' "$VALIDATE_RESPONSE_FILE" 2>/dev/null || true)

    ALL_WARNINGS=$(jq -r '
        [ .validationResults.warnings[]?,
          .signedCerts[]?.validationResults.warnings[]?,
          .chainCerts[]?.validationResults.warnings[]? ]
        | .[] | "  ⚠ \(.code // ""): \(.message // .)"
    ' "$VALIDATE_RESPONSE_FILE" 2>/dev/null || true)

    ALL_NOTICES=$(jq -r '
        [ .validationResults.notices[]?,
          .signedCerts[]?.validationResults.notices[]? ]
        | .[] | "  ℹ \(.code // ""): \(.message // .)"
    ' "$VALIDATE_RESPONSE_FILE" 2>/dev/null || true)

    if [ -n "$ALL_ERRORS" ]; then
        print_error "Validation returned ERRORS — cannot proceed:"
        echo -e "${RED}${ALL_ERRORS}${NC}"
        die "Resolve the errors above and re-run."
    fi

    [ -n "$ALL_NOTICES" ] && { echo -e "${BLUE}Notices:${NC}"; echo -e "${BLUE}${ALL_NOTICES}${NC}"; }

    if [ -n "$ALL_WARNINGS" ]; then
        echo
        print_warning "Validation returned WARNINGS:"
        echo -e "${YELLOW}${ALL_WARNINGS}${NC}"
        echo
        print_info "Signed certificate subject from validation:"
        jq -r '
            .signedCerts[]? |
            "  CN  : \(.subject.commonName // "n/a")",
            "  O   : \(.subject.organization // "n/a")",
            "  From: \(.startDate // "n/a")",
            "  To  : \(.endDate // "n/a")"
        ' "$VALIDATE_RESPONSE_FILE" 2>/dev/null || true
        echo
        print_warning "Warnings require acknowledgeWarnings=true on upload."
        ACKNOWLEDGE_WARNINGS=true
    else
        print_info "✓ Certificate chain validated — no warnings."
    fi
fi

# ============================================================================
# STEP 8: Confirm and upload to Akamai CCM
# ============================================================================
print_header "Step 4 — Upload Certificate to Akamai CCM"

print_info "Certificate summary:"
print_certificate_summary "$SIGNED_CERT_FILE" "$CERT_NAME"
echo

if $ACKNOWLEDGE_WARNINGS; then
    print_warning "Warnings were detected. Proceeding sets acknowledgeWarnings=true."
    print_warning "Review the warnings above before continuing."
    echo
fi

read -r -p "$(echo -e "${BOLD}Upload certificate to Akamai CCM? [y/N]${NC}: ")" confirm
case "$confirm" in
    [Yy]|[Yy][Ee][Ss]) ;;
    *)
        print_warning "Upload cancelled."
        print_info "CSR saved to:   $CSR_PEM_FILE"
        print_info "Signed cert at: $SIGNED_CERT_FILE"
        exit 0
        ;;
esac

PUT_PAYLOAD=$(jq -n \
    --arg certName    "$CERT_NAME" \
    --arg signedCert  "$SIGNED_CERT" \
    --arg trustChain  "$TRUST_CHAIN_PEM" \
    '{
        certificateName:      $certName,
        signedCertificatePem: $signedCert,
        trustChainPem:        $trustChain
    }')

PUT_REQUEST_FILE="$CERT_STORAGE_DIR/${CERT_CN}_upload_request.json"
echo "$PUT_PAYLOAD" > "$PUT_REQUEST_FILE"

UPLOAD_PATH="/ccm/v1/certificates/${CERTIFICATE_ID}"
$ACKNOWLEDGE_WARNINGS && UPLOAD_PATH="${UPLOAD_PATH}?acknowledgeWarnings=true"

print_info "Uploading certificate (ID: ${CERTIFICATE_ID})..."
print_debug "PUT $UPLOAD_PATH"

UPLOAD_RESPONSE_FILE="$CERT_STORAGE_DIR/${CERT_CN}_upload_response.json"
if ! akamai_http PUT \
    "$UPLOAD_PATH" \
    Content-Type:'application/json' \
    < "$PUT_REQUEST_FILE" \
    --body > "$UPLOAD_RESPONSE_FILE" 2>&1; then
    print_error "HTTPie returned non-zero. Response:"
    cat "$UPLOAD_RESPONSE_FILE"
    die "Certificate upload failed."
fi

FINAL_STATUS=$(jq -r '.certificateStatus // "UNKNOWN"' "$UPLOAD_RESPONSE_FILE")
FINAL_CERT_ID=$(jq -r '.certificateId // "'"$CERTIFICATE_ID"'"' "$UPLOAD_RESPONSE_FILE")

case "$FINAL_STATUS" in
    READY_FOR_USE|ACTIVE|DEPLOYED)
        echo
        print_info "✓ Certificate uploaded successfully!"
        echo
        jq -r '
            "  Certificate ID    : \(.certificateId // "n/a")",
            "  Certificate Name  : \(.certificateName // "n/a")",
            "  Status            : \(.certificateStatus // "n/a")",
            "  Valid from        : \(.signedCertificateNotValidBeforeDate // "n/a")",
            "  Valid to          : \(.signedCertificateNotValidAfterDate // "n/a")",
            "  Serial            : \(.signedCertificateSerialNumber // "n/a")",
            "  Issuer            : \(.signedCertificateIssuer // "n/a")",
            "  SHA256 Fingerprint: \(.signedCertificateSHA256Fingerprint // "n/a")"
        ' "$UPLOAD_RESPONSE_FILE" 2>/dev/null || true
        ;;
    *)
        print_warning "Upload completed with status: ${FINAL_STATUS}"
        print_warning "Check Akamai Control Center for deployment state."
        jq '.' "$UPLOAD_RESPONSE_FILE" 2>/dev/null || cat "$UPLOAD_RESPONSE_FILE"
        ;;
esac

echo
print_info "All files saved to: $CERT_STORAGE_DIR"
print_info "Script complete. Certificate ID: ${FINAL_CERT_ID}, Status: ${FINAL_STATUS}"
