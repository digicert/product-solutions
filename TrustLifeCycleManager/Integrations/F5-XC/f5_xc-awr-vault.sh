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
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5_xc-data.log"

# Vault Configuration
VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY=true
VAULT_SSM_ROLE_ID_PATH="/vault/myapp/role-id"
VAULT_SSM_SECRET_ID_PATH="/vault/myapp/secret-id"
VAULT_F5XC_TOKEN_PATH="secret/api-keys/f5xc"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to obfuscate sensitive data (shows first 4 and last 4 characters)
obfuscate_token() {
    local token="$1"
    local token_length=${#token}
    
    if [ $token_length -le 8 ]; then
        echo "[REDACTED]"
    else
        local first_part="${token:0:4}"
        local last_part="${token: -4}"
        echo "${first_part}****${last_part}"
    fi
}

# Function to authenticate with Vault and retrieve API token
get_f5xc_token_from_vault() {
    log_message "=========================================="
    log_message "Starting Vault authentication and token retrieval"
    log_message "=========================================="
    
    # Check if AWS CLI is available
    if ! command -v aws &> /dev/null; then
        log_message "ERROR: AWS CLI not found. Please install AWS CLI."
        return 1
    fi
    
    # Check if Vault CLI is available
    if ! command -v vault &> /dev/null; then
        log_message "ERROR: Vault CLI not found. Please install Vault."
        return 1
    fi
    
    log_message "Retrieving AppRole credentials from AWS SSM Parameter Store..."
    
    # Get Role ID from SSM
    ROLE_ID=$(aws ssm get-parameter \
        --name "$VAULT_SSM_ROLE_ID_PATH" \
        --query 'Parameter.Value' \
        --output text 2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to retrieve Role ID from SSM"
        log_message "Error details: $ROLE_ID"
        return 1
    fi
    log_message "Successfully retrieved Role ID from SSM"
    
    # Get Secret ID from SSM (encrypted)
    SECRET_ID=$(aws ssm get-parameter \
        --name "$VAULT_SSM_SECRET_ID_PATH" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text 2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to retrieve Secret ID from SSM"
        log_message "Error details: $SECRET_ID"
        return 1
    fi
    log_message "Successfully retrieved Secret ID from SSM"
    
    # Authenticate with Vault using AppRole
    log_message "Authenticating with Vault using AppRole..."
    VAULT_TOKEN=$(vault write -field=token auth/approle/login \
        role_id="$ROLE_ID" \
        secret_id="$SECRET_ID" 2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to authenticate with Vault"
        log_message "Error details: $VAULT_TOKEN"
        return 1
    fi
    
    export VAULT_TOKEN
    log_message "Successfully authenticated with Vault"
    
    # Retrieve F5XC API Token from Vault
    log_message "Retrieving F5XC API token from Vault path: $VAULT_F5XC_TOKEN_PATH"
    F5XC_API_TOKEN=$(vault kv get -field=api_token "$VAULT_F5XC_TOKEN_PATH" 2>&1)
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to retrieve F5XC API token from Vault"
        log_message "Error details: $F5XC_API_TOKEN"
        return 1
    fi
    
    # Validate token was retrieved
    if [ -z "$F5XC_API_TOKEN" ]; then
        log_message "ERROR: Retrieved F5XC API token is empty"
        return 1
    fi
    
    log_message "Successfully retrieved F5XC API token from Vault"
    log_message "API Token: $(obfuscate_token "$F5XC_API_TOKEN")"
    
    # Export for use in the script
    export F5XC_API_TOKEN
    
    # Clean up Vault token from environment after use (optional for security)
    # unset VAULT_TOKEN
    
    return 0
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
log_message "  VAULT_ADDR: $VAULT_ADDR"
log_message "  VAULT_SSM_ROLE_ID_PATH: $VAULT_SSM_ROLE_ID_PATH"
log_message "  VAULT_SSM_SECRET_ID_PATH: $VAULT_SSM_SECRET_ID_PATH"
log_message "  VAULT_F5XC_TOKEN_PATH: $VAULT_F5XC_TOKEN_PATH"

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

# Log the raw JSON for debugging (Note: No API token in arguments anymore)
log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract Argument_1 - first argument (F5XC Tenant)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - second argument (F5XC Namespace)
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument (F5XC Certificate Name)
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 extracted: '$ARGUMENT_3'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Note: Argument_4 (API Token) removed - will be retrieved from Vault

# Extract Argument_5 - fifth argument (if still needed)
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ -n "$ARGUMENT_5" ]; then
    log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
    log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"
fi

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
if [ -n "$ARGUMENT_5" ]; then
    ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')
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

# Extract all files from the files array
FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

# Retrieve F5XC API Token from Vault
log_message "=========================================="
log_message "Retrieving F5XC API Token from Vault"
log_message "=========================================="

if ! get_f5xc_token_from_vault; then
    log_message "ERROR: Failed to retrieve F5XC API token from Vault"
    log_message "Script will continue but F5XC upload will be skipped"
    F5XC_API_TOKEN=""
fi

# Log summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Arguments extracted:"
log_message "  Argument 1 (Tenant): $ARGUMENT_1"
log_message "  Argument 2 (Namespace): $ARGUMENT_2"
log_message "  Argument 3 (Certificate Name): $ARGUMENT_3"
log_message "  API Token: Retrieved from Vault - $(obfuscate_token "$F5XC_API_TOKEN")"
if [ -n "$ARGUMENT_5" ]; then
    log_message "  Argument 5: $ARGUMENT_5"
fi
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
log_message "Starting F5 XC Certificate Upload"
log_message "=========================================="

# F5 XC Configuration from arguments and Vault
F5XC_TENANT="$ARGUMENT_1"
F5XC_NAMESPACE="$ARGUMENT_2"
F5XC_CERT_NAME="$ARGUMENT_3"
# F5XC_API_TOKEN already set from Vault retrieval

# Validate required parameters
if [ -z "$F5XC_TENANT" ] || [ -z "$F5XC_NAMESPACE" ] || [ -z "$F5XC_CERT_NAME" ] || [ -z "$F5XC_API_TOKEN" ]; then
    log_message "ERROR: Missing required F5 XC parameters"
    log_message "  Tenant: $F5XC_TENANT"
    log_message "  Namespace: $F5XC_NAMESPACE"
    log_message "  Certificate Name: $F5XC_CERT_NAME"
    log_message "  API Token: $(obfuscate_token "$F5XC_API_TOKEN")"
    log_message "Skipping F5 XC certificate upload"
else
    # Check if certificate and key files exist
    if [ ! -f "$CRT_FILE_PATH" ]; then
        log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
        log_message "Skipping F5 XC certificate upload"
    elif [ ! -f "$KEY_FILE_PATH" ]; then
        log_message "ERROR: Private key file not found: $KEY_FILE_PATH"
        log_message "Skipping F5 XC certificate upload"
    else
        # Proceed with F5 XC upload
        log_message "F5 XC Configuration:"
        log_message "  Tenant: $F5XC_TENANT"
        log_message "  Namespace: $F5XC_NAMESPACE"
        log_message "  Certificate Name: $F5XC_CERT_NAME"
        log_message "  API Token: $(obfuscate_token "$F5XC_API_TOKEN")"
        log_message "  Certificate File: $CRT_FILE_PATH"
        log_message "  Key File: $KEY_FILE_PATH"
        
        # Construct base URL
        F5XC_BASE_URL="https://${F5XC_TENANT}.console.ves.volterra.io/api/config/namespaces/${F5XC_NAMESPACE}/certificates"
        log_message "F5 XC Base URL: $F5XC_BASE_URL"
        
        # Function to check if certificate exists in F5 XC
        check_f5xc_certificate_exists() {
            local response
            response=$(curl -s -w "\n%{http_code}" -X GET \
                "${F5XC_BASE_URL}/${F5XC_CERT_NAME}" \
                -H "Authorization: APIToken ${F5XC_API_TOKEN}" \
                -H "Content-Type: application/json" 2>&1)
            
            local http_code=$(echo "$response" | tail -n1)
            
            if [ "$http_code" = "200" ]; then
                return 0  # Certificate exists
            else
                return 1  # Certificate doesn't exist
            fi
        }
        
        # Function to upload new certificate to F5 XC
        upload_f5xc_certificate() {
            log_message "Uploading new certificate '${F5XC_CERT_NAME}' to F5 XC..."
            
            # Base64 encode certificate and key
            local cert_b64=$(cat "${CRT_FILE_PATH}" | base64 -w 0)
            local key_b64=$(cat "${KEY_FILE_PATH}" | base64 -w 0)
            
            local response
            response=$(curl -s -w "\n%{http_code}" -X POST \
                "${F5XC_BASE_URL}" \
                -H "Authorization: APIToken ${F5XC_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{
                    "metadata": {
                        "name": "'"${F5XC_CERT_NAME}"'",
                        "namespace": "'"${F5XC_NAMESPACE}"'"
                    },
                    "spec": {
                        "certificate_url": "string:///'"${cert_b64}"'",
                        "private_key": {
                            "clear_secret_info": {
                                "url": "string:///'"${key_b64}"'"
                            }
                        }
                    }
                }' 2>&1)
            
            local http_code=$(echo "$response" | tail -n1)
            local body=$(echo "$response" | sed '$d')
            
            if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
                log_message "SUCCESS: Certificate uploaded to F5 XC!"
                return 0
            else
                log_message "ERROR: Failed to upload certificate to F5 XC. HTTP Code: ${http_code}"
                # Obfuscate any API tokens that might appear in error responses
                local obfuscated_body=$(echo "$body" | sed "s/${F5XC_API_TOKEN}/$(obfuscate_token "$F5XC_API_TOKEN")/g")
                log_message "Response body: $obfuscated_body"
                return 1
            fi
        }
        
        # Function to replace existing certificate in F5 XC
        replace_f5xc_certificate() {
            log_message "Replacing existing certificate '${F5XC_CERT_NAME}' in F5 XC..."
            
            # Base64 encode certificate and key
            local cert_b64=$(cat "${CRT_FILE_PATH}" | base64 -w 0)
            local key_b64=$(cat "${KEY_FILE_PATH}" | base64 -w 0)
            
            local response
            response=$(curl -s -w "\n%{http_code}" -X PUT \
                "${F5XC_BASE_URL}/${F5XC_CERT_NAME}" \
                -H "Authorization: APIToken ${F5XC_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d '{
                    "metadata": {
                        "name": "'"${F5XC_CERT_NAME}"'",
                        "namespace": "'"${F5XC_NAMESPACE}"'"
                    },
                    "spec": {
                        "certificate_url": "string:///'"${cert_b64}"'",
                        "private_key": {
                            "clear_secret_info": {
                                "url": "string:///'"${key_b64}"'"
                            }
                        }
                    }
                }' 2>&1)
            
            local http_code=$(echo "$response" | tail -n1)
            local body=$(echo "$response" | sed '$d')
            
            if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
                log_message "SUCCESS: Certificate replaced in F5 XC!"
                return 0
            else
                log_message "ERROR: Failed to replace certificate in F5 XC. HTTP Code: ${http_code}"
                # Obfuscate any API tokens that might appear in error responses
                local obfuscated_body=$(echo "$body" | sed "s/${F5XC_API_TOKEN}/$(obfuscate_token "$F5XC_API_TOKEN")/g")
                log_message "Response body: $obfuscated_body"
                return 1
            fi
        }
        
        # Function to verify certificate in F5 XC
        verify_f5xc_certificate() {
            log_message "Verifying certificate in F5 XC..."
            
            local response
            response=$(curl -s -X GET \
                "${F5XC_BASE_URL}/${F5XC_CERT_NAME}" \
                -H "Authorization: APIToken ${F5XC_API_TOKEN}" \
                -H "Content-Type: application/json" 2>&1)
            
            # Extract relevant information
            local cert_name=$(echo "$response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"\([^"]*\)"/\1/')
            local expiry=$(echo "$response" | grep -o '"expiry_timestamp":"[^"]*"' | sed 's/"expiry_timestamp":"\([^"]*\)"/\1/')
            
            if [ -n "$cert_name" ]; then
                log_message "Certificate verified in F5 XC:"
                log_message "  Name: ${cert_name}"
                if [ -n "$expiry" ]; then
                    log_message "  Expiry: ${expiry}"
                fi
            else
                log_message "WARNING: Could not parse certificate details from F5 XC"
            fi
        }
        
        # Main F5 XC upload logic
        log_message "Checking if certificate '${F5XC_CERT_NAME}' exists in F5 XC namespace '${F5XC_NAMESPACE}'..."
        
        if check_f5xc_certificate_exists; then
            log_message "Certificate exists in F5 XC. Proceeding with replacement..."
            
            if replace_f5xc_certificate; then
                verify_f5xc_certificate
                log_message "F5 XC certificate replacement completed successfully"
            else
                log_message "ERROR: Failed to replace certificate in F5 XC"
            fi
        else
            log_message "Certificate does not exist in F5 XC. Proceeding with upload..."
            
            if upload_f5xc_certificate; then
                verify_f5xc_certificate
                log_message "F5 XC certificate upload completed successfully"
            else
                log_message "ERROR: Failed to upload certificate to F5 XC"
            fi
        fi
    fi
fi

log_message "=========================================="
log_message "F5 XC Certificate Upload Section Completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0