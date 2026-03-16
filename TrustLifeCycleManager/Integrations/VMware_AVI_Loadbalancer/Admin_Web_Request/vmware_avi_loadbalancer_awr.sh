#!/bin/bash

: <<'LEGAL_NOTICE'
Legal Notice (version October 29, 2024)
Copyright © 2024 DigiCert. All rights reserved.
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
subparagraphs (c)(1) and (2) of the Commercial Computer Software–Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# ============================================================================
# CONFIGURATION
# ============================================================================

# Legal Notice
LEGAL_NOTICE_ACCEPT="false"

# Logging
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/avi-upload.log"

# Avi Controller Configuration
# Set via arguments: ARGUMENT_1=controller, ARGUMENT_2=username, ARGUMENT_3=password
AVI_API_VERSION="22.1.3"

# Temporary files
WORK_DIR=$(mktemp -d)
COOKIE_FILE="${WORK_DIR}/avi_cookies.txt"

# ============================================================================
# FUNCTIONS
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Cleanup function
cleanup() {
    log_message "Cleaning up temporary files..."
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# Authenticate to Avi Controller
authenticate_avi() {
    log_message "Authenticating to Avi Controller: ${AVI_CONTROLLER}..."
    
    HTTP_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" \
        -c "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${AVI_USER}\",\"password\":\"${AVI_PASSWORD}\"}" \
        "https://${AVI_CONTROLLER}/login")

    if [ "${HTTP_CODE}" != "200" ]; then
        log_message "ERROR: Authentication failed (HTTP ${HTTP_CODE})"
        return 1
    fi

    CSRF_TOKEN=$(grep -i "csrftoken" "${COOKIE_FILE}" | awk '{print $NF}')
    
    if [ -z "${CSRF_TOKEN}" ]; then
        log_message "ERROR: Failed to obtain CSRF token"
        return 1
    fi

    log_message "Authentication successful, CSRF token obtained"
    return 0
}

# Upload certificate to Avi
upload_certificate() {
    log_message "Uploading certificate to Avi..."

    # Read certificate and key content
    CERT_CONTENT=$(cat "${CRT_FILE_PATH}")
    KEY_CONTENT=$(cat "${KEY_FILE_PATH}")

    # Build JSON payload
    PAYLOAD=$(jq -n \
        --arg name "${CERT_NAME}" \
        --arg cert "${CERT_CONTENT}" \
        --arg key "${KEY_CONTENT}" \
        '{
            "name": $name,
            "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
            "certificate": {
                "certificate": $cert
            },
            "key": $key
        }')

    RESPONSE=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -H "X-CSRFToken: ${CSRF_TOKEN}" \
        -H "Referer: https://${AVI_CONTROLLER}/" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        -X POST \
        -d "${PAYLOAD}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate")

    if echo "${RESPONSE}" | grep -q '"uuid"'; then
        CERT_UUID=$(echo "${RESPONSE}" | jq -r '.uuid')
        log_message "Certificate uploaded successfully"
        log_message "  Name: ${CERT_NAME}"
        log_message "  UUID: ${CERT_UUID}"
        return 0
    elif echo "${RESPONSE}" | grep -q "already exist"; then
        log_message "Certificate already exists - attempting update..."
        update_certificate
        return $?
    else
        log_message "ERROR: Failed to upload certificate"
        log_message "Response: ${RESPONSE}"
        return 1
    fi
}

# Update existing certificate in Avi
update_certificate() {
    log_message "Fetching existing certificate UUID..."
    
    EXISTING=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate?name=${CERT_NAME}")

    CERT_UUID=$(echo "${EXISTING}" | jq -r '.results[0].uuid')

    if [ -z "${CERT_UUID}" ] || [ "${CERT_UUID}" = "null" ]; then
        log_message "ERROR: Could not find existing certificate UUID"
        return 1
    fi

    log_message "Found existing certificate UUID: ${CERT_UUID}"

    # Read certificate and key content
    CERT_CONTENT=$(cat "${CRT_FILE_PATH}")
    KEY_CONTENT=$(cat "${KEY_FILE_PATH}")

    # Build JSON payload with UUID for update
    PAYLOAD=$(jq -n \
        --arg name "${CERT_NAME}" \
        --arg cert "${CERT_CONTENT}" \
        --arg key "${KEY_CONTENT}" \
        --arg uuid "${CERT_UUID}" \
        '{
            "uuid": $uuid,
            "name": $name,
            "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
            "certificate": {
                "certificate": $cert
            },
            "key": $key
        }')

    RESPONSE=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -H "X-CSRFToken: ${CSRF_TOKEN}" \
        -H "Referer: https://${AVI_CONTROLLER}/" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        -X PUT \
        -d "${PAYLOAD}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate/${CERT_UUID}")

    if echo "${RESPONSE}" | grep -q '"uuid"'; then
        log_message "Certificate updated successfully"
        log_message "  Name: ${CERT_NAME}"
        log_message "  UUID: ${CERT_UUID}"
        return 0
    else
        log_message "ERROR: Failed to update certificate"
        log_message "Response: ${RESPONSE}"
        return 1
    fi
}

# Extract certificate CN for naming
get_cert_cn() {
    if [ -f "${CRT_FILE_PATH}" ]; then
        CN=$(openssl x509 -in "${CRT_FILE_PATH}" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*\([^,]*\).*/\1/p')
        echo "${CN}"
    fi
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

log_message "=========================================="
log_message "Starting DigiCert TLM - AVI Upload Script"
log_message "=========================================="

# Check legal notice acceptance
log_message "Checking legal notice acceptance..."
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    log_message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed."
    exit 1
else
    log_message "Legal notice accepted, proceeding with script execution."
fi

# Check required commands
for cmd in curl jq openssl; do
    if ! command -v $cmd >/dev/null 2>&1; then
        log_message "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done
log_message "All required commands available (curl, jq, openssl)"

# Check DC1_POST_SCRIPT_DATA environment variable
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

# Read and decode the JSON data
CERT_INFO=${DC1_POST_SCRIPT_DATA}
JSON_STRING=$(echo "$CERT_INFO" | base64 -d)
log_message "JSON_STRING decoded successfully"

# Log raw JSON for debugging
log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract arguments (cleaned)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d '[:space:]')

log_message "Arguments extracted:"
log_message "  ARGUMENT_1 (AVI Controller): $ARGUMENT_1"
log_message "  ARGUMENT_2 (AVI Username): $ARGUMENT_2"
log_message "  ARGUMENT_3 (AVI Password): [REDACTED]"

# Extract certificate folder and files
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')

# Construct file paths
CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Private key file: $KEY_FILE"
log_message "  Certificate path: $CRT_FILE_PATH"
log_message "  Private key path: $KEY_FILE_PATH"

# Verify certificate files exist
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
fi
log_message "Certificate file exists: $CRT_FILE_PATH ($(stat -c%s "$CRT_FILE_PATH") bytes)"

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
fi
log_message "Private key file exists: $KEY_FILE_PATH ($(stat -c%s "$KEY_FILE_PATH") bytes)"

# Set AVI configuration from arguments
AVI_CONTROLLER="${ARGUMENT_1}"
AVI_USER="${ARGUMENT_2}"
AVI_PASSWORD="${ARGUMENT_3}"

# Set certificate name from certificate CN
CERT_NAME=$(get_cert_cn)
if [ -z "${CERT_NAME}" ]; then
    log_message "ERROR: Could not extract CN from certificate"
    exit 1
fi
log_message "Certificate name derived from CN: ${CERT_NAME}"

log_message "=========================================="
log_message "AVI Configuration:"
log_message "  Controller: ${AVI_CONTROLLER}"
log_message "  Username: ${AVI_USER}"
log_message "  API Version: ${AVI_API_VERSION}"
log_message "  Certificate Name: ${CERT_NAME}"
log_message "=========================================="

# Validate required AVI configuration
if [ -z "${AVI_CONTROLLER}" ] || [ -z "${AVI_USER}" ] || [ -z "${AVI_PASSWORD}" ]; then
    log_message "ERROR: Missing AVI configuration. Required arguments:"
    log_message "  ARGUMENT_1: AVI Controller hostname/IP"
    log_message "  ARGUMENT_2: AVI Username"
    log_message "  ARGUMENT_3: AVI Password"
    log_message "Example args: [\"alb.example.com\", \"admin\", \"password\"]"
    exit 1
fi

# Log certificate details
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
log_message "Certificates in file: ${CERT_COUNT}"

CERT_SUBJECT=$(openssl x509 -in "${CRT_FILE_PATH}" -noout -subject 2>/dev/null)
CERT_DATES=$(openssl x509 -in "${CRT_FILE_PATH}" -noout -dates 2>/dev/null)
log_message "Certificate subject: ${CERT_SUBJECT}"
log_message "Certificate validity: ${CERT_DATES}"

# Authenticate to AVI
log_message "=========================================="
log_message "Starting AVI upload process..."
log_message "=========================================="

if ! authenticate_avi; then
    log_message "ERROR: Failed to authenticate to AVI Controller"
    exit 1
fi

# Upload certificate
if ! upload_certificate; then
    log_message "ERROR: Failed to upload certificate to AVI"
    exit 1
fi

log_message "=========================================="
log_message "Certificate successfully uploaded to AVI"
log_message "  View in: Templates > Security > SSL/TLS Certificates"
log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0
