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

# VMware Avi Load Balancer: DigiCert TLM AWR post-delivery script for Linux.
# Revision: 2026-11-17-v5.3 (multi-VS and SNI binding; logging update).
# Save and transfer as UTF-8 without BOM, with Unix LF line endings.
#
# PURPOSE
# Upload/reuse the delivered certificate and associate it with one or more
# explicitly selected Virtual Services on the same Controller and tenant.
# Supports normal VSs, SNI children, and explicitly selected SNI parents.
# Enhanced Virtual Hosting (EVH) is not supported by this version.
#
# AWR ARGUMENTS (order matters; arguments 1 through 6 are required)
#  1 Controller hostname/IPv4[:port], without scheme or path.
#    Example: avi-controller.example.com
#  2 API username.
#  3 API password. Configure it in TLM; do not hardcode it in this script.
#  4 Tenant name. All selected Virtual Services must belong to this tenant.
#  5 Comma-separated Virtual Service names and/or UUIDs.
#    Example: web-vs,api-vs,portal-vs
#    A single name/UUID is also accepted. Spaces around entries are trimmed.
#    Dots, hyphens and underscores are allowed, e.g. www.example.com_VIP.
#    Semicolons, empty entries and control characters are rejected.
#    For a VS name containing a comma or semicolon, use its UUID instead.
#  6 Certificate object name prefix, e.g. tlm-web.
#    Use 1-40 letters, digits, underscores or hyphens. Keep this prefix stable
#    across reruns so an existing object for the same certificate can be reused.
#  7 Replacement selector (applies to EVERY selected VS needing an update):
#    AUTO_SINGLE (default): each VS must have exactly one certificate bound.
#    slot:N: replace the same zero-based position on each VS, e.g. slot:0.
#    Old certificate name/UUID: must occur exactly once on each applicable VS.
#    NONE: bind only to an empty certificate list; never replaces a binding.
#    VSs already associated with the new certificate object are skipped.
#  8 Mode: dry-run (default) or apply.
#  9 API version: defaults to 30.2.2. Set the appropriate version for the
#    target Controller; compatibility with other releases must be validated.
# 10 Optional PEM CA bundle path on the Agent for Controller HTTPS trust.
#
# SNI TARGET SELECTION
# - To update only an SNI child, list only that child in argument 5.
# - To update both child and parent, list both explicitly, separated by a comma.
# - The child may have no services/ports of its own. Its parent is read via GET
#   to validate the TLS listener; this read does not select the parent for update.
# - A parent is modified ONLY when explicitly included in argument 5.
# - Sharing the old certificate object never implicitly selects other VSs.
#   Existing certificate objects are retained, not overwritten in place.
#
# TLM SETUP AND EXECUTION
# - Upload this file as a new post-delivery script and select it in the AWR
#   enrollment profile. Configure the arguments in the order documented above.
# - Use PEM .crt delivery with exactly one matching, unencrypted PEM .key.
#   Optional PEM intermediate files ending in _ica.cer or _ica.crt are included.
# - The API account needs read access to selected VSs, their SNI parents and
#   certificate objects, plus permission to create certificate objects and
#   modify the bindings of the explicitly selected VSs.
# - After accepting the Legal Notice above, set LEGAL_NOTICE_ACCEPT="true"
#   below. Preserve Unix LF line endings when editing or transferring the file.
# - Start with argument 8 = dry-run, review the plan, then use apply.
# - Verify that the certificate SANs cover the DNS names of all target services.
# - Read /AWR/logs/avi-upload.log for the per-VS results. Override this default
#   using the AVI_LOGFILE environment variable if a different path is needed.
#   The Agent process must be able to create/write the log and snapshot files.
#   Each line carries a UTC timestamp and run id. The log records inputs, tool
#   versions, the selected certificate, each API call (method, path, HTTP
#   status), the plan, snapshots, writes and a per-VS RESULT line. It never
#   records the password, private key, cookies, CSRF token or response bodies.
# - INPUT_CHECK reports only the argument type, length, comma count and any
#   prohibited character positions/codepoints, not complete parameter values.
#   Examples: CR=13, LF=10, TAB=9, SEMICOLON=59. INPUT_RUNTIME records the
#   script revision, jq executable and jq version for troubleshooting.
# - A failure stops execution. Earlier successful bindings remain applied;
#   there is no automatic rollback or atomic transaction across VSs.
#   Inspect Controller state before retrying, especially after a timeout.
# - Dry-run does not verify write permissions or perform an endpoint TLS probe.
#   After apply, verify the certificate presented over HTTPS with the correct
#   hostname/SNI for each target. Configuration readback is not a traffic test.
#
# BEHAVIOR
# Preflight checks ALL unique targets before any certificate upload or PATCH.
# Deduplicates names/UUIDs resolving to the same VS. Uploads/reuses one shared
# certificate object, then changes each requested VS sequentially.
# Stops at the first failure and reports updated, unchanged and remaining VSs.
# Uses immutable/versioned certificate objects to avoid changing other VSs.
# Does NOT change SSL profiles, enable TLS listeners, or configure SNI topology.
# Dry-run authenticates and reads configuration but performs no API writes.
# Do not run concurrent writers against the same Virtual Service.
# Requires Linux, Bash 4+, curl, jq, OpenSSL, base64, mktemp, date, awk, sed,
# and the standard utilities used below (including GNU-compatible sort -V).

set -Eeuo pipefail
umask 077
LEGAL_NOTICE_ACCEPT="false"   # Set true after accepting the notice above.
SCRIPT_REVISION=2026-11-17-v5.3
LOGFILE="${AVI_LOGFILE:-/AWR/logs/avi-upload.log}"
# Fail visibly if the log cannot be written; every later message goes there.
if ! { mkdir -p -- "$(dirname -- "$LOGFILE")" && touch "$LOGFILE" && chmod 600 "$LOGFILE"; } 2>/dev/null; then
    printf 'AVI AWR ERROR: cannot create or write log file %s; set AVI_LOGFILE to a path the Agent account can write.\n' "$LOGFILE" >&2
    exit 1
fi
WORK_DIR=$(mktemp -d)
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
PHASE=INPUT; ACTIVE_TARGET=-1; SUMMARY_READY=false; MODE=unknown
declare -a TARGETS=() VS_IDS=() BEFORE_LIST=() INDEX_LIST=() STATUS=() SNAPSHOTS=() TOPOLOGY_LIST=()
log_message() { printf '[%s] [run=%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$RUN_ID" "$*" >> "$LOGFILE"; }
# Log only curl's own "curl: (N) reason" line (DNS, TLS trust, proxy, timeout).
# --silent --show-error prints no request or response data, but filter anyway.
curl_reason() {
    local reason
    reason=$(grep -m1 -E '^curl: \([0-9]+\)' "$1" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-240) || true
    printf '%s' "${reason:-no curl diagnostic}"
}
# Classify errors using only static labels. Never print the response body:
# appliance error messages may echo certificates, cookies or credentials.
error_category() {
    jq -Rrs 'ascii_downcase | if test("csrf|cross.site request forgery") then "CSRF_SESSION: Controller reports CSRF rejection; check session/token and request origin" elif test("permission|privilege|rbac|not authorized|not authorised|access denied|authorization failed|authorisation failed") then "AUTHORIZATION: Controller reports denied permissions; check account role and tenant/object scope" elif test("tenant") then "TENANT_SCOPE: Controller mentions tenant; check tenant access and object scope" elif test("session.*expir|authentication|not authenticated|login required") then "AUTHENTICATION: Controller reports an authentication/session problem" elif test("method not allowed|unsupported method") then "HTTP_METHOD: Controller reports an unsupported HTTP method" else "UNCLASSIFIED: consult Controller API/audit logs for the exact reason" end' "$1" 2>/dev/null || printf '%s' 'UNCLASSIFIED: error response could not be classified'
}
die() { log_message "ERROR: $*"; printf 'AVI AWR ERROR: %s (see %s)\n' "$*" "$LOGFILE" >&2; exit 1; }
finish() {
    local rc=$? i state result
    trap - EXIT
    set +e
    if [[ "$SUMMARY_READY" == true ]]; then
        if (( rc != 0 && ACTIVE_TARGET >= 0 )); then
            case "${STATUS[$ACTIVE_TARGET]}" in
                PATCH_ATTEMPTED) STATUS[$ACTIVE_TARGET]=FAILED_OR_UNCONFIRMED ;;
                PENDING|READY|ALREADY_ASSOCIATED) STATUS[$ACTIVE_TARGET]=FAILED ;;
            esac
        fi
        result=FAILED; (( rc == 0 )) && result=SUCCESS
        log_message "SUMMARY: result=$result mode=$MODE phase=$PHASE targets=${#TARGETS[@]} exit=$rc"
        printf 'AVI AWR %s: mode=%s, targets=%s, phase=%s (see %s)\n' "$result" "$MODE" "${#TARGETS[@]}" "$PHASE" "$LOGFILE"
        for i in "${!TARGETS[@]}"; do
            state=${STATUS[$i]}
            if (( rc != 0 )); then
                case "$state" in READY|PENDING) state=NOT_ATTEMPTED ;; esac
            fi
            log_message "RESULT: VS=${TARGETS[$i]} uuid=${VS_IDS[$i]:-unresolved} status=$state"
            printf 'VS=%s: %s\n' "${TARGETS[$i]}" "$state"
        done
        if (( rc != 0 )); then
            printf 'Stopped. Earlier successful changes remain; no automatic rollback. Inspect Controller and log before retrying.\n'
        fi
    fi
    rm -rf -- "$WORK_DIR"
    exit "$rc"
}
trap finish EXIT
trap 'rc=$?; log_message "ERROR: Unexpected failure at line $LINENO (exit $rc) in phase $PHASE. Check Controller state before retrying if a write was attempted."; printf "AVI AWR ERROR: unexpected failure at line %s (exit %s); see %s\n" "$LINENO" "$rc" "$LOGFILE" >&2; exit "$rc"' ERR
log_message "=========================================="
log_message "INIT: revision=$SCRIPT_REVISION pid=$$ user=$(id -un 2>/dev/null || printf unknown) log=$LOGFILE"
[[ "$LEGAL_NOTICE_ACCEPT" == true ]] || die 'Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT="true" after accepting the legal notice.'
log_message 'LEGAL_NOTICE: accepted (LEGAL_NOTICE_ACCEPT="true").'
for cmd in curl jq openssl base64 mktemp date awk sed cmp tr find sort cat; do
    command -v "$cmd" >/dev/null || die "Missing command: $cmd"
done
[[ -n "${DC1_POST_SCRIPT_DATA:-}" ]] || die 'DC1_POST_SCRIPT_DATA is missing.'
printf '%s' "$DC1_POST_SCRIPT_DATA" | base64 -d > "$WORK_DIR/request.json" || die 'Invalid base64 AWR data.'
jq -e 'type == "object" and (.args | type == "array") and (.files | type == "array") and (.certfolder | type == "string")' "$WORK_DIR/request.json" >/dev/null || die 'Invalid AWR JSON schema.'
arg() { jq -r --argjson i "$1" '.args[$i] // empty' "$WORK_DIR/request.json"; }
CONTROLLER=$(arg 0); AVI_USER=$(arg 1); AVI_PASSWORD=$(arg 2)
TENANT=$(arg 3); VS_SELECTOR=$(arg 4); NAME_PREFIX=$(arg 5)
SELECTOR=$(arg 6); SELECTOR=${SELECTOR:-AUTO_SINGLE}
MODE=$(arg 7); MODE=${MODE:-dry-run}
API_VERSION=$(arg 8); API_VERSION=${API_VERSION:-30.2.2}
CA_BUNDLE=$(arg 9)
[[ -n "$CONTROLLER" && -n "$AVI_USER" && -n "$AVI_PASSWORD" && -n "$TENANT" && -n "$VS_SELECTOR" && -n "$NAME_PREFIX" ]] || die 'Arguments 1 through 6 are required.'
[[ "$CONTROLLER" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die 'Controller must be hostname/IPv4[:port], without scheme/path.'
[[ "$API_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid API version.'
[[ "$NAME_PREFIX" =~ ^[a-zA-Z0-9_-]{1,40}$ ]] || die 'Certificate prefix must be 1-40 letters, digits, underscores or hyphens.'
[[ "$MODE" == dry-run || "$MODE" == apply ]] || die 'Mode must be dry-run or apply.'
for header in "$TENANT" "$AVI_USER"; do [[ "$header" != *$'\n'* && "$header" != *$'\r'* ]] || die 'Invalid newline in input.'; done
# Reject malformed lists BEFORE contacting the Controller. A comma in an AVI
# object name is intentionally not CSV-escaped; use that object's UUID.
JQ_EXECUTABLE=$(command -v jq)
JQ_VERSION=$(jq --version 2>/dev/null || printf '%s' unknown)
log_message "INPUT_RUNTIME: revision=$SCRIPT_REVISION bash=$BASH_VERSION jq=$JQ_EXECUTABLE version=$JQ_VERSION curl=$(curl --version 2>/dev/null | awk 'NR==1 {print $2}') openssl=$(openssl version 2>/dev/null | awk '{print $2}')"
# Do not conflate jq execution errors with invalid input. This report contains
# NO parameter values: only type, counts and prohibited codepoints/positions.
# Keep control characters rejected rather than silently changing VS names.
if ARG5_REPORT=$(jq -c '.args[4] | if type != "string" then {type:type,characters:null,commas:null,invalid:[]} else {type:type,characters:length,commas:([explode[] | select(. == 44)] | length),invalid:([explode | to_entries[] | select(.value == 59 or .value < 32 or .value == 127) | {position:(.key+1),codepoint:.value,kind:(if .value == 13 then "CR" elif .value == 10 then "LF" elif .value == 9 then "TAB" elif .value == 59 then "SEMICOLON" elif .value == 127 then "DEL" else "CONTROL" end)}])} end' "$WORK_DIR/request.json" 2> "$WORK_DIR/arg5-jq-error"); then
    :
else
    JQ_STATUS=$?
    die "Argument 5 validator could not execute (jq exit $JQ_STATUS; executable $JQ_EXECUTABLE). This is not evidence of invalid VS characters. No Controller calls made."
fi
log_message "INPUT_CHECK: $ARG5_REPORT"
printf 'AVI AWR INPUT_CHECK: %s\n' "$ARG5_REPORT"
if ARG5_TYPE=$(jq -r '.type' <<< "$ARG5_REPORT" 2>/dev/null) && ARG5_BAD_COUNT=$(jq -r '.invalid | length' <<< "$ARG5_REPORT" 2>/dev/null); then
    :
else
    die 'Unable to interpret argument 5 validation report; check jq in the Agent execution environment.'
fi
[[ "$ARG5_TYPE" == string ]] || die 'Argument 5 must be a string.'
[[ "$ARG5_BAD_COUNT" =~ ^[0-9]+$ ]] || die 'Unexpected argument 5 validation report; check jq in the Agent execution environment.'
[[ "$ARG5_BAD_COUNT" == 0 ]] || die 'Argument 5 contains prohibited characters. See INPUT_CHECK positions/codepoints. Dots, hyphens and underscores are allowed.'
jq '.args[4] | split(",") | map(gsub("^ +| +$"; ""))' "$WORK_DIR/request.json" > "$WORK_DIR/targets.json"
jq -e 'length > 0 and all(.[]; length > 0)' "$WORK_DIR/targets.json" >/dev/null || die 'Argument 5 contains an empty entry (check repeated/trailing commas).'
mapfile -t TARGETS < <(jq -r '.[]' "$WORK_DIR/targets.json")
for i in "${!TARGETS[@]}"; do STATUS[$i]=PENDING; done
SUMMARY_READY=true
log_message "START: revision=$SCRIPT_REVISION mode=$MODE controller=$CONTROLLER api_version=$API_VERSION tenant=$TENANT selector=$SELECTOR prefix=$NAME_PREFIX requested_targets=${#TARGETS[@]}"
TLS_OPTIONS=()
if [[ -n "$CA_BUNDLE" ]]; then
    [[ -r "$CA_BUNDLE" ]] || die 'CA bundle is not readable.'
    TLS_OPTIONS=(--cacert "$CA_BUNDLE")
    log_message "TLS_TRUST: CA bundle $CA_BUNDLE"
else
    log_message 'TLS_TRUST: system trust store (argument 10 not set)'
fi
CERT_FOLDER=$(jq -r '.certfolder' "$WORK_DIR/request.json")
[[ -d "$CERT_FOLDER" ]] || die 'AWR certificate directory does not exist.'
# Only accept basenames from the AWR file manifest, not arbitrary paths.
jq -e '.files | all(.[]; type == "string" and length > 0 and (contains("/") | not) and (contains("\\") | not) and . != "..")' "$WORK_DIR/request.json" >/dev/null || die 'AWR files must be basenames.'
mapfile -t KEYS < <(jq -r '.files[] | select(endswith(".key"))' "$WORK_DIR/request.json")
[[ ${#KEYS[@]} == 1 ]] || die 'Exactly one .key file must be delivered.'
KEY_PATH="$CERT_FOLDER/${KEYS[0]}"
# Empty passphrase deliberately rejects encrypted keys rather than prompting.
openssl pkey -in "$KEY_PATH" -passin pass: -pubout -out "$WORK_DIR/key.pub" 2>/dev/null || die 'Private key is unreadable or encrypted; deliver an unencrypted PEM key.'
MATCHES=0; CRT_PATH=''
while IFS= read -r file; do
    candidate="$CERT_FOLDER/$file"
    if openssl x509 -in "$candidate" -pubkey -noout > "$WORK_DIR/cert.pub" 2>/dev/null && cmp -s "$WORK_DIR/key.pub" "$WORK_DIR/cert.pub"; then
        CRT_PATH="$candidate"; MATCHES=$((MATCHES+1))
    fi
done < <(jq -r '.files[] | select(endswith(".crt"))' "$WORK_DIR/request.json")
[[ "$MATCHES" == 1 ]] || die 'Expected exactly one PEM .crt matching the delivered private key.'
openssl x509 -in "$CRT_PATH" -checkend 0 -noout >/dev/null || die 'Delivered certificate has expired.'
fingerprint() { openssl x509 -in "$1" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]'; }
FINGERPRINT=$(fingerprint "$CRT_PATH")
CERT_NAME="${NAME_PREFIX}-${FINGERPRINT}"
# Build full chain: leaf .crt (possibly already a bundle), plus *_ica.cer/crt.
# De-duplicate PEM certificates by DER fingerprint. Ignore unrelated files.
cat "$CRT_PATH" > "$WORK_DIR/chain-input.pem"
while IFS= read -r file; do
    [[ "$CERT_FOLDER/$file" == "$CRT_PATH" ]] && continue
    printf '\n' >> "$WORK_DIR/chain-input.pem"
    cat "$CERT_FOLDER/$file" >> "$WORK_DIR/chain-input.pem"
done < <(jq -r '.files[] | select(endswith("_ica.cer") or endswith("_ica.crt"))' "$WORK_DIR/request.json")
awk -v dir="$WORK_DIR" '/-----BEGIN CERTIFICATE-----/ {n++; f=dir "/part-" n ".pem"} f != "" {print > f} /-----END CERTIFICATE-----/ {close(f); f=""}' "$WORK_DIR/chain-input.pem"
: > "$WORK_DIR/fullchain.pem"
declare -A SEEN=()
# Version-sort ensures leaf stays first even with more than nine chain entries.
while IFS= read -r part; do
    fp=$(fingerprint "$part") || die 'Invalid PEM certificate in chain.'
    if [[ -z "${SEEN[$fp]:-}" ]]; then cat "$part" >> "$WORK_DIR/fullchain.pem"; SEEN[$fp]=1; fi
done < <(find "$WORK_DIR" -maxdepth 1 -name 'part-*.pem' | sort -V)
[[ -s "$WORK_DIR/fullchain.pem" ]] || die 'No PEM certificates found.'
CHAIN_COUNT=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$WORK_DIR/fullchain.pem" || true)
CERT_SUBJECT=$(openssl x509 -in "$CRT_PATH" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//' | tr -d '\000-\037\177')
CERT_NOT_AFTER=$(openssl x509 -in "$CRT_PATH" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
CERT_SERIAL=$(openssl x509 -in "$CRT_PATH" -noout -serial 2>/dev/null | sed 's/^serial=//')
log_message "CERT_SELECTED: file=$(basename -- "$CRT_PATH") key=${KEYS[0]} subject=$CERT_SUBJECT serial=$CERT_SERIAL not_after=$CERT_NOT_AFTER SHA256=$FINGERPRINT chain_certs=$CHAIN_COUNT object_name=$CERT_NAME"
COOKIE_FILE="$WORK_DIR/cookies"
# Build password-bearing JSON from a private request file, not command arguments.
jq '{username:.args[1], password:.args[2]}' "$WORK_DIR/request.json" > "$WORK_DIR/login.json"
log_message "LOGIN: POST https://$CONTROLLER/login"
if CODE=$(curl --silent --show-error --connect-timeout 15 --max-time 90 "${TLS_OPTIONS[@]}" --cookie-jar "$COOKIE_FILE" -H 'Content-Type: application/json' --data-binary "@$WORK_DIR/login.json" --output "$WORK_DIR/login-response" --write-out '%{http_code}' "https://$CONTROLLER/login" 2> "$WORK_DIR/curl-stderr"); then
    :
else
    CURL_STATUS=$?
    die "Controller login transport failure (curl exit $CURL_STATUS: $(curl_reason "$WORK_DIR/curl-stderr")). Check reachability, DNS, proxy and TLS trust (argument 10)."
fi
[[ "$CODE" == 200 ]] || die "Controller login failed (HTTP $CODE). $(error_category "$WORK_DIR/login-response")."
log_message "LOGIN: succeeded (HTTP 200)"
refresh_csrf() {
    CSRF=$(awk '$6 == "csrftoken" {v=$7} END {print v}' "$COOKIE_FILE")
    [[ -n "$CSRF" ]] || die 'No CSRF cookie in the current Controller session.'
}
refresh_csrf
api() {
    local method=$1 path=$2 output=$3 data=${4:-} code category curl_status
    refresh_csrf
    local opts=(--silent --show-error --connect-timeout 15 --max-time 90 "${TLS_OPTIONS[@]}"
        --cookie "$COOKIE_FILE" --cookie-jar "$COOKIE_FILE" -H 'Content-Type: application/json' -H "X-CSRFToken: $CSRF"
        -H "X-Avi-Version: $API_VERSION" -H "X-Avi-Tenant: $TENANT" -H "Referer: https://$CONTROLLER/"
        --request "$method" --output "$output" --write-out '%{http_code}')
    [[ -z "$data" ]] || opts+=(--data-binary "@$data")
    # Log the path without its query string (names are logged elsewhere).
    if code=$(curl "${opts[@]}" "https://$CONTROLLER$path" 2> "$WORK_DIR/curl-stderr"); then
        :
    else
        curl_status=$?
        die "$method ${path%%\?*} transport failure (curl exit $curl_status: $(curl_reason "$WORK_DIR/curl-stderr")); check Controller state before retrying a write."
    fi
    if [[ ! "$code" =~ ^2[0-9][0-9]$ ]]; then
        category=$(error_category "$output")
        die "$method ${path%%\?*} failed (HTTP $code). $category. No automatic retry or fallback."
    fi
    log_message "API: $method ${path%%\?*} HTTP $code"
    jq -e 'type == "object"' "$output" >/dev/null || die 'Non-JSON API response.'
}
resolve() {
    local kind=$1 selector=$2 output=$3 encoded
    if [[ "$selector" =~ ^${kind}-[a-fA-F0-9-]+$ ]]; then
        api GET "/api/$kind/$selector" "$output"
    else
        encoded=$(jq -nr --arg s "$selector" '$s | @uri')
        api GET "/api/$kind?name=$encoded&page_size=2" "$WORK_DIR/lookup.json"
        jq -e --arg n "$selector" '.count == 1 and (.results | length) == 1 and .results[0].name == $n' "$WORK_DIR/lookup.json" >/dev/null || die "No unique $kind match for the specified selector."
        jq '.results[0]' "$WORK_DIR/lookup.json" > "$output"
    fi
    local resolved_uuid
    resolved_uuid=$(jq -r '.uuid // empty' "$output")
    [[ "$resolved_uuid" =~ ^${kind}-[a-fA-F0-9-]+$ ]] || die 'API object has no valid UUID.'
}
refs() { jq -c '[.ssl_key_and_certificate_refs[]? | split("/")[-1] | split("?")[0]]' "$1"; }
# Validation never changes the binding target. For SNI, only the TLS listener
# check follows vh_parent_vs_ref, using a GET on this Controller/tenant.
# A parent may be PATCHed ONLY if explicitly selected as its own target.
# Never update an existing shared certificate object in place.
validate_vs() {
    local file=$1 expected_uuid=$2 vs_type parent_uuid='' parent_file
    [[ $(jq -r '.uuid // empty' "$file") == "$expected_uuid" ]] || die 'Virtual Service response UUID mismatch.'
    vs_type=$(jq -r '.type // "VS_TYPE_NORMAL"' "$file")
    case "$vs_type" in
        VS_TYPE_NORMAL)
            jq -e 'any(.services[]?; .enable_ssl == true)' "$file" >/dev/null || die 'Selected Virtual Service has no TLS-enabled listener; configure it first.'
            ;;
        VS_TYPE_VH_CHILD)
            [[ $(jq -r '.vh_type // "VS_TYPE_VH_SNI"' "$file") == VS_TYPE_VH_SNI ]] || die 'Only SNI children are supported; Enhanced Virtual Hosting (EVH) is not supported.'
            # Accept AVI absolute/relative object references, but never follow
            # an arbitrary reference host or query. Fetch the UUID locally.
            if parent_uuid=$(jq -er '.vh_parent_vs_ref | select(type == "string") | capture("^(?:https?://[^/\\s?#]+)?/api/virtualservice/(?<uuid>virtualservice-[a-fA-F0-9-]+)(?:\\?[^\\s#]*)?\\z") | .uuid' "$file" 2>/dev/null); then
                :
            else
                die 'SNI child has no valid vh_parent_vs_ref; no parent will be guessed.'
            fi
            [[ "$parent_uuid" != "$expected_uuid" ]] || die 'SNI child references itself as parent.'
            parent_file="$WORK_DIR/sni-parent.json"
            log_message "SNI_PARENT_CHECK: child=$expected_uuid parent=$parent_uuid action=GET_ONLY. Parent read access is required."
            api GET "/api/virtualservice/$parent_uuid" "$parent_file"
            jq -e --arg u "$parent_uuid" '.uuid == $u and .type == "VS_TYPE_VH_PARENT"' "$parent_file" >/dev/null || die 'SNI parent response has an unexpected UUID or Virtual Service type.'
            [[ $(jq -r '.vh_type // "VS_TYPE_VH_SNI"' "$parent_file") == VS_TYPE_VH_SNI ]] || die 'Referenced parent is not SNI; Enhanced Virtual Hosting (EVH) is not supported.'
            jq -e 'any(.services[]?; .enable_ssl == true)' "$parent_file" >/dev/null || die 'SNI parent has no TLS-enabled listener; child binding was not attempted.'
            log_message "SNI_VALIDATED: binding_target=$expected_uuid listener_parent=$parent_uuid. This validation reads the parent only; writes remain limited to explicitly selected targets."
            ;;
        VS_TYPE_VH_PARENT)
            # This branch is reached only for an explicit target from arg 5.
            [[ $(jq -r '.vh_type // "VS_TYPE_VH_SNI"' "$file") == VS_TYPE_VH_SNI ]] || die 'Only SNI parents are supported; Enhanced Virtual Hosting (EVH) is not supported.'
            jq -e 'any(.services[]?; .enable_ssl == true)' "$file" >/dev/null || die 'Explicitly selected SNI parent has no TLS-enabled listener.'
            log_message "SNI_PARENT_TARGET: parent=$expected_uuid explicitly selected in argument 5. Its certificate binding is included; unlisted children are not modified."
            ;;
        *) die 'Unsupported Virtual Service type; refusing to change bindings.' ;;
    esac
    jq -e '(.ssl_key_and_certificate_refs // []) | type == "array" and all(.[]; type == "string")' "$file" >/dev/null || die 'Invalid Virtual Service certificate reference list.'
    VALIDATED_TOPOLOGY="$vs_type:$parent_uuid"
}

PHASE=PREFLIGHT
NEW_UUID=''
ENCODED_NAME=$(jq -nr --arg s "$CERT_NAME" '$s | @uri')
api GET "/api/sslkeyandcertificate?name=$ENCODED_NAME&page_size=2" "$WORK_DIR/existing.json"
EXISTING_COUNT=$(jq -r '.count // -1' "$WORK_DIR/existing.json")
if [[ "$EXISTING_COUNT" == 1 ]]; then
    jq -e --arg n "$CERT_NAME" '(.results | length) == 1 and .results[0].name == $n' "$WORK_DIR/existing.json" >/dev/null || die 'Certificate lookup is ambiguous.'
    jq -r '.results[0].certificate.certificate // empty' "$WORK_DIR/existing.json" > "$WORK_DIR/existing.pem"
    [[ $(fingerprint "$WORK_DIR/existing.pem") == "$FINGERPRINT" ]] || die 'Versioned name exists with a different certificate.'
    NEW_UUID=$(jq -r '.results[0].uuid' "$WORK_DIR/existing.json")
    [[ "$NEW_UUID" =~ ^sslkeyandcertificate-[a-fA-F0-9-]+$ ]] || die 'Invalid existing certificate UUID.'
    log_message "CERTIFICATE_LOOKUP: object $CERT_NAME already exists (uuid=$NEW_UUID, same SHA256); it will be reused."
elif [[ "$EXISTING_COUNT" != 0 ]]; then
    die 'Certificate lookup is ambiguous or missing its count.'
else
    log_message "CERTIFICATE_LOOKUP: object $CERT_NAME not found; it will be uploaded in apply mode."
fi
declare -A SEEN_VS=()
UPDATES=0; OLD_UUID=''
for i in "${!TARGETS[@]}"; do
    ACTIVE_TARGET=$i
    log_message "Preflight: target=${TARGETS[$i]}"
    VS_FILE="$WORK_DIR/vs-$i.json"
    resolve virtualservice "${TARGETS[$i]}" "$VS_FILE"
    VS_UUID=$(jq -r '.uuid' "$VS_FILE")
    VS_IDS[$i]=$VS_UUID
    if [[ -n "${SEEN_VS[$VS_UUID]:-}" ]]; then
        STATUS[$i]=DUPLICATE_SKIPPED
        log_message "Duplicate target skipped: VS=$VS_UUID selector=${TARGETS[$i]}"
        continue
    fi
    SEEN_VS[$VS_UUID]=1
    validate_vs "$VS_FILE" "$VS_UUID"
    TOPOLOGY_LIST[$i]=$VALIDATED_TOPOLOGY
    BEFORE=$(refs "$VS_FILE")
    BEFORE_LIST[$i]=$BEFORE
    COUNT=$(jq 'length' <<< "$BEFORE")
    if [[ -n "$NEW_UUID" ]] && jq -e --arg u "$NEW_UUID" 'index($u) != null' <<< "$BEFORE" >/dev/null; then
        STATUS[$i]=ALREADY_ASSOCIATED
        log_message "Already associated: VS=$VS_UUID certificate=$NEW_UUID SHA256=$FINGERPRINT. No changes planned."
        continue
    fi
    INDEX=''
    case "$SELECTOR" in
        NONE) [[ "$COUNT" == 0 ]] || die 'NONE only permits an empty certificate list.' ;;
        AUTO_SINGLE) [[ "$COUNT" == 1 ]] || die 'AUTO_SINGLE requires exactly one bound certificate on each target. Select slot:N or an old certificate explicitly.'; INDEX=0 ;;
        slot:*) INDEX=${SELECTOR#slot:}; [[ "$INDEX" =~ ^(0|[1-9][0-9]*)$ && ${#INDEX} -lt 8 ]] || die 'Invalid slot index.'; (( INDEX < COUNT )) || die 'Slot index out of range.' ;;
        *) if [[ -z "$OLD_UUID" ]]; then
               resolve sslkeyandcertificate "$SELECTOR" "$WORK_DIR/old.json"
               OLD_UUID=$(jq -r '.uuid' "$WORK_DIR/old.json")
           fi
           jq --arg u "$OLD_UUID" '[to_entries[] | select(.value == $u) | .key]' <<< "$BEFORE" > "$WORK_DIR/indices.json"
           jq -e 'length == 1' "$WORK_DIR/indices.json" >/dev/null || die 'Specified old certificate must be bound exactly once to each target needing an update.'
           INDEX=$(jq -r '.[0]' "$WORK_DIR/indices.json") ;;
    esac
    INDEX_LIST[$i]=$INDEX
    STATUS[$i]=READY
    UPDATES=$((UPDATES+1))
    log_message "Plan: mode=$MODE tenant=$TENANT VS=$VS_UUID selector=$SELECTOR new_object=$CERT_NAME SHA256=$FINGERPRINT previous_refs=$BEFORE"
done
ACTIVE_TARGET=-1
log_message "PREFLIGHT completed: unique_targets=${#SEEN_VS[@]} updates=$UPDATES. No certificate upload or binding changes yet."
if [[ "$MODE" == dry-run ]]; then
    for i in "${!TARGETS[@]}"; do
        if [[ "${STATUS[$i]}" == READY ]]; then STATUS[$i]=PLANNED; fi
    done
    PHASE=DRY_RUN_DONE
    log_message 'DRY-RUN completed. No certificate uploaded and no Virtual Service modified. This does not validate write permissions or endpoint TLS.'
    exit 0
fi
# Recheck the whole plan before any write. This also detects a change to a VS
# that was already associated during preflight. Snapshots contain no keys.
PHASE=PREWRITE
for i in "${!TARGETS[@]}"; do
    [[ "${STATUS[$i]}" == DUPLICATE_SKIPPED ]] && continue
    ACTIVE_TARGET=$i
    VS_UUID=${VS_IDS[$i]}
    api GET "/api/virtualservice/$VS_UUID" "$WORK_DIR/recheck-$i.json"
    validate_vs "$WORK_DIR/recheck-$i.json" "$VS_UUID"
    [[ "$VALIDATED_TOPOLOGY" == "${TOPOLOGY_LIST[$i]}" ]] || die 'Virtual Service type or SNI parent changed after preflight; refusing to start writes.'
    [[ $(refs "$WORK_DIR/recheck-$i.json") == "${BEFORE_LIST[$i]}" ]] || { STATUS[$i]=FAILED; die 'Bindings changed after preflight; refusing to start writes.'; }
    if [[ "${STATUS[$i]}" == READY ]]; then
        SNAPSHOT="$(dirname -- "$LOGFILE")/avi-binding-${VS_UUID}-${RUN_ID}.json"
        jq '{uuid, name, tenant_ref, type, vh_type, vh_parent_vs_ref, ssl_key_and_certificate_refs:(.ssl_key_and_certificate_refs // [])}' "$WORK_DIR/recheck-$i.json" > "$SNAPSHOT"
        chmod 600 "$SNAPSHOT"
        SNAPSHOTS[$i]=$SNAPSHOT
        log_message "Previous bindings saved to $SNAPSHOT"
    fi
done
ACTIVE_TARGET=-1
if (( UPDATES == 0 )); then
    PHASE=DONE
    log_message 'SUCCESS: all unique targets already associated. No API writes.'
    exit 0
fi
PHASE=CERTIFICATE
if [[ -z "$NEW_UUID" ]]; then
    jq -n --arg n "$CERT_NAME" --rawfile c "$WORK_DIR/fullchain.pem" --rawfile k "$KEY_PATH" '{name:$n, type:"SSL_CERTIFICATE_TYPE_VIRTUALSERVICE", certificate:{certificate:$c}, key:$k}' > "$WORK_DIR/upload.json"
    api POST /api/sslkeyandcertificate "$WORK_DIR/upload-response.json" "$WORK_DIR/upload.json"
    NEW_UUID=$(jq -r '.uuid // empty' "$WORK_DIR/upload-response.json")
    [[ "$NEW_UUID" =~ ^sslkeyandcertificate-[a-fA-F0-9-]+$ ]] || die 'Upload did not return a valid certificate UUID.'
    log_message "CERTIFICATE_UPLOADED: name=$CERT_NAME uuid=$NEW_UUID chain_certs=$CHAIN_COUNT"
else
    log_message "CERTIFICATE_REUSED: name=$CERT_NAME uuid=$NEW_UUID"
fi
# Verify the shared object BEFORE binding any targets to it.
api GET "/api/sslkeyandcertificate/$NEW_UUID" "$WORK_DIR/verified-cert.json"
jq -r '.certificate.certificate // empty' "$WORK_DIR/verified-cert.json" > "$WORK_DIR/verified-cert.pem"
[[ $(fingerprint "$WORK_DIR/verified-cert.pem") == "$FINGERPRINT" ]] || die 'Installed object certificate does not match the delivered certificate. Inspect Controller.'
log_message "CERTIFICATE_VERIFIED: uuid=$NEW_UUID SHA256=$FINGERPRINT"
PHASE=BINDING
for i in "${!TARGETS[@]}"; do
    [[ "${STATUS[$i]}" == READY ]] || continue
    ACTIVE_TARGET=$i
    VS_UUID=${VS_IDS[$i]}; BEFORE=${BEFORE_LIST[$i]}; INDEX=${INDEX_LIST[$i]}
    log_message "Binding: target=${TARGETS[$i]} VS=$VS_UUID"
    # Recheck immediately before PATCH as well as before the overall batch.
    # This reduces races but cannot eliminate them without an atomic API guard.
    api GET "/api/virtualservice/$VS_UUID" "$WORK_DIR/current.json"
    validate_vs "$WORK_DIR/current.json" "$VS_UUID"
    [[ "$VALIDATED_TOPOLOGY" == "${TOPOLOGY_LIST[$i]}" ]] || die 'Virtual Service type or SNI parent changed concurrently; refusing to overwrite.'
    [[ $(refs "$WORK_DIR/current.json") == "$BEFORE" ]] || die 'Bindings changed concurrently; refusing to overwrite. Earlier changes remain; newly uploaded object may remain unbound.'
    if [[ "$SELECTOR" == NONE ]]; then
        jq -n --arg u "$NEW_UUID" '{replace:{ssl_key_and_certificate_refs:["/api/sslkeyandcertificate/"+$u]}}' > "$WORK_DIR/patch.json"
    else
        # Preserve all unselected references exactly, including absolute URLs.
        jq --arg u "$NEW_UUID" --argjson i "$INDEX" '{replace:{ssl_key_and_certificate_refs:(.ssl_key_and_certificate_refs | .[$i] = ("/api/sslkeyandcertificate/"+$u))}}' "$WORK_DIR/current.json" > "$WORK_DIR/patch.json"
    fi
    AFTER=$(jq -c '[.replace.ssl_key_and_certificate_refs[] | split("/")[-1] | split("?")[0]]' "$WORK_DIR/patch.json")
    STATUS[$i]=PATCH_ATTEMPTED
    api PATCH "/api/virtualservice/$VS_UUID" "$WORK_DIR/patch-response.json" "$WORK_DIR/patch.json"
    api GET "/api/virtualservice/$VS_UUID" "$WORK_DIR/verified.json"
    validate_vs "$WORK_DIR/verified.json" "$VS_UUID"
    [[ "$VALIDATED_TOPOLOGY" == "${TOPOLOGY_LIST[$i]}" ]] || die 'Virtual Service topology changed during binding verification; inspect Controller.'
    [[ $(refs "$WORK_DIR/verified.json") == "$AFTER" ]] || die "Binding verification failed. No automatic rollback; inspect Controller and snapshot ${SNAPSHOTS[$i]}."
    STATUS[$i]=UPDATED
    log_message "SUCCESS: certificate=$NEW_UUID bound to VS=$VS_UUID. Previous objects retained. Verify endpoint TLS/SNI separately."
done
ACTIVE_TARGET=-1; PHASE=DONE
log_message "SUCCESS: batch completed; updated=$UPDATES unique_targets=${#SEEN_VS[@]} certificate=$NEW_UUID SHA256=$FINGERPRINT. Verify endpoint TLS/SNI separately."
