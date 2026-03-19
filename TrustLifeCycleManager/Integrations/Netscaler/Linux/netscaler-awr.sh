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
# DigiCert TLM AWR Post-Enrollment Script - Citrix NetScaler ADC
# ============================================================================
#
# This script uploads and installs TLS certificates on a Citrix NetScaler
# (ADC) appliance via the Nitro REST API. It supports both initial
# certificate creation and subsequent renewals/updates.
#
# AWR Arguments:
#   Argument 1: NetScaler hostname/IP (excluding https:// and path)
#   Argument 2: Nitro API username
#   Argument 3: Nitro API password
#   Argument 4: SSL cert-key pair name on the ADC
#
# Behaviour:
#   - Uploads the certificate and key files to /nsconfig/ssl/ on the ADC
#     with a timestamp in the filename for auditability
#   - If the named cert-key pair already exists: updates it in place
#     (preserving all vserver bindings)
#   - If the named cert-key pair does not exist: creates a new one
#   - Saves the running configuration after changes
#
# ============================================================================

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/netscaler/netscaler-adc.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to obfuscate sensitive values in logs
obfuscate() {
    local VALUE="$1"
    local LENGTH=${#VALUE}
    if [ "$LENGTH" -le 4 ]; then
        echo "****"
    else
        echo "${VALUE:0:2}$(printf '*%.0s' $(seq 1 $((LENGTH - 4))))${VALUE:$((LENGTH - 2)):2}"
    fi
}

# Start logging
log_message "=========================================="
log_message "Starting DigiCert TLM AWR Post-Script"
log_message "Target Platform: Citrix NetScaler ADC (Nitro API)"
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

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# Extract the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')

# Extract Argument_1 - NetScaler hostname/IP
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 (NetScaler Host) extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - Nitro API username
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 (Username) extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - Nitro API password
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 (Password) extracted: '$(obfuscate "$ARGUMENT_3")'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - SSL cert-key pair name
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 (CertKey Name) extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - reserved for future use
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 (Reserved) extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

# Assign meaningful variable names
NETSCALER_HOST="$ARGUMENT_1"
NITRO_USER="$ARGUMENT_2"
NITRO_PASS="$ARGUMENT_3"
CERTKEY_NAME="$ARGUMENT_4"
NITRO_BASE_URL="https://${NETSCALER_HOST}/nitro/v1/config"

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
log_message "  NetScaler Host:  $NETSCALER_HOST"
log_message "  Nitro Username:  $NITRO_USER"
log_message "  Nitro Password:  $(obfuscate "$NITRO_PASS")"
log_message "  CertKey Name:    $CERTKEY_NAME"
log_message "  Nitro Base URL:  $NITRO_BASE_URL"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file:   $CRT_FILE"
log_message "  Private key file:   $KEY_FILE"
log_message "  Certificate path:   $CRT_FILE_PATH"
log_message "  Private key path:   $KEY_FILE_PATH"
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
# NETSCALER ADC INTEGRATION - NITRO REST API
# ============================================================================

log_message "=========================================="
log_message "Starting NetScaler ADC integration via Nitro API..."
log_message "=========================================="

# ---- Validate required arguments ----
log_message "Validating required arguments..."
VALIDATION_FAILED=false

if [ -z "$NETSCALER_HOST" ]; then
    log_message "ERROR: Argument 1 (NetScaler Host) is empty"
    VALIDATION_FAILED=true
fi
if [ -z "$NITRO_USER" ]; then
    log_message "ERROR: Argument 2 (Username) is empty"
    VALIDATION_FAILED=true
fi
if [ -z "$NITRO_PASS" ]; then
    log_message "ERROR: Argument 3 (Password) is empty"
    VALIDATION_FAILED=true
fi
if [ -z "$CERTKEY_NAME" ]; then
    log_message "ERROR: Argument 4 (CertKey Name) is empty"
    VALIDATION_FAILED=true
fi

if [ "$VALIDATION_FAILED" = true ]; then
    log_message "ERROR: One or more required arguments are missing. Aborting."
    log_message "  Required: Argument 1 (host), Argument 2 (user), Argument 3 (pass), Argument 4 (certkey name)"
    exit 1
fi
log_message "All required arguments validated successfully."

# ---- Generate timestamped filenames for auditability ----
TIMESTAMP=$(date '+%Y%m%d%H%M%S')
UPLOAD_CRT_FILENAME="${CERTKEY_NAME}-${TIMESTAMP}.crt"
UPLOAD_KEY_FILENAME="${CERTKEY_NAME}-${TIMESTAMP}.key"
ADC_SSL_LOCATION="/nsconfig/ssl"

log_message "Generated timestamped filenames for ADC upload:"
log_message "  Certificate: ${UPLOAD_CRT_FILENAME}"
log_message "  Private Key: ${UPLOAD_KEY_FILENAME}"

# ---- Base64 encode the certificate and key for Nitro systemfile upload ----
log_message "Base64-encoding certificate file for upload..."
CERT_B64=$(base64 -w 0 "$CRT_FILE_PATH")
if [ -z "$CERT_B64" ]; then
    log_message "ERROR: Failed to base64-encode certificate file"
    exit 1
fi
log_message "Certificate base64-encoded successfully (length: ${#CERT_B64} characters)"

log_message "Base64-encoding private key file for upload..."
KEY_B64=$(base64 -w 0 "$KEY_FILE_PATH")
if [ -z "$KEY_B64" ]; then
    log_message "ERROR: Failed to base64-encode private key file"
    exit 1
fi
log_message "Private key base64-encoded successfully (length: ${#KEY_B64} characters)"

# ---- Test connectivity to the NetScaler ----
log_message "Testing connectivity to NetScaler at ${NETSCALER_HOST}..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "X-NITRO-USER: ${NITRO_USER}" \
    -H "X-NITRO-PASS: ${NITRO_PASS}" \
    "${NITRO_BASE_URL}/nsconfig")

if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
    log_message "Connectivity test successful (HTTP ${HTTP_CODE})"
elif [ "$HTTP_CODE" -eq 401 ]; then
    log_message "ERROR: Authentication failed (HTTP 401). Check username and password."
    exit 1
else
    log_message "ERROR: Connectivity test failed (HTTP ${HTTP_CODE}). Check host and network."
    exit 1
fi

# ---- Step 1: Upload the certificate file to the ADC filesystem ----
log_message "------------------------------------------"
log_message "Step 1: Uploading certificate file to ADC filesystem"
log_message "  Target: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
log_message "------------------------------------------"

UPLOAD_CRT_PAYLOAD=$(cat <<EOF
{
    "systemfile": {
        "filename": "${UPLOAD_CRT_FILENAME}",
        "filelocation": "${ADC_SSL_LOCATION}",
        "filecontent": "${CERT_B64}",
        "fileencoding": "BASE64"
    }
}
EOF
)

UPLOAD_CRT_RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-NITRO-USER: ${NITRO_USER}" \
    -H "X-NITRO-PASS: ${NITRO_PASS}" \
    "${NITRO_BASE_URL}/systemfile" \
    -d "${UPLOAD_CRT_PAYLOAD}")

UPLOAD_CRT_HTTP_CODE=$(echo "$UPLOAD_CRT_RESPONSE" | tail -1)
UPLOAD_CRT_BODY=$(echo "$UPLOAD_CRT_RESPONSE" | sed '$d')
UPLOAD_CRT_ERROR=$(echo "$UPLOAD_CRT_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

log_message "Certificate upload response (HTTP ${UPLOAD_CRT_HTTP_CODE}): ${UPLOAD_CRT_BODY}"

if [ "$UPLOAD_CRT_ERROR" != "0" ] && [ -n "$UPLOAD_CRT_ERROR" ]; then
    log_message "ERROR: Certificate file upload failed (errorcode: ${UPLOAD_CRT_ERROR})"
    log_message "Response: ${UPLOAD_CRT_BODY}"
    exit 1
fi
log_message "Certificate file uploaded successfully to ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"

# ---- Step 2: Upload the private key file to the ADC filesystem ----
log_message "------------------------------------------"
log_message "Step 2: Uploading private key file to ADC filesystem"
log_message "  Target: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
log_message "------------------------------------------"

UPLOAD_KEY_PAYLOAD=$(cat <<EOF
{
    "systemfile": {
        "filename": "${UPLOAD_KEY_FILENAME}",
        "filelocation": "${ADC_SSL_LOCATION}",
        "filecontent": "${KEY_B64}",
        "fileencoding": "BASE64"
    }
}
EOF
)

UPLOAD_KEY_RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-NITRO-USER: ${NITRO_USER}" \
    -H "X-NITRO-PASS: ${NITRO_PASS}" \
    "${NITRO_BASE_URL}/systemfile" \
    -d "${UPLOAD_KEY_PAYLOAD}")

UPLOAD_KEY_HTTP_CODE=$(echo "$UPLOAD_KEY_RESPONSE" | tail -1)
UPLOAD_KEY_BODY=$(echo "$UPLOAD_KEY_RESPONSE" | sed '$d')
UPLOAD_KEY_ERROR=$(echo "$UPLOAD_KEY_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

log_message "Private key upload response (HTTP ${UPLOAD_KEY_HTTP_CODE}): ${UPLOAD_KEY_BODY}"

if [ "$UPLOAD_KEY_ERROR" != "0" ] && [ -n "$UPLOAD_KEY_ERROR" ]; then
    log_message "ERROR: Private key file upload failed (errorcode: ${UPLOAD_KEY_ERROR})"
    log_message "Response: ${UPLOAD_KEY_BODY}"
    exit 1
fi
log_message "Private key file uploaded successfully to ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"

# ---- Step 3: Check if the cert-key pair already exists on the ADC ----
log_message "------------------------------------------"
log_message "Step 3: Checking if cert-key pair '${CERTKEY_NAME}' already exists on the ADC"
log_message "------------------------------------------"

CERTKEY_CHECK_RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X GET \
    -H "X-NITRO-USER: ${NITRO_USER}" \
    -H "X-NITRO-PASS: ${NITRO_PASS}" \
    "${NITRO_BASE_URL}/sslcertkey/${CERTKEY_NAME}")

CERTKEY_CHECK_HTTP_CODE=$(echo "$CERTKEY_CHECK_RESPONSE" | tail -1)
CERTKEY_CHECK_BODY=$(echo "$CERTKEY_CHECK_RESPONSE" | sed '$d')
CERTKEY_CHECK_ERROR=$(echo "$CERTKEY_CHECK_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

log_message "Cert-key pair lookup response (HTTP ${CERTKEY_CHECK_HTTP_CODE}): ${CERTKEY_CHECK_BODY}"

CERTKEY_EXISTS=false
if [ "$CERTKEY_CHECK_ERROR" = "0" ]; then
    CERTKEY_EXISTS=true
    log_message "Cert-key pair '${CERTKEY_NAME}' EXISTS on the ADC - will perform UPDATE"
    log_message "  (All existing vserver bindings will be preserved)"
else
    log_message "Cert-key pair '${CERTKEY_NAME}' does NOT exist on the ADC - will perform CREATE"
fi

# ---- Step 4: Create or Update the cert-key pair ----
log_message "------------------------------------------"
log_message "Step 4: Installing certificate on the ADC"
log_message "------------------------------------------"

if [ "$CERTKEY_EXISTS" = true ]; then
    # -----------------------------------------------------------
    # UPDATE existing cert-key pair
    # Using POST with ?action=update which is the supported method
    # for updating SSL cert-key pairs on NetScaler 14.1+
    # nodomaincheck=true allows updating even if CN/SAN differs
    # -----------------------------------------------------------
    log_message "Performing UPDATE on existing cert-key pair '${CERTKEY_NAME}'..."
    log_message "  New certificate file: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
    log_message "  New private key file: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
    log_message "  nodomaincheck: true (allows CN/SAN changes during renewal)"

    # Try POST with ?action=update first (preferred method for 14.1+)
    log_message "Attempting update via POST ?action=update..."

    UPDATE_PAYLOAD=$(cat <<EOF
{
    "sslcertkey": {
        "certkey": "${CERTKEY_NAME}",
        "cert": "${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}",
        "key": "${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}",
        "nodomaincheck": true
    }
}
EOF
    )

    UPDATE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: ${NITRO_USER}" \
        -H "X-NITRO-PASS: ${NITRO_PASS}" \
        "${NITRO_BASE_URL}/sslcertkey?action=update" \
        -d "${UPDATE_PAYLOAD}")

    UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -1)
    UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')
    UPDATE_ERROR=$(echo "$UPDATE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

    log_message "Update (POST ?action=update) response (HTTP ${UPDATE_HTTP_CODE}): ${UPDATE_BODY}"

    if [ "$UPDATE_ERROR" != "0" ] && [ -n "$UPDATE_ERROR" ]; then
        # Fallback: try PUT method (used on some older Nitro versions)
        log_message "WARNING: POST ?action=update failed (errorcode: ${UPDATE_ERROR}). Trying PUT method as fallback..."

        UPDATE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
            -X PUT \
            -H "Content-Type: application/json" \
            -H "X-NITRO-USER: ${NITRO_USER}" \
            -H "X-NITRO-PASS: ${NITRO_PASS}" \
            "${NITRO_BASE_URL}/sslcertkey" \
            -d "${UPDATE_PAYLOAD}")

        UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -1)
        UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')
        UPDATE_ERROR=$(echo "$UPDATE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

        log_message "Update (PUT) response (HTTP ${UPDATE_HTTP_CODE}): ${UPDATE_BODY}"

        if [ "$UPDATE_ERROR" != "0" ] && [ -n "$UPDATE_ERROR" ]; then
            # Fallback: try with filename only (no path prefix)
            log_message "WARNING: PUT with full path failed (errorcode: ${UPDATE_ERROR}). Trying with filename only..."

            UPDATE_PAYLOAD_SHORT=$(cat <<EOF
{
    "sslcertkey": {
        "certkey": "${CERTKEY_NAME}",
        "cert": "${UPLOAD_CRT_FILENAME}",
        "key": "${UPLOAD_KEY_FILENAME}",
        "nodomaincheck": true
    }
}
EOF
            )

            UPDATE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
                -X POST \
                -H "Content-Type: application/json" \
                -H "X-NITRO-USER: ${NITRO_USER}" \
                -H "X-NITRO-PASS: ${NITRO_PASS}" \
                "${NITRO_BASE_URL}/sslcertkey?action=update" \
                -d "${UPDATE_PAYLOAD_SHORT}")

            UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -1)
            UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')
            UPDATE_ERROR=$(echo "$UPDATE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

            log_message "Update (POST ?action=update, filename only) response (HTTP ${UPDATE_HTTP_CODE}): ${UPDATE_BODY}"

            if [ "$UPDATE_ERROR" != "0" ] && [ -n "$UPDATE_ERROR" ]; then
                # Final fallback: PUT with filename only
                log_message "WARNING: POST with filename only failed. Trying PUT with filename only..."

                UPDATE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
                    -X PUT \
                    -H "Content-Type: application/json" \
                    -H "X-NITRO-USER: ${NITRO_USER}" \
                    -H "X-NITRO-PASS: ${NITRO_PASS}" \
                    "${NITRO_BASE_URL}/sslcertkey" \
                    -d "${UPDATE_PAYLOAD_SHORT}")

                UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -1)
                UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')
                UPDATE_ERROR=$(echo "$UPDATE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

                log_message "Update (PUT, filename only) response (HTTP ${UPDATE_HTTP_CODE}): ${UPDATE_BODY}"

                if [ "$UPDATE_ERROR" != "0" ] && [ -n "$UPDATE_ERROR" ]; then
                    log_message "ERROR: All update methods failed for cert-key pair '${CERTKEY_NAME}'"
                    log_message "  Last errorcode: ${UPDATE_ERROR}"
                    log_message "  Last response: ${UPDATE_BODY}"
                    exit 1
                fi
            fi
        fi
    fi

    log_message "SUCCESS: Cert-key pair '${CERTKEY_NAME}' updated successfully"
    log_message "  All existing vserver bindings remain intact"

else
    # -----------------------------------------------------------
    # CREATE new cert-key pair
    # Using POST on /sslcertkey to create a brand new pair
    # -----------------------------------------------------------
    log_message "Performing CREATE of new cert-key pair '${CERTKEY_NAME}'..."
    log_message "  Certificate file: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
    log_message "  Private key file: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"

    CREATE_PAYLOAD=$(cat <<EOF
{
    "sslcertkey": {
        "certkey": "${CERTKEY_NAME}",
        "cert": "${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}",
        "key": "${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}",
        "inform": "PEM"
    }
}
EOF
    )

    CREATE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -H "X-NITRO-USER: ${NITRO_USER}" \
        -H "X-NITRO-PASS: ${NITRO_PASS}" \
        "${NITRO_BASE_URL}/sslcertkey" \
        -d "${CREATE_PAYLOAD}")

    CREATE_HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -1)
    CREATE_BODY=$(echo "$CREATE_RESPONSE" | sed '$d')
    CREATE_ERROR=$(echo "$CREATE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

    log_message "Create response (HTTP ${CREATE_HTTP_CODE}): ${CREATE_BODY}"

    if [ "$CREATE_ERROR" != "0" ] && [ -n "$CREATE_ERROR" ]; then
        log_message "ERROR: Failed to create cert-key pair '${CERTKEY_NAME}' (errorcode: ${CREATE_ERROR})"
        log_message "Response: ${CREATE_BODY}"
        exit 1
    fi

    log_message "SUCCESS: Cert-key pair '${CERTKEY_NAME}' created successfully"
    log_message "  NOTE: The new cert-key pair is not yet bound to any vserver."
    log_message "  Bind it manually or via automation using the sslvserver_sslcertkey_binding endpoint."
fi

# ---- Step 5: Save the NetScaler configuration ----
log_message "------------------------------------------"
log_message "Step 5: Saving NetScaler running configuration"
log_message "  (Persisting changes across reboot)"
log_message "------------------------------------------"

SAVE_RESPONSE=$(curl -sk -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-NITRO-USER: ${NITRO_USER}" \
    -H "X-NITRO-PASS: ${NITRO_PASS}" \
    "${NITRO_BASE_URL}/nsconfig?action=save" \
    -d '{"nsconfig": {}}')

SAVE_HTTP_CODE=$(echo "$SAVE_RESPONSE" | tail -1)
SAVE_BODY=$(echo "$SAVE_RESPONSE" | sed '$d')
SAVE_ERROR=$(echo "$SAVE_BODY" | grep -oP '"errorcode":\s*\K[0-9]+')

log_message "Save config response (HTTP ${SAVE_HTTP_CODE}): ${SAVE_BODY}"

if [ "$SAVE_ERROR" != "0" ] && [ -n "$SAVE_ERROR" ]; then
    log_message "WARNING: Failed to save configuration (errorcode: ${SAVE_ERROR})"
    log_message "  The certificate changes are active but may not persist across reboot"
    log_message "Response: ${SAVE_BODY}"
else
    log_message "NetScaler configuration saved successfully"
fi

# ---- Final Summary ----
log_message "=========================================="
log_message "NETSCALER ADC INTEGRATION COMPLETE"
log_message "=========================================="
log_message "  NetScaler Host:        ${NETSCALER_HOST}"
log_message "  CertKey Pair Name:     ${CERTKEY_NAME}"
log_message "  Operation Performed:   $([ "$CERTKEY_EXISTS" = true ] && echo "UPDATE (existing)" || echo "CREATE (new)")"
log_message "  Uploaded Cert File:    ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
log_message "  Uploaded Key File:     ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
log_message "  Config Saved:          $([ "$SAVE_ERROR" = "0" ] && echo "YES" || echo "NO (warning)")"
log_message "=========================================="

# ============================================================================
# END OF NETSCALER ADC INTEGRATION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0