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
LOGFILE="/etc/digicert/AWR-Logs/imperva.log"
API_CALL_LOGFILE="/etc/digicert/AWR-Logs/imperva-api-call-responses.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to log API call details
log_api_call() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$API_CALL_LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting certificate variable extraction script"
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
log_message "  API_CALL_LOGFILE: $API_CALL_LOGFILE"

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

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
# log_message "Raw args array: $ARGS_ARRAY"

# Extract Argument_1 - first argument (Site ID)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - second argument (API ID)
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument (API Key)
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 extracted: '${ARGUMENT_3:0:5}...'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Log extracted arguments summary
log_message "Extracted arguments summary:"
log_message "  ARGUMENT_1: '$ARGUMENT_1'"
log_message "  ARGUMENT_2: '$ARGUMENT_2'"
log_message "  ARGUMENT_3: '${ARGUMENT_3:0:5}...'"
log_message "  ARGUMENT_4: '$ARGUMENT_4'"
log_message "  ARGUMENT_5: '$ARGUMENT_5'"

# Validate and clean arguments
log_message "Validating extracted argument values..."

# Remove any potential whitespace, newlines, or carriage returns from all arguments
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

# ========================================
# Determine certificate upload type (Argument 4) and network slice (Argument 5)
# SNI    = default workflow: PUT to /api/prov/v2/sites/{siteId}/customCertificate
# NONSNI = site group workflow: POST to /api/prov/v1/sitesgroups/manualCertificate/upload
#          (requires a network slice as Argument 5)
# ========================================
CERT_UPLOAD_TYPE=$(echo "$ARGUMENT_4" | tr '[:lower:]' '[:upper:]')
if [ -z "$CERT_UPLOAD_TYPE" ]; then
    CERT_UPLOAD_TYPE="SNI"
    log_message "No certificate upload type provided (Argument 4), defaulting to SNI"
fi

if [ "$CERT_UPLOAD_TYPE" != "SNI" ] && [ "$CERT_UPLOAD_TYPE" != "NONSNI" ]; then
    log_message "ERROR: Invalid certificate upload type '$ARGUMENT_4' (Argument 4). Must be SNI or NONSNI."
    exit 1
fi

NETWORK_SLICE="$ARGUMENT_5"
if [ "$CERT_UPLOAD_TYPE" = "NONSNI" ] && [ -z "$NETWORK_SLICE" ]; then
    log_message "ERROR: Certificate upload type NONSNI requires a network slice (Argument 5)."
    exit 1
fi

# Site ID (Argument 1) is only used by the SNI (per-site) endpoint. It may be
# left empty for NONSNI uploads, but must still be passed as a placeholder so
# the remaining arguments keep their positions.
if [ "$CERT_UPLOAD_TYPE" = "SNI" ] && [ -z "$ARGUMENT_1" ]; then
    log_message "ERROR: Certificate upload type SNI requires a Site ID (Argument 1)."
    exit 1
fi

log_message "Certificate upload type: $CERT_UPLOAD_TYPE"
if [ "$CERT_UPLOAD_TYPE" = "NONSNI" ]; then
    log_message "Network slice: $NETWORK_SLICE"
fi

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
log_message "Constructed file paths:"
log_message "  CRT_FILE_PATH: $CRT_FILE_PATH"
log_message "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Check if files exist
if [ -f "$CRT_FILE_PATH" ]; then
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"
else
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
fi

if [ -f "$KEY_FILE_PATH" ]; then
    log_message "Key file exists: $KEY_FILE_PATH"
    log_message "Key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"
else
    log_message "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
fi

# Count total certificates in the file for logging purposes
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
log_message "Total certificates in file: $CERT_COUNT"

# ========================================
# NEW: Base64 encode the entire certificate chain and private key
# ========================================
log_message "=========================================="
log_message "Base64 encoding certificate chain and private key..."
log_message "=========================================="

# Base64 encode the entire certificate chain (including all headers/footers)
# The -w 0 flag ensures no line wrapping (Linux)
# For macOS, omit the -w flag
CERT_CHAIN_BASE64=$(cat "$CRT_FILE_PATH" | base64 -w 0)
if [ $? -ne 0 ]; then
    # Fallback for macOS or systems where -w flag doesn't work
    log_message "Base64 with -w 0 failed, trying without -w flag (macOS compatible)..."
    CERT_CHAIN_BASE64=$(cat "$CRT_FILE_PATH" | base64)
fi
log_message "Certificate chain Base64 encoded successfully"
log_message "Certificate chain Base64 length: ${#CERT_CHAIN_BASE64} characters"

# Log first and last 50 characters of Base64 encoded certificate for verification
if [ ${#CERT_CHAIN_BASE64} -gt 100 ]; then
    CERT_B64_START="${CERT_CHAIN_BASE64:0:50}"
    CERT_B64_END="${CERT_CHAIN_BASE64: -50}"
    log_message "Certificate Base64 starts with: $CERT_B64_START"
    log_message "Certificate Base64 ends with: $CERT_B64_END"
else
    log_message "Certificate Base64: $CERT_CHAIN_BASE64"
fi

# Base64 encode the private key (including headers/footers)
KEY_BASE64=$(cat "$KEY_FILE_PATH" | base64 -w 0)
if [ $? -ne 0 ]; then
    # Fallback for macOS or systems where -w flag doesn't work
    log_message "Base64 with -w 0 failed, trying without -w flag (macOS compatible)..."
    KEY_BASE64=$(cat "$KEY_FILE_PATH" | base64)
fi
log_message "Private key Base64 encoded successfully"
log_message "Private key Base64 length: ${#KEY_BASE64} characters"

# Log first 50 characters of Base64 encoded key for verification (truncated for security)
KEY_B64_START="${KEY_BASE64:0:50}"
log_message "Private key Base64 starts with: $KEY_B64_START..."

# Verify Base64 encoding by attempting to decode back
log_message "Verifying Base64 encoding..."
VERIFY_CERT=$(echo "$CERT_CHAIN_BASE64" | base64 -d 2>&1 | head -1)
if [[ "$VERIFY_CERT" == *"BEGIN CERTIFICATE"* ]]; then
    log_message "Certificate Base64 verification: SUCCESS (decodes to valid PEM)"
else
    log_message "WARNING: Certificate Base64 may be invalid. First line after decode: $VERIFY_CERT"
fi

VERIFY_KEY=$(echo "$KEY_BASE64" | base64 -d 2>&1 | head -1)
if [[ "$VERIFY_KEY" == *"BEGIN"*"PRIVATE KEY"* ]]; then
    log_message "Private key Base64 verification: SUCCESS (decodes to valid PEM)"
else
    log_message "WARNING: Private key Base64 may be invalid. First line after decode: $VERIFY_KEY"
fi

# Determine auth_type based on private key file content
log_message "Analyzing private key file for auth_type detection..."
KEY_FILE_CONTENT=$(cat "${KEY_FILE_PATH}")

if echo "$KEY_FILE_CONTENT" | grep -q "BEGIN RSA PRIVATE KEY"; then
    AUTH_TYPE="RSA"
    log_message "Detected RSA private key (BEGIN RSA PRIVATE KEY found)"
elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN EC PRIVATE KEY"; then
    AUTH_TYPE="ECC"
    log_message "Detected ECC private key (BEGIN EC PRIVATE KEY found)"
elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
    # PKCS#8 format - need to determine if it's RSA or ECC
    # Check the certificate to determine the key type
    CERT_FILE_CONTENT=$(cat "${CRT_FILE_PATH}")
    if echo "$CERT_FILE_CONTENT" | openssl x509 -noout -text 2>/dev/null | grep -q "rsaEncryption\|RSA"; then
        AUTH_TYPE="RSA"
        log_message "Detected RSA private key (PKCS#8 format, determined from certificate)"
    elif echo "$CERT_FILE_CONTENT" | openssl x509 -noout -text 2>/dev/null | grep -q "id-ecPublicKey\|EC"; then
        AUTH_TYPE="ECC"
        log_message "Detected ECC private key (PKCS#8 format, determined from certificate)"
    else
        AUTH_TYPE="RSA"  # Default to RSA
        log_message "Could not determine key type from certificate, defaulting to RSA"
    fi
else
    AUTH_TYPE="RSA"  # Default to RSA
    log_message "Could not determine key type, defaulting to RSA"
fi

log_message "Final auth_type: $AUTH_TYPE"

# Prepare API call parameters
SITE_ID="$ARGUMENT_1"
API_ID="$ARGUMENT_2"
API_KEY="$ARGUMENT_3"

log_message "API call parameters:"
log_message "  Site ID: $SITE_ID"
log_message "  API ID: $API_ID"
log_message "  API Key: ${API_KEY:0:5}..." # Only show first 5 chars of API key for security

# Prepare truncated values for logging
CERT_FOR_LOG="${CERT_CHAIN_BASE64:0:100}..."
KEY_FOR_LOG="${KEY_BASE64:0:100}..."

if [ "$CERT_UPLOAD_TYPE" = "SNI" ]; then
    # ========================================
    # SNI workflow: PUT JSON payload to the per-site custom certificate endpoint
    # ========================================
    API_URL="https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"

    log_message "Preparing JSON payload with Base64 encoded data..."

    # Create the API payload
    API_PAYLOAD=$(cat <<EOF
{
  "certificate": "${CERT_CHAIN_BASE64}",
  "private_key": "${KEY_BASE64}",
  "auth_type": "${AUTH_TYPE}"
}
EOF
)

    log_message "JSON payload prepared successfully"
    log_message "Total payload size: ${#API_PAYLOAD} characters"

    JSON_PAYLOAD_FOR_LOG="{
  \"certificate\": \"$CERT_FOR_LOG\",
  \"private_key\": \"$KEY_FOR_LOG\",
  \"auth_type\": \"$AUTH_TYPE\"
}"

    # Log the complete curl command to api-call.log
    log_api_call "=========================================="
    log_api_call "COMPLETE CURL COMMAND (with Base64 encoded chain):"
    log_api_call "=========================================="
    log_api_call "curl --location --request PUT '$API_URL' \\"
    log_api_call "--header 'Content-Type: application/json' \\"
    log_api_call "--header 'x-API-Key: ${API_KEY:0:5}...' \\"
    log_api_call "--header 'x-API-Id: $API_ID' \\"
    log_api_call "--data '${JSON_PAYLOAD_FOR_LOG}'"
    log_api_call "=========================================="
    log_api_call "Note: Certificate and key are Base64 encoded entire PEM files (including headers/footers)"
    log_api_call "Certificate chain contains $CERT_COUNT certificate(s)"
    log_api_call "=========================================="

    # Make API call to Imperva
    log_message "=========================================="
    log_message "Making API call to Imperva with Base64 encoded certificate chain..."
    log_message "URL: $API_URL"
    log_message "Method: PUT"
    log_message "Headers:"
    log_message "  Content-Type: application/json"
    log_message "  x-API-Id: $API_ID"
    log_message "  x-API-Key: ${API_KEY:0:5}..."
    log_message "Payload preview (truncated):"
    log_message "  certificate (Base64): $CERT_FOR_LOG"
    log_message "  private_key (Base64): $KEY_FOR_LOG"
    log_message "  auth_type: $AUTH_TYPE"
    log_message "Certificate chain info:"
    log_message "  Number of certificates in chain: $CERT_COUNT"
    log_message "  Base64 encoded size: ${#CERT_CHAIN_BASE64} characters"
    log_message "  Private key Base64 size: ${#KEY_BASE64} characters"
    log_message "See $API_CALL_LOGFILE for complete curl command"
    log_message "=========================================="

    # Make the actual API call
    API_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
      --location \
      --request PUT "$API_URL" \
      --header 'Content-Type: application/json' \
      --header "x-API-Key: $API_KEY" \
      --header "x-API-Id: $API_ID" \
      --data "${API_PAYLOAD}")
else
    # ========================================
    # NONSNI workflow: POST form-encoded payload to the site group manual
    # certificate endpoint (network_slice, certificate, private_key).
    # Base64 values are passed via --data-urlencode so '+', '/' and '='
    # characters survive form encoding intact.
    # ========================================
    API_URL="https://my.incapsula.com/api/prov/v1/sitesgroups/manualCertificate/upload"

    log_message "Preparing form-encoded payload for non-SNI site group upload..."
    log_message "Payload fields: network_slice, certificate (Base64), private_key (Base64)"

    # Log the complete curl command to api-call.log
    log_api_call "=========================================="
    log_api_call "COMPLETE CURL COMMAND (non-SNI site group upload):"
    log_api_call "=========================================="
    log_api_call "curl --request POST '$API_URL' \\"
    log_api_call "--header 'x-API-Id: $API_ID' \\"
    log_api_call "--header 'x-API-Key: ${API_KEY:0:5}...' \\"
    log_api_call "--data-urlencode 'network_slice=$NETWORK_SLICE' \\"
    log_api_call "--data-urlencode 'certificate=$CERT_FOR_LOG' \\"
    log_api_call "--data-urlencode 'private_key=$KEY_FOR_LOG'"
    log_api_call "=========================================="
    log_api_call "Note: Certificate and key are Base64 encoded entire PEM files (including headers/footers)"
    log_api_call "Certificate chain contains $CERT_COUNT certificate(s)"
    log_api_call "=========================================="

    # Make API call to Imperva
    log_message "=========================================="
    log_message "Making non-SNI site group API call to Imperva..."
    log_message "URL: $API_URL"
    log_message "Method: POST"
    log_message "Headers:"
    log_message "  x-API-Id: $API_ID"
    log_message "  x-API-Key: ${API_KEY:0:5}..."
    log_message "Payload preview (truncated):"
    log_message "  network_slice: $NETWORK_SLICE"
    log_message "  certificate (Base64): $CERT_FOR_LOG"
    log_message "  private_key (Base64): $KEY_FOR_LOG"
    log_message "Certificate chain info:"
    log_message "  Number of certificates in chain: $CERT_COUNT"
    log_message "  Base64 encoded size: ${#CERT_CHAIN_BASE64} characters"
    log_message "  Private key Base64 size: ${#KEY_BASE64} characters"
    log_message "See $API_CALL_LOGFILE for complete curl command"
    log_message "=========================================="

    # Make the actual API call
    API_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
      --location \
      --request POST "$API_URL" \
      --header "x-API-Id: $API_ID" \
      --header "x-API-Key: $API_KEY" \
      --data-urlencode "network_slice=${NETWORK_SLICE}" \
      --data-urlencode "certificate=${CERT_CHAIN_BASE64}" \
      --data-urlencode "private_key=${KEY_BASE64}")
fi

# Extract HTTP status code and response body
HTTP_STATUS=$(echo "$API_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$API_RESPONSE" | grep -v "HTTP_STATUS:")

log_message "API call completed"
log_message "HTTP Status Code: $HTTP_STATUS"
log_message "Response Body: $RESPONSE_BODY"

# Imperva can return an application-level error in a successful HTTP response.
# The v2 sites API reports it as "resultCode"; the v1 sitesgroups API as "res".
RESULT_CODE=$(printf '%s' "$RESPONSE_BODY" | \
    grep -oE '"resultCode"[[:space:]]*:[[:space:]]*"?-?[0-9]+"?' | \
    sed -E 's/.*:[[:space:]]*"?(-?[0-9]+)"?/\1/' | head -n 1)
if [ -z "$RESULT_CODE" ]; then
    RESULT_CODE=$(printf '%s' "$RESPONSE_BODY" | \
        grep -oE '"res"[[:space:]]*:[[:space:]]*"?-?[0-9]+"?' | \
        sed -E 's/.*:[[:space:]]*"?(-?[0-9]+)"?/\1/' | head -n 1)
fi
if [ -n "$RESULT_CODE" ]; then
    log_message "Imperva result code: $RESULT_CODE"
fi

# Check if API call was successful
if { [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; } && \
   { [ -z "$RESULT_CODE" ] || [ "$RESULT_CODE" = "0" ]; }; then
    log_message "SUCCESS: Certificate chain uploaded successfully to Imperva"
    log_message "Certificate chain with $CERT_COUNT certificate(s) has been installed"
else
    log_message "ERROR: API call failed with status $HTTP_STATUS"
    log_message "Response: $RESPONSE_BODY"
    
    # Additional debugging for common issues
    if [[ "$RESPONSE_BODY" == *"certificate"* ]]; then
        log_message "DEBUG: Error appears to be certificate-related"
        log_message "DEBUG: Verify that the certificate chain is in correct order (domain -> intermediate -> root)"
    fi
    if [[ "$RESPONSE_BODY" == *"private"* ]] || [[ "$RESPONSE_BODY" == *"key"* ]]; then
        log_message "DEBUG: Error appears to be private key-related"
        log_message "DEBUG: Verify that the private key matches the certificate"
    fi
    if [[ "$RESPONSE_BODY" == *"auth_type"* ]]; then
        log_message "DEBUG: Error appears to be auth_type-related"
        log_message "DEBUG: Current auth_type: $AUTH_TYPE"
    fi
fi

log_message "=========================================="
log_message "Script execution completed"
log_message "Summary:"
log_message "  Certificate file: $CRT_FILE_PATH"
log_message "  Private key file: $KEY_FILE_PATH"
log_message "  Certificates in chain: $CERT_COUNT"
log_message "  Auth type: $AUTH_TYPE"
log_message "  Upload type: $CERT_UPLOAD_TYPE"
if [ "$CERT_UPLOAD_TYPE" = "NONSNI" ]; then
    log_message "  Network slice: $NETWORK_SLICE"
fi
log_message "  API endpoint: $API_URL"
log_message "  HTTP status: $HTTP_STATUS"
if { [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; } && \
    { [ -z "$RESULT_CODE" ] || [ "$RESULT_CODE" = "0" ]; }; then
    log_message "  Result: SUCCESS - Certificate chain uploaded"
else
    log_message "  Result: FAILED - Check response for details"
fi
log_message "=========================================="

# Exit with a code that reflects the actual API result. A non-2xx status
# (e.g. 401 Unauthorized, 403, 404, 500) is logged above but must fail here
# explicitly, otherwise the caller would treat a failed upload as success.
if { [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; } && \
   { [ -z "$RESULT_CODE" ] || [ "$RESULT_CODE" = "0" ]; }; then
    exit 0
else
    log_message "ERROR: Exiting with failure - API returned status $HTTP_STATUS and result code ${RESULT_CODE:-unknown}"
    exit 1
fi