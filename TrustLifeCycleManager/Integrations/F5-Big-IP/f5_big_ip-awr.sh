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
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/dc1_data.log"

# BIG-IP SSL Profile Update Configuration
UPDATE_SSL_PROFILE="true"  # Set to "true" to enable SSL profile update

# ============================================================================
# CUSTOM SCRIPT SECTION - BIG-IP F5 API INTEGRATION
# ============================================================================
#
# Arguments mapping:
# $ARGUMENT_1 - Username (e.g., admin)
# $ARGUMENT_2 - Password (e.g., Tra1ning!)
# $ARGUMENT_3 - BIG-IP IP address or hostname (e.g., ec2-18-117-237-17.us-east-2.compute.amazonaws.com:8443)
# $ARGUMENT_4 - Certificate Name (e.g., ssl-server.com)
# $ARGUMENT_5 - SSL Server Profile name (e.g., serverssl) - only used if UPDATE_SSL_PROFILE="true"
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

# Log the raw JSON for debugging (with password obfuscated)
log_message "=========================================="
log_message "Raw JSON content (password obfuscated):"
# Create a filtered version of JSON for logging
# First, extract the args array and replace the second argument (password)
ARGS_FOR_LOGGING=$(echo "$ARGS_ARRAY" | awk -F',' '{
    for(i=1; i<=NF; i++) {
        if(i==2) printf "\"********\"";
        else printf "%s", $i;
        if(i<NF) printf ",";
    }
}')
# Replace the original args array in JSON with the obfuscated one
JSON_STRING_FILTERED=$(echo "$JSON_STRING" | sed "s/\"args\":\[[^]]*\]/\"args\":[${ARGS_FOR_LOGGING}]/")
log_message "$JSON_STRING_FILTERED"
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

# Extract Argument_2 - second argument (PASSWORD - will be obfuscated in logs)
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
# Obfuscate password for logging
if [ ! -z "$ARGUMENT_2" ]; then
    ARGUMENT_2_OBFUSCATED="********"
else
    ARGUMENT_2_OBFUSCATED="[EMPTY]"
fi
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2_OBFUSCATED'"
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
log_message "  Argument 1 (Username): $ARGUMENT_1"
log_message "  Argument 2 (Password): $ARGUMENT_2_OBFUSCATED"
log_message "  Argument 3 (BIG-IP Host): $ARGUMENT_3"
log_message "  Argument 4 (Cert Name): $ARGUMENT_4"
log_message "  Argument 5 (SSL Profile): $ARGUMENT_5"
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

# Validate required arguments
if [ -z "$ARGUMENT_1" ] || [ -z "$ARGUMENT_2" ] || [ -z "$ARGUMENT_3" ] || [ -z "$ARGUMENT_4" ]; then
    log_message "ERROR: Missing required arguments for BIG-IP integration"
    log_message "  Username (Arg1): $ARGUMENT_1"
    log_message "  Password (Arg2): [HIDDEN]"
    log_message "  BIG-IP Host (Arg3): $ARGUMENT_3"
    log_message "  Certificate Name (Arg4): $ARGUMENT_4"
    log_message "Skipping BIG-IP integration due to missing arguments"
else
    # Set variables from arguments
    BIGIP_USER="$ARGUMENT_1"
    BIGIP_PASS="$ARGUMENT_2"
    BIGIP_HOST="$ARGUMENT_3"
    CERT_NAME="$ARGUMENT_4"
    SSL_PROFILE="$ARGUMENT_5"
    
    log_message "BIG-IP Configuration:"
    log_message "  Host: $BIGIP_HOST"
    log_message "  User: $BIGIP_USER"
    log_message "  Certificate Name: $CERT_NAME"
    log_message "  Update SSL Profile: $UPDATE_SSL_PROFILE"
    if [ "$UPDATE_SSL_PROFILE" = "true" ]; then
        log_message "  SSL Profile: $SSL_PROFILE"
    fi
    
    # Ensure files exist before proceeding
    if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
        
        # Step 1: Upload the certificate file
        log_message "Step 1: Uploading certificate file to BIG-IP..."
        CERT_SIZE=$(wc -c < "$CRT_FILE_PATH")
        CERT_RANGE_END=$((CERT_SIZE - 1))
        
        RESPONSE=$(curl -k -u "${BIGIP_USER}:${BIGIP_PASS}" \
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
        
        RESPONSE=$(curl -k -u "${BIGIP_USER}:${BIGIP_PASS}" \
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
        RESPONSE=$(curl -k -u "${BIGIP_USER}:${BIGIP_PASS}" \
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
        RESPONSE=$(curl -k -u "${BIGIP_USER}:${BIGIP_PASS}" \
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
        if [ "$UPDATE_SSL_PROFILE" = "true" ]; then
            if [ -z "$SSL_PROFILE" ]; then
                log_message "WARNING: UPDATE_SSL_PROFILE is true but SSL_PROFILE (Argument 5) is not set"
                log_message "Skipping SSL profile update"
            else
                log_message "Step 5: Updating Server SSL Profile..."
                RESPONSE=$(curl -k -u "${BIGIP_USER}:${BIGIP_PASS}" \
                    -X PATCH \
                    -H "Content-Type: application/json" \
                    "https://${BIGIP_HOST}/mgmt/tm/ltm/profile/server-ssl/${SSL_PROFILE}" \
                    -d "{
                        \"cert\": \"/Common/${CERT_NAME}\",
                        \"key\": \"/Common/${CERT_NAME}\"
                    }" \
                    -w "\nHTTP_CODE:%{http_code}" \
                    2>&1)
                
                HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
                if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
                    log_message "SUCCESS: Server SSL Profile updated"
                else
                    log_message "ERROR: Failed to update Server SSL Profile. HTTP Code: $HTTP_CODE"
                    log_message "Response: $RESPONSE"
                fi
            fi
        else
            log_message "Step 5: Skipping SSL profile update (UPDATE_SSL_PROFILE=$UPDATE_SSL_PROFILE)"
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