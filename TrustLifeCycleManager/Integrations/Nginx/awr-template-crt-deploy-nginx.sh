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
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/tlm_agent_3.1.4_linux64/log/dc1_data.log"

# --- Custom deployment configuration (added) ---
# Control whether to back up existing nginx certs before replacing them.
BACKUP_OLD_CERTS="true"          # True/False (default True)

# Control whether to restart nginx after deployment. If false, no restart is performed. If true and restart fails, reload is performed.
RESTART_NGINX="false"            # True/False (default False)

# Control whether to validate nginx configuration with 'nginx -t' and log the output.
VALIDATE_NGINX_CONFIG="true"     # True/False (default True)

# Target certificate/key paths as configured in nginx:
NGINX_CERT_PATH="/etc/nginx/ssl/ots_ogletreedeakins_com.pem"
NGINX_KEY_PATH="/etc/nginx/ssl/ots_ogletreedeakins_com.key"
# --- End custom deployment configuration ---


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
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $CRT_FILE         - The certificate filename (.crt)
#   $KEY_FILE         - The private key filename (.key)
#   $CRT_FILE_PATH    - Full path to the certificate file
#   $KEY_FILE_PATH    - Full path to the private key file
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Certificate inspection variables (if files exist):
#   $CERT_COUNT       - Number of certificates in the CRT file
#   $KEY_TYPE         - Type of key (RSA, ECC, PKCS#8 format, or Unknown)
#   $KEY_FILE_CONTENT - The full content of the private key file
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Utility function:
#   log_message "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="


# ADD CUSTOM LOGIC HERE:

# ------------------ BEGIN: NGINX cert deployment logic ------------------
log_message "Entering NGINX certificate deployment logic"

# Show inputs we expect from DC1 JSON
log_message "Source certificate folder (CERT_FOLDER): ${CERT_FOLDER:-<empty>}"
log_message "Source certificate filename (CRT_FILE): ${CRT_FILE:-<empty>}"
log_message "Source private key filename (KEY_FILE): ${KEY_FILE:-<empty>}"
log_message "Destination cert path (NGINX_CERT_PATH): ${NGINX_CERT_PATH}"
log_message "Destination key  path (NGINX_KEY_PATH):  ${NGINX_KEY_PATH}"
log_message "Backup old certs (BACKUP_OLD_CERTS): ${BACKUP_OLD_CERTS}"
log_message "Validate nginx config (VALIDATE_NGINX_CONFIG): ${VALIDATE_NGINX_CONFIG}"
log_message "Restart nginx (RESTART_NGINX): ${RESTART_NGINX}"

# Sanity checks for required variables
if [ -z "${CERT_FOLDER}" ] || [ -z "${CRT_FILE}" ] || [ -z "${KEY_FILE}" ]; then
    log_message "ERROR: Missing one or more required inputs (CERT_FOLDER/CRT_FILE/KEY_FILE). Aborting."
    exit 1
fi

# Build absolute source paths (already provided by template too)
SRC_CERT="${CRT_FILE_PATH:-${CERT_FOLDER}/${CRT_FILE}}"
SRC_KEY="${KEY_FILE_PATH:-${CERT_FOLDER}/${KEY_FILE}}"

# Verify the source files exist
if [ ! -f "${SRC_CERT}" ]; then
    log_message "ERROR: Source certificate not found at ${SRC_CERT}"
    exit 1
fi
if [ ! -f "${SRC_KEY}" ]; then
    log_message "ERROR: Source private key not found at ${SRC_KEY}"
    exit 1
fi

# Ensure destination directory exists
DEST_DIR_CERT="$(dirname "${NGINX_CERT_PATH}")"
DEST_DIR_KEY="$(dirname "${NGINX_KEY_PATH}")"
if [ ! -d "${DEST_DIR_CERT}" ]; then
    log_message "Destination directory ${DEST_DIR_CERT} does not exist. Creating..."
    mkdir -p "${DEST_DIR_CERT}" || { log_message "ERROR: Failed to create ${DEST_DIR_CERT}"; exit 1; }
fi

# Timestamp for backups and temp files
TS="$(date -u +%Y%m%d-%H%M%SZ)"

# Optional: back up existing certificate and key
if [ "${BACKUP_OLD_CERTS}" = "true" ]; then
    for DEST in "${NGINX_CERT_PATH}" "${NGINX_KEY_PATH}"; do
        if [ -f "${DEST}" ]; then
            BACKUP_PATH="${DEST}.${TS}.backup"
            log_message "Backing up ${DEST} -> ${BACKUP_PATH}"
            cp -p "${DEST}" "${BACKUP_PATH}" || { log_message "ERROR: Backup failed for ${DEST}"; exit 1; }
        else
            log_message "No existing file at ${DEST}; skipping backup."
        fi
    done
else
    log_message "BACKUP_OLD_CERTS=false; skipping backups."
fi

# Deploy the new certificate (copy atomically and set permissions)
deploy_file() {
    local SRC="$1"
    local DEST="$2"
    local MODE="$3"   # e.g., 0644 or 0600

    local DEST_DIR
    DEST_DIR="$(dirname "${DEST}")"

    # Create a temp file in the destination directory for atomic move
    local TMP
    if TMP="$(mktemp "${DEST_DIR}/$(basename "${DEST}").XXXXXX.tmp")"; then
        :
    else
        # Fallback if mktemp template style not supported
        TMP="${DEST}.tmp.${TS}"
    fi

    log_message "Copying ${SRC} -> ${TMP}"
    cp "${SRC}" "${TMP}" || { log_message "ERROR: Failed to copy ${SRC} to temporary file ${TMP}"; rm -f "${TMP}"; exit 1; }

    # Set strict permissions and ownership before moving into place
    chmod "${MODE}" "${TMP}" || { log_message "ERROR: chmod ${MODE} ${TMP} failed"; rm -f "${TMP}"; exit 1; }
    chown root:root "${TMP}" 2>/dev/null || true

    # Atomic move into final location
    mv -f "${TMP}" "${DEST}" || { log_message "ERROR: Failed to move ${TMP} to ${DEST}"; rm -f "${TMP}"; exit 1; }

    log_message "Deployed ${DEST} (mode ${MODE})"
}

# Copy/convert certificate to .pem path. Content format (.crt vs .pem) is compatible (base64 X.509).
deploy_file "${SRC_CERT}" "${NGINX_CERT_PATH}" 0644
# Copy private key (restrict permissions)
deploy_file "${SRC_KEY}" "${NGINX_KEY_PATH}" 0600

# Optionally validate nginx configuration
VALIDATION_OK="unknown"
if [ "${VALIDATE_NGINX_CONFIG}" = "true" ]; then
    log_message "Running nginx -t to validate configuration..."
    if nginx -t >> "${LOGFILE}" 2>&1; then
        VALIDATION_OK="yes"
        log_message "nginx -t: configuration test PASSED"
    else
        VALIDATION_OK="no"
        log_message "nginx -t: configuration test FAILED (see log for details)"
    fi
else
    log_message "VALIDATE_NGINX_CONFIG=false; skipping nginx -t validation."
fi

# Optionally restart nginx (only if validation succeeded or validation is disabled)
if [ "${RESTART_NGINX}" = "true" ]; then
    if [ "${VALIDATE_NGINX_CONFIG}" = "true" ] && [ "${VALIDATION_OK}" != "yes" ]; then
        log_message "Skipping nginx restart because validation failed."
    else
        log_message "Restarting nginx service..."
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl restart nginx >> "${LOGFILE}" 2>&1; then
                log_message "nginx restarted successfully via systemctl."
            else
                log_message "ERROR: systemctl restart nginx failed."
                exit 1
            fi
        elif command -v service >/dev/null 2>&1; then
            if service nginx restart >> "${LOGFILE}" 2>&1; then
                log_message "nginx restarted successfully via service."
            else
                log_message "ERROR: service nginx restart failed."
                exit 1
            fi
        else
            # Fallback to nginx signal if managers are unavailable
            if nginx -s reload >> "${LOGFILE}" 2>&1; then
                log_message "nginx reloaded successfully via 'nginx -s reload'."
            else
                log_message "ERROR: Failed to control nginx (no systemctl/service and reload failed)."
                exit 1
            fi
        fi
    fi
else
    log_message "RESTART_NGINX=false; not restarting nginx."
fi

log_message "NGINX certificate deployment logic complete"

log_message "Custom script section completed"
log_message "=========================================="

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0