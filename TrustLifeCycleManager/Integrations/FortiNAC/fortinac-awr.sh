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

# ============================================================================
# CONFIGURATION SECTION
# ============================================================================

# Legal Notice Acceptance - must be set to "true" to run
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/home/ubuntu/fortinac.log"

# ----------------------------------------------------------------------------
# FortiNAC Certificate Type Configuration
# ----------------------------------------------------------------------------
# Valid options:
#   - RADIUS      : Local RADIUS Server (EAP)
#   - RADSEC      : Local RADIUS Server (RadSec)
#   - PORTAL      : Portal
#   - AGENT       : Persistent Agent
#   - TOMCAT      : Admin UI
# ----------------------------------------------------------------------------
CERT_TYPE="RADSEC"

# ----------------------------------------------------------------------------
# Target Configuration
# ----------------------------------------------------------------------------
# USE_EXISTING_TARGET: Set to "true" to use pre-existing target, "false" to create new
#
# IMPORTANT: Creating new targets (USE_EXISTING_TARGET="false") is ONLY supported 
# for CERT_TYPE="RADIUS". The FortiNAC CSR API only creates Local RADIUS Server (EAP) targets.
# All other service types must use existing targets.
#
# ALIAS NAMING RESTRICTION: Target aliases may only contain alphanumeric characters 
# and underscores (_). No hyphens, spaces, or special characters allowed.
#   Valid:   my_alias, radius01, RemoteAPI
#   Invalid: my-alias, remote api, my.alias
#
# EXISTING_TARGET_ALIAS: Used when USE_EXISTING_TARGET="true"
#   - For factory default targets, use "default" OR the actual default alias name:
#     RADIUS     -> "default" or "radius"
#     RADSEC     -> "default" or "radsec"  
#     PORTAL     -> "default" or "portal"
#     AGENT      -> "default" or "agent"
#     TOMCAT     -> "default" or "tomcat"
#   - For custom RADIUS targets created via CSR, use the custom alias name
#     e.g., "fortinac_custom_csr"
#
# NEW_TARGET_ALIAS: Used when USE_EXISTING_TARGET="false" and CERT_TYPE="RADIUS"
#   - The alias name for the new RADIUS target to be created via CSR
#   - Must only contain alphanumeric characters and underscores
# ----------------------------------------------------------------------------
USE_EXISTING_TARGET="true"
EXISTING_TARGET_ALIAS="default"
NEW_TARGET_ALIAS="custom_alias"

# ----------------------------------------------------------------------------
# Service Restart Configuration
# ----------------------------------------------------------------------------
# Set to "true" to restart the service after certificate upload
# ----------------------------------------------------------------------------
RESTART_SERVICE="true"

# ----------------------------------------------------------------------------
# CSR Generation Parameters (only used when creating new target)
# ----------------------------------------------------------------------------
CSR_KEY_LENGTH="2048"
CSR_COUNTRY="US"
CSR_STATE="Utah"
CSR_CITY="Lehi"
CSR_ORG="DigiCert"
CSR_OU="Product"
CSR_CN="fortinac-temporary-csr"

# ============================================================================
# END OF CONFIGURATION SECTION
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to URL encode a string
url_encode() {
    local string="$1"
    local length="${#string}"
    local encoded=""
    local i c o
    
    for (( i = 0; i < length; i++ )); do
        c="${string:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-])
                encoded+="$c"
                ;;
            ' ')
                encoded+="%20"
                ;;
            '[')
                encoded+="%5B"
                ;;
            ']')
                encoded+="%5D"
                ;;
            '(')
                encoded+="("
                ;;
            ')')
                encoded+=")"
                ;;
            *)
                # Get hex value of character
                printf -v o '%%%02X' "'$c"
                encoded+="$o"
                ;;
        esac
    done
    echo "$encoded"
}

# Function to check if alias is a known default alias for the cert type
is_default_alias() {
    local cert_type="$1"
    local alias="$2"
    
    case "$cert_type" in
        "RADIUS")
            [ "$alias" = "default" ] || [ "$alias" = "radius" ] && return 0
            ;;
        "RADSEC")
            [ "$alias" = "default" ] || [ "$alias" = "radsec" ] && return 0
            ;;
        "PORTAL")
            [ "$alias" = "default" ] || [ "$alias" = "portal" ] && return 0
            ;;
        "AGENT")
            [ "$alias" = "default" ] || [ "$alias" = "agent" ] && return 0
            ;;
        "TOMCAT")
            [ "$alias" = "default" ] || [ "$alias" = "tomcat" ] && return 0
            ;;
    esac
    return 1
}

# Function to get certificate target path based on type and alias
get_target_path() {
    local cert_type="$1"
    local use_existing="$2"
    local new_alias="$3"
    local existing_alias="$4"
    
    if [ "$use_existing" = "true" ]; then
        if is_default_alias "$cert_type" "$existing_alias"; then
            # Pre-existing default targets - use simple names without alias suffix
            # Exception: RADIUS default includes [radius] in the target name
            case "$cert_type" in
                "RADIUS")
                    echo "Local%20RADIUS%20Server%20(EAP)%20%5Bradius%5D"
                    ;;
                "RADSEC")
                    echo "Local%20RADIUS%20Server%20(RadSec)"
                    ;;
                "PORTAL")
                    echo "Portal"
                    ;;
                "AGENT")
                    echo "Persistent%20Agent"
                    ;;
                "TOMCAT")
                    echo "Admin%20UI"
                    ;;
                *)
                    echo ""
                    ;;
            esac
        else
            # Custom existing alias - use Name [alias] format
            local base_name
            case "$cert_type" in
                "RADIUS")
                    base_name="Local RADIUS Server (EAP)"
                    ;;
                "RADSEC")
                    base_name="Local RADIUS Server (RadSec)"
                    ;;
                "PORTAL")
                    base_name="Portal"
                    ;;
                "AGENT")
                    base_name="Persistent Agent"
                    ;;
                "TOMCAT")
                    base_name="Admin UI"
                    ;;
                *)
                    base_name=""
                    ;;
            esac
            local full_path="${base_name} [${existing_alias}]"
            url_encode "$full_path"
        fi
    else
        # New targets created via CSR use Name [alias] format
        local base_name
        case "$cert_type" in
            "RADIUS")
                base_name="Local RADIUS Server (EAP)"
                ;;
            "RADSEC")
                base_name="Local RADIUS Server (RadSec)"
                ;;
            "PORTAL")
                base_name="Portal"
                ;;
            "AGENT")
                base_name="Persistent Agent"
                ;;
            "TOMCAT")
                base_name="Admin UI"
                ;;
            *)
                base_name=""
                ;;
        esac
        # URL encode the full path with alias
        local full_path="${base_name} [${new_alias}]"
        url_encode "$full_path"
    fi
}

# Function to get restart target path based on type and alias
get_restart_target() {
    local cert_type="$1"
    local use_existing="$2"
    local new_alias="$3"
    local existing_alias="$4"
    
    if [ "$use_existing" = "true" ]; then
        if is_default_alias "$cert_type" "$existing_alias"; then
            # Default aliases - restart target should match the upload target format
            # Some defaults include [alias], some don't - matches the Certificate Target column in UI
            case "$cert_type" in
                "RADIUS")
                    # UI shows: Local RADIUS Server (EAP) [radius]
                    echo "Local%20RADIUS%20Server%20(EAP)%20%5Bradius%5D"
                    ;;
                "RADSEC")
                    # UI shows: Local RADIUS Server (RadSec) - no alias
                    echo "Local%20RADIUS%20Server%20(RadSec)"
                    ;;
                "PORTAL")
                    # UI shows: Portal - no alias
                    echo "Portal"
                    ;;
                "AGENT")
                    # UI shows: Persistent Agent - no alias
                    echo "Persistent%20Agent"
                    ;;
                "TOMCAT")
                    # UI shows: Admin UI - no alias
                    echo "Admin%20UI"
                    ;;
                *)
                    echo ""
                    ;;
            esac
        else
            # Custom existing alias - use Name [alias] format
            local base_name
            case "$cert_type" in
                "RADIUS")
                    base_name="Local RADIUS Server (EAP)"
                    ;;
                "RADSEC")
                    base_name="Local RADIUS Server (RadSec)"
                    ;;
                "PORTAL")
                    base_name="Portal"
                    ;;
                "AGENT")
                    base_name="Persistent Agent"
                    ;;
                "TOMCAT")
                    base_name="Admin UI"
                    ;;
                *)
                    base_name=""
                    ;;
            esac
            local full_path="${base_name} [${existing_alias}]"
            url_encode "$full_path"
        fi
    else
        local base_name
        case "$cert_type" in
            "RADIUS")
                base_name="Local RADIUS Server (EAP)"
                ;;
            "RADSEC")
                base_name="Local RADIUS Server (RadSec)"
                ;;
            "PORTAL")
                base_name="Portal"
                ;;
            "AGENT")
                base_name="Persistent Agent"
                ;;
            "TOMCAT")
                base_name="Admin UI"
                ;;
            *)
                base_name=""
                ;;
        esac
        local full_path="${base_name} [${new_alias}]"
        url_encode "$full_path"
    fi
}

# Function to get certOwnerType based on cert type
get_cert_owner_type() {
    local cert_type="$1"
    case "$cert_type" in
        "RADIUS")
            echo "RADIUS"
            ;;
        "RADSEC")
            echo "RADSEC"
            ;;
        "PORTAL")
            echo "PORTAL"
            ;;
        "AGENT")
            echo "AGENT"
            ;;
        "TOMCAT")
            echo "TOMCAT"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Start logging
log_message "=========================================="
log_message "Starting FortiNAC Certificate Management Script"
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

# Log configuration
log_message "Configuration:"
log_message "  CERT_TYPE: $CERT_TYPE"
log_message "  USE_EXISTING_TARGET: $USE_EXISTING_TARGET"
log_message "  EXISTING_TARGET_ALIAS: $EXISTING_TARGET_ALIAS"
log_message "  NEW_TARGET_ALIAS: $NEW_TARGET_ALIAS"
log_message "  RESTART_SERVICE: $RESTART_SERVICE"
log_message "  LOGFILE: $LOGFILE"

# Validate CERT_TYPE
case "$CERT_TYPE" in
    "RADIUS"|"RADSEC"|"PORTAL"|"AGENT"|"TOMCAT")
        log_message "CERT_TYPE '$CERT_TYPE' is valid"
        ;;
    *)
        log_message "ERROR: Invalid CERT_TYPE '$CERT_TYPE'. Valid options: RADIUS, RADSEC, PORTAL, AGENT, TOMCAT"
        exit 1
        ;;
esac

# Validate target configuration
# Note: CSR generation only creates RADIUS (EAP) targets. Other service types 
# (RADSEC, PORTAL, AGENT, TOMCAT, REMOTE_API) can only use existing targets.
if [ "$USE_EXISTING_TARGET" = "false" ]; then
    if [ "$CERT_TYPE" != "RADIUS" ]; then
        log_message "ERROR: Creating new targets (USE_EXISTING_TARGET=false) is only supported for CERT_TYPE=RADIUS"
        log_message "The FortiNAC CSR generation API only creates Local RADIUS Server (EAP) targets."
        log_message "For $CERT_TYPE, you must use an existing target (USE_EXISTING_TARGET=true)"
        exit 1
    fi
    # Validate alias format - only alphanumeric and underscore allowed
    if [[ ! "$NEW_TARGET_ALIAS" =~ ^[a-zA-Z0-9_]+$ ]]; then
        log_message "ERROR: NEW_TARGET_ALIAS '$NEW_TARGET_ALIAS' contains invalid characters"
        log_message "Target alias may only contain alphanumeric characters and underscores (_)"
        log_message "Valid examples: my_alias, radius01, custom_cert"
        exit 1
    fi
    log_message "New target creation validated for RADIUS type"
    log_message "Alias format validated: $NEW_TARGET_ALIAS"
fi

# Validate existing alias format if not using default
if [ "$USE_EXISTING_TARGET" = "true" ] && [ "$EXISTING_TARGET_ALIAS" != "default" ]; then
    if ! is_default_alias "$CERT_TYPE" "$EXISTING_TARGET_ALIAS"; then
        if [[ ! "$EXISTING_TARGET_ALIAS" =~ ^[a-zA-Z0-9_]+$ ]]; then
            log_message "ERROR: EXISTING_TARGET_ALIAS '$EXISTING_TARGET_ALIAS' contains invalid characters"
            log_message "Target alias may only contain alphanumeric characters and underscores (_)"
            exit 1
        fi
        log_message "Custom existing alias format validated: $EXISTING_TARGET_ALIAS"
    fi
fi

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

# Extract the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract Argument_1 - FortiNAC Hostname
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
log_message "ARGUMENT_1 (Hostname) extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - Authorization Bearer Token
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
log_message "ARGUMENT_2 (Bearer Token) extracted: '[REDACTED]'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Assign to meaningful variable names
FORTINAC_HOST="$ARGUMENT_1"
BEARER_TOKEN="$ARGUMENT_2"

# Validate required arguments
if [ -z "$FORTINAC_HOST" ]; then
    log_message "ERROR: Argument 1 (FortiNAC Hostname) is empty"
    exit 1
fi

if [ -z "$BEARER_TOKEN" ]; then
    log_message "ERROR: Argument 2 (Bearer Token) is empty"
    exit 1
fi

# Construct base URL
BASE_URL="https://${FORTINAC_HOST}:8443/api/v2/settings/security/certificate-server"
log_message "Base URL: $BASE_URL"

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
log_message "FortiNAC Connection:"
log_message "  Hostname: $FORTINAC_HOST"
log_message "  Bearer Token: [REDACTED - ${#BEARER_TOKEN} chars]"
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
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
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
    log_message "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
fi

# ============================================================================
# FORTINAC CERTIFICATE MANAGEMENT SECTION
# ============================================================================

log_message "=========================================="
log_message "Starting FortiNAC Certificate Management..."
log_message "=========================================="

# Get certOwnerType
CERT_OWNER_TYPE=$(get_cert_owner_type "$CERT_TYPE")
log_message "Certificate Owner Type: $CERT_OWNER_TYPE"

# Step 1: Create new target via CSR if needed
if [ "$USE_EXISTING_TARGET" = "false" ]; then
    log_message "=========================================="
    log_message "Step 1: Creating new target via CSR generation..."
    log_message "=========================================="
    log_message "New target alias: $NEW_TARGET_ALIAS"
    log_message "CSR Parameters:"
    log_message "  Key Length: $CSR_KEY_LENGTH"
    log_message "  Country: $CSR_COUNTRY"
    log_message "  State: $CSR_STATE"
    log_message "  City: $CSR_CITY"
    log_message "  Organization: $CSR_ORG"
    log_message "  OU: $CSR_OU"
    log_message "  CN: $CSR_CN"
    
    CSR_PAYLOAD=$(cat <<EOF
{
  "keyLength": $CSR_KEY_LENGTH,
  "countryName": "$CSR_COUNTRY",
  "state": "$CSR_STATE",
  "city": "$CSR_CITY",
  "orgName": "$CSR_ORG",
  "ou": "$CSR_OU",
  "cn": "$CSR_CN",
  "sans": ["$CSR_CN"],
  "selfSigned": false,
  "certType": "server",
  "newTargetAlias": "$NEW_TARGET_ALIAS"
}
EOF
)
    
    log_message "CSR Request Payload:"
    log_message "$CSR_PAYLOAD"
    
    log_message "Sending CSR generation request..."
    CSR_RESPONSE=$(curl -sk --location "${BASE_URL}/csr/generate" \
        --header 'Content-Type: application/json' \
        --header "Authorization: Bearer ${BEARER_TOKEN}" \
        --data "$CSR_PAYLOAD" 2>&1)
    
    CSR_EXIT_CODE=$?
    log_message "CSR generation curl exit code: $CSR_EXIT_CODE"
    log_message "CSR generation response: $CSR_RESPONSE"
    
    # Check if CSR generation was successful
    if echo "$CSR_RESPONSE" | grep -q '"status":"success"'; then
        log_message "CSR generation successful - target created"
    elif echo "$CSR_RESPONSE" | grep -q '"status":"error"'; then
        CSR_ERROR=$(echo "$CSR_RESPONSE" | grep -oP '"errorMessage":"\K[^"]+')
        log_message "ERROR: CSR generation failed: $CSR_ERROR"
        exit 1
    else
        log_message "WARNING: Unexpected CSR response, continuing..."
    fi
else
    log_message "=========================================="
    log_message "Step 1: Using existing target (skipping CSR generation)"
    log_message "=========================================="
fi

# Step 2: Upload certificate and private key
log_message "=========================================="
log_message "Step 2: Uploading certificate and private key..."
log_message "=========================================="

# Get the target path
TARGET_PATH=$(get_target_path "$CERT_TYPE" "$USE_EXISTING_TARGET" "$NEW_TARGET_ALIAS" "$EXISTING_TARGET_ALIAS")
log_message "Target path: $TARGET_PATH"

UPLOAD_URL="${BASE_URL}/${TARGET_PATH}"
log_message "Upload URL: $UPLOAD_URL"

log_message "Upload parameters:"
log_message "  targetType: ServerCert"
log_message "  privateKeyType: provided"
log_message "  certOwnerType: $CERT_OWNER_TYPE"
log_message "  appliedTo: null"
log_message "  Certificate file: $CRT_FILE_PATH"
log_message "  Private key file: $KEY_FILE_PATH"

log_message "Sending certificate upload request..."
UPLOAD_RESPONSE=$(curl -sk --location "$UPLOAD_URL" \
    --header "Authorization: Bearer ${BEARER_TOKEN}" \
    -F 'targetType=ServerCert' \
    -F 'privateKeyType=provided' \
    -F "certOwnerType=${CERT_OWNER_TYPE}" \
    -F 'appliedTo=null' \
    -F "certs=@${CRT_FILE_PATH};type=application/x-x509-ca-cert" \
    -F "privateKey=@${KEY_FILE_PATH};type=application/x-x509-ca-cert" 2>&1)

UPLOAD_EXIT_CODE=$?
log_message "Certificate upload curl exit code: $UPLOAD_EXIT_CODE"
log_message "Certificate upload response: $UPLOAD_RESPONSE"

# Check if upload was successful
if echo "$UPLOAD_RESPONSE" | grep -q '"status":"success"'; then
    log_message "Certificate upload successful"
    
    # Check if restart is required
    if echo "$UPLOAD_RESPONSE" | grep -q '"restartRequired":true'; then
        log_message "Server indicates restart is required"
    fi
elif echo "$UPLOAD_RESPONSE" | grep -q '"status":"error"'; then
    UPLOAD_ERROR=$(echo "$UPLOAD_RESPONSE" | grep -oP '"errorMessage":"\K[^"]+')
    log_message "ERROR: Certificate upload failed: $UPLOAD_ERROR"
    exit 1
else
    log_message "WARNING: Unexpected upload response"
    log_message "Response content: $UPLOAD_RESPONSE"
fi

# Step 3: Restart service if configured
if [ "$RESTART_SERVICE" = "true" ]; then
    log_message "=========================================="
    log_message "Step 3: Restarting service..."
    log_message "=========================================="
    
    RESTART_TARGET=$(get_restart_target "$CERT_TYPE" "$USE_EXISTING_TARGET" "$NEW_TARGET_ALIAS" "$EXISTING_TARGET_ALIAS")
    log_message "Restart target: $RESTART_TARGET"
    
    RESTART_URL="${BASE_URL}/restart"
    log_message "Restart URL: $RESTART_URL"
    
    log_message "Sending restart request..."
    RESTART_RESPONSE=$(curl -sk -X POST "$RESTART_URL" \
        --header "Authorization: Bearer ${BEARER_TOKEN}" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        -d "target=${RESTART_TARGET}" 2>&1)
    
    RESTART_EXIT_CODE=$?
    log_message "Restart curl exit code: $RESTART_EXIT_CODE"
    log_message "Restart response: $RESTART_RESPONSE"
    
    # Check if restart was successful
    if echo "$RESTART_RESPONSE" | grep -q '"status":"success"'; then
        log_message "Service restart successful"
    elif echo "$RESTART_RESPONSE" | grep -q '"status":"error"'; then
        RESTART_ERROR=$(echo "$RESTART_RESPONSE" | grep -oP '"errorMessage":"\K[^"]+')
        log_message "ERROR: Service restart failed: $RESTART_ERROR"
        exit 1
    else
        log_message "WARNING: Unexpected restart response"
        log_message "Response content: $RESTART_RESPONSE"
    fi
else
    log_message "=========================================="
    log_message "Step 3: Service restart skipped (RESTART_SERVICE=false)"
    log_message "=========================================="
fi

# ============================================================================
# END OF FORTINAC CERTIFICATE MANAGEMENT SECTION
# ============================================================================

log_message "=========================================="
log_message "FortiNAC Certificate Management Summary"
log_message "=========================================="
log_message "Certificate Type: $CERT_TYPE"
log_message "Target: $TARGET_PATH"
log_message "Certificate uploaded: YES"
log_message "Service restarted: $RESTART_SERVICE"
log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0