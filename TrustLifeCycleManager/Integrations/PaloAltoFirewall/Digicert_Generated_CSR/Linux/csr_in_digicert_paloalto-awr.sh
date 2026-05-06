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
LOGFILE="/home/ubuntu/palo-alto-awr.log"

# Certificate naming configuration
# Options: "common_name" or "manual"
CERT_NAME_METHOD="common_name"

# If using manual method, specify the certificate name here
MANUAL_CERT_NAME="tf-automated-cert"

# Commit configuration after upload
COMMIT_CONFIG="true"  # Set to "true" to automatically commit after upload

# Passphrase for private key (if needed)
PRIVATE_KEY_PASSPHRASE=""

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to extract common name from certificate
extract_common_name() {
    local cert_file="$1"
    local common_name

    # Extract CN from certificate subject
    common_name=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,/]+' | tr -d ' ')

    if [ -n "$common_name" ]; then
        log_message "Extracted Common Name: $common_name"
        echo "$common_name"
    else
        log_message "WARNING: Could not extract Common Name from certificate"
        echo ""
    fi
}

# Ensure log directory exists
LOG_DIR=$(dirname "$LOGFILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Start logging
log_message "=========================================="
log_message "Starting Palo Alto certificate upload script"
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

# Extract Argument_1 (PA_URL) - first argument
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 (PA_API_KEY) - second argument
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')

# Map arguments to Palo Alto configuration
PA_URL="$ARGUMENT_1"
PA_API_KEY="$ARGUMENT_2"

# Validate Palo Alto configuration from arguments
if [ -z "$PA_URL" ]; then
    log_message "ERROR: PA_URL (Argument 1) is empty"
    exit 1
fi

if [ -z "$PA_API_KEY" ]; then
    log_message "ERROR: PA_API_KEY (Argument 2) is empty"
    exit 1
fi

# Log Palo Alto configuration
log_message "Palo Alto Configuration (from arguments):"
log_message "  PA_URL: $PA_URL"
# Mask API key for security - show only first and last 4 characters
if [ ${#PA_API_KEY} -gt 8 ]; then
    PA_API_KEY_MASKED="${PA_API_KEY:0:4}...${PA_API_KEY: -4}"
else
    PA_API_KEY_MASKED="****"
fi
log_message "  PA_API_KEY: '$PA_API_KEY_MASKED' (masked for security)"
log_message "  CERT_NAME_METHOD: $CERT_NAME_METHOD"
log_message "  MANUAL_CERT_NAME: $MANUAL_CERT_NAME"
log_message "  COMMIT_CONFIG: $COMMIT_CONFIG"

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
log_message "  Argument 1 (PA_URL): $PA_URL"
log_message "  Argument 2 (PA_API_KEY): $PA_API_KEY_MASKED"
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
# CUSTOM SCRIPT SECTION - PALO ALTO CERTIFICATE UPLOAD
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
#   $ARGUMENT_1       - First argument from args array (PA_URL)
#   $ARGUMENT_2       - Second argument from args array (PA_API_KEY)
#
# Palo Alto mapped variables:
#   $PA_URL           - Palo Alto management URL (from Argument 1)
#   $PA_API_KEY       - Palo Alto API key (from Argument 2)
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Utility function:
#   log_message "text" - Function to write timestamped messages to log file
#
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="

# Verify certificate and key files exist before proceeding
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
fi

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
fi

# Determine certificate name
if [ "$CERT_NAME_METHOD" = "common_name" ]; then
    CERT_NAME=$(extract_common_name "$CRT_FILE_PATH")
    if [ -z "$CERT_NAME" ]; then
        log_message "ERROR: Could not extract Common Name and CERT_NAME_METHOD is set to 'common_name'"
        log_message "Please either fix the certificate or set CERT_NAME_METHOD to 'manual' and specify MANUAL_CERT_NAME"
        exit 1
    fi
elif [ "$CERT_NAME_METHOD" = "manual" ]; then
    if [ -z "$MANUAL_CERT_NAME" ]; then
        log_message "ERROR: CERT_NAME_METHOD is set to 'manual' but MANUAL_CERT_NAME is empty"
        exit 1
    fi
    CERT_NAME="$MANUAL_CERT_NAME"
else
    log_message "ERROR: Invalid CERT_NAME_METHOD: $CERT_NAME_METHOD. Must be 'common_name' or 'manual'"
    exit 1
fi

log_message "Using certificate name: $CERT_NAME"

# Create temporary files for responses
CERT_RESPONSE_FILE=$(mktemp)
KEY_RESPONSE_FILE=$(mktemp)
COMMIT_RESPONSE_FILE=$(mktemp)
CURL_ERROR_FILE=$(mktemp)
log_message "Created temporary response files"

# Upload certificate
log_message "Uploading certificate to Palo Alto..."
log_message "API Endpoint: ${PA_URL}/api/"

CERT_HTTP_STATUS=$(curl --insecure -sS -w "%{http_code}" \
    -F "file=@${CRT_FILE_PATH}" \
    "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=certificate&certificate-name=${CERT_NAME}&format=pem" \
    -o "$CERT_RESPONSE_FILE" 2>"$CURL_ERROR_FILE")

CERT_RESPONSE=$(cat "$CERT_RESPONSE_FILE")
CURL_ERROR=$(cat "$CURL_ERROR_FILE")

log_message "Certificate upload completed"
log_message "Certificate HTTP Status Code: $CERT_HTTP_STATUS"
log_message "Certificate API Response: $CERT_RESPONSE"
if [ -n "$CURL_ERROR" ]; then
    log_message "Certificate curl error: $CURL_ERROR"
fi

# Check certificate upload success
if [ "$CERT_HTTP_STATUS" -eq 200 ] 2>/dev/null || [ "$CERT_HTTP_STATUS" -eq 201 ] 2>/dev/null; then
    log_message "SUCCESS: Certificate uploaded successfully"
else
    log_message "ERROR: Certificate upload failed with status $CERT_HTTP_STATUS"
    log_message "Certificate response: $CERT_RESPONSE"
    if [ -n "$CURL_ERROR" ]; then
        log_message "Curl error detail: $CURL_ERROR"
    fi
    rm -f "$CERT_RESPONSE_FILE" "$KEY_RESPONSE_FILE" "$COMMIT_RESPONSE_FILE" "$CURL_ERROR_FILE"
    exit 1
fi

# Upload private key
log_message "Uploading private key to Palo Alto..."

KEY_HTTP_STATUS=$(curl --insecure -sS -w "%{http_code}" \
    -F "file=@${KEY_FILE_PATH}" \
    "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=private-key&certificate-name=${CERT_NAME}&format=pem&passphrase=${PRIVATE_KEY_PASSPHRASE}" \
    -o "$KEY_RESPONSE_FILE" 2>"$CURL_ERROR_FILE")

KEY_RESPONSE=$(cat "$KEY_RESPONSE_FILE")
CURL_ERROR=$(cat "$CURL_ERROR_FILE")

log_message "Private key upload completed"
log_message "Private key HTTP Status Code: $KEY_HTTP_STATUS"
log_message "Private key API Response: $KEY_RESPONSE"
if [ -n "$CURL_ERROR" ]; then
    log_message "Private key curl error: $CURL_ERROR"
fi

# Check private key upload success
if [ "$KEY_HTTP_STATUS" -eq 200 ] 2>/dev/null || [ "$KEY_HTTP_STATUS" -eq 201 ] 2>/dev/null; then
    log_message "SUCCESS: Private key uploaded successfully"
else
    log_message "ERROR: Private key upload failed with status $KEY_HTTP_STATUS"
    log_message "Private key response: $KEY_RESPONSE"
    if [ -n "$CURL_ERROR" ]; then
        log_message "Curl error detail: $CURL_ERROR"
    fi
    rm -f "$CERT_RESPONSE_FILE" "$KEY_RESPONSE_FILE" "$COMMIT_RESPONSE_FILE" "$CURL_ERROR_FILE"
    exit 1
fi

# Commit configuration if enabled
if [ "$COMMIT_CONFIG" = "true" ]; then
    log_message "Committing Palo Alto configuration..."

    COMMIT_HTTP_STATUS=$(curl --insecure -sS -w "%{http_code}" \
        "${PA_URL}/api/?key=${PA_API_KEY}&type=commit&cmd=<commit></commit>" \
        -o "$COMMIT_RESPONSE_FILE" 2>"$CURL_ERROR_FILE")

    COMMIT_RESPONSE=$(cat "$COMMIT_RESPONSE_FILE")
    CURL_ERROR=$(cat "$CURL_ERROR_FILE")

    log_message "Configuration commit completed"
    log_message "Commit HTTP Status Code: $COMMIT_HTTP_STATUS"
    log_message "Commit API Response: $COMMIT_RESPONSE"
    if [ -n "$CURL_ERROR" ]; then
        log_message "Commit curl error: $CURL_ERROR"
    fi

    # Check commit success
    if [ "$COMMIT_HTTP_STATUS" -eq 200 ] 2>/dev/null || [ "$COMMIT_HTTP_STATUS" -eq 201 ] 2>/dev/null; then
        log_message "SUCCESS: Configuration committed successfully"
    else
        log_message "WARNING: Configuration commit failed with status $COMMIT_HTTP_STATUS"
        log_message "Commit response: $COMMIT_RESPONSE"
        log_message "Certificate and key were uploaded successfully, but commit failed"
    fi
else
    log_message "Configuration commit skipped (COMMIT_CONFIG is set to false)"
fi

# Clean up
rm -f "$CERT_RESPONSE_FILE" "$KEY_RESPONSE_FILE" "$COMMIT_RESPONSE_FILE" "$CURL_ERROR_FILE"
log_message "Cleaned up temporary files"

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

# Exit with appropriate code based on certificate and key upload status
if [ "$CERT_HTTP_STATUS" -eq 200 ] || [ "$CERT_HTTP_STATUS" -eq 201 ]; then
    if [ "$KEY_HTTP_STATUS" -eq 200 ] || [ "$KEY_HTTP_STATUS" -eq 201 ]; then
        exit 0
    else
        exit 1
    fi
else
    exit 1
fi