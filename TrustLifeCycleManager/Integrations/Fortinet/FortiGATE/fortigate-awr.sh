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
subparagraphs (c)(1) and (2) of the Commercial Computer Software–Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Configuration
LEGAL_NOTICE_ACCEPT="false"  # Set to "true" to accept the legal notice and proceed with script execution
LOGFILE="/opt/digicert/fortigate.log"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

fail() {
    log_message "ERROR: $1"
    exit 1
}

api_call() {
    METHOD="$1"
    URL="$2"
    DATA="$3"

    if [ -n "$DATA" ]; then
        curl -k --silent --show-error --write-out "\nHTTP_STATUS:%{http_code}" \
            --location --request "$METHOD" "$URL" \
            --header "Authorization: Bearer ${BEARER_TOKEN}" \
            --header "Content-Type: application/json" \
            --data "$DATA" 2>&1
    else
        curl -k --silent --show-error --write-out "\nHTTP_STATUS:%{http_code}" \
            --location --request "$METHOD" "$URL" \
            --header "Authorization: Bearer ${BEARER_TOKEN}" \
            --header "Content-Type: application/json" 2>&1
    fi
}

http_status() {
    echo "$1" | grep -oP 'HTTP_STATUS:\K[0-9]+'
}

http_body() {
    echo "$1" | sed 's/HTTP_STATUS:[0-9]*$//'
}

urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

json_get_arg() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
idx=int(sys.argv[2])
args=data.get("args", [])
print(args[idx] if idx < len(args) else "")
' "$JSON_STRING" "$1"
}

json_for_log() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
args=data.get("args", [])
if isinstance(args, list) and len(args) > 2:
    args[2] = "[REDACTED]"
print(json.dumps(data))
' "$JSON_STRING"
}

json_args_for_log() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
args=data.get("args", [])
if isinstance(args, list) and len(args) > 2:
    args[2] = "[REDACTED]"
print(json.dumps(args))
' "$JSON_STRING"
}

json_get_value() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
print(data.get(sys.argv[2], ""))
' "$JSON_STRING" "$1"
}

json_get_file_by_ext() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
ext=sys.argv[2]
for f in data.get("files", []):
    if f.endswith(ext):
        print(f)
        break
' "$JSON_STRING" "$1"
}

json_files_for_log() {
    python3 -c '
import json, sys
data=json.loads(sys.argv[1])
print(json.dumps(data.get("files", [])))
' "$JSON_STRING"
}

file_size() {
    stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "unknown"
}

log_certificate_file_details() {
    if [ -f "$CRT_FILE_PATH" ]; then
        log_message "Certificate file exists: $CRT_FILE_PATH"
        log_message "Certificate file size: $(file_size "$CRT_FILE_PATH") bytes"

        CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CRT_FILE_PATH")
        log_message "Total certificates in file: $CERT_COUNT"
    else
        log_message "WARNING: Certificate file not found: $CRT_FILE_PATH"
    fi
}

log_private_key_file_details() {
    if [ -f "$KEY_FILE_PATH" ]; then
        log_message "Private key file exists: $KEY_FILE_PATH"
        log_message "Private key file size: $(file_size "$KEY_FILE_PATH") bytes"

        if grep -q "BEGIN RSA PRIVATE KEY" "$KEY_FILE_PATH"; then
            log_message "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
        elif grep -q "BEGIN EC PRIVATE KEY" "$KEY_FILE_PATH"; then
            log_message "Key type: ECC (BEGIN EC PRIVATE KEY found)"
        elif grep -q "BEGIN PRIVATE KEY" "$KEY_FILE_PATH"; then
            log_message "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
        else
            log_message "Key type: Unknown"
        fi
    else
        log_message "WARNING: Private key file not found: $KEY_FILE_PATH"
    fi
}

log_import_error() {
    STATUS="$1"
    BODY="$2"
    RAW_RESPONSE="$3"

    if [ "$STATUS" = "401" ]; then
        log_message "ERROR: Authentication failed (401 Unauthorized)"
        log_message "Please verify the Bearer token is correct"
    elif [ "$STATUS" = "403" ]; then
        log_message "ERROR: Access forbidden (403 Forbidden)"
        log_message "The API token may not have sufficient permissions"
    elif [ "$STATUS" = "404" ]; then
        log_message "ERROR: API endpoint not found (404)"
        log_message "Please verify the FortiGate URL and API path"
    elif [ "$STATUS" = "500" ]; then
        log_message "ERROR: Internal server error (500)"
        log_message "FortiGate encountered an internal error"
    elif [ -z "$STATUS" ]; then
        log_message "ERROR: Failed to connect to FortiGate"
        log_message "Please verify the FortiGate URL is correct and accessible"
        log_message "Curl output: $RAW_RESPONSE"
    else
        log_message "WARNING: Unexpected HTTP status code: $STATUS"
        log_message "Response: $BODY"
    fi
}

make_import_payload() {
    python3 -c '
import base64, json, sys
cert_path=sys.argv[1]
key_path=sys.argv[2]
cert_name=sys.argv[3]

with open(cert_path, "rb") as f:
    cert=base64.b64encode(f.read()).decode()

with open(key_path, "rb") as f:
    key=base64.b64encode(f.read()).decode()

print(json.dumps({
    "type": "regular",
    "scope": "global",
    "certname": cert_name,
    "file_content": cert,
    "key_file_content": key
}))
' "$1" "$2" "$3"
}

make_single_field_payload() {
    python3 -c '
import json, sys
print(json.dumps({sys.argv[1]: sys.argv[2]}))
' "$1" "$2"
}

find_matching_singleton_field_value() {
    FIELD="$1"
    BASE="$2"

    python3 -c '
import json, sys

field = sys.argv[1]
base = sys.argv[2]
body = sys.stdin.read()

try:
    data = json.loads(body)
    result = data.get("results", data)
    value = result.get(field, "")

    if isinstance(value, str):
        if value == base or value.startswith(base + "-"):
            print(value)
except Exception:
    pass
' "$FIELD" "$BASE"
}

list_matching_table_objects() {
    python3 -c '
import json, sys

body=sys.stdin.read()
field=sys.argv[1]
base=sys.argv[2]

def unwrap(v):
    vals=[]
    if isinstance(v, str):
        vals.append(v)
    elif isinstance(v, dict):
        for k in ("name", "q_origin_key", "mkey", "value"):
            if k in v and isinstance(v[k], str):
                vals.append(v[k])
    elif isinstance(v, list):
        for item in v:
            vals.extend(unwrap(item))
    return vals

def matches(v):
    return v == base or v.startswith(base + "-")

try:
    data=json.loads(body)
    results=data.get("results", [])
    if isinstance(results, dict):
        results=[results]

    for item in results:
        vals=unwrap(item.get(field))
        matched=""
        for v in vals:
            if matches(v):
                matched=v
                break

        if matched:
            mkey=item.get("name") or item.get("q_origin_key") or item.get("mkey") or item.get("id")
            if mkey:
                print(str(mkey) + "|" + matched)
except Exception:
    pass
' "$FIELD" "$BASE"
}

log_message "=========================================="
log_message "Starting FortiGate Certificate Import Script"
log_message "=========================================="

log_message "Checking legal notice acceptance..."
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    log_message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed."
    log_message "Script execution terminated due to legal notice non-acceptance."
    log_message "=========================================="
    exit 1
else
    log_message "Legal notice accepted, proceeding with script execution."
fi

log_message "Configuration:"
log_message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
log_message "  LOGFILE: $LOGFILE"

log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

CERT_INFO=${DC1_POST_SCRIPT_DATA}
log_message "CERT_INFO length: ${#CERT_INFO} characters"

JSON_STRING=$(echo "$CERT_INFO" | base64 -d 2>/dev/null) || fail "Unable to decode DC1_POST_SCRIPT_DATA"
log_message "JSON_STRING decoded successfully"

log_message "=========================================="
log_message "Raw JSON content (sensitive values redacted):"
log_message "$(json_for_log)"
log_message "=========================================="

log_message "Extracting arguments from JSON..."
ARGS_ARRAY_FOR_LOG=$(json_args_for_log)
log_message "Raw args array (sensitive values redacted): $ARGS_ARRAY_FOR_LOG"

FORTIGATE_URL=$(json_get_arg 0 | tr -d '[:space:]')
log_message "ARGUMENT_1 (FortiGate URL) extracted: '$FORTIGATE_URL'"
log_message "ARGUMENT_1 length: ${#FORTIGATE_URL}"

CERT_BASE_NAME=$(json_get_arg 1 | tr -d '[:space:]')
log_message "ARGUMENT_2 (Certificate Base Name) extracted: '$CERT_BASE_NAME'"
log_message "ARGUMENT_2 length: ${#CERT_BASE_NAME}"

BEARER_TOKEN=$(json_get_arg 2 | tr -d '[:space:]')
log_message "ARGUMENT_3 (Bearer Token) extracted: '[REDACTED]'"
log_message "ARGUMENT_3 length: ${#BEARER_TOKEN}"

DELETE_MODE=$(json_get_arg 3 | tr -d '[:space:]')
log_message "ARGUMENT_4 (Delete Mode) extracted: '$DELETE_MODE'"
log_message "ARGUMENT_4 length: ${#DELETE_MODE}"

ASSIGN_MODE=$(json_get_arg 4 | tr -d '[:space:]')
log_message "ARGUMENT_5 (Assign Mode) extracted: '$ASSIGN_MODE'"
log_message "ARGUMENT_5 length: ${#ASSIGN_MODE}"

[ -z "$DELETE_MODE" ] && DELETE_MODE="keep_old"
[ -z "$ASSIGN_MODE" ] && ASSIGN_MODE="assign_refs"

CERT_FOLDER=$(json_get_value "certfolder")
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

CRT_FILE=$(json_get_file_by_ext ".crt")
log_message "Extracted CRT_FILE: $CRT_FILE"

KEY_FILE=$(json_get_file_by_ext ".key")
log_message "Extracted KEY_FILE: $KEY_FILE"

CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

FILES_ARRAY_FOR_LOG=$(json_files_for_log)
log_message "Files array content: $FILES_ARRAY_FOR_LOG"

DATE_SUFFIX=$(date '+%Y%m%d-%H%M%S')
NEW_CERT_NAME="${CERT_BASE_NAME}-${DATE_SUFFIX}"

log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "FortiGate Configuration:"
log_message "  FortiGate URL: $FORTIGATE_URL"
log_message "  Certificate Base Name: $CERT_BASE_NAME"
log_message "  New Certificate Name: $NEW_CERT_NAME"
log_message "  Bearer Token: [REDACTED - ${#BEARER_TOKEN} characters]"
log_message "  Delete Mode: $DELETE_MODE"
log_message "  Assign Mode: $ASSIGN_MODE"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Private key file: $KEY_FILE"
log_message "  Certificate path: $CRT_FILE_PATH"
log_message "  Private key path: $KEY_FILE_PATH"
log_message ""
log_message "All files in array: $FILES_ARRAY_FOR_LOG"
log_message "=========================================="

log_certificate_file_details
log_private_key_file_details

log_message "=========================================="
log_message "Starting FortiGate Certificate Import..."
log_message "=========================================="

[ -z "$FORTIGATE_URL" ] && fail "Argument 1 FortiGate URL is empty"
[ -z "$CERT_BASE_NAME" ] && fail "Argument 2 certificate base name is empty"
[ -z "$BEARER_TOKEN" ] && fail "Argument 3 bearer token is empty"
[ ! -f "$CRT_FILE_PATH" ] && fail "Certificate file does not exist: $CRT_FILE_PATH"
[ ! -f "$KEY_FILE_PATH" ] && fail "Private key file does not exist: $KEY_FILE_PATH"

log_message "All validations passed, proceeding with API call..."

MATCHED_OLD_CERTS_FILE="/tmp/fortigate_matched_old_certs_$$.txt"
: > "$MATCHED_OLD_CERTS_FILE"

IMPORT_URL="https://${FORTIGATE_URL}/api/v2/monitor/vpn-certificate/local/import"
log_message "FortiGate API URL: $IMPORT_URL"

log_message "Base64 encoding certificate file..."
log_message "Base64 encoding private key file..."
IMPORT_PAYLOAD=$(make_import_payload "$CRT_FILE_PATH" "$KEY_FILE_PATH" "$NEW_CERT_NAME") || fail "Failed to base64 encode certificate or private key file"
log_message "JSON payload constructed (certname: $NEW_CERT_NAME)"

log_message "Executing FortiGate API call..."
log_message "POST $IMPORT_URL"
IMPORT_RESPONSE=$(api_call POST "$IMPORT_URL" "$IMPORT_PAYLOAD")
IMPORT_HTTP_STATUS=$(http_status "$IMPORT_RESPONSE")
IMPORT_RESPONSE_BODY=$(http_body "$IMPORT_RESPONSE")

log_message "Import HTTP Status: $IMPORT_HTTP_STATUS"
log_message "Import Body: $IMPORT_RESPONSE_BODY"

if [ "$IMPORT_HTTP_STATUS" = "200" ]; then
    log_message "SUCCESS: Certificate imported successfully to FortiGate"
    log_message "Certificate Name: $NEW_CERT_NAME"
    log_message "FortiGate: $FORTIGATE_URL"
else
    log_import_error "$IMPORT_HTTP_STATUS" "$IMPORT_RESPONSE_BODY" "$IMPORT_RESPONSE"
    exit 1
fi

log_message "SUCCESS: Imported new certificate '$NEW_CERT_NAME'"

if [ "$ASSIGN_MODE" = "import_only" ]; then
    log_message "ASSIGN_MODE=import_only, skipping reference reassignment"
    rm -f "$MATCHED_OLD_CERTS_FILE"
    log_message "FortiGate certificate import section completed"
    log_message "=========================================="
    log_message "=========================================="
    log_message "Script execution completed"
    log_message "=========================================="
    exit 0
fi

REFERENCE_COUNT=0
FAILED_REASSIGN_COUNT=0

remember_old_cert() {
    [ -n "$1" ] && echo "$1" >> "$MATCHED_OLD_CERTS_FILE"
}

reassign_singleton() {
    LABEL="$1"
    ENDPOINT="$2"
    FIELD="$3"

    URL="https://${FORTIGATE_URL}/api/v2/cmdb/${ENDPOINT}"

    log_message "Checking $LABEL field $FIELD"
    RESP=$(api_call GET "$URL" "")
    CODE=$(http_status "$RESP")
    BODY=$(http_body "$RESP")

    log_message "$LABEL GET HTTP: $CODE"

    [ "$CODE" != "200" ] && {
        log_message "WARNING: Could not read $LABEL"
        return
    }

    RAW_VALUE=$(echo "$BODY" | python3 -c '
import json, sys
field=sys.argv[1]
try:
    d=json.load(sys.stdin)
    print(d.get("results", {}).get(field, "<missing>"))
except Exception:
    print("<parse-error>")
' "$FIELD")

    log_message "$LABEL raw $FIELD value: $RAW_VALUE"

    MATCHED_VALUE=$(echo "$BODY" | find_matching_singleton_field_value "$FIELD" "$CERT_BASE_NAME")

    if [ -z "$MATCHED_VALUE" ]; then
        log_message "No matching reference found in $LABEL field $FIELD"
        return
    fi

    log_message "Reference found: $LABEL uses '$MATCHED_VALUE'"
    remember_old_cert "$MATCHED_VALUE"

    PAYLOAD=$(make_single_field_payload "$FIELD" "$NEW_CERT_NAME")

    log_message "PUT $URL"
    UPDATE_RESP=$(api_call PUT "$URL" "$PAYLOAD")
    UPDATE_CODE=$(http_status "$UPDATE_RESP")
    UPDATE_BODY=$(http_body "$UPDATE_RESP")

    log_message "$LABEL update HTTP: $UPDATE_CODE"
    log_message "$LABEL update Body: $UPDATE_BODY"

    if [ "$UPDATE_CODE" = "200" ]; then
        REFERENCE_COUNT=$((REFERENCE_COUNT + 1))
        log_message "SUCCESS: Reassigned $LABEL from '$MATCHED_VALUE' to '$NEW_CERT_NAME'"
    else
        FAILED_REASSIGN_COUNT=$((FAILED_REASSIGN_COUNT + 1))
        log_message "ERROR: Failed to reassign $LABEL"
    fi
}

reassign_table() {
    LABEL="$1"
    ENDPOINT="$2"
    FIELD="$3"

    LIST_URL="https://${FORTIGATE_URL}/api/v2/cmdb/${ENDPOINT}"

    log_message "Checking table $LABEL field $FIELD"
    RESP=$(api_call GET "$LIST_URL" "")
    CODE=$(http_status "$RESP")
    BODY=$(http_body "$RESP")

    log_message "$LABEL GET HTTP: $CODE"

    [ "$CODE" != "200" ] && {
        log_message "WARNING: Could not list $LABEL"
        return
    }

    MATCHES=$(echo "$BODY" | list_matching_table_objects "$FIELD" "$CERT_BASE_NAME")

    [ -z "$MATCHES" ] && {
        log_message "No matching references found in $LABEL"
        return
    }

    TMP_MATCHES="/tmp/fortigate_matches_$$.txt"
    echo "$MATCHES" > "$TMP_MATCHES"

    while IFS='|' read -r MKEY MATCHED_VALUE; do
        [ -z "$MKEY" ] && continue

        remember_old_cert "$MATCHED_VALUE"

        ENCODED_MKEY=$(urlencode "$MKEY")
        UPDATE_URL="https://${FORTIGATE_URL}/api/v2/cmdb/${ENDPOINT}/${ENCODED_MKEY}"
        PAYLOAD=$(make_single_field_payload "$FIELD" "$NEW_CERT_NAME")

        log_message "PUT $UPDATE_URL"
        UPDATE_RESP=$(api_call PUT "$UPDATE_URL" "$PAYLOAD")
        UPDATE_CODE=$(http_status "$UPDATE_RESP")
        UPDATE_BODY=$(http_body "$UPDATE_RESP")

        log_message "$LABEL '$MKEY' update HTTP: $UPDATE_CODE"
        log_message "$LABEL '$MKEY' update Body: $UPDATE_BODY"

        if [ "$UPDATE_CODE" = "200" ]; then
            REFERENCE_COUNT=$((REFERENCE_COUNT + 1))
            log_message "SUCCESS: Reassigned $LABEL '$MKEY' from '$MATCHED_VALUE' to '$NEW_CERT_NAME'"
        else
            FAILED_REASSIGN_COUNT=$((FAILED_REASSIGN_COUNT + 1))
        fi
    done < "$TMP_MATCHES"

    rm -f "$TMP_MATCHES"
}

reassign_singleton "SSL-VPN settings" "vpn.ssl/settings" "servercert"
reassign_singleton "Admin HTTPS certificate" "system/global" "admin-server-cert"
reassign_singleton "Admin HTTPS certificate fallback" "system/global" "admin-server-certname"

reassign_table "IPsec phase1-interface" "vpn.ipsec/phase1-interface" "certificate"
reassign_table "IPsec phase1" "vpn.ipsec/phase1" "certificate"

log_message "=========================================="
log_message "References reassigned: $REFERENCE_COUNT"
log_message "Failed reassignments: $FAILED_REASSIGN_COUNT"
log_message "=========================================="

[ "$FAILED_REASSIGN_COUNT" -gt 0 ] && fail "One or more references failed to reassign"

if [ "$DELETE_MODE" = "delete_old" ]; then
    sort -u "$MATCHED_OLD_CERTS_FILE" | while read -r OLD_CERT; do
        [ -z "$OLD_CERT" ] && continue
        [ "$OLD_CERT" = "$NEW_CERT_NAME" ] && continue

        OLD_CERT_ENCODED=$(urlencode "$OLD_CERT")
        DELETE_URL="https://${FORTIGATE_URL}/api/v2/cmdb/vpn.certificate/local/${OLD_CERT_ENCODED}"

        log_message "DELETE $DELETE_URL"
        DELETE_RESPONSE=$(api_call DELETE "$DELETE_URL" "")
        DELETE_HTTP_STATUS=$(http_status "$DELETE_RESPONSE")
        DELETE_RESPONSE_BODY=$(http_body "$DELETE_RESPONSE")

        log_message "Delete '$OLD_CERT' HTTP Status: $DELETE_HTTP_STATUS"
        log_message "Delete '$OLD_CERT' Body: $DELETE_RESPONSE_BODY"
    done
else
    log_message "DELETE_MODE=$DELETE_MODE, leaving old certificates in place"
fi

rm -f "$MATCHED_OLD_CERTS_FILE"

log_message "FortiGate certificate import section completed"
log_message "=========================================="
log_message "=========================================="
log_message "Script execution completed"
log_message "New Certificate Name: $NEW_CERT_NAME"
log_message "=========================================="

exit 0
