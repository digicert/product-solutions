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
LOGFILE="/home/admin/digicert-automation/radware/radware_alteon.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to obfuscate sensitive strings
obfuscate_string() {
    local str="$1"
    local show_chars="${2:-3}"
    if [ ${#str} -le $show_chars ]; then
        echo "$str"
    else
        echo "${str:0:$show_chars}***"
    fi
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

# Extract Argument_1 - IP Address / Base URL
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 (IP Address) extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - Certificate ID
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 (Certificate ID) extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - Authentication Token (Base64)
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 (Auth Token) extracted: '$(obfuscate_string "$ARGUMENT_3")'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')

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
log_message "  Argument 1 (IP Address):     $ARGUMENT_1"
log_message "  Argument 2 (Certificate ID): $ARGUMENT_2"
log_message "  Argument 3 (Auth Token):     $(obfuscate_string "$ARGUMENT_3")"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file:   $CRT_FILE"
log_message "  Private key file:   $KEY_FILE"
log_message "  Certificate path:   $CRT_FILE_PATH"
log_message "  Private key path:   $KEY_FILE_PATH"
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
# CUSTOM SCRIPT SECTION - RADWARE ALTEON CERTIFICATE DEPLOYMENT
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
#   $ARGUMENT_1       - IP Address or hostname of the Radware Alteon
#   $ARGUMENT_2       - Certificate ID on the Alteon
#   $ARGUMENT_3       - Base64-encoded credentials for Basic Auth
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Utility functions:
#   log_message "text"        - Function to write timestamped messages to log file
#   obfuscate_string "text"   - Function to obfuscate sensitive strings in logs
#
# WHAT THIS SECTION DOES
# ---------------------------------------------------------------------------
# 1) Import the certificate PEM to the Alteon via REST API:
#       POST https://{ARG1}/config/sslcertimport?renew=1&id={ARG2}&type=certificate&src=txt
# 2) Import the private key PEM to the Alteon via REST API:
#       POST https://{ARG1}/config/sslcertimport?renew=1&id={ARG2}&type=key&src=txt
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "Starting Radware Alteon certificate deployment..."
log_message "=========================================="

# ADD CUSTOM LOGIC HERE:
# ----------------------------------------

# Validate required arguments
if [ -z "$ARGUMENT_1" ]; then
    log_message "ERROR: Argument 1 (IP Address / Base URL) is not provided"
    exit 1
fi

if [ -z "$ARGUMENT_2" ]; then
    log_message "ERROR: Argument 2 (Certificate ID) is not provided"
    exit 1
fi

if [ -z "$ARGUMENT_3" ]; then
    log_message "ERROR: Argument 3 (Auth Token) is not provided"
    exit 1
fi

BASE_URL="$ARGUMENT_1"
CERT_ID="$ARGUMENT_2"
AUTH_TOKEN="$ARGUMENT_3"

log_message "Radware Alteon target:"
log_message "  Base URL:        $BASE_URL"
log_message "  Certificate ID:  $CERT_ID"
log_message "  Auth Token:      $(obfuscate_string "$AUTH_TOKEN")"

# Construct API URIs
CERT_URI="https://${BASE_URL}/config/sslcertimport?renew=1&id=${CERT_ID}&type=certificate&src=txt"
KEY_URI="https://${BASE_URL}/config/sslcertimport?renew=1&id=${CERT_ID}&type=key&src=txt"

log_message "Certificate import URI: $CERT_URI"
log_message "Key import URI: $KEY_URI"

# Step 1: Import Certificate
log_message "Step 1: Importing certificate to Radware Alteon..."

CERT_RESPONSE=$(curl -k --silent --show-error \
    -X POST \
    -H "Content-Type: text/plain" \
    -H "Authorization: Basic ${AUTH_TOKEN}" \
    --data-binary "@${CRT_FILE_PATH}" \
    "$CERT_URI" \
    --write-out "\nHTTP_STATUS:%{http_code}" 2>&1 || true)

CERT_STATUS=$(echo "$CERT_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
CERT_BODY=$(echo "$CERT_RESPONSE" | sed '/HTTP_STATUS:/d')

log_message "Certificate import HTTP status: $CERT_STATUS"
if echo "$CERT_BODY" | grep -qi "success\|ok\|200"; then
    log_message "Certificate import response: Success"
else
    log_message "Certificate import response body: $CERT_BODY"
fi

if [ "$CERT_STATUS" != "200" ] && [ "$CERT_STATUS" != "201" ]; then
    log_message "ERROR: Certificate import failed with HTTP status $CERT_STATUS"
    log_message "Response: $CERT_BODY"
    exit 1
fi

log_message "Certificate imported successfully"

# Step 2: Import Private Key
log_message "Step 2: Importing private key to Radware Alteon..."

KEY_RESPONSE=$(curl -k --silent --show-error \
    -X POST \
    -H "Content-Type: text/plain" \
    -H "Authorization: Basic ${AUTH_TOKEN}" \
    --data-binary "@${KEY_FILE_PATH}" \
    "$KEY_URI" \
    --write-out "\nHTTP_STATUS:%{http_code}" 2>&1 || true)

KEY_STATUS=$(echo "$KEY_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
KEY_BODY=$(echo "$KEY_RESPONSE" | sed '/HTTP_STATUS:/d')

log_message "Key import HTTP status: $KEY_STATUS"
if echo "$KEY_BODY" | grep -qi "success\|ok\|200"; then
    log_message "Key import response: Success"
else
    log_message "Key import response body: $KEY_BODY"
fi

if [ "$KEY_STATUS" != "200" ] && [ "$KEY_STATUS" != "201" ]; then
    log_message "ERROR: Private key import failed with HTTP status $KEY_STATUS"
    log_message "Response: $KEY_BODY"
    exit 1
fi

log_message "Private key imported successfully"

log_message "Radware Alteon certificate deployment completed successfully"
log_message "  Certificate ID: $CERT_ID"
log_message "  Target:         $BASE_URL"

# ----------------------------------------
# END CUSTOM LOGIC

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0