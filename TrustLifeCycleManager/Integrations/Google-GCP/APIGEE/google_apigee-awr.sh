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
Export Regulation: The software and related technical data and services (collectively “Controlled Technology”)
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
US Government Restricted Rights: The software is provided with “Restricted Rights,” Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/apigee.log"
PROJECT_ID="< YOUR_PROJECT_ID >"
ENVIRONMENT="< YOUR_ENVIRONMENT >"
SA_KEY_PATH="/home/ubuntu/tlm_agent_3.0.15_linux64/user-scripts/service-account-key.json"

# Logging setup
exec > >(tee -a "$LOGFILE") 2>&1

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log "===== Script started ====="

# Legal notice check
if [[ "${LEGAL_NOTICE_ACCEPT,,}" != "true" ]]; then
    log "ERROR: You must accept the legal notice by setting LEGAL_NOTICE_ACCEPT=\"true\""
    exit 1
fi

# Validate environment variables
if [[ -z "$DC1_POST_SCRIPT_DATA" ]]; then
    log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set."
    exit 1
fi

# Parse input data
CERT_INFO="$DC1_POST_SCRIPT_DATA"
log "Decoding base64 JSON string..."
JSON_STRING=$(echo "$CERT_INFO" | base64 -d 2>>"$LOGFILE")
if [[ $? -ne 0 ]]; then
    log "ERROR: Failed to decode base64 string."
    exit 1
fi
log "Decoded JSON: $JSON_STRING"

# Extract JSON data
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
KEYSTORE=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*' | awk -F',' '{print $1}' | tr -d '"')
ALIAS=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*' | awk -F',' '{print $2}' | tr -d '"')
REFERENCE=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*' | awk -F',' '{print $3}' | tr -d '"')
DEPLOY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*' | awk -F',' '{print $4}' | tr -d '"')

# Validate extracted data
for var in CERT_FOLDER CRT_FILE KEY_FILE KEYSTORE ALIAS REFERENCE; do
    if [[ -z "${!var}" ]]; then
        log "ERROR: Failed to extract $var from JSON"
        exit 1
    fi
    log "$var: ${!var}"
done

# Construct file paths
CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

# Validate files exist
if [[ ! -f "$CRT_FILE_PATH" || ! -f "$KEY_FILE_PATH" ]]; then
    log "ERROR: Certificate or key file not found"
    log "CRT: $CRT_FILE_PATH"
    log "KEY: $KEY_FILE_PATH"
    exit 1
fi

# Validate service account key
if [[ ! -f "$SA_KEY_PATH" ]]; then
    log "ERROR: Service account key file not found at $SA_KEY_PATH"
    exit 1
fi

# Get access token
log "Getting access token..."
if ! gcloud auth activate-service-account --key-file="$SA_KEY_PATH" > /dev/null 2>&1; then
    log "ERROR: Failed to activate service account"
    exit 1
fi

APIGEE_TOKEN=$(gcloud auth print-access-token)
if [[ -z "$APIGEE_TOKEN" ]]; then
    log "ERROR: Failed to obtain access token"
    exit 1
fi
log "Access token obtained successfully"

##### Main Script Logic #####

# Handle different deployment modes
if [[ -n "$DEPLOY" ]]; then
    log "DEPLOY: $DEPLOY"
    case "$DEPLOY" in
        "rotate")
            log "Rotate mode selected - creating new keystore and updating reference"
            
            # Create new keystore
            log "Creating new keystore $KEYSTORE..."
            create_keystore_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -H "Content-Type: application/json" \
                -X POST \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/keystores" \
                -d "{\"name\":\"$KEYSTORE\"}")

            http_code=$(echo "$create_keystore_response" | tail -n1)
            response_body=$(echo "$create_keystore_response" | sed \$d)
            log "Keystore creation status: $http_code"
            log "Keystore creation response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to create keystore (HTTP $http_code)"
                exit 1
            fi

            # Upload certificate to new keystore
            log "Uploading certificate and key to new keystore..."
            upload_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -X POST \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/keystores/$KEYSTORE/aliases?alias=$ALIAS&format=keycertfile" \
                --form "keyFile=@$KEY_FILE_PATH" \
                --form "certFile=@$CRT_FILE_PATH")

            http_code=$(echo "$upload_response" | tail -n1)
            response_body=$(echo "$upload_response" | sed \$d)
            log "Certificate upload status: $http_code"
            log "Certificate upload response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to upload certificate and key (HTTP $http_code)"
                exit 1
            fi

            # Add debug logging before the reference update
            log "DEBUG: Current values:"
            log "KEYSTORE: $KEYSTORE"
            log "ALIAS: $ALIAS"
            log "REFERENCE: $REFERENCE"

            # Update reference to point to new keystore
            log "Updating reference to point to new keystore..."
            update_ref_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -H "Content-Type: application/json" \
                -X PUT \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/references/$REFERENCE" \
                -d "{
                    \"name\": \"$REFERENCE\",
                    \"refers\": \"$KEYSTORE\",
                    \"resourceType\": \"KeyStore\"
                }")

            http_code=$(echo "$update_ref_response" | tail -n1)
            response_body=$(echo "$update_ref_response" | sed \$d)
            log "Reference update status: $http_code"
            log "Reference update response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to update reference (HTTP $http_code)"
                exit 1
            fi

            log "Successfully rotated keystore and updated reference"
            log "===== Script finished ====="
            exit 0
            ;;
            
        "new")
            log "New installation mode selected"
            # Create keystore
            log "Creating keystore..."
            create_keystore_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -H "Content-Type: application/json" \
                -X POST \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/keystores" \
                -d "{\"name\":\"$KEYSTORE\"}")

            http_code=$(echo "$create_keystore_response" | tail -n1)
            response_body=$(echo "$create_keystore_response" | sed \$d)
            log "Keystore creation status: $http_code"
            log "Keystore creation response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to create keystore (HTTP $http_code)"
                exit 1
            fi

            # Upload certificate and key
            log "Uploading certificate and key..."
            upload_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -X POST \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/keystores/$KEYSTORE/aliases?alias=$ALIAS&format=keycertfile" \
                --form "keyFile=@$KEY_FILE_PATH" \
                --form "certFile=@$CRT_FILE_PATH")

            http_code=$(echo "$upload_response" | tail -n1)
            response_body=$(echo "$upload_response" | sed \$d)
            log "Certificate upload status: $http_code"
            log "Certificate upload response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to upload certificate and key (HTTP $http_code)"
                exit 1
            fi

            # Create reference
            log "Creating reference..."
            create_ref_response=$(curl -s -w "\n%{http_code}" \
                -H "Authorization: Bearer $APIGEE_TOKEN" \
                -H "Content-Type: application/json" \
                -X POST \
                "https://apigee.googleapis.com/v1/organizations/$PROJECT_ID/environments/$ENVIRONMENT/references" \
                -d "{\"name\":\"$REFERENCE\",\"refers\":\"$KEYSTORE\",\"resourceType\":\"KeyStore\"}")

            http_code=$(echo "$create_ref_response" | tail -n1)
            response_body=$(echo "$create_ref_response" | sed \$d)
            log "Reference creation status: $http_code"
            log "Reference creation response: $response_body"

            if [[ $http_code -lt 200 || $http_code -gt 299 ]]; then
                log "ERROR: Failed to create reference (HTTP $http_code)"
                exit 1
            fi

            log "Successfully completed new installation"
            log "===== Script finished ====="
            exit 0
            ;;
            
        *)
            log "ERROR: Invalid DEPLOY value. Must be 'new' or 'rotate'"
            exit 1
            ;;
    esac
else
    # Default to new installation if no DEPLOY specified
    log "No deployment mode specified, defaulting to new installation"
    DEPLOY="new"
fi

log "===== Script finished ====="