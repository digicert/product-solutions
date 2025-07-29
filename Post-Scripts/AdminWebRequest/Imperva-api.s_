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
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/template.log"



# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
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

# Log extracted arguments summary
log_message "Extracted arguments summary:"
log_message "  ARGUMENT_1: '$ARGUMENT_1'"
log_message "  ARGUMENT_2: '$ARGUMENT_2'"
log_message "  ARGUMENT_3: '$ARGUMENT_3'"
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

# Read certificate and key using dynamically constructed paths
log_message "Reading certificate and key files..."
CERT=$(cat "${CRT_FILE_PATH}" | sed 's/$/\\n/' | tr -d '\n')
KEY=$(cat "${KEY_FILE_PATH}" | sed 's/$/\\n/' | tr -d '\n')

# Log certificate and key lengths
log_message "Certificate content length: ${#CERT} characters"
log_message "Key content length: ${#KEY} characters"

# Extract certificate data without headers and footers (single line)
log_message "Extracting certificate and key data without headers/footers..."

# Extract certificate data (remove BEGIN/END CERTIFICATE lines and join all lines)
CERT_DATA_ONLY=$(cat "${CRT_FILE_PATH}" | grep -v "BEGIN CERTIFICATE" | grep -v "END CERTIFICATE" | tr -d '\n' | tr -d '\r' | tr -d ' ')
log_message "Certificate data extracted (without headers/footers)"
log_message "CERT_DATA_ONLY length: ${#CERT_DATA_ONLY} characters"

# Extract private key data (remove BEGIN/END PRIVATE KEY lines and join all lines)
KEY_DATA_ONLY=$(cat "${KEY_FILE_PATH}" | grep -v "BEGIN.*PRIVATE KEY" | grep -v "END.*PRIVATE KEY" | tr -d '\n' | tr -d '\r' | tr -d ' ')
log_message "Private key data extracted (without headers/footers)"
log_message "KEY_DATA_ONLY length: ${#KEY_DATA_ONLY} characters"

# Log truncated certificate and key data (first 20 characters)
CERT_TRUNCATED="${CERT_DATA_ONLY:0:20}"
KEY_TRUNCATED="${KEY_DATA_ONLY:0:20}"

log_message "Certificate data (truncated to 20 chars): $CERT_TRUNCATED"
log_message "Private key data (truncated to 20 chars): $KEY_TRUNCATED"

# Validate that we have actual data
if [ -z "$CERT_DATA_ONLY" ]; then
    log_message "WARNING: Certificate data extraction resulted in empty string"
else
    log_message "Certificate data extraction successful"
fi

if [ -z "$KEY_DATA_ONLY" ]; then
    log_message "WARNING: Private key data extraction resulted in empty string"
else
    log_message "Private key data extraction successful"
fi

# Write variables to output
log_message "Writing extracted variables:"
log_message "  Argument 1: $ARGUMENT_1"
log_message "  Argument 2: $ARGUMENT_2"
log_message "  Argument 3: $ARGUMENT_3"
log_message "  Argument 4: $ARGUMENT_4"
log_message "  Argument 5: $ARGUMENT_5"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Key file: $KEY_FILE"
log_message "  Certificate file path: $CRT_FILE_PATH"
log_message "  Key file path: $KEY_FILE_PATH"
log_message "  Certificate data only (length): ${#CERT_DATA_ONLY} characters"
log_message "  Private key data only (length): ${#KEY_DATA_ONLY} characters"

# Prepare certificate and key data for API call (without headers/footers)
log_message "Preparing certificate and key data for API call (without headers/footers)..."

# Use the certificate and key data without headers/footers for API
CERT_FOR_API="$CERT_DATA_ONLY"
KEY_FOR_API="$KEY_DATA_ONLY"

log_message "Certificate prepared for API (length: ${#CERT_FOR_API} characters)"
log_message "Private key prepared for API (length: ${#KEY_FOR_API} characters)"

# Log truncated plaintext values for verification
CERT_API_TRUNCATED="${CERT_FOR_API:0:20}"
KEY_API_TRUNCATED="${KEY_FOR_API:0:20}"
log_message "Certificate for API (truncated to 20 chars): $CERT_API_TRUNCATED"
log_message "Private key for API (truncated to 20 chars): $KEY_API_TRUNCATED"

# Prepare API call parameters
SITE_ID="$ARGUMENT_1"
API_ID="$ARGUMENT_2"
API_KEY="$ARGUMENT_3"

log_message "API call parameters:"
log_message "  Site ID: $SITE_ID"
log_message "  API ID: $API_ID"
log_message "  API Key: ${API_KEY:0:10}..." # Only show first 10 chars of API key for security

# Determine auth_type based on key content
if echo "$KEY_DATA_ONLY" | grep -q "BEGIN RSA PRIVATE KEY\|RSA"; then
    AUTH_TYPE="RSA"
elif echo "$KEY_DATA_ONLY" | grep -q "BEGIN EC PRIVATE KEY\|EC"; then
    AUTH_TYPE="ECC"
else
    AUTH_TYPE="RSA"  # Default to RSA
fi

log_message "Detected auth_type: $AUTH_TYPE"

# Make API call to Imperva
log_message "=========================================="
log_message "Making API call to Imperva..."
log_message "URL: https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"
log_message "=========================================="

API_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}\n" -X 'PUT' \
  "https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate" \
  -H 'accept: application/json' \
  -H "x-API-Id: $API_ID" \
  -H "x-API-Key: $API_KEY" \
  -H 'Content-Type: application/json' \
  -d "{
  \"certificate\": \"$CERT_FOR_API\",
  \"private_key\": \"$KEY_FOR_API\",
  \"auth_type\": \"$AUTH_TYPE\"
}")

# Extract HTTP status code and response body
HTTP_STATUS=$(echo "$API_RESPONSE" | grep "HTTP_STATUS:" | cut -d: -f2)
RESPONSE_BODY=$(echo "$API_RESPONSE" | grep -v "HTTP_STATUS:")

log_message "API call completed"
log_message "HTTP Status Code: $HTTP_STATUS"
log_message "Response Body: $RESPONSE_BODY"

# Check if API call was successful
if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
    log_message "SUCCESS: Certificate uploaded successfully to Imperva"
else
    log_message "ERROR: API call failed with status $HTTP_STATUS"
    log_message "Response: $RESPONSE_BODY"
fi

log_message "=========================================="
log_message "Variable extraction and API upload completed"
log_message "Available variables:"
log_message "  CERT - Full certificate with headers/footers (escaped newlines)"
log_message "  KEY - Full private key with headers/footers (escaped newlines)"
log_message "  CERT_DATA_ONLY - Certificate data without headers/footers (single line)"
log_message "  KEY_DATA_ONLY - Private key data without headers/footers (single line)"
log_message "  CERT_FOR_API - Certificate without headers/footers for API (same as CERT_DATA_ONLY)"
log_message "  KEY_FOR_API - Private key without headers/footers for API (same as KEY_DATA_ONLY)"
log_message "=========================================="

exit 0