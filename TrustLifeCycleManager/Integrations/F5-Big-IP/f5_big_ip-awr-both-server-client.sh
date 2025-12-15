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
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5server.log"

# BIG-IP SSL Profile Update Configuration
UPDATE_SERVER_SSL_PROFILE="true"  # Set to "true" to enable Server SSL profile update
UPDATE_CLIENT_SSL_PROFILE="true"  # Set to "true" to enable Client SSL profile update

# ============================================================================
# CUSTOM SCRIPT SECTION - BIG-IP F5 API INTEGRATION
# ============================================================================
#
# Arguments mapping:
# $ARGUMENT_1 - Username:Password (e.g., admin:Tra1ning123!)
# $ARGUMENT_2 - BIG-IP IP address or hostname (e.g., ec2-18-117-237-17.us-east-2.compute.amazonaws.com:8443)
# $ARGUMENT_3 - Certificate Name (e.g., ssl-server.com)
# $ARGUMENT_4 - SSL Server Profile name (e.g., serverssl) - only used if UPDATE_SERVER_SSL_PROFILE="true"
# $ARGUMENT_5 - SSL Client Profile name (e.g., clientssl) - only used if UPDATE_CLIENT_SSL_PROFILE="true"
#
# ============================================================================

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
log_message "  UPDATE_SERVER_SSL_PROFILE: $UPDATE_SERVER_SSL_PROFILE"
log_message "  UPDATE_CLIENT_SSL_PROFILE: $UPDATE_CLIENT_SSL_PROFILE"

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

# Log the raw JSON for debugging (with credentials obfuscated)
log_message "=========================================="
log_message "Raw JSON content (credentials obfuscated):"
# Create a filtered version of JSON for logging - obfuscate first argument (credentials)
JSON_STRING_FILTERED=$(echo "$JSON_STRING" | sed 's/"args":\["[^"]*"/"args":["********:********"/1')
log_message "$JSON_STRING_FILTERED"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: [CREDENTIALS HIDDEN]"

# Extract Argument_1 - first argument (Username:Password)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '********:********'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Parse username and password from ARGUMENT_1
BIGIP_USER=""
BIGIP_PASS=""
if [[ "$ARGUMENT_1" == *":"* ]]; then
    BIGIP_USER="${ARGUMENT_1%%:*}"
    BIGIP_PASS="${ARGUMENT_1#*:}"
    log_message "Credentials parsed successfully - Username: '$BIGIP_USER', Password: ********"
else
    log_message "WARNING: ARGUMENT_1 does not contain ':' separator. Expected format: username:password"
fi

# Extract Argument_2 - second argument (BIG-IP Host)
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument (Certificate Name)
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 extracted: '$ARGUMENT_3'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument (Server SSL Profile)
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument (Client SSL Profile)
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments (remove whitespace, newlines, carriage returns)
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
log_message "  Argument 1 (User:Pass): ********:********"
log_message "  Argument 2 (BIG-IP Host): $ARGUMENT_2"
log_message "  Argument 3 (Cert Name): $ARGUMENT_3"
log_message "  Argument 4 (Server SSL Profile): $ARGUMENT_4"
log_message "  Argument 5 (Client SSL Profile): $ARGUMENT_5"
log_message ""
log_message "Parsed credentials:"
log_message "  Username: $BIGIP_USER"
log_message "  Password: ********"
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

log_message "=========================================="
log_message "Starting BIG-IP F5 API Integration..."
log_message "=========================================="

# Set variables from arguments
BIGIP_HOST="$ARGUMENT_2"
CERT_NAME="$ARGUMENT_3"
SERVER_SSL_PROFILE="$ARGUMENT_4"
CLIENT_SSL_PROFILE="$ARGUMENT_5"

# Validate required arguments
if [ -z "$BIGIP_USER" ] || [ -z "$BIGIP_PASS" ] || [ -z "$BIGIP_HOST" ] || [ -z "$CERT_NAME" ]; then
    log_message "ERROR: Missing required arguments for BIG-IP integration"
    log_message "  Username: ${BIGIP_USER:-[EMPTY]}"
    log_message "  Password: [HIDDEN]"
    log_message "  BIG-IP Host (Arg2): $BIGIP_HOST"
    log_message "  Certificate Name (Arg3): $CERT_NAME"
    log_message "Skipping BIG-IP integration due to missing arguments"
else
    log_message "BIG-IP Configuration:"
    log_message "  Host: $BIGIP_HOST"
    log_message "  User: $BIGIP_USER"
    log_message "  Certificate Name: $CERT_NAME"
    log_message "  Update Server SSL Profile: $UPDATE_SERVER_SSL_PROFILE"
    if [ "$UPDATE_SERVER_SSL_PROFILE" = "true" ]; then
        log_message "  Server SSL Profile: $SERVER_SSL_PROFILE"
    fi
    log_message "  Update Client SSL Profile: $UPDATE_CLIENT_SSL_PROFILE"
    if [ "$UPDATE_CLIENT_SSL_PROFILE" = "true" ]; then
        log_message "  Client SSL Profile: $CLIENT_SSL_PROFILE"
    fi
    
    # Ensure files exist before proceeding
    if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
        
        # Step 1: Upload the certificate file
        log_message "Step 1: Uploading certificate file to BIG-IP..."
        CERT_SIZE=$(wc -c < "$CRT_FILE_PATH")
        CERT_RANGE_END=$((CERT_SIZE - 1))
        
        RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
            -X POST \
            -H "Content-Type: application/octet-stream" \
            -H "Content-Range: 0-${CERT_RANGE_END}/${CERT_SIZE}" \
            "https://${BIGIP_HOST}/mgmt/shared/file-transfer/uploads/${CERT_NAME}.crt" \
            --data-binary "@${CRT_FILE_PATH}" \
            -w "\nHTTP_CODE:%{http_code}" \
            2>&1)
        
        HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            log_message "SUCCESS: Certificate file uploaded"
        else
            log_message "ERROR: Failed to upload certificate file. HTTP Code: $HTTP_CODE"
            log_message "Response: $RESPONSE"
        fi
        
        # Step 2: Upload the key file
        log_message "Step 2: Uploading key file to BIG-IP..."
        KEY_SIZE=$(wc -c < "$KEY_FILE_PATH")
        KEY_RANGE_END=$((KEY_SIZE - 1))
        
        RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
            -X POST \
            -H "Content-Type: application/octet-stream" \
            -H "Content-Range: 0-${KEY_RANGE_END}/${KEY_SIZE}" \
            "https://${BIGIP_HOST}/mgmt/shared/file-transfer/uploads/${CERT_NAME}.key" \
            --data-binary "@${KEY_FILE_PATH}" \
            -w "\nHTTP_CODE:%{http_code}" \
            2>&1)
        
        HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            log_message "SUCCESS: Key file uploaded"
        else
            log_message "ERROR: Failed to upload key file. HTTP Code: $HTTP_CODE"
            log_message "Response: $RESPONSE"
        fi
        
        # Step 3: Install certificate
        log_message "Step 3: Installing certificate on BIG-IP..."
        RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
            -X POST \
            -H "Content-Type: application/json" \
            "https://${BIGIP_HOST}/mgmt/tm/sys/crypto/cert" \
            -d "{
                \"command\": \"install\",
                \"name\": \"${CERT_NAME}\",
                \"from-local-file\": \"/var/config/rest/downloads/${CERT_NAME}.crt\"
            }" \
            -w "\nHTTP_CODE:%{http_code}" \
            2>&1)
        
        HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            log_message "SUCCESS: Certificate installed"
        else
            log_message "ERROR: Failed to install certificate. HTTP Code: $HTTP_CODE"
            log_message "Response: $RESPONSE"
        fi
        
        # Step 4: Install key
        log_message "Step 4: Installing key on BIG-IP..."
        RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
            -X POST \
            -H "Content-Type: application/json" \
            "https://${BIGIP_HOST}/mgmt/tm/sys/crypto/key" \
            -d "{
                \"command\": \"install\",
                \"name\": \"${CERT_NAME}\",
                \"from-local-file\": \"/var/config/rest/downloads/${CERT_NAME}.key\"
            }" \
            -w "\nHTTP_CODE:%{http_code}" \
            2>&1)
        
        HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
            log_message "SUCCESS: Key installed"
        else
            log_message "ERROR: Failed to install key. HTTP Code: $HTTP_CODE"
            log_message "Response: $RESPONSE"
        fi
        
        # Step 5: Update Server SSL Profile (if enabled)
        if [ "$UPDATE_SERVER_SSL_PROFILE" = "true" ]; then
            if [ -z "$SERVER_SSL_PROFILE" ]; then
                log_message "WARNING: UPDATE_SERVER_SSL_PROFILE is true but SERVER_SSL_PROFILE (Argument 4) is not set"
                log_message "Skipping Server SSL profile update"
            else
                log_message "Step 5: Updating Server SSL Profile '$SERVER_SSL_PROFILE'..."
                RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
                    -X PATCH \
                    -H "Content-Type: application/json" \
                    "https://${BIGIP_HOST}/mgmt/tm/ltm/profile/server-ssl/${SERVER_SSL_PROFILE}" \
                    -d "{
                        \"cert\": \"/Common/${CERT_NAME}\",
                        \"key\": \"/Common/${CERT_NAME}\"
                    }" \
                    -w "\nHTTP_CODE:%{http_code}" \
                    2>&1)
                
                HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
                if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
                    log_message "SUCCESS: Server SSL Profile '$SERVER_SSL_PROFILE' updated"
                else
                    log_message "ERROR: Failed to update Server SSL Profile. HTTP Code: $HTTP_CODE"
                    log_message "Response: $RESPONSE"
                fi
            fi
        else
            log_message "Step 5: Skipping Server SSL profile update (UPDATE_SERVER_SSL_PROFILE=$UPDATE_SERVER_SSL_PROFILE)"
        fi
        
        # Step 6: Update Client SSL Profile (if enabled)
        if [ "$UPDATE_CLIENT_SSL_PROFILE" = "true" ]; then
            if [ -z "$CLIENT_SSL_PROFILE" ]; then
                log_message "WARNING: UPDATE_CLIENT_SSL_PROFILE is true but CLIENT_SSL_PROFILE (Argument 5) is not set"
                log_message "Skipping Client SSL profile update"
            else
                log_message "Step 6: Updating Client SSL Profile '$CLIENT_SSL_PROFILE'..."
                
                # Step 6a: Get the existing cert-key-chain entry name
                log_message "  Step 6a: Querying existing cert-key-chain entry name..."
                
                PROFILE_RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
                    "https://${BIGIP_HOST}/mgmt/tm/ltm/profile/client-ssl/${CLIENT_SSL_PROFILE}" \
                    2>&1)
                
                # Extract the cert-key-chain entry name using jq if available, otherwise use grep/sed
                if command -v jq &> /dev/null; then
                    ENTRY_NAME=$(echo "$PROFILE_RESPONSE" | jq -r '.certKeyChain[0].name // empty')
                else
                    # Fallback to grep/sed if jq is not available
                    ENTRY_NAME=$(echo "$PROFILE_RESPONSE" | grep -oP '"certKeyChain":\s*\[\s*\{\s*"name":\s*"\K[^"]+' | head -1)
                fi
                
                if [ -n "$ENTRY_NAME" ]; then
                    log_message "  Found existing cert-key-chain entry: '$ENTRY_NAME'"
                    
                    # Step 6b: Modify the existing entry using tmsh via bash API
                    log_message "  Step 6b: Modifying cert-key-chain entry..."
                    
                    RESPONSE=$(curl -sk -u "${BIGIP_USER}:${BIGIP_PASS}" \
                        -X POST \
                        -H "Content-Type: application/json" \
                        "https://${BIGIP_HOST}/mgmt/tm/util/bash" \
                        -d "{
                            \"command\": \"run\",
                            \"utilCmdArgs\": \"-c \\\"tmsh modify ltm profile client-ssl ${CLIENT_SSL_PROFILE} cert-key-chain modify { ${ENTRY_NAME} { cert /Common/${CERT_NAME} key /Common/${CERT_NAME} chain /Common/${CERT_NAME} } }\\\"\"
                        }" \
                        -w "\nHTTP_CODE:%{http_code}" \
                        2>&1)
                    
                    HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
                    
                    # Check for errors in response
                    if echo "$RESPONSE" | grep -qi "error"; then
                        log_message "ERROR: tmsh command returned error"
                        log_message "Response: $RESPONSE"
                    elif [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
                        log_message "SUCCESS: Client SSL Profile '$CLIENT_SSL_PROFILE' updated"
                    else
                        log_message "ERROR: Failed to update Client SSL Profile. HTTP Code: $HTTP_CODE"
                        log_message "Response: $RESPONSE"
                    fi
                else
                    log_message "WARNING: No cert-key-chain entries found in Client SSL Profile '$CLIENT_SSL_PROFILE'"
                    log_message "Cannot update Client SSL profile without existing cert-key-chain entry"
                fi
            fi
        else
            log_message "Step 6: Skipping Client SSL profile update (UPDATE_CLIENT_SSL_PROFILE=$UPDATE_CLIENT_SSL_PROFILE)"
        fi
        
        log_message "BIG-IP integration completed"
        
    else
        log_message "ERROR: Certificate or key files not found. Cannot proceed with BIG-IP integration"
        log_message "  Certificate path: $CRT_FILE_PATH (exists: $([ -f "$CRT_FILE_PATH" ] && echo "yes" || echo "no"))"
        log_message "  Key path: $KEY_FILE_PATH (exists: $([ -f "$KEY_FILE_PATH" ] && echo "yes" || echo "no"))"
    fi
fi

log_message "=========================================="
log_message "BIG-IP F5 API Integration completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0