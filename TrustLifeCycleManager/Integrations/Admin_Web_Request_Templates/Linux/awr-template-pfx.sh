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
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/template.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

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

# Extract the .pfx file name (instead of .crt and .key)
PFX_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.pfx')
if [ -z "$PFX_FILE" ]; then
    # Try alternative extensions for PKCS#12 format
    PFX_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.p12')
fi
log_message "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# This could be in different locations depending on your JSON structure
# Common field names: "password", "pfx_password", "keystore_password", "passphrase"
PFX_PASSWORD=$(echo "$JSON_STRING" | grep -oP '"password":"\K[^"]+' || \
               echo "$JSON_STRING" | grep -oP '"pfx_password":"\K[^"]+' || \
               echo "$JSON_STRING" | grep -oP '"keystore_password":"\K[^"]+' || \
               echo "$JSON_STRING" | grep -oP '"passphrase":"\K[^"]+')

if [ -z "$PFX_PASSWORD" ]; then
    log_message "WARNING: No PFX password found in JSON. Checking if password is in arguments..."
    # Sometimes the password might be passed as one of the arguments
    # You might need to adjust which argument contains the password
    # For example, if password is in argument 4 or 5:
    if [ ! -z "$ARGUMENT_4" ]; then
        log_message "Checking if Argument 4 could be the password..."
    fi
    if [ ! -z "$ARGUMENT_5" ]; then
        log_message "Checking if Argument 5 could be the password..."
    fi
else
    log_message "PFX password extracted from JSON"
    log_message "PFX password length: ${#PFX_PASSWORD} characters"
    # Log first 3 chars of password for verification (masked for security)
    if [ ${#PFX_PASSWORD} -ge 3 ]; then
        PFX_PASSWORD_MASKED="${PFX_PASSWORD:0:3}***"
        log_message "PFX password (masked): $PFX_PASSWORD_MASKED"
    else
        log_message "PFX password (masked): ***"
    fi
fi

# Construct file path
PFX_FILE_PATH="${CERT_FOLDER}/${PFX_FILE}"

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
log_message "  PFX file: $PFX_FILE"
log_message "  PFX file path: $PFX_FILE_PATH"
if [ ! -z "$PFX_PASSWORD" ]; then
    log_message "  PFX password: Found (${#PFX_PASSWORD} characters)"
else
    log_message "  PFX password: Not found"
fi
log_message ""
log_message "All files in array: $FILES_ARRAY"
log_message "=========================================="

# Check if PFX file exists
if [ -f "$PFX_FILE_PATH" ]; then
    log_message "PFX file exists: $PFX_FILE_PATH"
    log_message "PFX file size: $(stat -c%s "$PFX_FILE_PATH") bytes"
    
    # If we have the password, we can try to inspect the PFX contents
    if [ ! -z "$PFX_PASSWORD" ] && command -v openssl &> /dev/null; then
        log_message "OpenSSL is available, attempting to inspect PFX contents..."
        
        # Test if password is correct and get certificate info
        CERT_INFO=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -info -nokeys 2>&1 | head -20)
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
            fi
        else
            log_message "WARNING: Could not access PFX file with provided password (password may be incorrect)"
        fi
    elif command -v openssl &> /dev/null; then
        log_message "OpenSSL is available but no password provided, cannot inspect PFX contents"
    else
        log_message "OpenSSL not available, cannot inspect PFX contents"
    fi
else
    log_message "WARNING: PFX file not found: $PFX_FILE_PATH"
fi

# Additional check for any certificate-related files
log_message "=========================================="
log_message "Checking for all certificate-related files in folder..."
if [ -d "$CERT_FOLDER" ]; then
    CERT_FILES=$(ls -la "$CERT_FOLDER" 2>/dev/null | grep -E '\.(pfx|p12|cer|crt|key|pem)$')
    if [ ! -z "$CERT_FILES" ]; then
        log_message "Certificate-related files found:"
        echo "$CERT_FILES" | while read line; do
            log_message "  $line"
        done
    else
        log_message "No certificate files found in folder"
    fi
else
    log_message "Certificate folder does not exist: $CERT_FOLDER"
fi

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $PFX_FILE         - The filename of the PFX/P12 certificate (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file (folder + filename)
#   $PFX_PASSWORD     - Password for the PFX/P12 file (if available)
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array (AWR Parameter 1)
#   $ARGUMENT_2       - Second argument from args array (AWR Parameter 2)
#   $ARGUMENT_3       - Third argument from args array (AWR Parameter 3)
#   $ARGUMENT_4       - Fourth argument from args array (AWR Parameter 4)
#   $ARGUMENT_5       - Fifth argument from args array (AWR Parameter 5)
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Certificate inspection variables (if OpenSSL available and password correct):
#   $CERT_COUNT       - Number of certificates in the PFX
#   $KEY_TYPE         - Type of key (RSA, ECC, or Unknown)
#   $CERT_SUBJECT     - Certificate subject DN
#
# Utility function:
#   log_message "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="

# Example 1: Copy certificate to another location
# if [ -f "$PFX_FILE_PATH" ]; then
#     BACKUP_DIR="/backup/certificates"
#     mkdir -p "$BACKUP_DIR"
#     cp "$PFX_FILE_PATH" "$BACKUP_DIR/"
#     log_message "Certificate copied to backup location: $BACKUP_DIR"
# fi

# Example 2: Import certificate to Java keystore
# if [ ! -z "$PFX_PASSWORD" ] && [ -f "$PFX_FILE_PATH" ]; then
#     KEYSTORE_PATH="/path/to/keystore.jks"
#     KEYSTORE_PASS="changeit"
#     ALIAS_NAME="myservice"
#     
#     keytool -importkeystore \
#         -srckeystore "$PFX_FILE_PATH" \
#         -srcstoretype pkcs12 \
#         -srcstorepass "$PFX_PASSWORD" \
#         -destkeystore "$KEYSTORE_PATH" \
#         -deststoretype JKS \
#         -deststorepass "$KEYSTORE_PASS" \
#         -alias "$ALIAS_NAME" \
#         2>&1 | while read line; do log_message "Keystore import: $line"; done
# fi

# Example 3: Extract certificate and key from PFX for web server
# if [ ! -z "$PFX_PASSWORD" ] && [ -f "$PFX_FILE_PATH" ] && command -v openssl &> /dev/null; then
#     # Extract certificate
#     openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" \
#         -out "${CERT_FOLDER}/server.crt" -nokeys -clcerts
#     log_message "Certificate extracted to: ${CERT_FOLDER}/server.crt"
#     
#     # Extract private key (unencrypted)
#     openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" \
#         -out "${CERT_FOLDER}/server.key" -nocerts -nodes
#     log_message "Private key extracted to: ${CERT_FOLDER}/server.key"
#     
#     # Set appropriate permissions
#     chmod 644 "${CERT_FOLDER}/server.crt"
#     chmod 600 "${CERT_FOLDER}/server.key"
# fi

# Example 4: Restart services based on arguments
# if [ "$ARGUMENT_1" == "restart_nginx" ]; then
#     log_message "Restarting nginx service as requested..."
#     systemctl restart nginx
#     log_message "Nginx service restarted"
# fi

# Example 5: Send notification based on certificate deployment
# if [ -f "$PFX_FILE_PATH" ]; then
#     NOTIFICATION_EMAIL="$ARGUMENT_2"  # Assuming email is in argument 2
#     if [ ! -z "$NOTIFICATION_EMAIL" ]; then
#         echo "Certificate deployed: $PFX_FILE at $(date)" | \
#             mail -s "Certificate Deployment Notification" "$NOTIFICATION_EMAIL"
#         log_message "Notification sent to: $NOTIFICATION_EMAIL"
#     fi
# fi

# ADD YOUR CUSTOM LOGIC HERE:
# ----------------------------------------




# ----------------------------------------
# END OF CUSTOM LOGIC

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0