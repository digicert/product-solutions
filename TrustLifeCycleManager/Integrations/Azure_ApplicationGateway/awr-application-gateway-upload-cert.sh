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

# ============================================================================
# DigiCert TLM Agent Certificate Processing Script (PFX Format) - Linux Version
#
# Bash port of awr-application-gateway-upload-cert.ps1. Uploads a newly issued
# PFX certificate directly to an Azure Application Gateway SSL certificate
# store (no Key Vault) using the Azure CLI.
#
# Prerequisites (see install-prerequisites-ubuntu-24.04.sh):
#   bash, coreutils (base64), jq, openssl, azure-cli (az)
# ============================================================================

# ============================================================================
# Configuration
# ============================================================================
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/mike/agw-logfile.log"

# Isolated Azure CLI profile so this script never touches (or leaks into) an
# interactive user's `az login` session on the host. Removed on exit.
AZ_WORK_DIR="${AZ_WORK_DIR:-/tmp/digicert-agw-awr}"
# ============================================================================

# Make sure the log directory exists before the first log line is written
mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null

# Function to log messages with timestamp
log_message() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOGFILE"
}

fail_and_exit() {
    log_message "ERROR: $1"
    log_message "Script execution terminated."
    log_message "=========================================="
    exit 1
}

# Clean up the isolated Azure CLI session on every exit path
cleanup() {
    if [ -n "$AZURE_CONFIG_DIR" ] && [ -d "$AZURE_CONFIG_DIR" ]; then
        az logout --only-show-errors >/dev/null 2>&1
        rm -rf "$AZURE_CONFIG_DIR"
    fi
}
trap cleanup EXIT

# Start logging
log_message "=========================================="
log_message "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)"
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

# ============================================================================
# Dependency checks
# ============================================================================
log_message "Checking required commands..."
for cmd in base64 jq openssl az; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail_and_exit "Required command not found: $cmd (run install-prerequisites-ubuntu-24.04.sh)"
    fi
done
log_message "All required commands are available"
log_message "  az version: $(az version --query '"azure-cli"' -o tsv 2>/dev/null)"
log_message "  jq version: $(jq --version 2>/dev/null)"
log_message "  openssl:    $(openssl version 2>/dev/null)"

# ============================================================================
# DC1_POST_SCRIPT_DATA extraction
# ============================================================================
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
CERT_INFO=${DC1_POST_SCRIPT_DATA}

if [ -z "$CERT_INFO" ]; then
    fail_and_exit "DC1_POST_SCRIPT_DATA environment variable is not set"
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#CERT_INFO} characters)"
fi

# Decode JSON string from Base64
JSON_STRING=$(echo "$CERT_INFO" | base64 -d 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$JSON_STRING" ]; then
    fail_and_exit "Failed to decode Base64"
fi
log_message "JSON_STRING decoded successfully"

# Raw JSON logging disabled - JSON contains PFX password in clear text

# Parse JSON (validate it is well-formed before extracting anything)
if ! echo "$JSON_STRING" | jq -e . >/dev/null 2>&1; then
    fail_and_exit "Failed to parse JSON"
fi
log_message "JSON parsed successfully"

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# Initialize argument variables
ARGUMENT_1=""
ARGUMENT_2=""
ARGUMENT_3=""
ARGUMENT_4=""
ARGUMENT_5=""
ARGUMENT_6=""
ARGUMENT_7=""

# Helper: return args[N] (0-based) with all whitespace removed, or empty string
get_arg() {
    echo "$JSON_STRING" | jq -r --argjson i "$1" '.args[$i] // empty' 2>/dev/null | tr -d '[:space:]'
}

ARGS_COUNT=$(echo "$JSON_STRING" | jq -r '(.args // []) | length' 2>/dev/null)
ARGS_COUNT=${ARGS_COUNT:-0}

if [ "$ARGS_COUNT" -ge 1 ]; then
    # Raw args logging disabled on purpose - args[2] is the client secret
    log_message "Args array contains $ARGS_COUNT element(s)"

    if [ "$ARGS_COUNT" -ge 1 ]; then
        ARGUMENT_1=$(get_arg 0)
        log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"
    fi
    if [ "$ARGS_COUNT" -ge 2 ]; then
        ARGUMENT_2=$(get_arg 1)
        log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"
    fi
    if [ "$ARGS_COUNT" -ge 3 ]; then
        ARGUMENT_3=$(get_arg 2)
        log_message "ARGUMENT_3 extracted: [redacted]"
        log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"
    fi
    if [ "$ARGS_COUNT" -ge 4 ]; then
        ARGUMENT_4=$(get_arg 3)
        log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"
    fi
    if [ "$ARGS_COUNT" -ge 5 ]; then
        ARGUMENT_5=$(get_arg 4)
        log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
        log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"
    fi
    if [ "$ARGS_COUNT" -ge 6 ]; then
        ARGUMENT_6=$(get_arg 5)
        log_message "ARGUMENT_6 extracted: '$ARGUMENT_6'"
        log_message "ARGUMENT_6 length: ${#ARGUMENT_6}"
    fi
    if [ "$ARGS_COUNT" -ge 7 ]; then
        ARGUMENT_7=$(get_arg 6)
        log_message "ARGUMENT_7 extracted: '$ARGUMENT_7'"
        log_message "ARGUMENT_7 length: ${#ARGUMENT_7}"
    fi
fi

# Extract cert folder
CERT_FOLDER=$(echo "$JSON_STRING" | jq -r '.certfolder // empty')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx / .p12 file name (first match in the files array)
PFX_FILE=$(echo "$JSON_STRING" | jq -r '(.files // [])[] | select(test("\\.(pfx|p12)$"; "i"))' 2>/dev/null | head -n 1)
log_message "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# Check common field names for password
PFX_PASSWORD=$(echo "$JSON_STRING" | jq -r '.password // .pfx_password // .keystore_password // .passphrase // empty')

if [ -z "$PFX_PASSWORD" ]; then
    log_message "WARNING: No PFX password found in JSON"
else
    log_message "PFX password extracted from JSON"
    log_message "PFX password length: ${#PFX_PASSWORD} characters"
fi

# Construct file path
PFX_FILE_PATH="${CERT_FOLDER%/}/${PFX_FILE}"

# Extract all files from the files array
FILES_ARRAY=$(echo "$JSON_STRING" | jq -r '(.files // []) | join(",")')
log_message "Files array content: $FILES_ARRAY"

# Log summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Arguments extracted:"
log_message "  Argument 1 (Tenant ID)        : $ARGUMENT_1"
log_message "  Argument 2 (Client ID)        : $ARGUMENT_2"
if [ -n "$ARGUMENT_3" ]; then
    log_message "  Argument 3 (Client Secret)    : ***"
else
    log_message "  Argument 3 (Client Secret)    : Not set"
fi
log_message "  Argument 4 (Subscription ID)  : $ARGUMENT_4"
log_message "  Argument 5 (Resource Group)   : $ARGUMENT_5"
log_message "  Argument 6 (App Gateway Name) : $ARGUMENT_6"
log_message "  Argument 7 (Cert Name in AGW) : $ARGUMENT_7"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  PFX file: $PFX_FILE"
log_message "  PFX file path: $PFX_FILE_PATH"
if [ -n "$PFX_PASSWORD" ]; then
    log_message "  PFX password: Found (${#PFX_PASSWORD} characters)"
else
    log_message "  PFX password: Not found"
fi
log_message ""
log_message "All files in array: $FILES_ARRAY"
log_message "=========================================="

# Check if PFX file exists
if [ -n "$PFX_FILE" ] && [ -f "$PFX_FILE_PATH" ]; then
    PFX_SIZE=$(stat -c %s "$PFX_FILE_PATH" 2>/dev/null)
    log_message "PFX file exists: $PFX_FILE_PATH"
    log_message "PFX file size: ${PFX_SIZE:-unknown} bytes"

    # If we have the password, we can try to inspect the PFX contents.
    # The password is handed to openssl through the environment (-passin env:)
    # so it never appears on the command line / in the process list.
    if [ -n "$PFX_PASSWORD" ]; then
        export PFX_PASSWORD
        LEAF_CERT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -clcerts -nokeys -passin env:PFX_PASSWORD 2>/dev/null)
        if [ -z "$LEAF_CERT" ]; then
            # Older PFX files use RC2/3DES; OpenSSL 3 needs the legacy provider for those
            LEAF_CERT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -clcerts -nokeys -legacy -passin env:PFX_PASSWORD 2>/dev/null)
        fi

        if [ -n "$LEAF_CERT" ]; then
            log_message "Successfully accessed PFX file with provided password"
            log_message "Certificate subject: $(echo "$LEAF_CERT" | openssl x509 -noout -subject 2>/dev/null | sed 's/^subject=//')"
            log_message "Certificate issuer: $(echo "$LEAF_CERT" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
            log_message "Certificate thumbprint: $(echo "$LEAF_CERT" | openssl x509 -noout -fingerprint -sha1 2>/dev/null | sed 's/^.*=//; s/://g')"
            log_message "Certificate valid from: $(echo "$LEAF_CERT" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//')"
            log_message "Certificate valid to: $(echo "$LEAF_CERT" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
            log_message "Signature algorithm: $(echo "$LEAF_CERT" | openssl x509 -noout -text 2>/dev/null | grep -m1 'Signature Algorithm' | sed 's/^.*Signature Algorithm: //')"

            # Check if it has a private key
            if openssl pkcs12 -in "$PFX_FILE_PATH" -nocerts -nodes -passin env:PFX_PASSWORD >/dev/null 2>&1 || \
               openssl pkcs12 -in "$PFX_FILE_PATH" -nocerts -nodes -legacy -passin env:PFX_PASSWORD >/dev/null 2>&1; then
                log_message "Certificate has private key: Yes"
                KEY_TYPE=$(echo "$LEAF_CERT" | openssl x509 -noout -text 2>/dev/null | grep -m1 'Public Key Algorithm' | sed 's/^.*Public Key Algorithm: //')
                log_message "Private key type: ${KEY_TYPE:-unknown}"
            else
                log_message "Certificate has private key: No"
            fi
        else
            log_message "WARNING: Could not access PFX file with provided password"
        fi
    else
        log_message "No password provided, cannot inspect PFX contents"
    fi
else
    log_message "WARNING: PFX file not found: $PFX_FILE_PATH"
fi

# Additional check for any certificate-related files
log_message "=========================================="
log_message "Checking for all certificate-related files in folder..."
if [ -n "$CERT_FOLDER" ] && [ -d "$CERT_FOLDER" ]; then
    CERT_FILES=$(find "$CERT_FOLDER" -type f \( -iname '*.pfx' -o -iname '*.p12' -o -iname '*.cer' -o -iname '*.crt' -o -iname '*.key' -o -iname '*.pem' \) 2>/dev/null)
    if [ -n "$CERT_FILES" ]; then
        log_message "Certificate-related files found:"
        while IFS= read -r f; do
            log_message "  $(basename "$f") - $(stat -c %s "$f" 2>/dev/null) bytes - $(stat -c %y "$f" 2>/dev/null | cut -d. -f1)"
        done <<< "$CERT_FILES"
    else
        log_message "No certificate files found in folder"
    fi
else
    log_message "Certificate folder does not exist: $CERT_FOLDER"
fi

# ============================================================================
# CUSTOM SCRIPT SECTION
# ============================================================================
#
# Available variables:
#   $CERT_FOLDER      - Folder path where certificates are stored
#   $PFX_FILE         - PFX/P12 filename (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file
#   $PFX_PASSWORD     - Password for the PFX/P12 file
#   $ARGUMENT_1..7    - AWR Parameters 1-7 (mapped to Azure connection details below)
#   $JSON_STRING      - The full decoded JSON payload from DC1_POST_SCRIPT_DATA
#   log_message       - Writes a timestamped line to the log file
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="

# ============================================================================
# AZURE APPLICATION GATEWAY - CERTIFICATE UPLOAD (No Key Vault)
# ============================================================================
# Map AWR Parameters to descriptive variables.
# Configure these in the TLM AWR Post Script parameter fields:
#
#   Parameter 1 (ARGUMENT_1) : Azure Tenant ID
#   Parameter 2 (ARGUMENT_2) : Service Principal Client ID (App ID)
#   Parameter 3 (ARGUMENT_3) : Service Principal Client Secret
#                              (leave 1-3 empty to use Managed Identity instead)
#   Parameter 4 (ARGUMENT_4) : Azure Subscription ID
#   Parameter 5 (ARGUMENT_5) : Resource Group Name
#   Parameter 6 (ARGUMENT_6) : Application Gateway Name
#   Parameter 7 (ARGUMENT_7) : SSL Certificate Name (label used inside AGW)

log_message "Starting Azure Application Gateway certificate upload..."

AZ_TENANT_ID="$ARGUMENT_1"
AZ_CLIENT_ID="$ARGUMENT_2"
AZ_CLIENT_SECRET="$ARGUMENT_3"
AZ_SUBSCRIPTION_ID="$ARGUMENT_4"
RESOURCE_GROUP="$ARGUMENT_5"
APP_GATEWAY_NAME="$ARGUMENT_6"
AGW_CERT_NAME="$ARGUMENT_7"

# --- Validate required parameters ---
MISSING=""
[ -z "$AZ_SUBSCRIPTION_ID" ] && MISSING="${MISSING}ARGUMENT_4 (Subscription ID), "
[ -z "$RESOURCE_GROUP" ]     && MISSING="${MISSING}ARGUMENT_5 (Resource Group), "
[ -z "$APP_GATEWAY_NAME" ]   && MISSING="${MISSING}ARGUMENT_6 (App Gateway Name), "
[ -z "$AGW_CERT_NAME" ]      && MISSING="${MISSING}ARGUMENT_7 (Certificate Name), "

if [ -n "$MISSING" ]; then
    fail_and_exit "Missing required AWR parameters: ${MISSING%, }"
fi

if [ -z "$PFX_FILE" ] || [ ! -f "$PFX_FILE_PATH" ]; then
    fail_and_exit "PFX file not found at: $PFX_FILE_PATH"
fi

if [ -z "$PFX_PASSWORD" ]; then
    fail_and_exit "PFX password is required for Application Gateway upload"
fi

# --- Prepare an isolated Azure CLI profile ---
mkdir -p "$AZ_WORK_DIR" 2>/dev/null || fail_and_exit "Failed to create AZ_WORK_DIR: $AZ_WORK_DIR"
AZURE_CONFIG_DIR=$(mktemp -d "$AZ_WORK_DIR/azcfg.XXXXXX") || fail_and_exit "Failed to create temporary Azure CLI config directory"
export AZURE_CONFIG_DIR
export AZURE_CORE_ONLY_SHOW_ERRORS=true
export AZURE_CORE_NO_COLOR=true
export AZURE_CORE_COLLECT_TELEMETRY=false
log_message "Using isolated Azure CLI config directory: $AZURE_CONFIG_DIR"

# --- Authenticate to Azure ---
if [ -n "$AZ_TENANT_ID" ] && [ -n "$AZ_CLIENT_ID" ] && [ -n "$AZ_CLIENT_SECRET" ]; then
    log_message "Authenticating with Service Principal (Client ID: $AZ_CLIENT_ID)..."
    # Note: az login has no way to read the secret from the environment, so it is
    # passed as an argument and is briefly visible to other local processes.
    AZ_LOGIN_OUT=$(az login --service-principal \
        --username "$AZ_CLIENT_ID" \
        --password "$AZ_CLIENT_SECRET" \
        --tenant "$AZ_TENANT_ID" \
        --output none 2>&1)
    if [ $? -ne 0 ]; then
        log_message "ERROR: Azure authentication failed: $AZ_LOGIN_OUT"
        fail_and_exit "Service Principal authentication failed"
    fi
    log_message "Service Principal authentication successful"
else
    log_message "No Service Principal credentials provided - attempting Managed Identity..."
    AZ_LOGIN_OUT=$(az login --identity --output none 2>&1)
    if [ $? -ne 0 ]; then
        log_message "ERROR: Azure authentication failed: $AZ_LOGIN_OUT"
        fail_and_exit "Managed Identity authentication failed"
    fi
    log_message "Managed Identity authentication successful"
fi

AZ_SET_OUT=$(az account set --subscription "$AZ_SUBSCRIPTION_ID" 2>&1)
if [ $? -ne 0 ]; then
    log_message "ERROR: $AZ_SET_OUT"
    fail_and_exit "Failed to set subscription context: $AZ_SUBSCRIPTION_ID"
fi
log_message "Subscription context set: $AZ_SUBSCRIPTION_ID"

# --- Retrieve the Application Gateway ---
log_message "Retrieving Application Gateway '$APP_GATEWAY_NAME' in resource group '$RESOURCE_GROUP'..."
APPGW_JSON=$(az network application-gateway show \
    --name "$APP_GATEWAY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query '{operationalState: operationalState, provisioningState: provisioningState, sslCertificates: sslCertificates[].name}' \
    --output json 2>&1)
if [ $? -ne 0 ]; then
    log_message "ERROR: $APPGW_JSON"
    fail_and_exit "Failed to retrieve Application Gateway"
fi

APPGW_OP_STATE=$(echo "$APPGW_JSON" | jq -r '.operationalState // "unknown"')
APPGW_PROV_STATE=$(echo "$APPGW_JSON" | jq -r '.provisioningState // "unknown"')
log_message "Application Gateway retrieved - State: $APPGW_OP_STATE, Provisioning: $APPGW_PROV_STATE"

# --- Add or update the SSL certificate (each az call commits the change) ---
# Set-AzApplicationGateway in the PowerShell version is a separate commit step;
# the Azure CLI ssl-cert create/update commands commit immediately and block
# until the gateway update completes, which may take several minutes.
CERT_EXISTS=$(echo "$APPGW_JSON" | jq -r --arg n "$AGW_CERT_NAME" '(.sslCertificates // []) | index($n) != null')

if [ "$CERT_EXISTS" = "true" ]; then
    log_message "Certificate '$AGW_CERT_NAME' already exists - updating..."
    log_message "Committing Application Gateway changes to Azure (may take several minutes)..."
    AZ_CERT_OUT=$(az network application-gateway ssl-cert update \
        --gateway-name "$APP_GATEWAY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AGW_CERT_NAME" \
        --cert-file "$PFX_FILE_PATH" \
        --cert-password "$PFX_PASSWORD" \
        --output none 2>&1)
    AZ_CERT_RC=$?
    ACTION_DESC="updated in"
else
    log_message "Certificate '$AGW_CERT_NAME' not found - adding new..."
    log_message "Committing Application Gateway changes to Azure (may take several minutes)..."
    AZ_CERT_OUT=$(az network application-gateway ssl-cert create \
        --gateway-name "$APP_GATEWAY_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$AGW_CERT_NAME" \
        --cert-file "$PFX_FILE_PATH" \
        --cert-password "$PFX_PASSWORD" \
        --output none 2>&1)
    AZ_CERT_RC=$?
    ACTION_DESC="added to"
fi

if [ $AZ_CERT_RC -ne 0 ]; then
    # Scrub the PFX password should the CLI echo the failing command back
    log_message "ERROR: ${AZ_CERT_OUT//$PFX_PASSWORD/***}"
    fail_and_exit "Failed to commit SSL certificate to gateway"
fi
log_message "SSL certificate object $ACTION_DESC gateway"
log_message "Application Gateway update committed successfully"

# --- Report final gateway state ---
UPDATED_JSON=$(az network application-gateway show \
    --name "$APP_GATEWAY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query '{operationalState: operationalState, provisioningState: provisioningState}' \
    --output json 2>/dev/null)
log_message "  Provisioning state : $(echo "$UPDATED_JSON" | jq -r '.provisioningState // "unknown"')"
log_message "  Operational state  : $(echo "$UPDATED_JSON" | jq -r '.operationalState // "unknown"')"

log_message "=========================================="
log_message "Certificate upload to Application Gateway completed successfully"
log_message "  AGW Certificate Name : $AGW_CERT_NAME"
log_message "  Application Gateway  : $APP_GATEWAY_NAME"
log_message "  Resource Group       : $RESOURCE_GROUP"
log_message "  Subscription         : $AZ_SUBSCRIPTION_ID"
log_message "=========================================="

log_message "Script execution completed"
log_message "=========================================="

exit 0
