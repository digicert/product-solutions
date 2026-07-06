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
LOGFILE="/opt/tlm_agent_3.1.11_linux64/log/dc1_data.log"

# Java Keystore Configuration
# WebLogic uses the SAME keystore as both identity AND trust store.
# The keystore must contain:
#   1. PrivateKeyEntry  - the leaf certificate + private key (under JKS_ALIAS)
#   2. trustedCertEntry - the intermediate CA certificate
#   3. trustedCertEntry - the root CA certificate
# The script imports the leaf cert AND the CA chain automatically from the PFX.
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
log_message "Starting WebLogic cert automation script"
log_message "=========================================="

# Check legal notice acceptance
log_message "Checking legal notice acceptance..."
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    log_message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed."
    exit 1
else
    log_message "Legal notice accepted, proceeding with script execution."
fi

# Log initial configuration
log_message "Configuration:"
log_message "  LOGFILE: $LOGFILE"
log_message "  JKS_PATH: $JKS_PATH"
log_message "  JKS_ALIAS: $JKS_ALIAS"
log_message "  JKS_BACKUP_DIR: $JKS_BACKUP_DIR"
log_message "  KEYTOOL: $KEYTOOL"

# Check DC1_POST_SCRIPT_DATA
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

CERT_INFO=${DC1_POST_SCRIPT_DATA}

# Decode JSON string - strip \r to handle CRLF line endings
JSON_STRING=$(echo "$CERT_INFO" | base64 -d | tr -d '\r')
log_message "JSON_STRING decoded successfully"

# Log JSON with passwords masked
JSON_MASKED=$(echo "$JSON_STRING" \
    | sed 's/"password":"[^"]*"/"password":"***"/g' \
    | sed 's/"keystorepassword":"[^"]*"/"keystorepassword":"***"/g' \
    | sed 's/"truststorepassword":"[^"]*"/"truststorepassword":"***"/g')
log_message "--- DC1_POST_SCRIPT_DATA payload (passwords masked) ---"
log_message "$JSON_MASKED"
log_message "-------------------------------------------------------"

# Extract cert folder
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract files array
FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

# Extract PFX files
PFX_FILES_STRING=$(echo "$FILES_ARRAY" | tr -d '"' | tr -d ' ')
IFS=',' read -ra PFX_FILES_TEMP <<< "$PFX_FILES_STRING"

PFX_FILES=()
for file in "${PFX_FILES_TEMP[@]}"; do
    if [[ "$file" == *.pfx ]] || [[ "$file" == *.p12 ]]; then
        PFX_FILES+=("$file")
    fi
done
log_message "Found ${#PFX_FILES[@]} PFX file(s): ${PFX_FILES[*]}"

# Identify non-legacy PFX
NON_LEGACY_PFX=""
LEGACY_PFX=""
for pfx_file in "${PFX_FILES[@]}"; do
    if [[ "$pfx_file" == *"_legacy"* ]]; then
        LEGACY_PFX="$pfx_file"
    else
        NON_LEGACY_PFX="$pfx_file"
    fi
done
if [ -z "$NON_LEGACY_PFX" ] && [ ${#PFX_FILES[@]} -gt 0 ]; then
    NON_LEGACY_PFX="${PFX_FILES[0]}"
fi
log_message "Non-legacy PFX: $NON_LEGACY_PFX"
log_message "Legacy PFX: $LEGACY_PFX"

# Extract PFX password - strip \r\n
PFX_PASSWORD=$(echo "$JSON_STRING" | grep -oP '"password":"\K[^"]+' | tr -d '\r\n')
if [ -z "$PFX_PASSWORD" ]; then
    log_message "WARNING: No PFX password found in 'password' field"
else
    log_message "PFX password extracted (masked: ${PFX_PASSWORD:0:3}***)"
fi

PFX_FILE_PATH="${CERT_FOLDER}/${NON_LEGACY_PFX}"
log_message "PFX file path: $PFX_FILE_PATH"

# Verify PFX file
if [ ! -f "$PFX_FILE_PATH" ]; then
    log_message "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
fi
log_message "PFX file exists: $PFX_FILE_PATH ($(stat -c%s "$PFX_FILE_PATH") bytes)"

# Inspect PFX with OpenSSL
if command -v openssl &> /dev/null; then
    openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -info -nokeys >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        log_message "Successfully accessed PFX file with provided password"
        CERT_COUNT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | grep -c "BEGIN CERTIFICATE")
        log_message "Total certificates in PFX: $CERT_COUNT"
        CERT_SUBJECT=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)
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
        fi
    else
        log_message "ERROR: Could not access PFX file with provided password"
        exit 1
    fi
else
    log_message "ERROR: OpenSSL not available"
    exit 1
fi

# ========================================
# JAVA KEYSTORE UPDATE SECTION
# ========================================
log_message "=========================================="
log_message "Starting Java Keystore Update Process"
log_message "=========================================="

if [ ! -x "$KEYTOOL" ]; then
    log_message "ERROR: keytool not found at $KEYTOOL"
    exit 1
fi
log_message "keytool is available: $KEYTOOL"

# Create backup directory
if [ ! -d "$JKS_BACKUP_DIR" ]; then
    mkdir -p "$JKS_BACKUP_DIR"
    log_message "Created backup directory: $JKS_BACKUP_DIR"
fi

# Backup existing keystore and detect storetype
if [ -f "$JKS_PATH" ]; then
    BACKUP_FILE="${JKS_BACKUP_DIR}/weblogic_$(date +%Y%m%d_%H%M%S).jks"
    cp "$JKS_PATH" "$BACKUP_FILE"
    if [ $? -eq 0 ]; then
        log_message "Backed up existing keystore to: $BACKUP_FILE"
    else
        log_message "ERROR: Failed to backup existing keystore"
        exit 1
    fi

    DEST_STORETYPE=$($KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>/dev/null \
        | grep -i "Keystore type:" | awk '{print tolower($3)}' | tr -d '[:space:]')
    if [ -z "$DEST_STORETYPE" ]; then
        DEST_STORETYPE="pkcs12"
        log_message "Could not detect destination keystore type, defaulting to: $DEST_STORETYPE"
    else
        log_message "Detected destination keystore type: $DEST_STORETYPE"
    fi
    log_message "Using temp keystore strategy (avoids PKCS12 MAC integrity issues)"
else
    log_message "Keystore does not exist at $JKS_PATH, will be created as PKCS12"
    DEST_STORETYPE="pkcs12"
fi

log_message "Source PFX: $PFX_FILE_PATH"
log_message "Target JKS: $JKS_PATH"
log_message "Alias: $JKS_ALIAS"
log_message "Destination storetype: $DEST_STORETYPE"

# Detect source alias in PFX
SRC_ALIAS=$($KEYTOOL -list \
    -keystore "$PFX_FILE_PATH" \
    -storepass "$PFX_PASSWORD" \
    -storetype pkcs12 2>/dev/null \
    | grep -i "PrivateKeyEntry" | head -1 | cut -d',' -f1 | tr -d '[:space:]')

if [ -z "$SRC_ALIAS" ]; then
    SRC_ALIAS=$($KEYTOOL -list \
        -keystore "$PFX_FILE_PATH" \
        -storepass "$PFX_PASSWORD" \
        -storetype pkcs12 2>/dev/null \
        | grep -v "^Keystore" | grep -v "^Your keystore" | grep -v "^$" \
        | grep -v "^Warning" | grep -v "^Certificate" \
        | grep -v "^keytool" | grep -v "error" \
        | head -1 | cut -d',' -f1 | tr -d '[:space:]')
    [ -n "$SRC_ALIAS" ] && log_message "Got alias from first non-header line: '$SRC_ALIAS'"
fi

if [ -z "$SRC_ALIAS" ]; then
    SRC_ALIAS=$(openssl pkcs12 -in "$PFX_FILE_PATH" -passin pass:"$PFX_PASSWORD" -nokeys 2>/dev/null \
        | grep -i "friendlyName" | head -1 | awk '{print $2}' | tr -d '[:space:]')
    [ -n "$SRC_ALIAS" ] && log_message "Got alias from openssl friendlyName: '$SRC_ALIAS'"
fi

if [ -z "$SRC_ALIAS" ]; then
    log_message "WARNING: Could not determine source alias - will import all entries"
else
    log_message "Found source alias in PFX: '$SRC_ALIAS'"
fi

TEMP_JKS="${JKS_PATH}.tmp_$$"
log_message "Importing into temp keystore: $TEMP_JKS"

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

# Rename alias if needed
if [ -z "$SRC_ALIAS" ]; then
    IMPORTED_ALIAS=$($KEYTOOL -list -keystore "$TEMP_JKS" -storepass "$JKS_PASSWORD" \
        -storetype "$DEST_STORETYPE" 2>/dev/null \
        | grep -i "PrivateKeyEntry" | head -1 | cut -d',' -f1 | tr -d '[:space:]')
    if [ -n "$IMPORTED_ALIAS" ] && [ "$IMPORTED_ALIAS" != "$JKS_ALIAS" ]; then
        log_message "Renaming imported alias '$IMPORTED_ALIAS' to '$JKS_ALIAS'..."
        $KEYTOOL -changealias -keystore "$TEMP_JKS" -storepass "$JKS_PASSWORD" \
            -alias "$IMPORTED_ALIAS" -destalias "$JKS_ALIAS" 2>&1 | tee -a "$LOGFILE"
    fi
fi

# =====================================================
# FIX: Import CA chain certificates as trusted entries
#
# WebLogic uses the SAME keystore as both identity store
# (private key + leaf cert) and trust store (CA certs).
# Without the CA chain in the keystore WebLogic logs:
#   "No trusted certificates have been loaded"
# and SSL on port 7002 fails to start.
#
# We extract ALL CA certificates from the PFX and import
# them as trustedCertEntry entries in the keystore.
# =====================================================
log_message "=========================================="
log_message "Importing CA chain certificates as trusted entries"
log_message "=========================================="

# Extract all CA certs from PFX into a temp bundle
CA_BUNDLE="/tmp/ca_bundle_$$.pem"
openssl pkcs12 \
    -in "$PFX_FILE_PATH" \
    -passin pass:"$PFX_PASSWORD" \
    -nokeys -cacerts 2>/dev/null > "$CA_BUNDLE"

if [ ! -s "$CA_BUNDLE" ]; then
    log_message "WARNING: No CA certificates found in PFX - trying -chain flag..."
    openssl pkcs12 \
        -in "$PFX_FILE_PATH" \
        -passin pass:"$PFX_PASSWORD" \
        -nokeys 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/{c++} c>1{print}' > "$CA_BUNDLE"
fi

if [ -s "$CA_BUNDLE" ]; then
    # Split the bundle into individual cert files and import each
    CA_COUNT=0
    CERT_NUM=0
    while IFS= read -r line; do
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
            CERT_NUM=$((CERT_NUM + 1))
            CERT_FILE="/tmp/ca_cert_${$}_${CERT_NUM}.pem"
            echo "$line" > "$CERT_FILE"
        elif [[ "$line" == "-----END CERTIFICATE-----" ]]; then
            echo "$line" >> "$CERT_FILE"

            # Get subject to use as alias
            CERT_SUBJECT=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null \
                | sed 's/.*CN\s*=\s*//;s/,.*//' | tr -d ' ' | tr '[:upper:]' '[:lower:]' \
                | sed 's/[^a-z0-9]/-/g' | cut -c1-50)
            CA_ALIAS="ca-${CERT_NUM}-${CERT_SUBJECT}"
            [ -z "$CERT_SUBJECT" ] && CA_ALIAS="ca-cert-${CERT_NUM}"

            log_message "Importing CA cert $CERT_NUM (alias: $CA_ALIAS)..."
            $KEYTOOL -importcert -noprompt \
                -keystore  "$TEMP_JKS" \
                -storepass "$JKS_PASSWORD" \
                -alias     "$CA_ALIAS" \
                -file      "$CERT_FILE" 2>&1 | tee -a "$LOGFILE"

            if [ ${PIPESTATUS[0]} -eq 0 ]; then
                log_message "CA cert $CERT_NUM imported successfully as '$CA_ALIAS'"
                CA_COUNT=$((CA_COUNT + 1))
            else
                log_message "WARNING: Failed to import CA cert $CERT_NUM"
            fi
            rm -f "$CERT_FILE"
        elif [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
            echo "$line" >> "$CERT_FILE"
        fi
    done < "$CA_BUNDLE"

    log_message "CA chain import complete: $CA_COUNT certificate(s) added as trusted entries"
else
    log_message "WARNING: Could not extract CA certificates from PFX - trust store will be empty"
    log_message "WebLogic may fail to start SSL if no trusted CAs are present"
fi

rm -f "$CA_BUNDLE"

# Atomically replace destination keystore with temp
mv -f "$TEMP_JKS" "$JKS_PATH"
if [ $? -eq 0 ]; then
    log_message "SUCCESS: Keystore updated at $JKS_PATH"
else
    log_message "ERROR: Could not replace $JKS_PATH"
    rm -f "$TEMP_JKS"
    exit 1
fi

# Verify final keystore
log_message "=========================================="
log_message "Verifying final keystore contents"
log_message "=========================================="
$KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 | tee -a "$LOGFILE"

$KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" >/dev/null 2>&1
if [ $? -eq 0 ]; then
    log_message "SUCCESS: Certificate alias '$JKS_ALIAS' verified in keystore"
    $KEYTOOL -list -v -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" -alias "$JKS_ALIAS" 2>&1 \
        | grep -E "Owner:|Issuer:|Valid from:|SHA256:" | tee -a "$LOGFILE"
else
    log_message "WARNING: Alias '$JKS_ALIAS' not found - checking all entries..."
    $KEYTOOL -list -keystore "$JKS_PATH" -storepass "$JKS_PASSWORD" 2>&1 | grep "Entry" | tee -a "$LOGFILE"
fi

log_message "Keystore: $JKS_PATH"
log_message "Source PFX: $NON_LEGACY_PFX"
[ -n "$BACKUP_FILE" ] && log_message "Backup saved to: $BACKUP_FILE"

# ========================================
# WEBLOGIC RESTART
# ========================================
log_message "=========================================="
log_message "Restarting WebLogic to load new certificate"
log_message "=========================================="

log_message "Stopping WebLogic..."
if [ "$(id -u)" -eq 0 ]; then
    su - "$WL_USER" -c "$WL_DOMAIN_BIN/stopWebLogic.sh" >> "$LOGFILE" 2>&1
else
    "$WL_DOMAIN_BIN/stopWebLogic.sh" >> "$LOGFILE" 2>&1
fi

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

if [ "$(id -u)" -eq 0 ]; then
    chown -R "$WL_USER":"$WL_USER" "$(dirname $JKS_PATH)" 2>/dev/null
fi

log_message "Starting WebLogic..."
if [ "$(id -u)" -eq 0 ]; then
    nohup su - "$WL_USER" -c "$WL_DOMAIN_BIN/startWebLogic.sh" >> "$LOGFILE" 2>&1 &
else
    nohup "$WL_DOMAIN_BIN/startWebLogic.sh" >> "$LOGFILE" 2>&1 &
fi

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
    log_message "WebLogic is up on port 7001 after ${ELAPSED}s."
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
