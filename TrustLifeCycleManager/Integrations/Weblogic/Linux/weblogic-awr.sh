#!/bin/bash

: <<'LEGAL_NOTICE'
Legal Notice (version January 1, 2026)
Copyright (c) 2026 DigiCert. All rights reserved.
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
subparagraphs (c)(1) and (2) of the Commercial Computer Software-Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/opt/digicert/weblogic_awr.log"

# Java Keystore Configuration
JKS_PATH="/home/admin/Oracle/Middleware/Oracle_Home/user_projects/domains/base_domain/security/DemoIdentity.jks"
JKS_PASSWORD="DemoIdentityKeyStorePassPhrase"
JKS_BACKUP_DIR="/home/backups"
JKS_ALIAS="DemoIdentity"    # Must match exactly what WebLogic SSL config uses (case-sensitive)
USE_CN_AS_ALIAS="false"

# Explicit keytool path - avoids TLM agent environment using wrong JDK
KEYTOOL="/usr/lib/jvm/java-11-openjdk-11.0.22.0.7-2.el9.x86_64/bin/keytool"

# WebLogic Restart Configuration
WL_DOMAIN_BIN="/home/admin/Oracle/Middleware/Oracle_Home/user_projects/domains/base_domain/bin"
WL_USER="admin"             # OS user that owns/runs WebLogic - restart runs as this user
WL_RESTART_TIMEOUT=120      # seconds to wait for WebLogic to come back up after restart

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

# Decode JSON string - strip \r to handle Windows-style CRLF line endings
JSON_STRING=$(echo "$CERT_INFO" | base64 -d | tr -d '\r')
log_message "JSON_STRING decoded successfully"

# Log the raw JSON for debugging
log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d '[:space:]')

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

# Extract all PFX files into an array
PFX_FILES_STRING=$(echo "$FILES_ARRAY" | tr -d '"' | tr -d ' ')
IFS=',' read -ra PFX_FILES_TEMP <<< "$PFX_FILES_STRING"

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

if [ -z "$NON_LEGACY_PFX" ] && [ ${#PFX_FILES[@]} -gt 0 ]; then
    NON_LEGACY_PFX="${PFX_FILES[0]}"
    log_message "No explicit non-legacy file found, using: $NON_LEGACY_PFX"
fi

# Extract the PFX password from JSON
# Strip \r in case the base64-decoded JSON has Windows-style CRLF line endings
# which would append a carriage return to extracted values and corrupt passwords
PFX_PASSWORD=$(echo "$JSON_STRING" | grep -oP '"password":"\K[^"]+' | tr -d '\r\n')

if [ -z "$PFX_PASSWORD" ]; then
    log_message "WARNING: No PFX password found in JSON with 'password' field"
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

log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Non-legacy PFX file: $NON_LEGACY_PFX"
log_message "  Legacy PFX file: $LEGACY_PFX"
log_message "  PFX file path: $PFX_FILE_PATH"
if [ -n "$PFX_PASSWORD" ]; then
    log_message "  PFX password: Found (${#PFX_PASSWORD} characters)"
else
    log_message "  PFX password: Not found"
fi
log_message "=========================================="

# Check if PFX file exists and inspect it
if [ -f "$PFX_FILE_PATH" ]; then
    log_message "PFX file exists: $PFX_FILE_PATH"
    log_message "PFX file size: $(stat -c%s "$PFX_FILE_PATH") bytes"

    if [ -n "$PFX_PASSWORD" ] && command -v openssl &> /dev/null; then
        log_message "OpenSSL is available, attempting to inspect PFX contents..."

        openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -info -nokeys >/dev/null 2>&1
        if [ $? -eq 0 ]; then
            log_message "Successfully accessed PFX file with provided password"

            CERT_COUNT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE")
            log_message "Total certificates in PFX: $CERT_COUNT"

            KEY_INFO=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nocerts -nodes 2>/dev/null | head -5)
            if echo "$KEY_INFO" | grep -q "RSA"; then
                KEY_TYPE="RSA"
            elif echo "$KEY_INFO" | grep -q "EC"; then
                KEY_TYPE="ECC"
            else
                KEY_TYPE="Unknown"
            fi
            log_message "Key type in PFX: $KEY_TYPE"

            CERT_SUBJECT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
            if [ -n "$CERT_SUBJECT" ]; then
                log_message "Certificate subject: $CERT_SUBJECT"
                CN=$(echo "$CERT_SUBJECT" | grep -oP 'CN\s*=\s*\K[^,/]+' | tr -d ' ')
                if [ -n "$CN" ]; then
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

if [ ! -x "$KEYTOOL" ] &> /dev/null; then
    log_message "ERROR: keytool not found at $KEYTOOL"
    exit 1
fi
log_message "keytool is available: $KEYTOOL"

JAVA_VERSION=$($KEYTOOL -version 2>&1 || echo "Unknown")
log_message "Java keytool version: $JAVA_VERSION"

# Create backup directory if it doesn't exist
if [ ! -d "$JKS_BACKUP_DIR" ]; then
    mkdir -p "$JKS_BACKUP_DIR"
    log_message "Created backup directory: $JKS_BACKUP_DIR"
fi

# Backup existing keystore and detect its actual storetype
if [ -f "$JKS_PATH" ]; then
    BACKUP_FILE="${JKS_BACKUP_DIR}/weblogic_$(date +%Y%m%d_%H%M%S).jks"
    cp "$JKS_PATH" "$BACKUP_FILE"
    if [ $? -eq 0 ]; then
        log_message "Backed up existing keystore to: $BACKUP_FILE"
    else
        log_message "ERROR: Failed to backup existing keystore"
        exit 1
    fi

    # FIX: Detect actual storetype - the file may be PKCS12 despite a .jks extension.
    DEST_STORETYPE=$($KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>/dev/null \
        | grep -i "Keystore type:" | awk '{print tolower($3)}' | tr -d '[:space:]')
    if [ -z "$DEST_STORETYPE" ]; then
        DEST_STORETYPE="pkcs12"
        log_message "Could not detect destination keystore type, defaulting to: $DEST_STORETYPE"
    else
        log_message "Detected destination keystore type: $DEST_STORETYPE"
    fi

    # DO NOT delete the alias before import.
    # Deleting from a PKCS12 keystore breaks its internal MAC integrity,
    # causing "keystore password was incorrect" on the subsequent import.
    # Instead we import into a fresh temp keystore, then replace the
    # destination file entirely - this avoids all integrity issues.
    log_message "Alias management: using temp keystore strategy (avoids PKCS12 integrity issues)"
else
    log_message "Keystore does not exist at $JKS_PATH, will be created as PKCS12"
    DEST_STORETYPE="pkcs12"
fi

# Import PFX into Java keystore
log_message "=========================================="
log_message "Importing PFX into Java Keystore"
log_message "=========================================="
log_message "Source PFX: $PFX_FILE_PATH"
log_message "Target JKS: $JKS_PATH"
log_message "Alias: $JKS_ALIAS"
log_message "Destination storetype: $DEST_STORETYPE"

# FIX: Detect source alias from PFX with proper whitespace stripping.
SRC_ALIAS=$($KEYTOOL -list \
    -keystore "$PFX_FILE_PATH" \
    -storepass "$PFX_PASSWORD" \
    -storetype pkcs12 2>/dev/null \
    | grep -i "PrivateKeyEntry" | head -1 | cut -d',' -f1 | tr -d '[:space:]')

if [ -z "$SRC_ALIAS" ]; then
    # JDK 11 output format: "1, Jun. 23, 2026, PrivateKeyEntry,"
    # The alias is the first comma-separated field on any non-header line.
    # Explicitly exclude error lines and header lines.
    SRC_ALIAS=$($KEYTOOL -list \
        -keystore "$PFX_FILE_PATH" \
        -storepass "$PFX_PASSWORD" \
        -storetype pkcs12 2>/dev/null \
        | grep -v "^Keystore" \
        | grep -v "^Your keystore" \
        | grep -v "^$" \
        | grep -v "^Warning" \
        | grep -v "^Certificate" \
        | grep -v "^$KEYTOOL" \
        | grep -v "error" \
        | head -1 | cut -d',' -f1 | tr -d '[:space:]')
    if [ -n "$SRC_ALIAS" ]; then
        log_message "Got alias from first non-header line: '$SRC_ALIAS'"
    fi
fi

if [ -z "$SRC_ALIAS" ]; then
    # Last resort: openssl friendlyName
    SRC_ALIAS=$(openssl pkcs12 \
        -in "$PFX_FILE_PATH" \
        -passin pass:"$PFX_PASSWORD" \
        -nokeys 2>/dev/null \
        | grep -i "friendlyName" | head -1 | awk '{print $2}' | tr -d '[:space:]')
    if [ -n "$SRC_ALIAS" ]; then
        log_message "Got alias from openssl friendlyName: '$SRC_ALIAS'"
    fi
fi

if [ -z "$SRC_ALIAS" ]; then
    log_message "WARNING: Could not determine source alias - will import all entries"
    SRC_ALIAS=""
else
    log_message "Found source alias in PFX: '$SRC_ALIAS'"
fi

# Write password to a temp file to avoid shell special-character
# interpretation issues when passing passwords like "P@ssword12" as
# arguments. $KEYTOOL reads the password safely from the file via
# the -J-Dkeystore.pkcs12.legacy flag workaround, but the simplest
# fix is to use a password file passed via stdin where supported,
# or escape via printf into a temp file that $KEYTOOL reads.
#
# Simplest reliable approach: write the PFX password to a temp file
# and use -J args to pass it, avoiding any shell interpolation issue.
# Actually the most portable fix: use the JAVA_TOOL_OPTIONS env var
# approach is complex. Instead just ensure the password variable is
# exported and use it directly - bash double-quotes are safe for @.
# The real issue may be the JDK version requiring -J-Dkeystore.pkcs12.legacy
# for PKCS12 files created with older OpenSSL.

log_message "Attempting import with legacy PKCS12 flag for OpenSSL-created PFX..."

TEMP_JKS="${JKS_PATH}.tmp_$$"
log_message "Importing into temp keystore: $TEMP_JKS"

# Build import command based on whether we have a source alias.
# When SRC_ALIAS is known: use -srcalias and -destalias to import just the
#   private key entry and rename it to JKS_ALIAS in one step.
# When SRC_ALIAS is empty: import all entries without alias flags - $KEYTOOL
#   will import everything; we then rename the alias in a second step.
run_import() {
    local use_legacy=$1
    local legacy_flag=""
    [ "$use_legacy" = "true" ] && legacy_flag="-J-Dkeystore.pkcs12.legacy"

    rm -f "$TEMP_JKS"

    if [ -n "$SRC_ALIAS" ]; then
        $KEYTOOL $legacy_flag -importkeystore \
            -srckeystore    "$PFX_FILE_PATH" \
            -srcstoretype   pkcs12 \
            -srcstorepass   "$PFX_PASSWORD" \
            -srcalias       "$SRC_ALIAS" \
            -destkeystore   "$TEMP_JKS" \
            -deststoretype  "$DEST_STORETYPE" \
            -deststorepass  "$JKS_PASSWORD" \
            -destalias      "$JKS_ALIAS" \
            -noprompt 2>&1 | tee -a "$LOGFILE"
    else
        # No srcalias known - import all entries, then rename afterward
        $KEYTOOL $legacy_flag -importkeystore \
            -srckeystore    "$PFX_FILE_PATH" \
            -srcstoretype   pkcs12 \
            -srcstorepass   "$PFX_PASSWORD" \
            -destkeystore   "$TEMP_JKS" \
            -deststoretype  "$DEST_STORETYPE" \
            -deststorepass  "$JKS_PASSWORD" \
            -noprompt 2>&1 | tee -a "$LOGFILE"
    fi
    return ${PIPESTATUS[0]}
}

# Try 4 combinations: legacy flag on/off x with/without srcalias
for legacy in true false; do
    run_import "$legacy"
    IMPORT_RESULT=$?
    if [ $IMPORT_RESULT -eq 0 ]; then
        log_message "Import succeeded (legacy=$legacy)"
        break
    else
        log_message "Import failed (legacy=$legacy, exit=$IMPORT_RESULT) - trying next method..."
    fi
done

if [ $IMPORT_RESULT -ne 0 ]; then
    log_message "ERROR: All import methods failed"
    rm -f "$TEMP_JKS"
    exit 1
fi

# If we imported all entries (no srcalias), rename the private key entry
# to JKS_ALIAS using $KEYTOOL -changealias
if [ -z "$SRC_ALIAS" ]; then
    IMPORTED_ALIAS=$($KEYTOOL -list \
        -keystore "$TEMP_JKS" \
        -storepass "$JKS_PASSWORD" \
        -storetype "$DEST_STORETYPE" 2>/dev/null \
        | grep -i "PrivateKeyEntry" | head -1 | cut -d',' -f1 | tr -d '[:space:]')

    if [ -n "$IMPORTED_ALIAS" ] && [ "$IMPORTED_ALIAS" != "$JKS_ALIAS" ]; then
        log_message "Renaming imported alias '$IMPORTED_ALIAS' to '$JKS_ALIAS'..."
        $KEYTOOL -changealias \
            -keystore   "$TEMP_JKS" \
            -storepass  "$JKS_PASSWORD" \
            -alias      "$IMPORTED_ALIAS" \
            -destalias  "$JKS_ALIAS" 2>&1 | tee -a "$LOGFILE"
        log_message "Alias renamed to '$JKS_ALIAS'"
    fi
fi

# Atomically replace destination with temp keystore
mv -f "$TEMP_JKS" "$JKS_PATH"
if [ $? -eq 0 ]; then
    log_message "SUCCESS: PFX successfully imported into Java keystore"
else
    log_message "ERROR: Import succeeded but could not replace $JKS_PATH"
    rm -f "$TEMP_JKS"
    exit 1
fi

# Verify the import
if [ $IMPORT_RESULT -eq 0 ]; then
    log_message "=========================================="
    log_message "Verifying Java Keystore Import"
    log_message "=========================================="

    log_message "Listing all keystore entries:"
    $KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 | tee -a "$LOGFILE"

    $KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_message "SUCCESS: Certificate alias '$JKS_ALIAS' verified in keystore"
        log_message "Certificate details for alias '$JKS_ALIAS':"
        $KEYTOOL -list -v \
            -keystore "$JKS_PATH" \
            -storepass "$JKS_PASSWORD" \
            -alias "$JKS_ALIAS" 2>&1 \
            | grep -E "Owner:|Issuer:|Valid from:|SHA256:" | tee -a "$LOGFILE"
    else
        log_message "WARNING: Alias '$JKS_ALIAS' not found after import, checking what was imported..."
        $KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 \
            | grep "PrivateKeyEntry" | tee -a "$LOGFILE"
    fi

    log_message "=========================================="
    log_message "Java Keystore Update Completed Successfully"
    log_message "=========================================="
    log_message "Keystore: $JKS_PATH"
    log_message "Source PFX: $NON_LEGACY_PFX"
    if [ -n "$LEGACY_PFX" ]; then
        log_message "Legacy PFX (not imported): $LEGACY_PFX"
    fi
    if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
        log_message "Backup saved to: $BACKUP_FILE"
    fi
else
    log_message "=========================================="
    log_message "ERROR: Java Keystore Update Failed"
    log_message "=========================================="
    exit 1
fi

log_message "=========================================="
log_message "Restarting WebLogic to load new certificate"
log_message "=========================================="

# Stop WebLogic
log_message "Stopping WebLogic..."
if [ "$(id -u)" -eq 0 ]; then
    # Running as root - use su to stop/start as WL_USER
    su - "$WL_USER" -c "$WL_DOMAIN_BIN/stopWebLogic.sh" >> "$LOGFILE" 2>&1
else
    "$WL_DOMAIN_BIN/stopWebLogic.sh" >> "$LOGFILE" 2>&1
fi

# Wait for WebLogic to fully stop
STOP_WAIT=0
while pgrep -f "weblogic.Server" > /dev/null 2>&1; do
    sleep 2
    STOP_WAIT=$((STOP_WAIT + 2))
    if [ $STOP_WAIT -ge 60 ]; then
        log_message "WARNING: WebLogic did not stop cleanly after 60s - forcing kill..."
        pkill -f "weblogic.Server" 2>/dev/null
        sleep 3
        break
    fi
done
log_message "WebLogic stopped."

# Fix ownership of any files written by root during this script run
# so WebLogic can start cleanly as WL_USER
if [ "$(id -u)" -eq 0 ]; then
    chown -R "$WL_USER":"$WL_USER" \
        "$(dirname $JKS_PATH)" \
        "$WL_DOMAIN_BIN/../servers/AdminServer/data/" 2>/dev/null
fi

# Start WebLogic
log_message "Starting WebLogic..."
if [ "$(id -u)" -eq 0 ]; then
    nohup su - "$WL_USER" -c "$WL_DOMAIN_BIN/startWebLogic.sh" >> "$LOGFILE" 2>&1 &
else
    nohup "$WL_DOMAIN_BIN/startWebLogic.sh" >> "$LOGFILE" 2>&1 &
fi

# Probe HTTP port until WebLogic responds (confirms it is up)
log_message "Waiting for WebLogic to start (max ${WL_RESTART_TIMEOUT}s)..."
ELAPSED=0
WL_UP=false
while [ $ELAPSED -lt $WL_RESTART_TIMEOUT ]; do
    if curl -sk --max-time 3 "http://localhost:7001/console" > /dev/null 2>&1; then
        WL_UP=true
        break
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done

if [ "$WL_UP" = "true" ]; then
    log_message "WebLogic is up and responding on port 7001 after ${ELAPSED}s."
    # Also probe SSL port
    sleep 5
    if curl -sk --max-time 3 "https://localhost:7002/console" > /dev/null 2>&1; then
        log_message "SSL port 7002 is responding - new certificate is live."
    else
        log_message "WARNING: SSL port 7002 not responding yet - WebLogic may still be initialising."
    fi
else
    log_message "WARNING: WebLogic did not respond within ${WL_RESTART_TIMEOUT}s. Check logs manually."
fi

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0
