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
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/lightspeed.log"

# Rocket certificate paths
ROCKET_CERT_DIR="/usr/local/rocket/etc"
ROCKET_CERT_FILE="${ROCKET_CERT_DIR}/cert.pem"
ROCKET_KEY_FILE="${ROCKET_CERT_DIR}/cert_key.pem"
ROCKET_CERT_BACKUP="${ROCKET_CERT_FILE}.orig"
ROCKET_KEY_BACKUP="${ROCKET_KEY_FILE}.orig"

# Target ownership and permissions
TARGET_OWNER="srv-62-relay"
TARGET_GROUP="srv-62-relay"
TARGET_PERMISSIONS="664"

# Service to restart
SERVICE_NAME="lsws"
SERVICE_RESTART="false"

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
log_message "  SERVICE_RESTART: $SERVICE_RESTART"

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
log_message "  Argument 1: $ARGUMENT_1"
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
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $CRT_FILE         - The certificate filename (.crt)
#   $KEY_FILE         - The private key filename (.key)
#   $CRT_FILE_PATH    - Full path to the certificate file
#   $KEY_FILE_PATH    - Full path to the private key file
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Certificate inspection variables (if files exist):
#   $CERT_COUNT       - Number of certificates in the CRT file
#   $KEY_TYPE         - Type of key (RSA, ECC, PKCS#8 format, or Unknown)
#   $KEY_FILE_CONTENT - The full content of the private key file
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Utility function:
#   log_message "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="


# ADD CUSTOM LOGIC HERE:
# ----------------------------------------

# Deploy certificates to Rocket server
log_message "Starting Rocket certificate deployment..."
log_message "Target directory: $ROCKET_CERT_DIR"
log_message "Target owner:group: ${TARGET_OWNER}:${TARGET_GROUP}"
log_message "Target permissions: $TARGET_PERMISSIONS"

# Verify source certificate files exist
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Source certificate file not found: $CRT_FILE_PATH"
    log_message "Certificate deployment FAILED"
    exit 1
fi

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Source private key file not found: $KEY_FILE_PATH"
    log_message "Certificate deployment FAILED"
    exit 1
fi

log_message "Source certificate file verified: $CRT_FILE_PATH"
log_message "Source private key file verified: $KEY_FILE_PATH"

# Check if target directory exists
if [ ! -d "$ROCKET_CERT_DIR" ]; then
    log_message "ERROR: Target directory does not exist: $ROCKET_CERT_DIR"
    log_message "Certificate deployment FAILED"
    exit 1
fi

log_message "Target directory exists: $ROCKET_CERT_DIR"

# Backup existing certificate if it exists
if [ -f "$ROCKET_CERT_FILE" ]; then
    log_message "Backing up existing certificate: $ROCKET_CERT_FILE -> $ROCKET_CERT_BACKUP"
    if mv "$ROCKET_CERT_FILE" "$ROCKET_CERT_BACKUP"; then
        log_message "Certificate backup successful"
    else
        log_message "ERROR: Failed to backup certificate"
        exit 1
    fi
else
    log_message "No existing certificate to backup: $ROCKET_CERT_FILE"
fi

# Backup existing private key if it exists
if [ -f "$ROCKET_KEY_FILE" ]; then
    log_message "Backing up existing private key: $ROCKET_KEY_FILE -> $ROCKET_KEY_BACKUP"
    if mv "$ROCKET_KEY_FILE" "$ROCKET_KEY_BACKUP"; then
        log_message "Private key backup successful"
    else
        log_message "ERROR: Failed to backup private key"
        exit 1
    fi
else
    log_message "No existing private key to backup: $ROCKET_KEY_FILE"
fi

# Copy new certificate
log_message "Copying new certificate: $CRT_FILE_PATH -> $ROCKET_CERT_FILE"
if cp "$CRT_FILE_PATH" "$ROCKET_CERT_FILE"; then
    log_message "Certificate copy successful"
else
    log_message "ERROR: Failed to copy certificate"
    # Attempt to restore backup
    if [ -f "$ROCKET_CERT_BACKUP" ]; then
        log_message "Attempting to restore certificate backup..."
        mv "$ROCKET_CERT_BACKUP" "$ROCKET_CERT_FILE"
    fi
    exit 1
fi

# Copy new private key
log_message "Copying new private key: $KEY_FILE_PATH -> $ROCKET_KEY_FILE"
if cp "$KEY_FILE_PATH" "$ROCKET_KEY_FILE"; then
    log_message "Private key copy successful"
else
    log_message "ERROR: Failed to copy private key"
    # Attempt to restore backups
    if [ -f "$ROCKET_CERT_BACKUP" ]; then
        log_message "Attempting to restore certificate backup..."
        mv "$ROCKET_CERT_BACKUP" "$ROCKET_CERT_FILE"
    fi
    if [ -f "$ROCKET_KEY_BACKUP" ]; then
        log_message "Attempting to restore private key backup..."
        mv "$ROCKET_KEY_BACKUP" "$ROCKET_KEY_FILE"
    fi
    exit 1
fi

# Set ownership for certificate
log_message "Setting ownership for certificate: ${TARGET_OWNER}:${TARGET_GROUP}"
if chown "${TARGET_OWNER}:${TARGET_GROUP}" "$ROCKET_CERT_FILE"; then
    log_message "Certificate ownership set successfully"
else
    log_message "ERROR: Failed to set certificate ownership"
    exit 1
fi

# Set ownership for private key
log_message "Setting ownership for private key: ${TARGET_OWNER}:${TARGET_GROUP}"
if chown "${TARGET_OWNER}:${TARGET_GROUP}" "$ROCKET_KEY_FILE"; then
    log_message "Private key ownership set successfully"
else
    log_message "ERROR: Failed to set private key ownership"
    exit 1
fi

# Set permissions for certificate (664 = rw-rw-r--)
log_message "Setting permissions for certificate: $TARGET_PERMISSIONS"
if chmod "$TARGET_PERMISSIONS" "$ROCKET_CERT_FILE"; then
    log_message "Certificate permissions set successfully"
else
    log_message "ERROR: Failed to set certificate permissions"
    exit 1
fi

# Set permissions for private key (664 = rw-rw-r--)
log_message "Setting permissions for private key: $TARGET_PERMISSIONS"
if chmod "$TARGET_PERMISSIONS" "$ROCKET_KEY_FILE"; then
    log_message "Private key permissions set successfully"
else
    log_message "ERROR: Failed to set private key permissions"
    exit 1
fi

# Verify deployment
log_message "=========================================="
log_message "DEPLOYMENT VERIFICATION:"
log_message "=========================================="

if [ -f "$ROCKET_CERT_FILE" ]; then
    CERT_PERMS=$(stat -c "%a" "$ROCKET_CERT_FILE")
    CERT_OWNER=$(stat -c "%U:%G" "$ROCKET_CERT_FILE")
    CERT_SIZE=$(stat -c "%s" "$ROCKET_CERT_FILE")
    log_message "Certificate deployed:"
    log_message "  Path: $ROCKET_CERT_FILE"
    log_message "  Permissions: $CERT_PERMS"
    log_message "  Owner: $CERT_OWNER"
    log_message "  Size: $CERT_SIZE bytes"
else
    log_message "ERROR: Certificate file not found after deployment"
    exit 1
fi

if [ -f "$ROCKET_KEY_FILE" ]; then
    KEY_PERMS=$(stat -c "%a" "$ROCKET_KEY_FILE")
    KEY_OWNER=$(stat -c "%U:%G" "$ROCKET_KEY_FILE")
    KEY_SIZE=$(stat -c "%s" "$ROCKET_KEY_FILE")
    log_message "Private key deployed:"
    log_message "  Path: $ROCKET_KEY_FILE"
    log_message "  Permissions: $KEY_PERMS"
    log_message "  Owner: $KEY_OWNER"
    log_message "  Size: $KEY_SIZE bytes"
else
    log_message "ERROR: Private key file not found after deployment"
    exit 1
fi

if [ -f "$ROCKET_CERT_BACKUP" ]; then
    log_message "Certificate backup created: $ROCKET_CERT_BACKUP"
fi

if [ -f "$ROCKET_KEY_BACKUP" ]; then
    log_message "Private key backup created: $ROCKET_KEY_BACKUP"
fi

log_message "=========================================="
log_message "Rocket certificate deployment completed successfully"
log_message "=========================================="

# Restart service (if enabled)
if [ "$SERVICE_RESTART" = "true" ]; then
    log_message "=========================================="
    log_message "Restarting $SERVICE_NAME service..."
    log_message "=========================================="

    # Check if service exists
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
        log_message "Service $SERVICE_NAME found in systemd"
        
        # Check service status before restart
        SERVICE_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>&1)
        log_message "Service status before restart: $SERVICE_STATUS"
        
        # Restart the service
        log_message "Executing: systemctl restart $SERVICE_NAME"
        if systemctl restart "$SERVICE_NAME"; then
            log_message "Service $SERVICE_NAME restarted successfully"
            
            # Wait a moment for service to stabilize
            sleep 2
            
            # Verify service is running
            SERVICE_STATUS_AFTER=$(systemctl is-active "$SERVICE_NAME" 2>&1)
            log_message "Service status after restart: $SERVICE_STATUS_AFTER"
            
            if [ "$SERVICE_STATUS_AFTER" = "active" ]; then
                log_message "Service $SERVICE_NAME is active and running"
            else
                log_message "WARNING: Service $SERVICE_NAME may not be running properly"
                log_message "Service status: $SERVICE_STATUS_AFTER"
                # Get detailed status
                SERVICE_DETAIL=$(systemctl status "$SERVICE_NAME" 2>&1 | head -n 10)
                log_message "Service details: $SERVICE_DETAIL"
            fi
        else
            log_message "ERROR: Failed to restart service $SERVICE_NAME"
            SERVICE_ERROR=$(systemctl status "$SERVICE_NAME" 2>&1 | head -n 10)
            log_message "Service error details: $SERVICE_ERROR"
            exit 1
        fi
    else
        log_message "WARNING: Service $SERVICE_NAME not found in systemd"
        log_message "Available services matching 'lsws': $(systemctl list-unit-files | grep lsws)"
        exit 1
    fi

    log_message "=========================================="
    log_message "Service restart completed"
    log_message "=========================================="
else
    log_message "=========================================="
    log_message "Service restart SKIPPED (SERVICE_RESTART=$SERVICE_RESTART)"
    log_message "=========================================="
fi

# ----------------------------------------
# END CUSTOM LOGIC

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0