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

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/tls-guru.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting DC1_POST_SCRIPT_DATA extraction script"
log_message "=========================================="

# Check legal notice acceptance
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
log_message "  LOGFILE: $LOGFILE"

# Log environment variable check
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

# Read the Base64-encoded JSON string from the environment variable
CERT_INFO=${DC1_POST_SCRIPT_DATA}
log_message "CERT_INFO length: ${#CERT_INFO} characters"

# Decode JSON string
JSON_STRING=$(echo "$CERT_INFO" | base64 -d)
log_message "JSON_STRING decoded successfully"

# Log the raw JSON for debugging
log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract Argument_1 - first argument
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - second argument
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 extracted: '$ARGUMENT_3'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

# Extract cert folder
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt file name
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
log_message "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
log_message "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

# Extract all files from the files array
FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

# Log summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Arguments extracted:"
log_message "  Argument 1: $ARGUMENT_1"
log_message "  Argument 2: $ARGUMENT_2"
log_message "  Argument 3: $ARGUMENT_3"
log_message "  Argument 4: $ARGUMENT_4"
log_message "  Argument 5: $ARGUMENT_5"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Private key file: $KEY_FILE"
log_message "  Certificate path: $CRT_FILE_PATH"
log_message "  Private key path: $KEY_FILE_PATH"
log_message ""
log_message "All files in array: $FILES_ARRAY"
log_message "=========================================="

# Check if files exist
if [ -f "$CRT_FILE_PATH" ]; then
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"
    
    # Count certificates in the file
    CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
    log_message "Total certificates in file: $CERT_COUNT"
else
    log_message "WARNING: Certificate file not found: $CRT_FILE_PATH"
fi

if [ -f "$KEY_FILE_PATH" ]; then
    log_message "Private key file exists: $KEY_FILE_PATH"
    log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"
    
    # Determine key type
    KEY_FILE_CONTENT=$(cat "${KEY_FILE_PATH}")
    if echo "$KEY_FILE_CONTENT" | grep -q "BEGIN RSA PRIVATE KEY"; then
        KEY_TYPE="RSA"
        log_message "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN EC PRIVATE KEY"; then
        KEY_TYPE="ECC"
        log_message "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
        KEY_TYPE="PKCS#8 format (generic)"
        log_message "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    else
        KEY_TYPE="Unknown"
        log_message "Key type: Unknown"
    fi
else
    log_message "WARNING: Private key file not found: $KEY_FILE_PATH"
fi

# ============================================================================
# CUSTOM SCRIPT SECTION - Alibaba Cloud WAF 3.0 Certificate Deployment
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="

# ----------------------------------------------------------------------------
# Alibaba Cloud WAF 3.0 Configuration
# ----------------------------------------------------------------------------
TMP_DIR="${TMP_DIR:-/tmp/digicert-alibaba-waf3-awr}"
CLI_PROFILE="${CLI_PROFILE:-digicert-awr}"
WAF_API_VERSION="2021-10-01"

mkdir -p "$TMP_DIR" >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# Helper Functions
# ----------------------------------------------------------------------------
fail_and_exit() {
    log_message "ERROR: $1"
    echo "RESULT: ERROR - $1"
    exit 1
}

success_and_exit() {
    log_message "SUCCESS: $1"
    echo "RESULT: SUCCESS - $1"
    exit 0
}

mask_value() {
    local s="$1"
    local len=${#s}
    if [ "$len" -le 8 ]; then
        printf '%s' "***"
    else
        printf '%s...%s' "${s:0:4}" "${s: -4}"
    fi
}

json_get_string() {
    local json="$1"
    local key="$2"
    printf '%s' "$json" | tr -d '\n\r' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

verify_cert_and_key_match() {
    local cert_file="$1"
    local key_file="$2"
    local cert_pub key_pub

    cert_pub="$(openssl x509 -in "$cert_file" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $2}')"
    key_pub="$(openssl pkey -in "$key_file" -pubout -outform DER | openssl dgst -sha256 | awk '{print $2}')"

    [ -n "$cert_pub" ] || fail_and_exit "Unable to read public key from certificate file"
    [ -n "$key_pub" ] || fail_and_exit "Unable to read public key from private key file"
    [ "$cert_pub" = "$key_pub" ] || fail_and_exit "Certificate and private key do not match"
}

cleanup_profile() {
    aliyun configure delete --profile "$CLI_PROFILE" >/dev/null 2>&1 || true
}

configure_cli_profile() {
    cleanup_profile

    aliyun configure set \
        --profile "$CLI_PROFILE" \
        --mode AK \
        --access-key-id "$ALIBABA_ACCESS_KEY_ID" \
        --access-key-secret "$ALIBABA_ACCESS_KEY_SECRET" \
        --region "$ALIBABA_REGION_ID" >/dev/null 2>&1

    [ $? -eq 0 ] || fail_and_exit "Failed to configure Alibaba Cloud CLI profile"
}

call_cli_createcerts() {
    local cert_name="$1"
    local cert_content="$2"
    local cert_key="$3"
    local response_file="$TMP_DIR/createcerts_response.json"

    aliyun waf-openapi CreateCerts \
        --force \
        --version "$WAF_API_VERSION" \
        --profile "$CLI_PROFILE" \
        --RegionId "$ALIBABA_REGION_ID" \
        --InstanceId "$INSTANCE_ID" \
        --CertName "$cert_name" \
        --CertContent "$cert_content" \
        --CertKey "$cert_key" \
        > "$response_file"

    [ $? -eq 0 ] || fail_and_exit "CreateCerts CLI call failed"

    cat "$response_file"
}

call_cli_modifydomaincert() {
    local cert_id="$1"
    local stdout_file="$TMP_DIR/modifydomaincert_stdout.json"
    local stderr_file="$TMP_DIR/modifydomaincert_stderr.log"
    local rc

    aliyun waf-openapi ModifyDomainCert \
        --force \
        --version "$WAF_API_VERSION" \
        --method POST \
        --region "$ALIBABA_REGION_ID" \
        --profile "$CLI_PROFILE" \
        --RegionId "$ALIBABA_REGION_ID" \
        --InstanceId "$INSTANCE_ID" \
        --Domain "$DOMAIN_NAME" \
        --CertId "$cert_id" \
        >"$stdout_file" 2>"$stderr_file"

    rc=$?

    log_message "ModifyDomainCert CLI exit code: $rc"

    if [ -s "$stderr_file" ]; then
        log_message "ModifyDomainCert CLI stderr: $(tr '\n' ' ' < "$stderr_file")"
    fi

    if [ $rc -ne 0 ]; then
        echo "__ERROR__$(cat "$stderr_file" 2>/dev/null)"
        return 1
    fi

    cat "$stdout_file"
}

# ----------------------------------------------------------------------------
# Credential cleanup trap - ensures CLI profile and temp files are removed
# on all exit paths (success, failure, or signal)
# ----------------------------------------------------------------------------
trap 'cleanup_profile 2>/dev/null; rm -rf "$TMP_DIR" 2>/dev/null' EXIT

# ----------------------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------------------
command -v aliyun >/dev/null 2>&1 || fail_and_exit "Required command not found: aliyun"

# Map template arguments to named variables
ALIBABA_ACCESS_KEY_ID="$ARGUMENT_1"
ALIBABA_ACCESS_KEY_SECRET="$ARGUMENT_2"
ALIBABA_REGION_ID="$ARGUMENT_3"
INSTANCE_ID="$ARGUMENT_4"
DOMAIN_NAME="$ARGUMENT_5"

[ -n "$ALIBABA_ACCESS_KEY_ID" ]     || fail_and_exit "ARGUMENT_1 (Access Key ID) is required"
[ -n "$ALIBABA_ACCESS_KEY_SECRET" ] || fail_and_exit "ARGUMENT_2 (Access Key Secret) is required"
[ -n "$ALIBABA_REGION_ID" ]         || fail_and_exit "ARGUMENT_3 (Region ID) is required"
[ -n "$INSTANCE_ID" ]               || fail_and_exit "ARGUMENT_4 (Instance ID) is required"
[ -n "$DOMAIN_NAME" ]               || fail_and_exit "ARGUMENT_5 (Domain Name) is required"

[ -f "$CRT_FILE_PATH" ] || fail_and_exit "Certificate file not found: $CRT_FILE_PATH"
[ -f "$KEY_FILE_PATH" ] || fail_and_exit "Private key file not found: $KEY_FILE_PATH"

verify_cert_and_key_match "$CRT_FILE_PATH" "$KEY_FILE_PATH"

log_message "AccessKey ID: $(mask_value "$ALIBABA_ACCESS_KEY_ID")"
log_message "Region ID: $ALIBABA_REGION_ID"
log_message "Instance ID: $INSTANCE_ID"
log_message "Domain Name: $DOMAIN_NAME"

# ----------------------------------------------------------------------------
# Deploy certificate to Alibaba Cloud WAF 3.0
# ----------------------------------------------------------------------------
configure_cli_profile

CERT_CONTENT="$(cat "$CRT_FILE_PATH")"
CERT_KEY="$(cat "$KEY_FILE_PATH")"
CERT_BASENAME="$(basename "$CRT_FILE" .crt)"
CERT_NAME="${CERT_BASENAME}-$(date -u +%Y%m%dT%H%M%SZ)"

log_message "Calling CreateCerts via Alibaba Cloud CLI"
CREATE_RESPONSE="$(call_cli_createcerts "$CERT_NAME" "$CERT_CONTENT" "$CERT_KEY")"
CERT_IDENTIFIER="$(json_get_string "$CREATE_RESPONSE" "CertIdentifier")"
CREATE_REQUEST_ID="$(json_get_string "$CREATE_RESPONSE" "RequestId")"

[ -n "$CERT_IDENTIFIER" ] || fail_and_exit "CreateCerts did not return CertIdentifier (RequestId=${CREATE_REQUEST_ID:-unknown})"

log_message "CreateCerts succeeded: CertIdentifier=$CERT_IDENTIFIER RequestId=${CREATE_REQUEST_ID:-N/A}"

log_message "Calling ModifyDomainCert via Alibaba Cloud CLI"
MODIFY_RESPONSE="$(call_cli_modifydomaincert "$CERT_IDENTIFIER")" || fail_and_exit "${MODIFY_RESPONSE#__ERROR__}"

MODIFY_REQUEST_ID="$(json_get_string "$MODIFY_RESPONSE" "RequestId")"
[ -n "$MODIFY_REQUEST_ID" ] || fail_and_exit "ModifyDomainCert did not return RequestId"

success_and_exit "Alibaba Cloud WAF 3.0 certificate updated for domain ${DOMAIN_NAME}; CertId=${CERT_IDENTIFIER}; RequestId=${MODIFY_REQUEST_ID}"

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================