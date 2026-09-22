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
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/pqc-demo-logfile.log"

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

# Extract Argument_6 - sixth argument
ARGUMENT_6=$(echo "$ARGS_ARRAY" | awk -F',' '{print $6}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_6 extracted: '$ARGUMENT_6'"
log_message "ARGUMENT_6 length: ${#ARGUMENT_6}"

# Extract Argument_7 - seventh argument
ARGUMENT_7=$(echo "$ARGS_ARRAY" | awk -F',' '{print $7}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_7 extracted: '$ARGUMENT_7'"
log_message "ARGUMENT_7 length: ${#ARGUMENT_7}"

# Extract Argument_8 - eighth argument
ARGUMENT_8=$(echo "$ARGS_ARRAY" | awk -F',' '{print $8}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_8 extracted: '$ARGUMENT_8'"
log_message "ARGUMENT_8 length: ${#ARGUMENT_8}"

# Extract Argument_9 - ninth argument
ARGUMENT_9=$(echo "$ARGS_ARRAY" | awk -F',' '{print $9}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_9 extracted: '$ARGUMENT_9'"
log_message "ARGUMENT_9 length: ${#ARGUMENT_9}"

# Extract Argument_10 - tenth argument
ARGUMENT_10=$(echo "$ARGS_ARRAY" | awk -F',' '{print $10}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_10 extracted: '$ARGUMENT_10'"
log_message "ARGUMENT_10 length: ${#ARGUMENT_10}"

# Extract Argument_11 - eleventh argument
ARGUMENT_11=$(echo "$ARGS_ARRAY" | awk -F',' '{print $11}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_11 extracted: '$ARGUMENT_11'"
log_message "ARGUMENT_11 length: ${#ARGUMENT_11}"

# Extract Argument_12 - twelfth argument
ARGUMENT_12=$(echo "$ARGS_ARRAY" | awk -F',' '{print $12}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_12 extracted: '$ARGUMENT_12'"
log_message "ARGUMENT_12 length: ${#ARGUMENT_12}"

# Extract Argument_13 - thirteenth argument
ARGUMENT_13=$(echo "$ARGS_ARRAY" | awk -F',' '{print $13}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_13 extracted: '$ARGUMENT_13'"
log_message "ARGUMENT_13 length: ${#ARGUMENT_13}"

# Extract Argument_14 - fourteenth argument
ARGUMENT_14=$(echo "$ARGS_ARRAY" | awk -F',' '{print $14}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_14 extracted: '$ARGUMENT_14'"
log_message "ARGUMENT_14 length: ${#ARGUMENT_14}"

# Extract Argument_15 - fifteenth argument
ARGUMENT_15=$(echo "$ARGS_ARRAY" | awk -F',' '{print $15}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_15 extracted: '$ARGUMENT_15'"
log_message "ARGUMENT_15 length: ${#ARGUMENT_15}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')
ARGUMENT_6=$(echo "$ARGUMENT_6" | tr -d '[:space:]')
ARGUMENT_7=$(echo "$ARGUMENT_7" | tr -d '[:space:]')
ARGUMENT_8=$(echo "$ARGUMENT_8" | tr -d '[:space:]')
ARGUMENT_9=$(echo "$ARGUMENT_9" | tr -d '[:space:]')
ARGUMENT_10=$(echo "$ARGUMENT_10" | tr -d '[:space:]')
ARGUMENT_11=$(echo "$ARGUMENT_11" | tr -d '[:space:]')
ARGUMENT_12=$(echo "$ARGUMENT_12" | tr -d '[:space:]')
ARGUMENT_13=$(echo "$ARGUMENT_13" | tr -d '[:space:]')
ARGUMENT_14=$(echo "$ARGUMENT_14" | tr -d '[:space:]')
ARGUMENT_15=$(echo "$ARGUMENT_15" | tr -d '[:space:]')

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
log_message "  Argument 6: $ARGUMENT_6"
log_message "  Argument 7: $ARGUMENT_7"
log_message "  Argument 8: $ARGUMENT_8"
log_message "  Argument 9: $ARGUMENT_9"
log_message "  Argument 10: $ARGUMENT_10"
log_message "  Argument 11: $ARGUMENT_11"
log_message "  Argument 12: $ARGUMENT_12"
log_message "  Argument 13: $ARGUMENT_13"
log_message "  Argument 14: $ARGUMENT_14"
log_message "  Argument 15: $ARGUMENT_15"
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
# Argument variables (from JSON args array, up to 15):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
#   $ARGUMENT_6       - Sixth argument from args array
#   $ARGUMENT_7       - Seventh argument from args array
#   $ARGUMENT_8       - Eighth argument from args array
#   $ARGUMENT_9       - Ninth argument from args array
#   $ARGUMENT_10      - Tenth argument from args array
#   $ARGUMENT_11      - Eleventh argument from args array
#   $ARGUMENT_12      - Twelfth argument from args array
#   $ARGUMENT_13      - Thirteenth argument from args array
#   $ARGUMENT_14      - Fourteenth argument from args array
#   $ARGUMENT_15      - Fifteenth argument from args array
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
#
# PURPOSE: deploy the TLM-issued (PQC/ML-DSA) certificate + key onto the Apache
#          PQC vhost, then gracefully reload so the new cert is served live.
#
# BEHAVIOUR: certificates are OVERWRITTEN in place. No backup is taken.
#
# OPTIONAL ARGUMENT OVERRIDES (from the AWR "args" array, all optional):
#   ARGUMENT_1 = deploy cert path   (SSLCertificateFile the vhost points at)
#   ARGUMENT_2 = deploy key  path   (SSLCertificateKeyFile the vhost points at)
#   ARGUMENT_3 = PQC vhost port     (for the post-deploy health probe)
# If an argument is empty, the corresponding default below is used.

# ---- PQC vhost deployment configuration (defaults) ----
APACHE_PREFIX="/opt/httpd-pqc"
APACHECTL="${APACHE_PREFIX}/bin/apachectl"
HTTPD_BIN="${APACHE_PREFIX}/bin/httpd"
PQC_OPENSSL="/opt/openssl-pqc/bin/openssl"       # PQC-capable OpenSSL (NOT the system one)

DEPLOY_CRT="${ARGUMENT_1:-${APACHE_PREFIX}/conf/tlm-pqc.crt}"   # vhost SSLCertificateFile MUST point here
DEPLOY_KEY="${ARGUMENT_2:-${APACHE_PREFIX}/conf/tlm-pqc.key}"   # vhost SSLCertificateKeyFile MUST point here
PQC_VHOST_PORT="${ARGUMENT_3:-443}"                            # port the PQC vhost listens on

log_message "PQC deploy: CRT->$DEPLOY_CRT  KEY->$DEPLOY_KEY  port=$PQC_VHOST_PORT  openssl=$PQC_OPENSSL"

# 0. Tooling / source sanity ------------------------------------------------
if [ ! -x "$PQC_OPENSSL" ]; then
    log_message "ERROR: PQC-capable OpenSSL not found/executable at $PQC_OPENSSL"
    exit 1
fi
if [ ! -f "$CRT_FILE_PATH" ] || [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: issued cert/key not found ($CRT_FILE_PATH / $KEY_FILE_PATH)"
    exit 1
fi

# 1. Validate the issued certificate parses, and log its algorithm ----------
if ! "$PQC_OPENSSL" x509 -in "$CRT_FILE_PATH" -noout >/dev/null 2>>"$LOGFILE"; then
    log_message "ERROR: certificate failed to parse with $PQC_OPENSSL. Aborting (server unchanged)."
    exit 1
fi
SIG_ALGO=$("$PQC_OPENSSL" x509 -in "$CRT_FILE_PATH" -noout -text 2>/dev/null \
           | grep -m1 -i "Signature Algorithm" | sed 's/.*: *//')
CERT_SUBJECT=$("$PQC_OPENSSL" x509 -in "$CRT_FILE_PATH" -noout -subject 2>/dev/null | sed -E 's/^subject=? *//')
log_message "Issued cert subject          : $CERT_SUBJECT"
log_message "Issued cert signature algo   : $SIG_ALGO"

# 2. Validate the private key parses ----------------------------------------
if ! "$PQC_OPENSSL" pkey -in "$KEY_FILE_PATH" -noout >/dev/null 2>>"$LOGFILE"; then
    log_message "ERROR: private key failed to parse with $PQC_OPENSSL."
    log_message "       If this is an ML-DSA key, verify the FIPS 204 private-key encoding"
    log_message "       (seed-only vs expanded) is one this OpenSSL build accepts. Aborting."
    exit 1
fi

# 3. Confirm the key matches the certificate (algorithm-agnostic) -----------
#    ML-DSA has no modulus to compare, so compare the derived public keys.
CRT_PUB_FP=$("$PQC_OPENSSL" x509 -in "$CRT_FILE_PATH" -noout -pubkey 2>/dev/null | "$PQC_OPENSSL" sha256 2>/dev/null)
KEY_PUB_FP=$("$PQC_OPENSSL" pkey  -in "$KEY_FILE_PATH" -pubout   2>/dev/null | "$PQC_OPENSSL" sha256 2>/dev/null)
if [ -z "$CRT_PUB_FP" ] || [ "$CRT_PUB_FP" != "$KEY_PUB_FP" ]; then
    log_message "ERROR: private key does NOT match certificate (public keys differ). Aborting deploy."
    exit 1
fi
log_message "GUARD: key matches certificate (public keys identical)."

# 4. Deploy (overwrite in place; NO backup, per requirement) ----------------
if ! cp -f "$CRT_FILE_PATH" "$DEPLOY_CRT"; then
    log_message "ERROR: failed to write $DEPLOY_CRT (check permissions / path)"
    exit 1
fi
if ! cp -f "$KEY_FILE_PATH" "$DEPLOY_KEY"; then
    log_message "ERROR: failed to write $DEPLOY_KEY (check permissions / path)"
    exit 1
fi
chmod 600 "$DEPLOY_KEY" 2>/dev/null
chmod 644 "$DEPLOY_CRT" 2>/dev/null
DEPLOYED_CHAIN_COUNT=$(grep -c "BEGIN CERTIFICATE" "$DEPLOY_CRT")
log_message "Deployed cert -> $DEPLOY_CRT (certs in file: $DEPLOYED_CHAIN_COUNT), key -> $DEPLOY_KEY. Overwritten, no backup."
# NOTE: if TLM emits the issuing chain as a SEPARATE file, concatenate it into
#       $DEPLOY_CRT (leaf first) so Apache serves the full chain, e.g.:
#          cat "$CRT_FILE_PATH" "$CERT_FOLDER/chain.pem" > "$DEPLOY_CRT"

# 5. Validate Apache config BEFORE reloading --------------------------------
#    The running server keeps its currently-loaded cert until a reload, so a
#    failed configtest here leaves the live service untouched.
if ! "$APACHECTL" configtest >>"$LOGFILE" 2>&1; then
    log_message "ERROR: 'apachectl configtest' failed after deploy. NOT reloading; live server unaffected."
    exit 1
fi
log_message "apachectl configtest: Syntax OK"

# 6. Reload (graceful = no dropped connections; re-reads certs) -------------
if pgrep -f "$HTTPD_BIN" >/dev/null 2>&1; then
    if ! "$APACHECTL" -k graceful >>"$LOGFILE" 2>&1; then
        log_message "ERROR: graceful reload failed. Check $APACHE_PREFIX/logs/error_log"
        exit 1
    fi
    log_message "Apache gracefully reloaded."
else
    if ! "$APACHECTL" -k start >>"$LOGFILE" 2>&1; then
        log_message "ERROR: Apache was not running and failed to start. Check error_log."
        exit 1
    fi
    log_message "Apache was not running; started."
fi
sleep 1

# 7. Health probe: confirm the vhost is actually serving the new cert -------
PQC_SNI=$("$PQC_OPENSSL" x509 -in "$DEPLOY_CRT" -noout -subject 2>/dev/null | sed -E 's/.*CN *= *//; s/[,/].*//')
[ -z "$PQC_SNI" ] && PQC_SNI="localhost"
DEPLOYED_FP=$("$PQC_OPENSSL" x509 -in "$DEPLOY_CRT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
SERVED_FP=$(echo | "$PQC_OPENSSL" s_client -connect "127.0.0.1:${PQC_VHOST_PORT}" -servername "$PQC_SNI" 2>/dev/null \
            | "$PQC_OPENSSL" x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
log_message "Health probe: SNI=$PQC_SNI  deployed_fp=$DEPLOYED_FP  served_fp=$SERVED_FP"
if [ -n "$SERVED_FP" ] && [ "$SERVED_FP" = "$DEPLOYED_FP" ]; then
    log_message "SUCCESS: PQC vhost on :$PQC_VHOST_PORT is serving the newly issued certificate ($SIG_ALGO)."
else
    log_message "WARNING: served cert fingerprint does not match deployed cert."
    log_message "         Confirm the vhost SSLCertificateFile points at $DEPLOY_CRT and it listens on :$PQC_VHOST_PORT."
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