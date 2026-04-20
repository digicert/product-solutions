#!/bin/bash

: <<'LEGAL_NOTICE'
Legal Notice (version January 1, 2026)
Copyright © 2026 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.
For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.
The software described in this notice is provided by DigiCert and distributed under licenses
restricting its use, copying, distribution, and decompilation or reverse engineering.
No part of the software may be reproduced in any form by any means without prior written authorization
of DigiCert and its licensors, if any.
Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
your agreement and, in the event of conflict, these terms control.
THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# ============================================================================
# Configuration
# ============================================================================
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/digicert-alibaba-alb-awr.log"
TMP_DIR="${TMP_DIR:-/tmp/digicert-alibaba-alb-awr}"

# Alibaba Cloud Certificate Service endpoint. Override with ALIBABA_CAS_ENDPOINT
# if you need a regional CAS endpoint (e.g. cas.cn-hangzhou.aliyuncs.com).
CAS_ENDPOINT="${ALIBABA_CAS_ENDPOINT:-cas.aliyuncs.com}"

# Deploy type default if ARGUMENT_5 is not supplied:
#   "default"    - replaces the primary / default certificate on the listener
#   "additional" - adds an additional (SNI) certificate to the listener
DEPLOY_TYPE_DEFAULT="default"

# Listener readiness polling
WAIT_TIMEOUT_SEC="300"
POLL_INTERVAL_SEC="10"

# ============================================================================
# Logging helpers
# ============================================================================
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

mask_credential() {
    local s="$1"
    local len=${#s}
    if [ "$len" -le 8 ]; then
        printf '%s' "***"
    else
        printf '%s...%s' "${s:0:4}" "${s: -4}"
    fi
}

fail_and_exit() {
    log_message "ERROR: $1"
    log_message "=========================================="
    log_message "Script execution terminated with error"
    log_message "=========================================="
    exit 1
}

# Start logging
log_message "=========================================="
log_message "Starting DigiCert AWR - Alibaba Cloud ALB deployment"
log_message "=========================================="

# ============================================================================
# Legal notice gate
# ============================================================================
log_message "Checking legal notice acceptance..."
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    log_message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed."
    log_message "Script execution terminated due to legal notice non-acceptance."
    log_message "=========================================="
    exit 1
else
    log_message "Legal notice accepted, proceeding with script execution."
fi

# Log initial configuration
log_message "Configuration:"
log_message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
log_message "  LOGFILE:             $LOGFILE"
log_message "  TMP_DIR:             $TMP_DIR"
log_message "  CAS_ENDPOINT:        $CAS_ENDPOINT"
log_message "  WAIT_TIMEOUT_SEC:    $WAIT_TIMEOUT_SEC"
log_message "  POLL_INTERVAL_SEC:   $POLL_INTERVAL_SEC"

# ============================================================================
# Dependency checks
# ============================================================================
log_message "Checking required commands..."
for cmd in curl jq openssl python3 base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail_and_exit "Required command not found: $cmd"
    fi
done
log_message "All required commands are available"

mkdir -p "$TMP_DIR" || fail_and_exit "Failed to create TMP_DIR: $TMP_DIR"

# ============================================================================
# DC1_POST_SCRIPT_DATA extraction
# ============================================================================
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    fail_and_exit "DC1_POST_SCRIPT_DATA environment variable is not set"
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

CERT_INFO=${DC1_POST_SCRIPT_DATA}
log_message "CERT_INFO length: ${#CERT_INFO} characters"

JSON_STRING=$(echo "$CERT_INFO" | base64 -d)
if [ -z "$JSON_STRING" ]; then
    fail_and_exit "Failed to decode DC1_POST_SCRIPT_DATA"
fi
log_message "JSON_STRING decoded successfully"

log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# ----------------------------------------------------------------------------
# Extract arguments from JSON
# ----------------------------------------------------------------------------
log_message "Extracting arguments from JSON..."
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array length: ${#ARGS_ARRAY}"

ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d '[:space:]')

# Credential-safe logging
log_message "ARGUMENT_1 (Access Key ID):  $(mask_credential "$ARGUMENT_1") (length: ${#ARGUMENT_1})"
log_message "ARGUMENT_2 (Key Secret):     <redacted> (length: ${#ARGUMENT_2})"
log_message "ARGUMENT_3 (Region ID):      $ARGUMENT_3"
log_message "ARGUMENT_4 (Listener ID):    $ARGUMENT_4"
log_message "ARGUMENT_5 (Deploy type):    ${ARGUMENT_5:-<empty, will default to $DEPLOY_TYPE_DEFAULT>}"

# Map arguments -> Alibaba variables
ALIBABA_ACCESS_KEY_ID="$ARGUMENT_1"
ALIBABA_ACCESS_KEY_SECRET="$ARGUMENT_2"
ALIBABA_REGION_ID="$ARGUMENT_3"
LISTENER_ID="$ARGUMENT_4"
DEPLOY_TYPE="${ARGUMENT_5:-$DEPLOY_TYPE_DEFAULT}"

# Validate required arguments
[ -n "$ALIBABA_ACCESS_KEY_ID" ]     || fail_and_exit "ARGUMENT_1 (Access Key ID) is required"
[ -n "$ALIBABA_ACCESS_KEY_SECRET" ] || fail_and_exit "ARGUMENT_2 (Access Key Secret) is required"
[ -n "$ALIBABA_REGION_ID" ]         || fail_and_exit "ARGUMENT_3 (Region ID) is required"
[ -n "$LISTENER_ID" ]               || fail_and_exit "ARGUMENT_4 (Listener ID) is required"

if [ "$DEPLOY_TYPE" != "default" ] && [ "$DEPLOY_TYPE" != "additional" ]; then
    fail_and_exit "ARGUMENT_5 (Deploy type) must be 'default' or 'additional'; got: '$DEPLOY_TYPE'"
fi

# Derive the ALB endpoint for the region
ALB_ENDPOINT="alb.${ALIBABA_REGION_ID}.aliyuncs.com"
log_message "ALB_ENDPOINT: $ALB_ENDPOINT"

# ----------------------------------------------------------------------------
# Extract cert folder + certificate and key files
# ----------------------------------------------------------------------------
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
log_message "Extracted CRT_FILE: $CRT_FILE"

KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
log_message "Extracted KEY_FILE: $KEY_FILE"

CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Certificate folder: $CERT_FOLDER"
log_message "Certificate file:   $CRT_FILE"
log_message "Private key file:   $KEY_FILE"
log_message "Certificate path:   $CRT_FILE_PATH"
log_message "Private key path:   $KEY_FILE_PATH"
log_message "=========================================="

# File existence + sanity checks
if [ -f "$CRT_FILE_PATH" ]; then
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"
    CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
    log_message "Total certificates in file: $CERT_COUNT"
else
    fail_and_exit "Certificate file not found: $CRT_FILE_PATH"
fi

if [ -f "$KEY_FILE_PATH" ]; then
    log_message "Private key file exists: $KEY_FILE_PATH"
    log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"

    KEY_FILE_CONTENT=$(cat "${KEY_FILE_PATH}")
    if echo "$KEY_FILE_CONTENT" | grep -q "BEGIN RSA PRIVATE KEY"; then
        KEY_TYPE="RSA"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN EC PRIVATE KEY"; then
        KEY_TYPE="ECC"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
        KEY_TYPE="PKCS#8 format (generic)"
    else
        KEY_TYPE="Unknown"
    fi
    log_message "Key type: $KEY_TYPE"
else
    fail_and_exit "Private key file not found: $KEY_FILE_PATH"
fi

# ============================================================================
# CUSTOM SCRIPT SECTION - Alibaba Cloud ALB deployment
# ============================================================================
log_message "=========================================="
log_message "Starting custom script section (Alibaba ALB)"
log_message "=========================================="

# ----------------------------------------------------------------------------
# Helper: percent-encode per Alibaba Cloud API spec (RFC 3986, tilde-safe)
# ----------------------------------------------------------------------------
percent_encode() {
python3 - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe='~'))
PY
}

gen_nonce() {
    openssl rand -hex 16
}

utc_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ----------------------------------------------------------------------------
# Alibaba Cloud RPC call (HMAC-SHA1 signed GET).
# Usage: rpc_call <endpoint> <version> <Key=Value> [<Key=Value> ...]
# Writes response to stdout, returns non-zero on HTTP or transport failure.
# ----------------------------------------------------------------------------
rpc_call() {
    local endpoint="$1"
    local version="$2"
    shift 2

    local params=(
        "AccessKeyId=$ALIBABA_ACCESS_KEY_ID"
        "Format=JSON"
        "RegionId=$ALIBABA_REGION_ID"
        "SignatureMethod=HMAC-SHA1"
        "SignatureNonce=$(gen_nonce)"
        "SignatureVersion=1.0"
        "Timestamp=$(utc_ts)"
        "Version=$version"
    )

    local kv
    for kv in "$@"; do
        params+=("$kv")
    done

    local canonical
    canonical="$(
        for kv in "${params[@]}"; do
            local k="${kv%%=*}"
            local v="${kv#*=}"
            printf '%s=%s\n' "$(percent_encode "$k")" "$(percent_encode "$v")"
        done | sort | paste -sd'&' -
    )"

    local string_to_sign="GET&%2F&$(percent_encode "$canonical")"
    local signature
    signature="$(
        printf '%s' "$string_to_sign" \
        | openssl dgst -sha1 -hmac "${ALIBABA_ACCESS_KEY_SECRET}&" -binary \
        | openssl base64 -A
    )"

    local url="https://${endpoint}/?${canonical}&Signature=$(percent_encode "$signature")"
    local resp_file http_code rc body

    resp_file="$(mktemp "${TMP_DIR}/rpc.XXXXXX")"

    http_code="$(curl -sS -o "$resp_file" -w '%{http_code}' "$url")"
    rc=$?

    if [ $rc -ne 0 ]; then
        body="$(cat "$resp_file" 2>/dev/null || true)"
        rm -f "$resp_file"
        log_message "curl failed (rc=$rc) endpoint=$endpoint version=$version body=$body"
        return 1
    fi

    if [[ ! "$http_code" =~ ^2 ]]; then
        body="$(cat "$resp_file" 2>/dev/null || true)"
        rm -f "$resp_file"
        log_message "HTTP error $http_code from $endpoint: $body"
        return 1
    fi

    cat "$resp_file"
    rm -f "$resp_file"
    return 0
}

# ----------------------------------------------------------------------------
# Stage the .crt / .key as .pem copies in TMP_DIR before upload.
#
# NOTE: CAS UploadUserCertificate accepts inline PEM-encoded content as string
# parameters — the file extension itself isn't inspected by the API. We still
# create .pem copies so that:
#   (a) the originals under $CERT_FOLDER are never touched,
#   (b) logs / on-disk artifacts consistently use the ".pem" terminology that
#       Alibaba docs use for CAS uploads, and
#   (c) if anything downstream ever does key off the extension, we're covered.
# ----------------------------------------------------------------------------
CRT_BASENAME="$(basename "$CRT_FILE" .crt)"
KEY_BASENAME="$(basename "$KEY_FILE" .key)"
CRT_PEM_PATH="${TMP_DIR}/${CRT_BASENAME}.pem"
KEY_PEM_PATH="${TMP_DIR}/${KEY_BASENAME}.key.pem"

cp "$CRT_FILE_PATH" "$CRT_PEM_PATH" || fail_and_exit "Failed to stage $CRT_FILE_PATH -> $CRT_PEM_PATH"
cp "$KEY_FILE_PATH" "$KEY_PEM_PATH" || fail_and_exit "Failed to stage $KEY_FILE_PATH -> $KEY_PEM_PATH"
chmod 600 "$KEY_PEM_PATH" 2>/dev/null || true
log_message "Staged certificate PEM: $CRT_PEM_PATH"
log_message "Staged private key PEM: $KEY_PEM_PATH"

# ----------------------------------------------------------------------------
# Build a unique certificate name for CAS (must be unique per upload)
# ----------------------------------------------------------------------------
ORIGINAL_CERT_NAME="$CRT_BASENAME"
CERT_NAME="${ORIGINAL_CERT_NAME}-$(date -u +%Y%m%dT%H%M%SZ)"
log_message "Original cert name: $ORIGINAL_CERT_NAME"
log_message "CAS cert name:      $CERT_NAME"
log_message "Deploy type:        $DEPLOY_TYPE"
log_message "Listener ID:        $LISTENER_ID"

# ----------------------------------------------------------------------------
# Upload the certificate to Alibaba Cloud Certificate Service (CAS)
# ----------------------------------------------------------------------------
log_message "Uploading certificate to Alibaba CAS..."
CERT_PEM_CONTENT="$(cat "$CRT_PEM_PATH")"
KEY_PEM_CONTENT="$(cat "$KEY_PEM_PATH")"

UPLOAD_RESP="$(rpc_call "$CAS_ENDPOINT" "2020-04-07" \
    "Action=UploadUserCertificate" \
    "Name=$CERT_NAME" \
    "Cert=$CERT_PEM_CONTENT" \
    "Key=$KEY_PEM_CONTENT")" \
    || fail_and_exit "CAS UploadUserCertificate call failed"

echo "$UPLOAD_RESP" > "$TMP_DIR/upload_user_certificate.json"
UPLOADED_CERT_ID="$(echo "$UPLOAD_RESP" | jq -r '.CertId // empty')"
if [ -z "$UPLOADED_CERT_ID" ] || [ "$UPLOADED_CERT_ID" = "null" ]; then
    log_message "UploadUserCertificate response: $UPLOAD_RESP"
    fail_and_exit "UploadUserCertificate did not return a CertId"
fi
log_message "Certificate uploaded. CertId=$UPLOADED_CERT_ID"

# ----------------------------------------------------------------------------
# Apply the uploaded cert to the ALB listener
# ----------------------------------------------------------------------------
if [ "$DEPLOY_TYPE" = "default" ]; then
    log_message "Submitting default certificate update to listener $LISTENER_ID"
    UPDATE_RESP="$(rpc_call "$ALB_ENDPOINT" "2020-06-16" \
        "Action=UpdateListenerAttribute" \
        "ListenerId=$LISTENER_ID" \
        "Certificates.1.CertificateId=$UPLOADED_CERT_ID")" \
        || fail_and_exit "UpdateListenerAttribute call failed"
    echo "$UPDATE_RESP" > "$TMP_DIR/update_listener_attribute.json"
else
    log_message "Submitting additional certificate association to listener $LISTENER_ID"
    UPDATE_RESP="$(rpc_call "$ALB_ENDPOINT" "2020-06-16" \
        "Action=AssociateAdditionalCertificatesWithListener" \
        "ListenerId=$LISTENER_ID" \
        "Certificates.1.CertificateId=$UPLOADED_CERT_ID")" \
        || fail_and_exit "AssociateAdditionalCertificatesWithListener call failed"
    echo "$UPDATE_RESP" > "$TMP_DIR/associate_additional_certificates.json"
fi

# ----------------------------------------------------------------------------
# Poll until the listener returns to Running / Associated (or timeout)
# ----------------------------------------------------------------------------
log_message "Waiting for ALB listener to become ready (timeout=${WAIT_TIMEOUT_SEC}s)"
elapsed=0
while true; do
    ATTR_RESP="$(rpc_call "$ALB_ENDPOINT" "2020-06-16" \
        "Action=GetListenerAttribute" \
        "ListenerId=$LISTENER_ID")" \
        || fail_and_exit "GetListenerAttribute failed during polling"
    echo "$ATTR_RESP" > "$TMP_DIR/get_listener_attribute_latest.json"

    LISTENER_STATUS="$(echo "$ATTR_RESP" | jq -r '.ListenerStatus // .Status // empty')"
    [ -n "$LISTENER_STATUS" ] || fail_and_exit "Unable to parse listener status from response"

    log_message "Listener status=$LISTENER_STATUS, elapsed=${elapsed}s"

    if [ "$DEPLOY_TYPE" = "default" ]; then
        case "$LISTENER_STATUS" in
            Running)
                log_message "Listener is Running"
                break
                ;;
            Configuring)
                ;;
            *)
                fail_and_exit "Unexpected listener status during default deployment: $LISTENER_STATUS"
                ;;
        esac
    else
        case "$LISTENER_STATUS" in
            Running|Associated)
                log_message "Listener additional certificate operation is ready"
                break
                ;;
            Configuring|Associating)
                ;;
            *)
                fail_and_exit "Unexpected listener status during additional certificate deployment: $LISTENER_STATUS"
                ;;
        esac
    fi

    if [ "$elapsed" -ge "$WAIT_TIMEOUT_SEC" ]; then
        fail_and_exit "Timed out after ${WAIT_TIMEOUT_SEC}s waiting for listener readiness"
    fi

    sleep "$POLL_INTERVAL_SEC"
    elapsed=$((elapsed + POLL_INTERVAL_SEC))
done

# ----------------------------------------------------------------------------
# Final listener certificate listing (for audit; non-fatal on failure)
# ----------------------------------------------------------------------------
FINAL_CERTS_RESP="$(rpc_call "$ALB_ENDPOINT" "2020-06-16" \
    "Action=ListListenerCertificates" \
    "ListenerId=$LISTENER_ID")" \
    || log_message "WARNING: ListListenerCertificates failed (non-fatal)"

if [ -n "$FINAL_CERTS_RESP" ]; then
    echo "$FINAL_CERTS_RESP" > "$TMP_DIR/list_listener_certificates.json"
fi

log_message "=========================================="
log_message "Alibaba ALB deployment SUCCESS"
log_message "  Listener ID:    $LISTENER_ID"
log_message "  CAS Cert ID:    $UPLOADED_CERT_ID"
log_message "  CAS Cert Name:  $CERT_NAME"
log_message "  Deploy type:    $DEPLOY_TYPE"
log_message "=========================================="

# Cleanup staged PEM files (leave API response artifacts in TMP_DIR for troubleshooting)
rm -f "$CRT_PEM_PATH" "$KEY_PEM_PATH"

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0