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
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/cloudflare-awr.log"

BUNDLE_METHOD="force"  # Can be "ubiquitous", "optimal", or "force"

# Certificate type configuration:
# "legacy_custom" - Custom Legacy (supports non-SNI clients, broader compatibility)
# "sni_custom" - Custom Modern (SNI required, recommended for modern setups)
CERTIFICATE_TYPE="sni_custom"  # Default: "sni_custom" (Custom Modern)

# Certificate deletion strategy:
# "none" - Don't delete any existing certificates (accumulate all)
# "all" - Delete all existing certificates before uploading
# "matching" - Only delete certificates that cover the same hostname(s) being uploaded
CERT_DELETE_MODE="matching"  # Recommended: "none" to keep multiple certificates

# Debug mode flag - set to "true" to enable detailed logging
# WARNING: This will log sensitive information including full AUTH_TOKEN
# Only use in testing/development environments
DEBUG_MODE="false"  # Set to "true" to enable debug logging

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting Cloudflare certificate upload script"
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "DEBUG MODE ENABLED"
fi
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
log_message "  Default BUNDLE_METHOD: $BUNDLE_METHOD"
log_message "  CERTIFICATE_TYPE: $CERTIFICATE_TYPE"
log_message "  CERT_DELETE_MODE: $CERT_DELETE_MODE"

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
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "Decoded JSON_STRING: $JSON_STRING"
else
    log_message "JSON_STRING decoded successfully"
fi

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array to debug
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "Raw args array: $ARGS_ARRAY"
fi

# Extract ZONE_ID - first argument
ZONE_ID=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "Raw ZONE_ID after extraction: '$ZONE_ID'"
fi
log_message "ZONE_ID length: ${#ZONE_ID}"

# Extract AUTH_TOKEN - second argument
AUTH_TOKEN=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "Raw AUTH_TOKEN after extraction (full): '$AUTH_TOKEN'"
fi
log_message "AUTH_TOKEN length: ${#AUTH_TOKEN}"

# Extract BUNDLE_METHOD - third argument (if provided)
BUNDLE_METHOD_EXTRACTED=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ -n "$BUNDLE_METHOD_EXTRACTED" ]; then
    BUNDLE_METHOD="$BUNDLE_METHOD_EXTRACTED"
    log_message "BUNDLE_METHOD extracted from args: $BUNDLE_METHOD"
fi

# Extract CERT_DELETE_MODE - fourth argument (if provided)
CERT_DELETE_MODE_EXTRACTED=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ -n "$CERT_DELETE_MODE_EXTRACTED" ]; then
    CERT_DELETE_MODE="$CERT_DELETE_MODE_EXTRACTED"
    log_message "CERT_DELETE_MODE extracted from args: $CERT_DELETE_MODE"
fi

# Extract CERTIFICATE_TYPE - fifth argument (if provided)
CERTIFICATE_TYPE_EXTRACTED=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
if [ -n "$CERTIFICATE_TYPE_EXTRACTED" ]; then
    CERTIFICATE_TYPE="$CERTIFICATE_TYPE_EXTRACTED"
    log_message "CERTIFICATE_TYPE extracted from args: $CERTIFICATE_TYPE"

    # Validate certificate type
    if [ "$CERTIFICATE_TYPE" != "legacy_custom" ] && [ "$CERTIFICATE_TYPE" != "sni_custom" ]; then
        log_message "WARNING: Invalid CERTIFICATE_TYPE '$CERTIFICATE_TYPE'. Using default 'sni_custom'"
        CERTIFICATE_TYPE="sni_custom"
    fi
fi

# Log extracted arguments
log_message "Extracted arguments:"
log_message "  ZONE_ID: '$ZONE_ID'"
# Mask auth token for security - show only first and last 4 characters
if [ -n "$AUTH_TOKEN" ]; then
    AUTH_TOKEN_MASKED="${AUTH_TOKEN:0:4}...${AUTH_TOKEN: -4}"
    log_message "  AUTH_TOKEN: '$AUTH_TOKEN_MASKED' (masked for security)"
    if [ "$DEBUG_MODE" = "true" ]; then
        # Also log hex dump of first few chars to check for hidden characters
        log_message "  AUTH_TOKEN first 10 chars hex: $(echo -n "${AUTH_TOKEN:0:10}" | xxd -p)"
    fi
else
    log_message "  AUTH_TOKEN: [empty]"
fi
log_message "  BUNDLE_METHOD: '$BUNDLE_METHOD'"
log_message "  CERT_DELETE_MODE: '$CERT_DELETE_MODE'"
if [ "$CERTIFICATE_TYPE" = "legacy_custom" ]; then
    log_message "  CERTIFICATE_TYPE: '$CERTIFICATE_TYPE' (Custom Legacy)"
else
    log_message "  CERTIFICATE_TYPE: '$CERTIFICATE_TYPE' (Custom Modern - SNI required)"
fi

# Validate and clean AUTH_TOKEN and ZONE_ID
log_message "Validating extracted values..."

# Remove any potential whitespace, newlines, or carriage returns
ZONE_ID=$(echo "$ZONE_ID" | tr -d '[:space:]')
AUTH_TOKEN=$(echo "$AUTH_TOKEN" | tr -d '[:space:]')

# Validate ZONE_ID format (should be 32 characters, alphanumeric)
if [[ ! "$ZONE_ID" =~ ^[a-zA-Z0-9]{32}$ ]]; then
    log_message "WARNING: ZONE_ID format seems invalid. Expected 32 alphanumeric characters, got: '${ZONE_ID}' (length: ${#ZONE_ID})"
fi

# Validate AUTH_TOKEN format (typically 40 characters, alphanumeric with possible special chars)
if [ ${#AUTH_TOKEN} -lt 30 ] || [ ${#AUTH_TOKEN} -gt 50 ]; then
    log_message "WARNING: AUTH_TOKEN length seems unusual. Got length: ${#AUTH_TOKEN}"
fi

# Validate CERT_DELETE_MODE
if [[ ! "$CERT_DELETE_MODE" =~ ^(none|all|matching)$ ]]; then
    log_message "WARNING: Invalid CERT_DELETE_MODE '$CERT_DELETE_MODE'. Must be 'none', 'all', or 'matching'. Defaulting to 'none'."
    CERT_DELETE_MODE="none"
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

# Read certificate and key using dynamically constructed paths
log_message "Reading certificate and key files..."
CERT=$(cat "${CRT_FILE_PATH}" | sed 's/$/\\n/' | tr -d '\n')
KEY=$(cat "${KEY_FILE_PATH}" | sed 's/$/\\n/' | tr -d '\n')

# Log certificate and key lengths
log_message "Certificate content length: ${#CERT} characters"
log_message "Key content length: ${#KEY} characters"

if [ "$DEBUG_MODE" = "true" ]; then
    # Show first and last few characters of cert and key for debugging
    log_message "Certificate starts with: ${CERT:0:50}..."
    log_message "Certificate ends with: ...${CERT: -50}"
    log_message "Key starts with: ${KEY:0:50}..."
    log_message "Key ends with: ...${KEY: -50}"
fi

# Prepare API payload
API_PAYLOAD='{
  "certificate": "'"${CERT}"'",
  "private_key": "'"${KEY}"'",
  "bundle_method": "'"${BUNDLE_METHOD}"'",
  "type": "'"${CERTIFICATE_TYPE}"'"
}'

# Log API call details
log_message "Preparing Cloudflare API call..."
log_message "API Endpoint: https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates"
log_message "Bundle method: $BUNDLE_METHOD"
if [ "$CERTIFICATE_TYPE" = "legacy_custom" ]; then
    log_message "Certificate type: $CERTIFICATE_TYPE (Custom Legacy - supports non-SNI clients)"
else
    log_message "Certificate type: $CERTIFICATE_TYPE (Custom Modern - SNI required)"
fi

# Create a temporary file for the response
RESPONSE_FILE=$(mktemp)
log_message "Created temporary response file: $RESPONSE_FILE"

# ========================================
# CHECK FOR EXISTING CERTIFICATES AND DELETE (BASED ON MODE)
# ========================================

if [ "$CERT_DELETE_MODE" = "none" ]; then
    log_message "CERT_DELETE_MODE is 'none' - skipping certificate deletion check"
    log_message "New certificate will be added alongside any existing certificates"
    
elif [ "$CERT_DELETE_MODE" = "all" ] || [ "$CERT_DELETE_MODE" = "matching" ]; then
    log_message "Checking for existing certificates (mode: $CERT_DELETE_MODE)..."
    
    # Get list of existing certificates
    LIST_RESPONSE_FILE=$(mktemp)
    LIST_HTTP_STATUS=$(curl -s -w "%{http_code}" -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates" \
         -H "Authorization: Bearer ${AUTH_TOKEN}" \
         -H "Content-Type: application/json" \
         -o "$LIST_RESPONSE_FILE" 2>&1)
    
    LIST_RESPONSE=$(cat "$LIST_RESPONSE_FILE")
    
    if [ "$DEBUG_MODE" = "true" ]; then
        log_message "List certificates HTTP Status: $LIST_HTTP_STATUS"
        log_message "List certificates response: $LIST_RESPONSE"
    fi
    
    # Check if we got the list successfully
    if [ "$LIST_HTTP_STATUS" -eq 200 ]; then
        
        if [ "$CERT_DELETE_MODE" = "all" ]; then
            # Delete ALL certificates
            log_message "Mode 'all': Will delete all existing certificates"
            CERT_IDS=$(echo "$LIST_RESPONSE" | grep -oP '"id":"\K[^"]+')
            
        elif [ "$CERT_DELETE_MODE" = "matching" ]; then
            # Smart deletion - only delete certs covering the same hostname(s)
            log_message "Mode 'matching': Will only delete certificates covering the same hostnames"
            log_message "Extracting hostnames from new certificate..."
            
            # Extract SANs from the new certificate being uploaded
            # First convert the escaped newlines back to real newlines for openssl
            NEW_CERT_HOSTS=$(echo "$CERT" | sed 's/\\n/\n/g' | openssl x509 -noout -text 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -n1 | tr ',' '\n' | grep -oP 'DNS:\K[^,\s]+' | sort | tr '\n' '|' | sed 's/|$//')
            
            if [ -n "$NEW_CERT_HOSTS" ]; then
                log_message "New certificate covers hostnames: $(echo "$NEW_CERT_HOSTS" | tr '|' ', ')"
                
                # Initialize empty list
                CERT_IDS=""
                
                # Parse each certificate in the response
                # We need to extract both ID and hosts for each certificate
                CERT_COUNT=0
                while read -r line; do
                    if echo "$line" | grep -q '"id"'; then
                        CURRENT_ID=$(echo "$line" | grep -oP '"id":"\K[^"]+')
                        CURRENT_HOSTS=$(echo "$line" | grep -oP '"hosts":\[\K[^]]*' | tr -d '"' | tr ',' '\n' | sort | tr '\n' '|' | sed 's/|$//')
                        
                        if [ -n "$CURRENT_ID" ] && [ -n "$CURRENT_HOSTS" ]; then
                            # Check if any hostname matches
                            MATCH_FOUND=false
                            
                            # Convert pipe-separated lists to arrays for comparison
                            IFS='|' read -ra NEW_HOSTS_ARRAY <<< "$NEW_CERT_HOSTS"
                            IFS='|' read -ra CURRENT_HOSTS_ARRAY <<< "$CURRENT_HOSTS"
                            
                            for new_host in "${NEW_HOSTS_ARRAY[@]}"; do
                                for current_host in "${CURRENT_HOSTS_ARRAY[@]}"; do
                                    if [ "$new_host" = "$current_host" ]; then
                                        MATCH_FOUND=true
                                        break 2
                                    fi
                                done
                            done
                            
                            if [ "$MATCH_FOUND" = true ]; then
                                log_message "Found matching certificate ID $CURRENT_ID covering: $(echo "$CURRENT_HOSTS" | tr '|' ', ')"
                                CERT_IDS="${CERT_IDS}${CURRENT_ID}"$'\n'
                                CERT_COUNT=$((CERT_COUNT + 1))
                            fi
                        fi
                    fi
                done < <(echo "$LIST_RESPONSE" | jq -c '.result[]' 2>/dev/null || echo "$LIST_RESPONSE" | grep -oP '\{"id":"[^}]+,"hosts":\[[^\]]+\][^}]*\}')
                
                if [ $CERT_COUNT -eq 0 ]; then
                    log_message "No certificates found with matching hostnames"
                fi
            else
                log_message "WARNING: Could not extract hostnames from new certificate"
                log_message "Skipping deletion to be safe"
                CERT_IDS=""
            fi
        fi
        
        if [ -n "$CERT_IDS" ]; then
            # Count and delete certificates
            CERT_COUNT=$(echo "$CERT_IDS" | grep -v '^$' | wc -l)
            log_message "Found $CERT_COUNT certificate(s) to delete"
            
            # Delete each certificate
            while IFS= read -r CERT_ID; do
                if [ -n "$CERT_ID" ]; then
                    log_message "Deleting certificate ID: $CERT_ID"
                    
                    DELETE_RESPONSE_FILE=$(mktemp)
                    DELETE_HTTP_STATUS=$(curl -s -w "%{http_code}" -X DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates/${CERT_ID}" \
                         -H "Authorization: Bearer ${AUTH_TOKEN}" \
                         -H "Content-Type: application/json" \
                         -o "$DELETE_RESPONSE_FILE" 2>&1)
                    
                    DELETE_RESPONSE=$(cat "$DELETE_RESPONSE_FILE")
                    
                    if [ "$DELETE_HTTP_STATUS" -eq 200 ] || [ "$DELETE_HTTP_STATUS" -eq 204 ]; then
                        log_message "Successfully deleted certificate ID: $CERT_ID"
                    else
                        log_message "WARNING: Failed to delete certificate ID: $CERT_ID (HTTP Status: $DELETE_HTTP_STATUS)"
                        if [ "$DEBUG_MODE" = "true" ]; then
                            log_message "Delete response: $DELETE_RESPONSE"
                        fi
                    fi
                    
                    rm -f "$DELETE_RESPONSE_FILE"
                fi
            done <<< "$CERT_IDS"
            
            # Add a small delay to ensure deletion is processed
            sleep 2
            log_message "Certificate deletion completed, proceeding with upload"
        else
            log_message "No certificates to delete, proceeding with upload"
        fi
    else
        log_message "WARNING: Could not check for existing certificates (HTTP Status: $LIST_HTTP_STATUS)"
        log_message "Proceeding with certificate upload anyway..."
    fi
    
    rm -f "$LIST_RESPONSE_FILE"
fi

# ========================================
# UPLOAD NEW CERTIFICATE
# ========================================
log_message "Uploading new certificate..."

# Debug: Show the exact curl command being used (with masked token)
if [ "$DEBUG_MODE" = "true" ]; then
    log_message "Debug - Curl command structure:"
    log_message "  URL: https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates"
    log_message "  Authorization header: Bearer ${AUTH_TOKEN_MASKED}"
    log_message "  Content-Type: application/json"
fi

# Upload the new certificate
HTTP_STATUS=$(curl -s -w "%{http_code}" -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates" \
     -H "Authorization: Bearer ${AUTH_TOKEN}" \
     -H "Content-Type: application/json" \
     --data "${API_PAYLOAD}" \
     -o "$RESPONSE_FILE" 2>&1)

# Read the response
RESPONSE=$(cat "$RESPONSE_FILE")

# Log the response
log_message "API call completed"
log_message "HTTP Status Code: $HTTP_STATUS"
log_message "API Response: $RESPONSE"

# Parse response for success/error
if echo "$RESPONSE" | grep -q '"success":true'; then
    log_message "SUCCESS: Certificate uploaded successfully"
    # Try to extract certificate ID if available
    CERT_ID=$(echo "$RESPONSE" | grep -oP '"id":"\K[^"]+' | head -1)
    if [ -n "$CERT_ID" ]; then
        log_message "Certificate ID: $CERT_ID"
    fi
else
    log_message "ERROR: Certificate upload failed"
    # Try to extract error messages
    ERRORS=$(echo "$RESPONSE" | grep -oP '"message":"\K[^"]+')
    if [ -n "$ERRORS" ]; then
        log_message "Error messages: $ERRORS"
    fi
fi

# Clean up
rm -f "$RESPONSE_FILE"
log_message "Cleaned up temporary files"

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

# Exit with appropriate code based on HTTP status
if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
    exit 0
else
    exit 1
fi