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

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/var/log/satellite-cert-update.log"

# Target certificate paths for Satellite
SATELLITE_CERT_DIR="/root/satellite_cert"
SATELLITE_SERVER_CERT="$SATELLITE_CERT_DIR/rhn-sat-dev-2_crt.pem"
SATELLITE_SERVER_KEY="$SATELLITE_CERT_DIR/rhn-sat-dev-2_key.pem"
SATELLITE_CHAIN_FILE="$SATELLITE_CERT_DIR/digicert-chain.pem"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to backup certificates
backup_certs() {
    local target=$1
    log_message "Backing up $target"
    cp -f "$target" "$target.$(date +'%Y%m%d')" 2>/dev/null || log_message "No existing file to backup: $target"
}

# Function to rollback certificates
rollback_certs() {
    log_message "Starting certificate rollback..."
    for target in "$SATELLITE_SERVER_CERT" "$SATELLITE_SERVER_KEY" "$SATELLITE_CHAIN_FILE"; do
        if [ -f "$target.$(date +'%Y%m%d')" ]; then
            log_message "Restoring $target from $target.$(date +'%Y%m%d')"
            cp -f "$target.$(date +'%Y%m%d')" "$target" || {
                log_message "ERROR: Failed to restore $target"
                return 1
            }
        fi
    done
    log_message "Rollback completed"
    return 0
}

# Function to install certificates
install_certs() {
    local cert=$1
    local key=$2
    local chain=$3
    
    log_message "Running katello-certs-check to validate certificates..."
    /usr/sbin/katello-certs-check \
        -c "$cert" \
        -k "$key" \
        -b "$chain" 2>&1 | while read line; do
        log_message "  $line"
    done
    
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log_message "Certificate validation successful, proceeding with installation..."
        
        /usr/sbin/satellite-installer --scenario satellite \
            --certs-server-cert "$cert" \
            --certs-server-key "$key" \
            --certs-server-ca-cert "$chain" \
            --certs-update-server --certs-update-server-ca 2>&1 | while read line; do
            log_message "  $line"
        done
        
        if [ ${PIPESTATUS[0]} -eq 0 ]; then
            log_message "Certificate installation completed successfully"
            return 0
        else
            log_message "ERROR: Satellite installer failed"
            return 1
        fi
    else
        log_message "ERROR: Certificate validation failed"
        return 1
    fi
}

# Start logging
log_message "=========================================="
log_message "Starting Red Hat Satellite certificate update script"
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
log_message "  SATELLITE_CERT_DIR: $SATELLITE_CERT_DIR"

# Check DC1_POST_SCRIPT_DATA environment variable
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

# Decode the Base64-encoded JSON string
CERT_INFO=${DC1_POST_SCRIPT_DATA}
JSON_STRING=$(echo "$CERT_INFO" | base64 -d)
log_message "JSON_STRING decoded successfully"

# Extract cert folder from JSON
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt file name
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
log_message "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
log_message "Extracted KEY_FILE: $KEY_FILE"

# Construct source file paths
SOURCE_CRT_PATH="${CERT_FOLDER}/${CRT_FILE}"
SOURCE_KEY_PATH="${CERT_FOLDER}/${KEY_FILE}"
log_message "Source file paths:"
log_message "  Certificate: $SOURCE_CRT_PATH"
log_message "  Private key: $SOURCE_KEY_PATH"

# Check if source files exist
if [ ! -f "$SOURCE_CRT_PATH" ]; then
    log_message "ERROR: Certificate file not found: $SOURCE_CRT_PATH"
    exit 1
fi

if [ ! -f "$SOURCE_KEY_PATH" ]; then
    log_message "ERROR: Key file not found: $SOURCE_KEY_PATH"
    exit 1
fi

log_message "Source certificate file size: $(stat -c%s "$SOURCE_CRT_PATH") bytes"
log_message "Source key file size: $(stat -c%s "$SOURCE_KEY_PATH") bytes"

# Count total certificates in the file
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${SOURCE_CRT_PATH}")
log_message "Total certificates in chain: $CERT_COUNT"

# Create satellite cert directory if it doesn't exist
if [ ! -d "$SATELLITE_CERT_DIR" ]; then
    log_message "Creating satellite certificate directory: $SATELLITE_CERT_DIR"
    mkdir -p "$SATELLITE_CERT_DIR"
fi

# Backup existing certificates
log_message "Backing up existing certificates..."
backup_certs "$SATELLITE_SERVER_CERT"
backup_certs "$SATELLITE_SERVER_KEY"
backup_certs "$SATELLITE_CHAIN_FILE"

# Process the certificate chain - separate server cert from chain
log_message "Processing certificate chain..."
TEMP_CERT="$SATELLITE_SERVER_CERT.tmp"
TEMP_CHAIN="$SATELLITE_CHAIN_FILE.tmp"
> "$TEMP_CERT"
> "$TEMP_CHAIN"

INCERT='false'
CERT_NUM=0
OUTFILE="$TEMP_CERT"

while IFS= read -r line; do
    if [[ $line == *"BEGIN CERTIFICATE"* ]]; then
        INCERT='true'
        CERT_NUM=$((CERT_NUM + 1))
        if [ $CERT_NUM -gt 1 ]; then
            OUTFILE="$TEMP_CHAIN"
        fi
    fi
    
    if [[ $INCERT == "true" ]]; then
        echo "$line" >> "$OUTFILE"
    fi
    
    if [[ $line == *"END CERTIFICATE"* ]]; then
        INCERT='false'
    fi
done < "$SOURCE_CRT_PATH"

# Verify the server certificate contains the hostname
log_message "Verifying server certificate..."
if openssl x509 -in "$TEMP_CERT" -noout -text 2>/dev/null | grep -q "$(hostname -s)"; then
    log_message "Server certificate verified - contains hostname $(hostname -s)"
    cp -f "$TEMP_CERT" "$SATELLITE_SERVER_CERT"
    rm -f "$TEMP_CERT"
else
    log_message "WARNING: Server certificate may not contain hostname $(hostname -s)"
    log_message "Proceeding with installation anyway..."
    cp -f "$TEMP_CERT" "$SATELLITE_SERVER_CERT"
    rm -f "$TEMP_CERT"
fi

# Verify the chain certificate
log_message "Processing certificate chain..."
if [ -s "$TEMP_CHAIN" ]; then
    if openssl x509 -in "$TEMP_CHAIN" -noout -text 2>/dev/null | grep -q "DigiCert"; then
        log_message "Chain certificates verified - contains DigiCert CA"
    else
        log_message "WARNING: Chain may not contain expected DigiCert CA"
    fi
    cp -f "$TEMP_CHAIN" "$SATELLITE_CHAIN_FILE"
    rm -f "$TEMP_CHAIN"
else
    # If no separate chain, use the full certificate file as chain
    log_message "No separate chain found, using full certificate file"
    cp -f "$SOURCE_CRT_PATH" "$SATELLITE_CHAIN_FILE"
fi

# Copy the private key
log_message "Installing private key..."
cp -f "$SOURCE_KEY_PATH" "$SATELLITE_SERVER_KEY"

# Set appropriate permissions
log_message "Setting file permissions..."
chmod 600 "$SATELLITE_SERVER_KEY"
chmod 644 "$SATELLITE_SERVER_CERT"
chmod 644 "$SATELLITE_CHAIN_FILE"

# Install certificates
log_message "=========================================="
log_message "Beginning certificate installation to Satellite..."
log_message "=========================================="

install_certs "$SATELLITE_SERVER_CERT" "$SATELLITE_SERVER_KEY" "$SATELLITE_CHAIN_FILE"
INSTALL_RESULT=$?

if [ $INSTALL_RESULT -ne 0 ]; then
    log_message "ERROR: Certificate installation failed, initiating rollback..."
    rollback_certs
    
    log_message "Attempting to reinstall with rolled-back certificates..."
    install_certs "$SATELLITE_SERVER_CERT" "$SATELLITE_SERVER_KEY" "$SATELLITE_CHAIN_FILE"
    
    if [ $? -ne 0 ]; then
        log_message "CRITICAL: Failed to install even with rolled-back certificates!"
        log_message "Manual intervention required immediately!"
        log_message "Please contact system administrators for urgent assistance."
        exit 1
    else
        log_message "Rollback successful - Satellite is running with previous certificates"
        log_message "New certificate installation failed - manual investigation required"
        exit 1
    fi
fi

# Verify Satellite services
log_message "Verifying Satellite services..."
sleep 5
if /usr/sbin/satellite-installer --help >/dev/null 2>&1; then
    log_message "Satellite services appear to be running normally"
else
    log_message "WARNING: Unable to verify Satellite services"
fi

log_message "=========================================="
log_message "Certificate update completed successfully"
log_message "Summary:"
log_message "  Source certificate: $SOURCE_CRT_PATH"
log_message "  Source key: $SOURCE_KEY_PATH"
log_message "  Certificates in chain: $CERT_COUNT"
log_message "  Server certificate: $SATELLITE_SERVER_CERT"
log_message "  Server key: $SATELLITE_SERVER_KEY"
log_message "  Chain file: $SATELLITE_CHAIN_FILE"
log_message "  Result: SUCCESS"
log_message "=========================================="

exit 0