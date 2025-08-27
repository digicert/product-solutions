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
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/dc1_data.log"

# Java Keystore Configuration
JKS_PATH="/home/weblogic.jks"
JKS_PASSWORD="changeit"
JKS_BACKUP_DIR="/home/backups"
JKS_ALIAS="server_cert"  # Fixed alias to use in keystore
USE_CN_AS_ALIAS="false"  # Set to "true" to use certificate CN as alias, "false" to use JKS_ALIAS

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format with JKS update)"
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
log_message "  JKS_PATH: $JKS_PATH"
log_message "  JKS_ALIAS: $JKS_ALIAS"
log_message "  JKS_BACKUP_DIR: $JKS_BACKUP_DIR"

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

# Extract all 5 arguments (might be empty)
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

log_message "Arguments extracted:"
log_message "  ARGUMENT_1: '$ARGUMENT_1'"
log_message "  ARGUMENT_2: '$ARGUMENT_2'"
log_message "  ARGUMENT_3: '$ARGUMENT_3'"
log_message "  ARGUMENT_4: '$ARGUMENT_4'"
log_message "  ARGUMENT_5: '$ARGUMENT_5'"

# Extract cert folder
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract ALL files from the files array
FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

# Extract all PFX files into an array - FIXED parsing
# Remove quotes and split by comma
PFX_FILES_STRING=$(echo "$FILES_ARRAY" | tr -d '"' | tr -d ' ')
IFS=',' read -ra PFX_FILES_TEMP <<< "$PFX_FILES_STRING"

# Filter for PFX files
PFX_FILES=()
for file in "${PFX_FILES_TEMP[@]}"; do
    if [[ "$file" == *.pfx ]] || [[ "$file" == *.p12 ]]; then
        PFX_FILES+=("$file")
    fi
done

log_message "Found ${#PFX_FILES[@]} PFX file(s): ${PFX_FILES[*]}"

# Identify the non-legacy PFX file
NON_LEGACY_PFX=""
LEGACY_PFX=""

for pfx_file in "${PFX_FILES[@]}"; do
    if [[ "$pfx_file" == *"_legacy"* ]]; then
        LEGACY_PFX="$pfx_file"
        log_message "Identified legacy PFX file: $LEGACY_PFX"
    else
        NON_LEGACY_PFX="$pfx_file"
        log_message "Identified non-legacy PFX file: $NON_LEGACY_PFX"
    fi
done

# If no non-legacy file found, use the first available PFX
if [ -z "$NON_LEGACY_PFX" ] && [ ${#PFX_FILES[@]} -gt 0 ]; then
    NON_LEGACY_PFX="${PFX_FILES[0]}"
    log_message "No explicit non-legacy file found, using: $NON_LEGACY_PFX"
fi

# Extract the PFX password from JSON - FIXED parsing
PFX_PASSWORD=$(echo "$JSON_STRING" | grep -oP '"password":"\K[^"]+')

if [ -z "$PFX_PASSWORD" ]; then
    log_message "WARNING: No PFX password found in JSON with 'password' field"
    # Try alternative field names
    PFX_PASSWORD=$(echo "$JSON_STRING" | grep -oP '"pfx_password":"\K[^"]+' || \
                   echo "$JSON_STRING" | grep -oP '"keystore_password":"\K[^"]+' || \
                   echo "$JSON_STRING" | grep -oP '"passphrase":"\K[^"]+')
    
    if [ -z "$PFX_PASSWORD" ]; then
        log_message "WARNING: No PFX password found in any expected fields"
    fi
else
    log_message "PFX password extracted from JSON"
    log_message "PFX password length: ${#PFX_PASSWORD} characters"
    if [ ${#PFX_PASSWORD} -ge 3 ]; then
        PFX_PASSWORD_MASKED="${PFX_PASSWORD:0:3}***"
        log_message "PFX password (masked): $PFX_PASSWORD_MASKED"
    else
        log_message "PFX password (masked): ***"
    fi
fi

# Construct file path for non-legacy PFX
PFX_FILE_PATH="${CERT_FOLDER}/${NON_LEGACY_PFX}"

# Log summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Non-legacy PFX file: $NON_LEGACY_PFX"
log_message "  Legacy PFX file: $LEGACY_PFX"
log_message "  PFX file path: $PFX_FILE_PATH"
if [ ! -z "$PFX_PASSWORD" ]; then
    log_message "  PFX password: Found (${#PFX_PASSWORD} characters)"
else
    log_message "  PFX password: Not found"
fi
log_message "=========================================="

# Check if PFX file exists and inspect it
if [ -f "$PFX_FILE_PATH" ]; then
    log_message "PFX file exists: $PFX_FILE_PATH"
    log_message "PFX file size: $(stat -c%s "$PFX_FILE_PATH") bytes"
    
    if [ ! -z "$PFX_PASSWORD" ] && command -v openssl &> /dev/null; then
        log_message "OpenSSL is available, attempting to inspect PFX contents..."
        
        # Test if password is correct
        openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -info -nokeys >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_message "Successfully accessed PFX file with provided password"
            
            # Count certificates in PFX
            CERT_COUNT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE")
            log_message "Total certificates in PFX: $CERT_COUNT"
            
            # Get key type
            KEY_INFO=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nocerts -nodes 2>/dev/null | head -5)
            if echo "$KEY_INFO" | grep -q "RSA"; then
                KEY_TYPE="RSA"
            elif echo "$KEY_INFO" | grep -q "EC"; then
                KEY_TYPE="ECC"
            else
                KEY_TYPE="Unknown"
            fi
            log_message "Key type in PFX: $KEY_TYPE"
            
            # Get certificate subject
            CERT_SUBJECT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
            if [ ! -z "$CERT_SUBJECT" ]; then
                log_message "Certificate subject: $CERT_SUBJECT"
                # Extract CN from subject
                CN=$(echo "$CERT_SUBJECT" | grep -oP 'CN\s*=\s*\K[^,/]+' | tr -d ' ')
                if [ ! -z "$CN" ]; then
                    log_message "Certificate CN: $CN"
                    if [ "$USE_CN_AS_ALIAS" == "true" ]; then
                        JKS_ALIAS="$CN"
                        log_message "Using CN as keystore alias: $JKS_ALIAS"
                    else
                        log_message "Using configured keystore alias: $JKS_ALIAS (CN=$CN)"
                    fi
                else
                    log_message "Using configured keystore alias: $JKS_ALIAS"
                fi
            fi
        else
            log_message "ERROR: Could not access PFX file with provided password"
            exit 1
        fi
    else
        if [ -z "$PFX_PASSWORD" ]; then
            log_message "ERROR: No password provided for PFX file"
        else
            log_message "ERROR: OpenSSL not available"
        fi
        exit 1
    fi
else
    log_message "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
fi

# ========================================
# JAVA KEYSTORE UPDATE SECTION
# ========================================
log_message "=========================================="
log_message "Starting Java Keystore Update Process"
log_message "=========================================="

# Check if keytool is available
if ! command -v keytool &> /dev/null; then
    log_message "ERROR: keytool command not found. Please ensure Java is installed and keytool is in PATH"
    exit 1
fi
log_message "keytool is available"

# Check Java version
JAVA_VERSION=$(keytool -version 2>&1 || echo "Unknown")
log_message "Java keytool version: $JAVA_VERSION"

# Create backup directory if it doesn't exist
if [ ! -d "$JKS_BACKUP_DIR" ]; then
    mkdir -p "$JKS_BACKUP_DIR"
    log_message "Created backup directory: $JKS_BACKUP_DIR"
fi

# Backup existing keystore if it exists
if [ -f "$JKS_PATH" ]; then
    BACKUP_FILE="${JKS_BACKUP_DIR}/weblogic_$(date +%Y%m%d_%H%M%S).jks"
    cp "$JKS_PATH" "$BACKUP_FILE"
    if [ $? -eq 0 ]; then
        log_message "Backed up existing keystore to: $BACKUP_FILE"
    else
        log_message "ERROR: Failed to backup existing keystore"
        exit 1
    fi
    
    # Check if alias already exists
    keytool -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_message "Alias '$JKS_ALIAS' already exists in keystore, will be replaced"
        # Delete existing alias
        keytool -delete -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_message "Deleted existing alias '$JKS_ALIAS' from keystore"
        fi
    else
        log_message "Alias '$JKS_ALIAS' does not exist in keystore, will be added"
    fi
else
    log_message "Keystore does not exist at $JKS_PATH, will be created"
fi

# Import PFX into Java keystore
log_message "=========================================="
log_message "Importing PFX into Java Keystore"
log_message "=========================================="
log_message "Source PFX: $PFX_FILE_PATH"
log_message "Target JKS: $JKS_PATH"
log_message "Alias: $JKS_ALIAS"

# Method 1: Direct import using keytool (Java 6+)
log_message "Attempting direct PFX import using keytool..."

# First, try to get the source alias from the PFX
SRC_ALIAS=$(keytool -list -keystore "$PFX_FILE_PATH" -storepass "$PFX_PASSWORD" -storetype pkcs12 2>/dev/null | grep "PrivateKeyEntry" | head -1 | cut -d',' -f1)
if [ -z "$SRC_ALIAS" ]; then
    SRC_ALIAS="1"
    log_message "Could not determine source alias, using default: $SRC_ALIAS"
else
    log_message "Found source alias in PFX: $SRC_ALIAS"
fi

# Import the certificate
keytool -importkeystore \
    -srckeystore "$PFX_FILE_PATH" \
    -srcstoretype pkcs12 \
    -srcstorepass "$PFX_PASSWORD" \
    -srcalias "$SRC_ALIAS" \
    -destkeystore "$JKS_PATH" \
    -deststoretype jks \
    -deststorepass "$JKS_PASSWORD" \
    -destalias "$JKS_ALIAS" \
    -destkeypass "$JKS_PASSWORD" \
    -noprompt 2>&1 | tee -a "$LOGFILE"

IMPORT_RESULT=${PIPESTATUS[0]}

if [ $IMPORT_RESULT -eq 0 ]; then
    log_message "SUCCESS: PFX successfully imported into Java keystore"
else
    log_message "Import failed with error code: $IMPORT_RESULT"
    log_message "Trying alternative import method..."
    
    # Method 2: Try without specifying source alias
    keytool -importkeystore \
        -srckeystore "$PFX_FILE_PATH" \
        -srcstoretype pkcs12 \
        -srcstorepass "$PFX_PASSWORD" \
        -destkeystore "$JKS_PATH" \
        -deststoretype jks \
        -deststorepass "$JKS_PASSWORD" \
        -noprompt 2>&1 | tee -a "$LOGFILE"
    
    IMPORT_RESULT=${PIPESTATUS[0]}
    
    if [ $IMPORT_RESULT -eq 0 ]; then
        log_message "SUCCESS: Certificate imported using alternative method"
    else
        log_message "ERROR: Failed to import PFX into keystore"
        exit 1
    fi
fi

# Verify the import
if [ $IMPORT_RESULT -eq 0 ]; then
    log_message "=========================================="
    log_message "Verifying Java Keystore Import"
    log_message "=========================================="
    
    # List all entries in the keystore
    log_message "Listing all keystore entries:"
    keytool -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 | tee -a "$LOGFILE"
    
    # Check specific alias (might have been imported with original name)
    keytool -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: Certificate alias '$JKS_ALIAS' verified in keystore"
        
        # Get certificate details
        log_message "Certificate details for alias '$JKS_ALIAS':"
        keytool -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" -v 2>&1 | grep -E "Owner:|Issuer:|Valid from:|SHA256:" | tee -a "$LOGFILE"
    else
        log_message "WARNING: Alias '$JKS_ALIAS' not found, checking what was imported..."
        log_message "All aliases in keystore:"
        keytool -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 | grep "Entry," | tee -a "$LOGFILE"
    fi
    
    log_message "=========================================="
    log_message "Java Keystore Update Completed Successfully"
    log_message "=========================================="
    log_message "Keystore: $JKS_PATH"
    log_message "Source PFX: $NON_LEGACY_PFX"
    if [ ! -z "$LEGACY_PFX" ]; then
        log_message "Legacy PFX (not imported): $LEGACY_PFX"
    fi
    if [ -f "$BACKUP_FILE" ]; then
        log_message "Backup saved to: $BACKUP_FILE"
    fi
else
    log_message "=========================================="
    log_message "ERROR: Java Keystore Update Failed"
    log_message "=========================================="
    exit 1
fi

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0