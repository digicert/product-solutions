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
# Configuration
# ============================================================================
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/opt/digicert/logs/postfix-awr.log"

# Postfix Configuration
# Set to "true" to restart/reload Postfix after certificate replacement
RESTART_POSTFIX="true"

# ============================================================================
# Argument Mapping (configured in TLM Admin Web Request)
# ============================================================================
# ARGUMENT_1 - (not used - available for future use)
# ARGUMENT_2 - (not used - available for future use)
# ARGUMENT_3 - (not used - available for future use)
# ARGUMENT_4 - (not used - available for future use)
# ARGUMENT_5 - (not used - available for future use)
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to log certificate details from a live STARTTLS connection
log_live_cert_details() {
    local LABEL="$1"
    local SERVERNAME
    SERVERNAME=$(postconf -h myhostname 2>/dev/null)
    if [ -z "$SERVERNAME" ]; then
        SERVERNAME="localhost"
    fi

    log_message "--- $LABEL: Live STARTTLS Certificate (servername: $SERVERNAME) ---"
    LIVE_CERT_OUTPUT=$(openssl s_client -connect localhost:25 -starttls smtp -servername "$SERVERNAME" 2>/dev/null </dev/null \
        | openssl x509 -noout -serial -subject -issuer -dates 2>&1)
    if [ $? -eq 0 ] && [ -n "$LIVE_CERT_OUTPUT" ]; then
        while IFS= read -r line; do
            log_message "  $line"
        done <<< "$LIVE_CERT_OUTPUT"
    else
        log_message "  WARNING: Unable to retrieve live certificate via STARTTLS"
    fi
    log_message "--- End $LABEL Live STARTTLS Certificate ---"
}

# Start logging
log_message "=========================================="
log_message "Starting Postfix TLS Certificate Replacement Script"
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
log_message "  RESTART_POSTFIX: $RESTART_POSTFIX"
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
# POSTFIX TLS CERTIFICATE REPLACEMENT
# ============================================================================

log_message "=========================================="
log_message "Starting Postfix TLS certificate replacement..."
log_message "=========================================="

# ---- STEP 1: Read current Postfix TLS configuration (BEFORE) ----
log_message "--- BEFORE: Current Postfix TLS Configuration ---"
CURRENT_CERT_FILE=$(postconf -h smtpd_tls_cert_file 2>/dev/null)
CURRENT_KEY_FILE=$(postconf -h smtpd_tls_key_file 2>/dev/null)
log_message "  smtpd_tls_cert_file = $CURRENT_CERT_FILE"
log_message "  smtpd_tls_key_file  = $CURRENT_KEY_FILE"

# Log current certificate details from file
if [ -f "$CURRENT_CERT_FILE" ]; then
    log_message "--- BEFORE: Current certificate details (from file) ---"
    BEFORE_CERT_DETAILS=$(openssl x509 -in "$CURRENT_CERT_FILE" -noout -serial -subject -issuer -dates 2>&1)
    while IFS= read -r line; do
        log_message "  $line"
    done <<< "$BEFORE_CERT_DETAILS"
else
    log_message "  WARNING: Current certificate file not found: $CURRENT_CERT_FILE"
fi

# Log current live STARTTLS certificate
log_live_cert_details "BEFORE"

# ---- STEP 2: Validate new certificate and key ----
log_message "Validating new certificate and key files..."

if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: New certificate file not found: $CRT_FILE_PATH"
    log_message "Script execution terminated."
    exit 1
fi

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: New private key file not found: $KEY_FILE_PATH"
    log_message "Script execution terminated."
    exit 1
fi

# Verify the certificate and key match
# Use public key hash comparison which works for both RSA and ECC keys
CERT_PUBKEY_HASH=$(openssl x509 -noout -pubkey -in "$CRT_FILE_PATH" 2>/dev/null | openssl md5)
KEY_PUBKEY_HASH=$(openssl pkey -pubout -in "$KEY_FILE_PATH" 2>/dev/null | openssl md5)

if [ -z "$CERT_PUBKEY_HASH" ] || [ -z "$KEY_PUBKEY_HASH" ]; then
    log_message "WARNING: Unable to extract public key for matching"
    log_message "  Certificate public key hash: ${CERT_PUBKEY_HASH:-empty}"
    log_message "  Key public key hash:         ${KEY_PUBKEY_HASH:-empty}"
else
    if [ "$CERT_PUBKEY_HASH" = "$KEY_PUBKEY_HASH" ]; then
        log_message "Certificate and private key match confirmed (public key hash)"
        log_message "  Public key hash: $CERT_PUBKEY_HASH"
    else
        log_message "ERROR: Certificate and private key DO NOT MATCH"
        log_message "  Certificate public key hash: $CERT_PUBKEY_HASH"
        log_message "  Key public key hash:         $KEY_PUBKEY_HASH"
        log_message "Script execution terminated."
        exit 1
    fi
fi

# Log new certificate details
log_message "--- New certificate details ---"
NEW_CERT_DETAILS=$(openssl x509 -in "$CRT_FILE_PATH" -noout -serial -subject -issuer -dates 2>&1)
while IFS= read -r line; do
    log_message "  $line"
done <<< "$NEW_CERT_DETAILS"

# ---- STEP 3: Update Postfix TLS configuration ----
log_message "Updating Postfix TLS configuration..."

postconf -e "smtpd_tls_cert_file = $CRT_FILE_PATH"
if [ $? -eq 0 ]; then
    log_message "Successfully updated smtpd_tls_cert_file = $CRT_FILE_PATH"
else
    log_message "ERROR: Failed to update smtpd_tls_cert_file"
    exit 1
fi

postconf -e "smtpd_tls_key_file = $KEY_FILE_PATH"
if [ $? -eq 0 ]; then
    log_message "Successfully updated smtpd_tls_key_file = $KEY_FILE_PATH"
else
    log_message "ERROR: Failed to update smtpd_tls_key_file"
    exit 1
fi

# Ensure TLS is enabled
postconf -e "smtpd_tls_security_level = may"
log_message "Ensured smtpd_tls_security_level = may"

# ---- STEP 4: Reload/Restart Postfix ----
if [ "$RESTART_POSTFIX" = "true" ]; then
    log_message "Reloading Postfix to apply new certificate..."
    systemctl reload postfix
    if [ $? -eq 0 ]; then
        log_message "Postfix reloaded successfully"
    else
        log_message "WARNING: Postfix reload failed, attempting restart..."
        systemctl restart postfix
        if [ $? -eq 0 ]; then
            log_message "Postfix restarted successfully"
        else
            log_message "ERROR: Postfix restart failed"
            exit 1
        fi
    fi

    # Brief pause to allow Postfix to fully initialise with new cert
    sleep 2
else
    log_message "RESTART_POSTFIX is set to false - skipping Postfix reload"
    log_message "NOTE: Postfix must be reloaded manually for the new certificate to take effect"
fi

# ---- STEP 5: Log AFTER configuration and live certificate ----
log_message "--- AFTER: Updated Postfix TLS Configuration ---"
AFTER_CERT_FILE=$(postconf -h smtpd_tls_cert_file 2>/dev/null)
AFTER_KEY_FILE=$(postconf -h smtpd_tls_key_file 2>/dev/null)
log_message "  smtpd_tls_cert_file = $AFTER_CERT_FILE"
log_message "  smtpd_tls_key_file  = $AFTER_KEY_FILE"

if [ "$RESTART_POSTFIX" = "true" ]; then
    log_live_cert_details "AFTER"
else
    log_message "  Skipping live STARTTLS check (Postfix has not been reloaded)"
fi

# ---- STEP 6: Summary ----
log_message "=========================================="
log_message "POSTFIX CERTIFICATE REPLACEMENT SUMMARY:"
log_message "=========================================="
log_message "  BEFORE cert file: $CURRENT_CERT_FILE"
log_message "  AFTER  cert file: $AFTER_CERT_FILE"
log_message "  BEFORE key file:  $CURRENT_KEY_FILE"
log_message "  AFTER  key file:  $AFTER_KEY_FILE"
log_message "  Postfix reloaded: $RESTART_POSTFIX"
log_message "=========================================="

# ============================================================================
# END OF POSTFIX TLS CERTIFICATE REPLACEMENT
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0