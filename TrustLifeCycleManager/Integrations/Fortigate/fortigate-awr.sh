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

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/fortigate.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting FortiGate Certificate Import Script"
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

# Extract Argument_1 - FortiGate URL (without https://)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 (FortiGate URL) extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - Certificate Name
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 (Cert Name) extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - Authorization Bearer Token
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 (Bearer Token) extracted: '[REDACTED]'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument (optional)
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument (optional)
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

# Assign to meaningful variable names for FortiGate integration
FORTIGATE_URL="$ARGUMENT_1"
CERT_NAME="$ARGUMENT_2"
BEARER_TOKEN="$ARGUMENT_3"

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
log_message "FortiGate Configuration:"
log_message "  FortiGate URL: $FORTIGATE_URL"
log_message "  Certificate Name: $CERT_NAME"
log_message "  Bearer Token: [REDACTED - ${#BEARER_TOKEN} characters]"
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
# FORTIGATE CERTIFICATE IMPORT SECTION
# ============================================================================
#
# This section imports the certificate and private key to FortiGate via API
#
# Required Arguments (from TLM Certificate Template):
#   Argument 1: FortiGate URL (without https://) 
#               Example: ec2-18-119-128-230.us-east-2.compute.amazonaws.com
#   Argument 2: Certificate name for FortiGate
#               Example: tlsguru-pem2
#   Argument 3: Authorization Bearer Token
#               Example: abc123
#
# ============================================================================

log_message "=========================================="
log_message "Starting FortiGate Certificate Import..."
log_message "=========================================="

# Validate required arguments
if [ -z "$FORTIGATE_URL" ]; then
    log_message "ERROR: FortiGate URL (Argument 1) is not set"
    exit 1
fi

if [ -z "$CERT_NAME" ]; then
    log_message "ERROR: Certificate Name (Argument 2) is not set"
    exit 1
fi

if [ -z "$BEARER_TOKEN" ]; then
    log_message "ERROR: Bearer Token (Argument 3) is not set"
    exit 1
fi

# Validate certificate and key files exist
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Certificate file does not exist: $CRT_FILE_PATH"
    exit 1
fi

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Private key file does not exist: $KEY_FILE_PATH"
    exit 1
fi

log_message "All validations passed, proceeding with API call..."

# Base64 encode the certificate and key files
log_message "Base64 encoding certificate file..."
CERT_BASE64=$(base64 -w 0 "$CRT_FILE_PATH")
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to base64 encode certificate file"
    exit 1
fi
log_message "Certificate base64 encoded successfully (length: ${#CERT_BASE64} characters)"

log_message "Base64 encoding private key file..."
KEY_BASE64=$(base64 -w 0 "$KEY_FILE_PATH")
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to base64 encode private key file"
    exit 1
fi
log_message "Private key base64 encoded successfully (length: ${#KEY_BASE64} characters)"

# Construct the FortiGate API URL
FORTIGATE_API_URL="https://${FORTIGATE_URL}/api/v2/monitor/vpn-certificate/local/import"
log_message "FortiGate API URL: $FORTIGATE_API_URL"

# Construct the JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
  "type": "regular",
  "scope": "global",
  "certname": "${CERT_NAME}",
  "file_content": "${CERT_BASE64}",
  "key_file_content": "${KEY_BASE64}"
}
EOF
)

log_message "JSON payload constructed (certname: $CERT_NAME)"

# Execute the API call
log_message "Executing FortiGate API call..."
log_message "POST $FORTIGATE_API_URL"

API_RESPONSE=$(curl -k --silent --show-error --write-out "\nHTTP_STATUS:%{http_code}" \
    --location --request POST "$FORTIGATE_API_URL" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$JSON_PAYLOAD" 2>&1)

# Extract HTTP status code and response body
HTTP_STATUS=$(echo "$API_RESPONSE" | grep -oP 'HTTP_STATUS:\K[0-9]+')
RESPONSE_BODY=$(echo "$API_RESPONSE" | sed 's/HTTP_STATUS:[0-9]*$//')

log_message "API Response HTTP Status: $HTTP_STATUS"
log_message "API Response Body: $RESPONSE_BODY"

# Check if the API call was successful
if [ "$HTTP_STATUS" = "200" ]; then
    log_message "SUCCESS: Certificate imported successfully to FortiGate"
    log_message "Certificate Name: $CERT_NAME"
    log_message "FortiGate: $FORTIGATE_URL"
elif [ "$HTTP_STATUS" = "401" ]; then
    log_message "ERROR: Authentication failed (401 Unauthorized)"
    log_message "Please verify the Bearer token is correct"
    exit 1
elif [ "$HTTP_STATUS" = "403" ]; then
    log_message "ERROR: Access forbidden (403 Forbidden)"
    log_message "The API token may not have sufficient permissions"
    exit 1
elif [ "$HTTP_STATUS" = "404" ]; then
    log_message "ERROR: API endpoint not found (404)"
    log_message "Please verify the FortiGate URL and API path"
    exit 1
elif [ "$HTTP_STATUS" = "500" ]; then
    log_message "ERROR: Internal server error (500)"
    log_message "FortiGate encountered an internal error"
    exit 1
elif [ -z "$HTTP_STATUS" ]; then
    log_message "ERROR: Failed to connect to FortiGate"
    log_message "Please verify the FortiGate URL is correct and accessible"
    log_message "Curl output: $API_RESPONSE"
    exit 1
else
    log_message "WARNING: Unexpected HTTP status code: $HTTP_STATUS"
    log_message "Response: $RESPONSE_BODY"
fi

log_message "FortiGate certificate import section completed"
log_message "=========================================="

# ============================================================================
# END OF FORTIGATE CERTIFICATE IMPORT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0