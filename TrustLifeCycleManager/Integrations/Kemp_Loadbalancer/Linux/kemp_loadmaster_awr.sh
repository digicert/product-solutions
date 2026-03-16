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
as applicable, and the Technical Data - Commercial Items cl... at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/kemp.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to obfuscate credentials in URLs
obfuscate_url() {
    local url="$1"
    # Check if URL contains credentials (username:password@)
    if echo "$url" | grep -q '://[^@]*:[^@]*@'; then
        # Extract parts of the URL
        local scheme=$(echo "$url" | sed 's/\(.*:\/\/\).*/\1/')
        local creds=$(echo "$url" | sed 's/.*:\/\/\([^@]*\)@.*/\1/')
        local rest=$(echo "$url" | sed 's/.*@\(.*\)/\1/')
        
        # Split credentials
        local username=$(echo "$creds" | cut -d: -f1)
        local password=$(echo "$creds" | cut -d: -f2-)
        
        # Obfuscate username (show first 3 chars)
        local obs_user=""
        if [ ${#username} -le 3 ]; then
            obs_user="${username}"
        else
            obs_user="${username:0:3}***"
        fi
        
        # Obfuscate password (show first 3 chars)
        local obs_pass=""
        if [ ${#password} -le 3 ]; then
            obs_pass="${password}"
        else
            obs_pass="${password:0:3}***"
        fi
        
        # Return obfuscated URL
        echo "${scheme}${obs_user}:${obs_pass}@${rest}"
    else
        # No credentials in URL, return as-is
        echo "$url"
    fi
}

# Function to obfuscate standalone strings (for arguments if needed)
obfuscate_string() {
    local str="$1"
    local show_chars="${2:-3}"  # Default to showing 3 chars
    
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

# Log the raw JSON for debugging (with obfuscation if it contains sensitive data)
log_message "=========================================="
log_message "Raw JSON content: [Content logged but check for sensitive data]"
# Note: Not logging raw JSON to avoid exposing credentials that might be in args
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Args array extracted (not logging raw content for security)"

# Extract Argument_1 - first argument
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$(obfuscate_url "$ARGUMENT_1")'"
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

# Build full paths
CRT_FILE_PATH="$CERT_FOLDER/$CRT_FILE"
KEY_FILE_PATH="$CERT_FOLDER/$KEY_FILE"

log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Arguments extracted:"
log_message "  Argument 1: $(obfuscate_url "$ARGUMENT_1")"
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

# Check if files exist & basic metadata
if [ -f "$CRT_FILE_PATH" ]; then
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"
    CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
    log_message "Total certificates in file: $CERT_COUNT"
else
    log_message "WARNING: Certificate file not found: $CRT_FILE_PATH"
fi

if [ -f "$KEY_FILE_PATH" ]; then
    log_message "Private key file exists: $KEY_FILE_PATH"
    log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"
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
# CUSTOM SCRIPT SECTION - KEMP LOADMASTER CERTIFICATE DEPLOYMENT
# ============================================================================
#
# This section uploads a certificate and private key to a Kemp LoadMaster (LM)
# and assigns the certificate to a target Virtual Service (VS).
#
# ARGUMENTS (from the JSON "args" array in DC1_POST_SCRIPT_DATA)
# ---------------------------------------------------------------------------
#   ARGUMENT_1  Base URL **including scheme, credentials, host and port** of
#               the LoadMaster REST API endpoint.
#               Example:
#               https://bal:Tra1ning123!@ec2-3-145-191-244.us-east-2.compute.amazonaws.com:8444
#
#   ARGUMENT_2  Virtual Service IP address to update.
#               Example: 172.31.7.5
#
#   ARGUMENT_3  Virtual Service port to update.
#               Example: 443
#
#   ARGUMENT_4  Certificate name (identifier) on the LoadMaster.
#               This is how the certificate will appear in the LM UI/API.
#               Example: Certificate
#
#   ARGUMENT_5  (Optional / currently unused) Reserved for future use.
#
# WHAT THIS SECTION DOES
# ---------------------------------------------------------------------------
# 1) Combine the CRT and KEY that were just downloaded by DigiCert into a
#    single PEM bundle:
#       cat <certificate.crt> <private.key> > <CertificateName>.pem
# 2) Check the LoadMaster for an existing certificate with that name:
#       GET  {ARG1}/access/listcert
#    (response is XML; parsed with xmllint if available, else grep)
# 3) Upload the PEM to the LoadMaster:
#       POST {ARG1}/access/addcert?cert={ARG4}&replace={0|1}
#       Body: --data-binary @<CertificateName>.pem
#       Headers: Content-Type: application/x-x509-ca-cert
# 4) Assign the certificate to the Virtual Service:
#       GET  {ARG1}/access/modvs?vs={ARG2}&port={ARG3}&prot=tcp&CertFile={ARG4}
#
# NOTE:
# - The combined PEM should contain your full server cert plus private key.
#   If your .crt already includes the intermediate chain, it will be preserved.
# - The REST API is typically XML-based and must be enabled on the LoadMaster.
#   See official docs for enabling and using the API.
# ============================================================================

log_message "=========================================="
log_message "Starting Kemp LoadMaster certificate deployment..."
log_message "=========================================="

# Validate required arguments for Kemp flow
if [ -z "$ARGUMENT_1" ]; then
    log_message "ERROR: Argument 1 (Base URL with credentials) is not provided"
    exit 1
fi

if [ -z "$ARGUMENT_2" ]; then
    log_message "ERROR: Argument 2 (Virtual Service IP) is not provided"
    exit 1
fi

if [ -z "$ARGUMENT_3" ]; then
    log_message "ERROR: Argument 3 (Virtual Service Port) is not provided"
    exit 1
fi

if [ -z "$ARGUMENT_4" ]; then
    log_message "ERROR: Argument 4 (Certificate Name) is not provided"
    exit 1
fi

BASE_URL="$ARGUMENT_1"
VS_IP="$ARGUMENT_2"
VS_PORT="$ARGUMENT_3"
CERT_NAME="$ARGUMENT_4"

log_message "Kemp target:"
log_message "  Base URL: $(obfuscate_url "$BASE_URL")"
log_message "  VS: $VS_IP:$VS_PORT (tcp)"
log_message "  Certificate name: $CERT_NAME"

# Step 1: Build combined PEM (cert + key)
COMBINED_PEM_PATH="${CERT_FOLDER}/${CERT_NAME}.pem"
if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
    log_message "Combining certificate and key into PEM..."
    # Your example: cat cert_file key_file > combined.pem
    cat "$CRT_FILE_PATH" "$KEY_FILE_PATH" > "$COMBINED_PEM_PATH"
    chmod 600 "$COMBINED_PEM_PATH"
    log_message "Combined PEM created: $COMBINED_PEM_PATH"
    log_message "Combined PEM size: $(stat -c%s "$COMBINED_PEM_PATH") bytes"
else
    log_message "ERROR: Missing certificate or key file."
    log_message "  Expected certificate: $CRT_FILE_PATH"
    log_message "  Expected key:         $KEY_FILE_PATH"
    exit 1
fi

# Clean up the combined PEM on script exit
# trap 'rm -f "$COMBINED_PEM_PATH"' EXIT

# Step 2: Check if certificate already exists on LoadMaster
LISTCERT_URL="${BASE_URL}/access/listcert"
log_message "Checking certificate existence via: $(obfuscate_url "$LISTCERT_URL")"

LIST_RESPONSE=$(curl -k --location --silent --show-error "$LISTCERT_URL" --write-out "\nHTTP_STATUS:%{http_code}" 2>&1 || true)
LIST_STATUS=$(echo "$LIST_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
LIST_BODY=$(echo "$LIST_RESPONSE" | sed '/HTTP_STATUS:/d')

log_message "listcert HTTP status: $LIST_STATUS"
# log_message "listcert response body: $LIST_BODY"  # Commented out for security

CERT_EXISTS="false"
if command -v xmllint >/dev/null 2>&1; then
    if echo "$LIST_BODY" | xmllint --format --xpath "boolean(//name[text()='$CERT_NAME'])" - 2>/dev/null | grep -qi 'true'; then
        CERT_EXISTS="true"
    fi
else
    # Fallback if xmllint is unavailable
    if echo "$LIST_BODY" | grep -q "<name>${CERT_NAME}</name>"; then
        CERT_EXISTS="true"
    fi
fi
log_message "Certificate '$CERT_NAME' exists on LoadMaster? $CERT_EXISTS"

# Step 3: Upload or overwrite the certificate
UPLOAD_URL="${BASE_URL}/access/addcert?cert=${CERT_NAME}"
if [ "$CERT_EXISTS" = "true" ]; then
    UPLOAD_URL="${UPLOAD_URL}&replace=1"
    log_message "Certificate exists; will POST with replace=1"
else
    log_message "Certificate not found; will POST without replace=1"
fi

log_message "Uploading PEM to: $(obfuscate_url "$UPLOAD_URL")"
UPLOAD_RESPONSE=$(curl -k --location --silent --show-error \
    --header 'Content-Type: application/x-x509-ca-cert' \
    --data-binary "@${COMBINED_PEM_PATH}" \
    "$UPLOAD_URL" \
    --write-out "\nHTTP_STATUS:%{http_code}" 2>&1 || true)

UPLOAD_STATUS=$(echo "$UPLOAD_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | sed '/HTTP_STATUS:/d')

log_message "addcert HTTP status: $UPLOAD_STATUS"

log_message "addcert response body: $UPLOAD_BODY"

# Only log non-sensitive parts of response
if echo "$UPLOAD_BODY" | grep -q "Success\|success\|OK"; then
    log_message "addcert response: Success"
else
    log_message "addcert response: [Response received - check status]"
fi

if [ "$UPLOAD_STATUS" != "200" ] && [ "$UPLOAD_STATUS" != "201" ]; then
    log_message "ERROR: Certificate upload failed."
    exit 1
fi

# Step 4: Assign the certificate to the Virtual Service
ASSIGN_URL="${BASE_URL}/access/modvs?vs=${VS_IP}&port=${VS_PORT}&prot=tcp&CertFile=${CERT_NAME}"
log_message "Assigning certificate to VS via: $(obfuscate_url "$ASSIGN_URL")"

ASSIGN_RESPONSE=$(curl -k --location --silent --show-error \
    "$ASSIGN_URL" \
    --write-out "\nHTTP_STATUS:%{http_code}" 2>&1 || true)

ASSIGN_STATUS=$(echo "$ASSIGN_RESPONSE" | sed -n 's/^HTTP_STATUS://p')
ASSIGN_BODY=$(echo "$ASSIGN_RESPONSE" | sed '/HTTP_STATUS:/d')

log_message "modvs HTTP status: $ASSIGN_STATUS"
# Only log non-sensitive parts of response
if echo "$ASSIGN_BODY" | grep -q "Success\|success\|OK"; then
    log_message "modvs response: Success"
else
    log_message "modvs response: [Response received - check status]"
fi

if [ "$ASSIGN_STATUS" = "200" ] || [ "$ASSIGN_STATUS" = "201" ]; then
    log_message "SUCCESS: '${CERT_NAME}' assigned to VS ${VS_IP}:${VS_PORT}"
else
    log_message "WARNING: modvs returned non-success status; verify assignment in the LM UI."
fi

log_message "Kemp LoadMaster certificate deployment section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0
