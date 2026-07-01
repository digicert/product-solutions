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
LEGAL_NOTICE_ACCEPT="false"   # Set to "true" to accept the legal notice and enable script execution
LOGFILE="/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log"

# Secret to redact from all log output. Set once the auth token is known
# (see below); until then logging is unaffected.
REDACT_TOKEN=""
REDACT_MASK="***REDACTED***"

# Function to log messages with timestamp. Any occurrence of REDACT_TOKEN in
# the message is masked so the FortiWeb auth token (which base64-decodes to
# admin credentials) never lands in the log file.
log_message() {
    local msg="$1"
    if [ -n "$REDACT_TOKEN" ]; then
        msg="${msg//$REDACT_TOKEN/$REDACT_MASK}"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOGFILE"
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

# Identify the FortiWeb auth token (second arg) as early as possible so every
# subsequent log line - including the raw JSON dump below - redacts it.
REDACT_TOKEN=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*' | awk -F',' '{print $2}' | tr -d '"' | tr -d '[:space:]')

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
# CUSTOM SCRIPT SECTION - FORTIWEB API CERTIFICATE UPLOAD
# ============================================================================
#
# This section uploads the certificate and key to FortiWeb using the API
#
# Arguments used:
#   ARGUMENT_1: FortiWeb URL (e.g., ec2-18-218-166-16.us-east-2.compute.amazonaws.com)
#   ARGUMENT_2: Authorization Token
#
# ============================================================================

log_message "=========================================="
log_message "Starting FortiWeb API certificate upload..."
log_message "=========================================="

# Validate required arguments
if [ -z "$ARGUMENT_1" ]; then
    log_message "ERROR: Argument 1 (FortiWeb URL) is not provided"
    log_message "Skipping FortiWeb upload - URL not specified"
else
    if [ -z "$ARGUMENT_2" ]; then
        log_message "ERROR: Argument 2 (Authorization Token) is not provided"
        log_message "Skipping FortiWeb upload - Authorization token not specified"
    else
        # Check if certificate and key files exist
        if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
            
            # Set FortiWeb API variables
            FORTIWEB_URL="$ARGUMENT_1"
            AUTH_TOKEN="$ARGUMENT_2"
            
            # Remove any trailing/leading whitespace from URL and token
            FORTIWEB_URL=$(echo "$FORTIWEB_URL" | xargs)
            AUTH_TOKEN=$(echo "$AUTH_TOKEN" | xargs)
            
            # Construct the API endpoint
            API_ENDPOINT="https://${FORTIWEB_URL}:8443/api/v2.0/system/certificate.local.import_certificate"
            
            log_message "FortiWeb Upload Configuration:"
            log_message "  FortiWeb URL: $FORTIWEB_URL"
            log_message "  API Endpoint: $API_ENDPOINT"
            log_message "  Certificate file: $CRT_FILE_PATH"
            log_message "  Key file: $KEY_FILE_PATH"
            log_message "  Auth token length: ${#AUTH_TOKEN} characters"
            
            # ============================================================
            # RENEWAL-SAFE UPLOAD (ROTATE, DON'T OVERWRITE)
            # ============================================================
            # FortiWeb cannot overwrite an existing local certificate:
            #   * importing under a name that already exists fails as a
            #     "duplicate" error, and
            #   * a certificate that is bound to a server policy cannot be
            #     deleted while it is in use.
            #
            # So instead of "delete then re-import under the same name" we
            # rotate the certificate:
            #   1. Import the new cert under a UNIQUE name (sanitised CN +
            #      certificate serial). FortiWeb derives the stored name from
            #      the uploaded file name, so we stage the files under that
            #      unique name -> the duplicate error can never occur.
            #   2. Confirm the name FortiWeb actually assigned (list diff).
            #   3. For every PREVIOUS cert belonging to this CN, check whether
            #      a server policy is still bound to it:
            #         bound   -> repoint the policy to the new cert, THEN
            #                    delete the old cert (now unreferenced),
            #         unbound -> just delete the old cert (housekeeping).
            #
            # NOTE: two behaviours are FortiWeb-version specific and worth
            # confirming against your appliance:
            #   (a) the CMDB body used to repoint a policy's certificate
            #       ({"data":{"certificate":"..."}} below), and
            #   (b) the JSON field names returned by the cert/policy lists.
            # The flow is non-destructive on ambiguity: an old cert is only
            # deleted once the new cert is confirmed present (and, when it was
            # bound, once the policy has been successfully repointed).

            CMDB_CERT_BASE="https://${FORTIWEB_URL}:8443/api/v2.0/cmdb/system/certificate.local"
            CMDB_POLICY_BASE="https://${FORTIWEB_URL}:8443/api/v2.0/cmdb/server-policy/policy"
            CMDB_SNI_BASE="https://${FORTIWEB_URL}:8443/api/v2.0/cmdb/system/certificate.sni"
            CMDB_MULTILOCAL_BASE="https://${FORTIWEB_URL}:8443/api/v2.0/cmdb/system/certificate.multi-local"
            LIST_ENDPOINT="https://${FORTIWEB_URL}:8443/api/v2.0/system/certificate.local"

            # Helper: raw JSON of the local certificate list
            get_cert_list_json() {
                curl -k --location -g --request GET "$LIST_ENDPOINT" \
                    --header "Authorization: $AUTH_TOKEN" \
                    --header 'Accept: application/json' \
                    --silent --show-error 2>/dev/null
            }

            # Helper: sorted, unique list of local certificate names
            get_cert_names() {
                get_cert_list_json | grep -oP '"(?:name|mkey)"\s*:\s*"\K[^"]+' | sort -u
            }

            # Helper: pkey_type (key algorithm code) of the cert named $1.
            get_cert_pkey_type() {
                get_cert_list_json | python3 -c '
import sys, json
name = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
res = d.get("results", []) if isinstance(d, dict) else d
for c in (res if isinstance(res, list) else [res]):
    if isinstance(c, dict) and name in (c.get("name"), c.get("_id"), c.get("mkey")):
        pt = c.get("pkey_type")
        if pt is not None:
            print(pt)
        break
' "$1" 2>/dev/null
            }

            # Helper: names of local certs whose *subject CN* equals $1 AND
            # whose key algorithm (pkey_type) equals $3, excluding the cert
            # named $2 (the newly-uploaded one). Reads the real subject from
            # the API rather than trusting the cert name, so off-convention
            # names are still recognised. The pkey_type filter ensures an RSA
            # renewal never touches an ECC cert of the same CN (and vice
            # versa). If $3 is empty the algorithm filter is skipped (CN only).
            # Requires python3.
            get_cert_names_by_cn() {
                get_cert_list_json | python3 -c '
import sys, json, re
target = sys.argv[1].strip().lower()
exclude = sys.argv[2]
want_pkey = sys.argv[3] if len(sys.argv) > 3 else ""
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
res = d.get("results", []) if isinstance(d, dict) else d
for c in (res if isinstance(res, list) else [res]):
    if not isinstance(c, dict):
        continue
    name = c.get("name") or c.get("_id") or c.get("mkey")
    m = re.search(r"CN\s*=\s*([^,/]+)", c.get("subject") or "")
    cn = m.group(1).strip().lower() if m else ""
    if not name or name == exclude or not cn or cn != target:
        continue
    if want_pkey and str(c.get("pkey_type")) != want_pkey:
        continue
    print(name)
' "$1" "$2" "$3" 2>/dev/null
            }

            # --- Derive a unique, FortiWeb-safe certificate name ------------
            CERT_CN=$(openssl x509 -in "$CRT_FILE_PATH" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p' | sed 's/\s*$//')
            CERT_SERIAL=$(openssl x509 -in "$CRT_FILE_PATH" -noout -serial 2>/dev/null | cut -d'=' -f2 | tr 'A-F' 'a-f')

            if [ -z "$CERT_CN" ]; then
                log_message "WARNING: Could not extract Common Name; falling back to certificate file base name"
                BASE_NAME=$(basename "$CRT_FILE" | sed 's/\.[^.]*$//')
            else
                BASE_NAME="$CERT_CN"
            fi
            # FortiWeb only permits alphanumerics and underscores in the name
            BASE_NAME=$(echo "$BASE_NAME" | sed 's/[^A-Za-z0-9]/_/g')
            SHORT_SERIAL=$(echo "$CERT_SERIAL" | tail -c 13)
            [ -z "$SHORT_SERIAL" ] && SHORT_SERIAL=$(date '+%Y%m%d%H%M%S')
            UNIQUE_NAME="${BASE_NAME}_${SHORT_SERIAL}"

            log_message "Certificate Common Name : ${CERT_CN:-<unknown>}"
            log_message "Certificate serial      : ${CERT_SERIAL:-<unknown>}"
            log_message "Domain name prefix      : $BASE_NAME"
            log_message "New unique cert name    : $UNIQUE_NAME"

            # --- Stage the cert/key under the unique name -------------------
            STAGE_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/fwb_stage_$$")
            mkdir -p "$STAGE_DIR"; chmod 700 "$STAGE_DIR"
            UP_CRT="${STAGE_DIR}/${UNIQUE_NAME}.crt"
            UP_KEY="${STAGE_DIR}/${UNIQUE_NAME}.key"
            cp "$CRT_FILE_PATH" "$UP_CRT"
            cp "$KEY_FILE_PATH" "$UP_KEY"
            chmod 600 "$UP_KEY"

            # --- Snapshot existing certs (to detect the new name + old ones)-
            BEFORE_NAMES=$(get_cert_names)
            log_message "Existing certificates on FortiWeb: $(echo "$BEFORE_NAMES" | tr '\n' ' ')"

            log_message "=========================================="
            log_message "Executing certificate upload to FortiWeb (name: $UNIQUE_NAME)..."

            CURL_RESPONSE=$(curl -k --location -g --request POST "$API_ENDPOINT" \
                --header "Authorization: $AUTH_TOKEN" \
                --header 'Accept: application/json' \
                --header 'Content-Type: multipart/form-data' \
                --form "certificateFile=@${UP_CRT}" \
                --form "keyFile=@${UP_KEY}" \
                --form 'type=certificate' \
                --form 'hsm=undefined' \
                --form 'password=undefined' \
                --write-out "\nHTTP_STATUS:%{http_code}" \
                --silent \
                --show-error \
                2>&1)

# Remove the staged private key material
rm -rf "$STAGE_DIR"

            # Extract HTTP status code and response body
            HTTP_STATUS=$(echo "$CURL_RESPONSE" | grep "HTTP_STATUS:" | cut -d':' -f2)
            RESPONSE_BODY=$(echo "$CURL_RESPONSE" | sed '/HTTP_STATUS:/d')

            log_message "HTTP Status Code: $HTTP_STATUS"
            log_message "Response Body: $RESPONSE_BODY"

            if [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "201" ]; then
                log_message "SUCCESS: Certificate uploaded successfully to FortiWeb"

                # --- Confirm the name FortiWeb actually assigned -----------
                sleep 1
                AFTER_NAMES=$(get_cert_names)
                NEW_CERT_NAME=$(comm -13 <(echo "$BEFORE_NAMES") <(echo "$AFTER_NAMES") 2>/dev/null | grep -v '^$' | head -n1)
                if [ -z "$NEW_CERT_NAME" ]; then
                    NEW_CERT_NAME="$UNIQUE_NAME"
                    log_message "Could not detect new cert via list diff; assuming '$NEW_CERT_NAME'"
                else
                    log_message "FortiWeb stored the new certificate as: $NEW_CERT_NAME"
                fi

                # --- Identify PREVIOUS certs for this domain ---------------
                # Preferred: match on the real subject CN reported by the API,
                # constrained to the SAME key algorithm as the new cert, so an
                # RSA renewal never touches an ECC cert of the same CN (and
                # vice versa). Falls back to the name convention when the CN is
                # unknown or python3 is unavailable.
                CERT_ALGO=$(openssl x509 -in "$CRT_FILE_PATH" -noout -text 2>/dev/null | grep -i "Public Key Algorithm" | head -n1 | sed 's/.*: *//')
                if command -v python3 >/dev/null 2>&1 && [ -n "$CERT_CN" ]; then
                    NEW_PKEY_TYPE=$(get_cert_pkey_type "$NEW_CERT_NAME")
                    log_message "New certificate key algorithm: ${CERT_ALGO:-unknown} (FortiWeb pkey_type=${NEW_PKEY_TYPE:-unknown})"
                    if [ -z "$NEW_PKEY_TYPE" ]; then
                        log_message "WARNING: could not determine new cert's pkey_type - selecting by CN only (a same-CN cert of a different algorithm could be affected)"
                    fi
                    OLD_CERTS=$(get_cert_names_by_cn "$CERT_CN" "$NEW_CERT_NAME" "$NEW_PKEY_TYPE" | grep -v '^$' | sort -u)
                    log_message "Selecting previous certificates by subject CN '$CERT_CN' and matching key algorithm"
                else
                    # Fallback: sanitised base name (optionally with a hex serial
                    # suffix), plus the raw CN in case it was stored verbatim.
                    log_message "Selecting previous certificates by name convention (CN or python3 unavailable)"
                    OLD_CERTS=$(echo "$BEFORE_NAMES" | grep -E "^${BASE_NAME}(_[a-f0-9]+)?$")
                    if [ -n "$CERT_CN" ]; then
                        OLD_CERTS=$(printf '%s\n%s\n' "$OLD_CERTS" "$(echo "$BEFORE_NAMES" | grep -Fx "$CERT_CN")")
                    fi
                    OLD_CERTS=$(echo "$OLD_CERTS" | grep -v '^$' | sort -u | grep -vx "$NEW_CERT_NAME")
                fi

                OLD_CERT_COUNT=$(echo "$OLD_CERTS" | grep -c '[^[:space:]]')
                log_message "Previous certificate(s) selected for rotation ($OLD_CERT_COUNT): $(echo "$OLD_CERTS" | tr '\n' ' ')"

                if [ -z "$OLD_CERTS" ]; then
                    log_message "No previous certificate found for this domain - initial import, nothing to rotate"
                else
                    # Fetch the list of server-policy names once
                    POLICY_NAMES=$(curl -k --location -g --request GET "$CMDB_POLICY_BASE" \
                        --header "Authorization: $AUTH_TOKEN" \
                        --header 'Accept: application/json' \
                        --silent --show-error 2>/dev/null \
                        | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u)
                    log_message "Server policies discovered to scan: $(echo "$POLICY_NAMES" | tr '\n' ' ')"

                    # Collect the SNI configuration object names once. A cert
                    # can be referenced either directly by a policy's
                    # 'certificate' field OR inside an SNI object member's
                    # 'local-cert' field - both block deletion, so we handle both.
                    SNI_NAMES=$(curl -k --location -g --request GET "$CMDB_SNI_BASE" \
                        --header "Authorization: $AUTH_TOKEN" \
                        --header 'Accept: application/json' \
                        --silent --show-error 2>/dev/null \
                        | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u)
                    log_message "SNI objects discovered to scan: $(echo "$SNI_NAMES" | tr '\n' ' ')"

                    # Collect multi-local (dual RSA/ECC/DSA) certificate group
                    # names. When a domain serves multiple algorithms, the cert
                    # is referenced by the group's rsa-cert/ecc-cert/dsa-cert
                    # field rather than a policy or SNI member directly.
                    MULTILOCAL_NAMES=$(curl -k --location -g --request GET "$CMDB_MULTILOCAL_BASE" \
                        --header "Authorization: $AUTH_TOKEN" \
                        --header 'Accept: application/json' \
                        --silent --show-error 2>/dev/null \
                        | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u)
                    log_message "Multi-cert groups discovered to scan: $(echo "$MULTILOCAL_NAMES" | tr '\n' ' ')"

                    HAVE_PY3=0
                    command -v python3 >/dev/null 2>&1 && HAVE_PY3=1

                    echo "$OLD_CERTS" | while IFS= read -r OLD_CERT; do
                        [ -z "$OLD_CERT" ] && continue
                        log_message "Processing previous certificate: $OLD_CERT"

                        REF_FOUND=0     # was the old cert referenced anywhere?
                        REF_FAILED=0    # did any repoint attempt fail?

                        # ---- (1) SNI members that reference the old cert ------
                        # Members are a child table, retrieved separately from
                        # the parent SNI object:
                        #   GET  certificate.sni/members?mkey=<sni>
                        # Each result has an "id" (the sub-key) and a
                        # "local-cert" field naming the certificate it uses.
                        for SNI in $SNI_NAMES; do
                            SNI_JSON=$(curl -k --location -g --request GET "${CMDB_SNI_BASE}/members?mkey=${SNI}" \
                                --header "Authorization: $AUTH_TOKEN" \
                                --header 'Accept: application/json' \
                                --silent --show-error 2>/dev/null)

                            if [ "$HAVE_PY3" == "1" ]; then
                                # Emit the id of every member whose local-cert == OLD_CERT
                                MEMBER_IDS=$(printf '%s' "$SNI_JSON" | python3 -c '
import sys, json
target = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
res = d.get("results", []) if isinstance(d, dict) else d
if isinstance(res, dict):
    res = [res]
for m in res:
    if not isinstance(m, dict):
        continue
    if m.get("local-cert") == target:
        mid = m.get("id") or m.get("_id") or m.get("mkey")
        if mid is not None:
            print(mid)
' "$OLD_CERT" 2>/dev/null)
                            else
                                # No python3: can only detect presence, not the member id
                                MEMBER_IDS=""
                                if printf '%s' "$SNI_JSON" | grep -q "\"local-cert\"\s*:\s*\"${OLD_CERT}\""; then
                                    log_message "WARNING: SNI object '$SNI' references '$OLD_CERT' but python3 is unavailable - cannot auto-repoint the SNI member"
                                    REF_FOUND=1
                                    REF_FAILED=1
                                fi
                            fi

                            for MID in $MEMBER_IDS; do
                                REF_FOUND=1
                                log_message "Certificate '$OLD_CERT' is used by SNI '$SNI' member '$MID' - repointing local-cert to '$NEW_CERT_NAME'"
                                log_message "PUT ${CMDB_SNI_BASE}/members?mkey=${SNI}&sub_mkey=${MID} body={\"data\":{\"local-cert\":\"${NEW_CERT_NAME}\"}}"
                                SNI_PUT=$(curl -k --location -g --request PUT "${CMDB_SNI_BASE}/members?mkey=${SNI}&sub_mkey=${MID}" \
                                    --header "Authorization: $AUTH_TOKEN" \
                                    --header 'Accept: application/json' \
                                    --header 'Content-Type: application/json' \
                                    --data "{\"data\":{\"local-cert\":\"${NEW_CERT_NAME}\"}}" \
                                    --write-out "\nHTTP_STATUS:%{http_code}" \
                                    --silent --show-error 2>&1)
                                SNI_PUT_STATUS=$(echo "$SNI_PUT" | grep "HTTP_STATUS:" | cut -d':' -f2)
                                log_message "SNI repoint HTTP Status: $SNI_PUT_STATUS"
                                log_message "SNI repoint Response: $(echo "$SNI_PUT" | sed '/HTTP_STATUS:/d')"
                                if [ "$SNI_PUT_STATUS" == "200" ]; then
                                    log_message "SNI '$SNI' member '$MID' successfully repointed to '$NEW_CERT_NAME'"
                                else
                                    log_message "ERROR: Failed to repoint SNI '$SNI' member '$MID'"
                                    REF_FAILED=1
                                fi
                            done
                        done

                        # ---- (1b) Multi-cert groups that reference the old cert
                        # A dual-algorithm domain references the cert via the
                        # group's rsa-cert / ecc-cert / dsa-cert field. Swap
                        # whichever field points at the old cert to the new one
                        # (same algorithm, guaranteed by the pkey_type scoping).
                        for MLG in $MULTILOCAL_NAMES; do
                            MLG_JSON=$(curl -k --location -g --request GET "${CMDB_MULTILOCAL_BASE}?mkey=${MLG}" \
                                --header "Authorization: $AUTH_TOKEN" \
                                --header 'Accept: application/json' \
                                --silent --show-error 2>/dev/null)
                            for FIELD in rsa-cert ecc-cert dsa-cert; do
                                FIELD_VAL=$(printf '%s' "$MLG_JSON" | grep -oP "\"${FIELD}\"\s*:\s*\"\K[^\"]+" | head -n1)
                                if [ "$FIELD_VAL" == "$OLD_CERT" ]; then
                                    REF_FOUND=1
                                    log_message "Certificate '$OLD_CERT' is used by multi-cert group '$MLG' field '$FIELD' - repointing to '$NEW_CERT_NAME'"
                                    log_message "PUT ${CMDB_MULTILOCAL_BASE}?mkey=${MLG} body={\"data\":{\"${FIELD}\":\"${NEW_CERT_NAME}\"}}"
                                    MLG_PUT=$(curl -k --location -g --request PUT "${CMDB_MULTILOCAL_BASE}?mkey=${MLG}" \
                                        --header "Authorization: $AUTH_TOKEN" \
                                        --header 'Accept: application/json' \
                                        --header 'Content-Type: application/json' \
                                        --data "{\"data\":{\"${FIELD}\":\"${NEW_CERT_NAME}\"}}" \
                                        --write-out "\nHTTP_STATUS:%{http_code}" \
                                        --silent --show-error 2>&1)
                                    MLG_PUT_STATUS=$(echo "$MLG_PUT" | grep "HTTP_STATUS:" | cut -d':' -f2)
                                    log_message "Multi-cert repoint HTTP Status: $MLG_PUT_STATUS"
                                    log_message "Multi-cert repoint Response: $(echo "$MLG_PUT" | sed '/HTTP_STATUS:/d')"
                                    if [ "$MLG_PUT_STATUS" == "200" ]; then
                                        log_message "Multi-cert group '$MLG' field '$FIELD' successfully repointed to '$NEW_CERT_NAME'"
                                    else
                                        log_message "ERROR: Failed to repoint multi-cert group '$MLG' field '$FIELD'"
                                        REF_FAILED=1
                                    fi
                                fi
                            done
                        done

                        # ---- (2) Server policies bound directly to the cert ---
                        for POL in $POLICY_NAMES; do
                            POL_CERT=$(curl -k --location -g --request GET "${CMDB_POLICY_BASE}?mkey=${POL}" \
                                --header "Authorization: $AUTH_TOKEN" \
                                --header 'Accept: application/json' \
                                --silent --show-error 2>/dev/null \
                                | grep -oP '"certificate"\s*:\s*"\K[^"]+' | head -n1)
                            log_message "Policy '$POL' certificate field = '${POL_CERT:-<none>}'"
                            if [ "$POL_CERT" == "$OLD_CERT" ]; then
                                REF_FOUND=1
                                log_message "Certificate '$OLD_CERT' is bound to server policy '$POL' - repointing to '$NEW_CERT_NAME'"
                                log_message "PUT ${CMDB_POLICY_BASE}?mkey=${POL} body={\"data\":{\"certificate\":\"${NEW_CERT_NAME}\"}}"
                                REBIND_RESPONSE=$(curl -k --location -g --request PUT "${CMDB_POLICY_BASE}?mkey=${POL}" \
                                    --header "Authorization: $AUTH_TOKEN" \
                                    --header 'Accept: application/json' \
                                    --header 'Content-Type: application/json' \
                                    --data "{\"data\":{\"certificate\":\"${NEW_CERT_NAME}\"}}" \
                                    --write-out "\nHTTP_STATUS:%{http_code}" \
                                    --silent --show-error 2>&1)
                                REBIND_STATUS=$(echo "$REBIND_RESPONSE" | grep "HTTP_STATUS:" | cut -d':' -f2)
                                log_message "Rebind HTTP Status: $REBIND_STATUS"
                                log_message "Rebind Response: $(echo "$REBIND_RESPONSE" | sed '/HTTP_STATUS:/d')"
                                if [ "$REBIND_STATUS" == "200" ]; then
                                    log_message "Policy '$POL' successfully repointed to '$NEW_CERT_NAME'"
                                else
                                    log_message "ERROR: Failed to repoint policy '$POL'"
                                    REF_FAILED=1
                                fi
                            fi
                        done

                        if [ "$REF_FOUND" == "1" ]; then
                            log_message "Waiting 2 seconds for FortiWeb to apply the new binding(s)..."
                            sleep 2
                        else
                            log_message "Certificate '$OLD_CERT' is not referenced by any policy or SNI object"
                        fi

                        # Only delete once every reference was cleared successfully
                        if [ "$REF_FAILED" == "1" ]; then
                            log_message "ERROR: One or more references to '$OLD_CERT' could not be repointed - leaving it in place for manual review"
                            continue
                        fi

                        # Safety gate: FortiWeb exposes "can_delete" per cert, which
                        # is false while the cert is still referenced by ANY object
                        # (including object types this script does not scan). If it
                        # is still false after our repoints, do NOT attempt deletion.
                        if [ "$HAVE_PY3" == "1" ]; then
                            CAN_DELETE=$(get_cert_list_json 2>/dev/null | python3 -c '
import sys, json
target = sys.argv[1]
try:
    d = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit(0)
res = d.get("results", []) if isinstance(d, dict) else d
for c in (res if isinstance(res, list) else [res]):
    if isinstance(c, dict) and target in (c.get("name"), c.get("_id"), c.get("mkey")):
        print("yes" if c.get("can_delete") else "no"); sys.exit(0)
print("absent")
' "$OLD_CERT" 2>/dev/null)
                            log_message "Pre-delete can_delete check for '$OLD_CERT': ${CAN_DELETE:-unknown}"
                            if [ "$CAN_DELETE" == "no" ]; then
                                log_message "SKIP: '$OLD_CERT' still reports can_delete=false (an object we did not repoint still references it) - leaving it in place for manual review"
                                continue
                            elif [ "$CAN_DELETE" == "absent" ]; then
                                log_message "'$OLD_CERT' no longer present - nothing to delete"
                                continue
                            fi
                        fi

                        # Old cert is now unreferenced (or never was) -> delete it
                        log_message "Deleting old certificate: $OLD_CERT"
                        log_message "DELETE ${CMDB_CERT_BASE}?mkey=${OLD_CERT}"
                        DEL_RESPONSE=$(curl -k --location -g --request DELETE "${CMDB_CERT_BASE}?mkey=${OLD_CERT}" \
                            --header "Authorization: $AUTH_TOKEN" \
                            --header 'Accept: application/json' \
                            --write-out "\nHTTP_STATUS:%{http_code}" \
                            --silent --show-error 2>&1)
                        DEL_STATUS=$(echo "$DEL_RESPONSE" | grep "HTTP_STATUS:" | cut -d':' -f2)
                        if [ "$DEL_STATUS" == "200" ]; then
                            log_message "SUCCESS: Old certificate '$OLD_CERT' deleted"
                        else
                            log_message "WARNING: Could not delete old certificate '$OLD_CERT' (HTTP $DEL_STATUS): $(echo "$DEL_RESPONSE" | sed '/HTTP_STATUS:/d')"
                        fi
                    done
                fi

                log_message "FortiWeb certificate rotation completed"

                # Optional: log any returned details from the import response
                if [ ! -z "$RESPONSE_BODY" ]; then
                    log_message "FortiWeb Response Details:"
                    log_message "$RESPONSE_BODY"
                fi
            else
                log_message "ERROR: Failed to upload certificate to FortiWeb"
                log_message "HTTP Status: $HTTP_STATUS"
                log_message "Error Response: $RESPONSE_BODY"

                # Provide troubleshooting information
                if [ "$HTTP_STATUS" == "401" ]; then
                    log_message "Authentication failed - please verify the authorization token"
                elif [ "$HTTP_STATUS" == "400" ]; then
                    log_message "Bad request - the certificate/key may be invalid, or the name already exists"
                elif [ "$HTTP_STATUS" == "404" ]; then
                    log_message "API endpoint not found - please verify the FortiWeb URL and API path"
                elif [ -z "$HTTP_STATUS" ]; then
                    log_message "Connection failed - please verify the FortiWeb URL and network connectivity"
                    log_message "Full curl output: $CURL_RESPONSE"
                fi
            fi
            
        else
            log_message "ERROR: Certificate or key file not found"
            log_message "  Certificate exists: $([ -f "$CRT_FILE_PATH" ] && echo "Yes" || echo "No")"
            log_message "  Key exists: $([ -f "$KEY_FILE_PATH" ] && echo "Yes" || echo "No")"
            log_message "Skipping FortiWeb upload - required files not available"
        fi
    fi
fi

# Optional: Verify certificate was imported by querying FortiWeb API
if [ ! -z "$FORTIWEB_URL" ] && [ ! -z "$AUTH_TOKEN" ] && [ "$HTTP_STATUS" == "200" -o "$HTTP_STATUS" == "201" ]; then
    log_message "Attempting to verify certificate import..."
    
    VERIFY_ENDPOINT="https://${FORTIWEB_URL}:8443/api/v2.0/system/certificate.local"
    
    VERIFY_RESPONSE=$(curl -k --location -g --request GET "$VERIFY_ENDPOINT" \
        --header "Authorization: $AUTH_TOKEN" \
        --header 'Accept: application/json' \
        --silent \
        --show-error \
        2>&1)
    
    if [ $? -eq 0 ]; then
        log_message "Certificate list retrieved from FortiWeb"
        # You could parse this response to confirm the certificate was added
        # log_message "Certificates on FortiWeb: $VERIFY_RESPONSE"
    else
        log_message "Could not verify certificate import (non-critical)"
    fi
fi

log_message "FortiWeb certificate upload section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0