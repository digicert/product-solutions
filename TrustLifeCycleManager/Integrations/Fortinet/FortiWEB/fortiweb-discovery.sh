#!/bin/bash
#
# fortiweb-discovery.sh
# ---------------------
# Read-only helper for inspecting a FortiWeb appliance's certificate,
# server-policy and SNI configuration via the REST API. Use it to confirm
# object names, field names and the nested SNI member structure that
# fortiweb-awr.sh relies on for certificate rotation.
#
# Everything here is GET-only EXCEPT the optional `sni-put-test` command,
# which performs a reversible PUT to validate the repoint body format.
#
# LOCAL/MANUAL USE ONLY. This script is NOT part of the Trust Lifecycle
# Manager automation and is never uploaded to or executed by TLM - TLM runs
# fortiweb-awr.sh only, which is fully self-contained. Run this from your own
# machine when setting up or debugging a FortiWeb environment.
#
# SECURITY: TOKEN is read from the environment and used only in the curl
# Authorization header - it is never written to a log or echoed. Two things to
# keep in mind: (1) the token base64-decodes to admin credentials, so treat it
# as a password; (2) while curl runs, the token is briefly visible in the
# process list (ps) on a shared host. Prefer a dedicated, least-privilege API
# admin, and avoid pasting captured output/shell history into shared channels.
#
# Usage:
#   export FWB="your-fortiweb-host"        # host only, no scheme
#   export TOKEN="your-auth-token"         # same value TLM passes as Argument_2
#   ./fortiweb-discovery.sh certs
#   ./fortiweb-discovery.sh policies
#   ./fortiweb-discovery.sh sni                       # list SNI objects
#   ./fortiweb-discovery.sh sni-members <sni-name>    # members of one SNI object
#   ./fortiweb-discovery.sh multi-local               # list multi-cert (RSA/ECC) groups
#   ./fortiweb-discovery.sh multi-local-obj <name>    # one multi-cert group in full
#   ./fortiweb-discovery.sh policy <policy-name>      # one policy in full
#   ./fortiweb-discovery.sh all                       # certs + policies + sni
#   ./fortiweb-discovery.sh sni-put-test <sni> <sub_mkey> <new-cert> <orig-cert>
#                                                     # reversible repoint test

set -u

: "${FWB:?Set FWB to the FortiWeb host (no scheme), e.g. export FWB=fw.example.com}"
: "${TOKEN:?Set TOKEN to the FortiWeb API authorization token}"

BASE="https://${FWB}:8443/api/v2.0"
AUTH=(-H "Authorization: ${TOKEN}" -H 'Accept: application/json')

# Pretty-print JSON if python3 is available, otherwise pass through raw
pp() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool 2>/dev/null || cat
    else
        cat
    fi
}

get() {
    echo "GET $1" >&2
    curl -k --location -g --silent --show-error "${AUTH[@]}" "$1" | pp
    echo
}

case "${1:-}" in
    certs)
        get "${BASE}/system/certificate.local"
        ;;
    policies)
        get "${BASE}/cmdb/server-policy/policy"
        ;;
    policy)
        get "${BASE}/cmdb/server-policy/policy?mkey=${2:?policy name required}"
        ;;
    sni)
        get "${BASE}/cmdb/system/certificate.sni"
        ;;
    sni-members)
        get "${BASE}/cmdb/system/certificate.sni/members?mkey=${2:?sni object name required}"
        ;;
    multi-local)
        get "${BASE}/cmdb/system/certificate.multi-local"
        ;;
    multi-local-obj)
        get "${BASE}/cmdb/system/certificate.multi-local?mkey=${2:?multi-local group name required}"
        ;;
    all)
        get "${BASE}/system/certificate.local"
        get "${BASE}/cmdb/server-policy/policy"
        get "${BASE}/cmdb/system/certificate.sni"
        ;;
    sni-put-test)
        SNI="${2:?sni name required}"; SUB="${3:?sub_mkey required}"
        NEWC="${4:?new cert name required}"; ORIG="${5:?original cert name required}"
        URL="${BASE}/cmdb/system/certificate.sni/members?mkey=${SNI}&sub_mkey=${SUB}"
        echo "PUT (repoint -> ${NEWC})" >&2
        curl -k --location -g --silent --show-error "${AUTH[@]}" \
            -H 'Content-Type: application/json' -X PUT "$URL" \
            --data "{\"data\":{\"local-cert\":\"${NEWC}\"}}" -w '\nHTTP:%{http_code}\n'
        echo "--- verify ---" >&2
        get "${BASE}/cmdb/system/certificate.sni/members?mkey=${SNI}"
        echo "PUT (revert -> ${ORIG})" >&2
        curl -k --location -g --silent --show-error "${AUTH[@]}" \
            -H 'Content-Type: application/json' -X PUT "$URL" \
            --data "{\"data\":{\"local-cert\":\"${ORIG}\"}}" -w '\nHTTP:%{http_code}\n'
        ;;
    *)
        grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
