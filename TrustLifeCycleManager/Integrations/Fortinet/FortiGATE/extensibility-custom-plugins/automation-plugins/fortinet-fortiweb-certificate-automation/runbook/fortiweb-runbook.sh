#!/bin/bash
#
# fortiweb-runbook.sh
# -------------------
# Manual companion to RUNBOOK.md: performs, one sub-command at a time, the same
# FortiWeb REST API calls the TLM FortiWeb automation plugin makes, so the whole
# lifecycle can be rehearsed by hand before the plugin is uploaded to TLM.
#
# LOCAL/MANUAL USE ONLY - never uploaded to or executed by TLM.
#
# Read-only sub-commands:  token  test  certs  refs  download-test  tls  candelete  confirm  validate
# Local-only sub-commands: csr  selfsign  name
# Writing sub-commands (ask for confirmation unless -y is given): import  repoint  delete
#
# Setup:
#   export FWB="fortiweb-host"          # host only, no scheme / port
#   export PORT="443"                   # optional, defaults to 443
#   export SSH_PORT="22"                # optional, for cli-certs
#   export FWB_USER="admin"; export FWB_PASS='secret'; export VDOM="root"
#   #  ...or export TOKEN="<base64 token>" to reuse an existing token instead of user/pass
#
# Usage:
#   ./fortiweb-runbook.sh token                              # show decoded token (password masked) + base URL
#   ./fortiweb-runbook.sh test                               # step 1  - GET certificate list (testConnection)
#   ./fortiweb-runbook.sh certs                              # step 2a - local certificates, key fields summarised
#   ./fortiweb-runbook.sh refs [cert]                        # step 2b - policy / SNI / multi-local references
#   ./fortiweb-runbook.sh download-test <cert>               # step 2c - try the PEM download/view endpoints
#   ./fortiweb-runbook.sh cli-certs                          # step 2c - SSH "show system certificate local" (what the plugin runs)
#   ./fortiweb-runbook.sh download-probe <cert>              # step 2d - brute-force the REST download endpoint's argument shape
#   ./fortiweb-runbook.sh tls <ip> <port> [sni]              # step 2c - certificate served by a VIP
#   ./fortiweb-runbook.sh csr <cn> [san1,san2,...] [rsa:2048|ec:256]   # step 3 - key + CSR into ./work
#   ./fortiweb-runbook.sh selfsign                           # step 3  - dry-run: self-sign ./work/request.csr
#   ./fortiweb-runbook.sh name <cert.crt>                    # step 4a - unique name the plugin would use
#   ./fortiweb-runbook.sh import <cert.crt> <key> [name]     # step 4b - multipart import under that name
#   ./fortiweb-runbook.sh confirm <name>                     # step 4c - entry as stored by FortiWeb
#   ./fortiweb-runbook.sh repoint <old> <new>                # step 5a - repoint every reference of <old>
#   ./fortiweb-runbook.sh candelete <cert>                   # step 5b - can_delete / q_ref gate
#   ./fortiweb-runbook.sh delete <cert>                      # step 5b - DELETE (only if can_delete)
#   ./fortiweb-runbook.sh validate <name> [leaf.crt]         # step 6  - status OK + serial comparison
#
# Add -y as the FIRST argument to skip confirmation prompts on writing commands.

set -u

YES=0
if [ "${1:-}" = "-y" ]; then YES=1; shift; fi

: "${FWB:?Set FWB to the FortiWeb host (no scheme), e.g. export FWB=fw.example.com}"
PORT="${PORT:-443}"
VDOM="${VDOM:-root}"
if [ -z "${TOKEN:-}" ]; then
    : "${FWB_USER:?Set FWB_USER and FWB_PASS (or TOKEN)}"
    : "${FWB_PASS:?Set FWB_USER and FWB_PASS (or TOKEN)}"
    # Same construction as AdapterConfig.authorizationToken(): base64 of the credential JSON.
    # python3 is used when present so quotes/backslashes in the password are JSON-escaped.
    if command -v python3 >/dev/null 2>&1; then
        TOKEN=$(FWB_USER="$FWB_USER" FWB_PASS="$FWB_PASS" VDOM="$VDOM" python3 -c '
import os, json, base64
j = json.dumps({"username": os.environ["FWB_USER"], "password": os.environ["FWB_PASS"], "vdom": os.environ["VDOM"]}, separators=(",", ":"))
print(base64.b64encode(j.encode()).decode())')
    else
        TOKEN=$(printf '{"username":"%s","password":"%s","vdom":"%s"}' "$FWB_USER" "$FWB_PASS" "$VDOM" | base64 | tr -d '\n')
    fi
fi

BASE="https://${FWB}:${PORT}/api/v2.0"
AUTH=(-H "Authorization: ${TOKEN}" -H 'Accept: application/json')
WORK="${WORK:-./work}"

have_py() { command -v python3 >/dev/null 2>&1; }
pp() { if have_py; then python3 -m json.tool 2>/dev/null || cat; else cat; fi; }

# GET helper: prints the URL to stderr, body to stdout
get() {
    echo "GET $1" >&2
    curl -k --location -g --silent --show-error "${AUTH[@]}" "$1"
}
get_status() {   # like get, but appends HTTP:<code>
    echo "GET $1" >&2
    curl -k --location -g --silent --show-error "${AUTH[@]}" "$1" -w '\nHTTP:%{http_code}\n'
}
names_of() {     # names (mkey/name/_id) from a CMDB list body on stdin
    grep -oP '"(?:mkey|name|_id)"\s*:\s*"\K[^"]+' | sort -u
}
confirm() {
    [ "$YES" = "1" ] && return 0
    read -r -p "$1 [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}
need() { [ -n "${!1:-}" ] || { echo "ERROR: $2" >&2; exit 2; }; }

# ---------------------------------------------------------------------------
cmd_token() {
    echo "Base URL : $BASE"
    echo "Token    : (base64, ${#TOKEN} chars - not printed)"
    echo -n "Decoded  : "
    echo "$TOKEN" | base64 -d 2>/dev/null | sed -E 's/("password":")([^"\\]|\\.)*/\1********/'
    echo
}

cmd_test() {
    OUT=$(get_status "$BASE/system/certificate.local")
    CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
    BODY=$(echo "$OUT" | sed '/^HTTP:/d')
    echo "HTTP $CODE"
    if [ "$CODE" = "200" ] && ! echo "$BODY" | grep -qE '"errcode"\s*:\s*-'; then
        COUNT=$(echo "$BODY" | grep -o '"name"' | wc -l | tr -d ' ')
        echo "PASS: testConnection would report active ($COUNT local certificate(s))"
    elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
        echo "FAIL: UNAUTHORIZED - check FWB_USER/FWB_PASS/VDOM and the admin profile"
    else
        echo "FAIL: FORTIWEB_API_ERROR - body follows"; echo "$BODY" | pp
    fi
}

cmd_certs() {
    BODY=$(get "$BASE/system/certificate.local")
    if have_py; then
        echo "$BODY" | python3 -c '
import sys, json, re
d = json.load(sys.stdin); res = d.get("results", d)
res = res if isinstance(res, list) else [res]
print(f"{len(res)} local certificate(s)\n")
for c in res:
    m = re.search(r"CN\s*=\s*([^,/]+)", c.get("subject") or "")
    cn = m.group(1).strip() if m else "?"
    self_signed = (c.get("issuer") or "").strip().lower() == (c.get("subject") or "").strip().lower()
    print(f"name={c.get('name')!r} cn={cn!r} selfSigned={self_signed} pkey_type={c.get('pkey_type')} "
          f"status={c.get('status')} serial={c.get('serialNumber')!r} validTo={c.get('validTo')!r} "
          f"q_ref={c.get('q_ref')} can_delete={c.get('can_delete')}")
print("\n-- raw --")
print(json.dumps(d, indent=2))'
    else
        echo "$BODY"
    fi
}

# Print every reference; with a cert name, only references to it. Emits lines:
#   POLICY <policy> <cert>  |  SNI <sni> <member-id> <cert>  |  MULTI <group> <field> <cert>
scan_refs() {
    local FILTER="${1:-}"
    for P in $(get "$BASE/cmdb/server-policy/policy" | names_of); do
        J=$(get "$BASE/cmdb/server-policy/policy?mkey=$P")
        C=$(echo "$J" | grep -oP '"certificate"\s*:\s*"\K[^"]*' | head -n1)
        echo "policy '$P': certificate='${C:-}' certificate-type='$(echo "$J" | grep -oP '"certificate-type"\s*:\s*"\K[^"]*' | head -n1)' sni-certificate='$(echo "$J" | grep -oP '"sni-certificate"\s*:\s*"\K[^"]*' | head -n1)' multi-certificate='$(echo "$J" | grep -oP '"multi-certificate"\s*:\s*"\K[^"]*' | head -n1)' vserver='$(echo "$J" | grep -oP '"vserver"\s*:\s*"\K[^"]*' | head -n1)' https-service='$(echo "$J" | grep -oP '"https-service"\s*:\s*"\K[^"]*' | head -n1)'" >&2
        if [ -n "$C" ] && { [ -z "$FILTER" ] || [ "$C" = "$FILTER" ]; }; then echo "POLICY $P $C"; fi
    done
    for S in $(get "$BASE/cmdb/system/certificate.sni" | names_of); do
        J=$(get "$BASE/cmdb/system/certificate.sni/members?mkey=$S")
        if have_py; then
            echo "$J" | python3 -c '
import sys, json
sni, flt = sys.argv[1], sys.argv[2]
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
res = d.get("results", d); res = res if isinstance(res, list) else [res]
for m in res:
    if not isinstance(m, dict): continue
    mid = m.get("id") or m.get("_id") or m.get("mkey"); cert = m.get("local-cert") or ""
    print(f"sni {sni!r} member {mid!r} domain={m.get('domain')!r} local-cert={cert!r} multi-local-cert-group={m.get('multi-local-cert-group')!r}", file=sys.stderr)
    if cert and (not flt or cert == flt) and mid is not None: print(f"SNI {sni} {mid} {cert}")' "$S" "$FILTER"
        else
            echo "  (python3 missing - raw SNI members for $S)" >&2; echo "$J" >&2
        fi
    done
    for G in $(get "$BASE/cmdb/system/certificate.multi-local" | names_of); do
        J=$(get "$BASE/cmdb/system/certificate.multi-local?mkey=$G")
        for F in rsa-cert ecc-cert dsa-cert; do
            V=$(echo "$J" | grep -oP "\"${F}\"\s*:\s*\"\K[^\"]+" | head -n1)
            [ -n "$V" ] && echo "multi-local '$G': $F='$V'" >&2
            if [ -n "$V" ] && { [ -z "$FILTER" ] || [ "$V" = "$FILTER" ]; }; then echo "MULTI $G $F $V"; fi
        done
    done
}

cmd_refs() {
    local FILTER="${1:-}"
    echo "== scanning references${FILTER:+ to '$FILTER'} =="
    REFS=$(scan_refs "$FILTER")
    echo
    if [ -z "$REFS" ]; then
        echo "No references${FILTER:+ to '$FILTER'} found (plugin would skip the repoint phase)."
    else
        echo "References${FILTER:+ to '$FILTER'}:"; echo "$REFS" | sed 's/^/  /'
    fi
}

cmd_download_test() {
    need 1 "certificate name required"
    for U in "$BASE/system/certificate.local.download?mkey=$1" \
             "$BASE/system/certificate.local.download?mkey=$1&type=certificate" \
             "$BASE/system/certificate.local.view?mkey=$1"; do
        OUT=$(get_status "$U")
        CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
        if echo "$OUT" | grep -q "BEGIN CERTIFICATE"; then
            echo "HTTP $CODE - PEM FOUND via $U"
            echo "$OUT" | sed '/^HTTP:/d' | sed 's/\\n/\n/g' | grep -A100 "BEGIN CERTIFICATE" | grep -B100 -m1 "END CERTIFICATE" | openssl x509 -noout -subject -serial 2>/dev/null
            return 0
        fi
        echo "HTTP $CODE - no PEM in body: $(echo "$OUT" | sed '/^HTTP:/d' | tr -d '\n' | head -c 200)"
    done
    echo "RESULT: certificate body not retrievable via the management API (plugin surfaces metadata only, or falls back to TLS for policy-bound certs)"
}

# Probe the parameter shape of certificate.local.download (the endpoint exists on 8.0.5 - it
# answers errcode -20007 "invalid argument" to mkey=<name> - but the accepted arguments are not
# documented). Reports every variant that returns a PEM, or any answer other than -20007/-20001.
cmd_download_probe() {
    need 1 "certificate name required"
    local N="$1" HITS=0 COUNT=0 TOTAL
    # One line per request: verdict, HTTP code, errcode (if any), URL. Verdicts:
    #   PEM  = body contains a certificate      ???  = accepted the arguments (errcode other than -20007/-20001)
    #   arg  = -20007 invalid argument          url  = -20001 invalid URL       (both = try the next variant)
    probe_one() {   # <method> <url> [json-body]
        local M="$1" URL="$2" B="${3:-}" OUT CODE BODY EC V
        if [ "$M" = "POST" ]; then
            OUT=$(curl -k --location -g --silent --max-time 15 "${AUTH[@]}" -H 'Content-Type: application/json' -X POST "$URL" --data "$B" -w '\nHTTP:%{http_code}')
        else
            OUT=$(curl -k --location -g --silent --max-time 15 "${AUTH[@]}" "$URL" -w '\nHTTP:%{http_code}')
        fi
        CODE=$(echo "$OUT" | tail -n1 | cut -d: -f2); [ -z "$CODE" ] && CODE="timeout"
        BODY=$(echo "$OUT" | sed '$d')
        EC=$(echo "$BODY" | grep -oE '"errcode":\s*"?-?[0-9]+' | head -n1 | grep -oE '\-?[0-9]+$')
        if echo "$BODY" | grep -q "BEGIN CERTIFICATE"; then V="PEM"; HITS=$((HITS+1))
        elif [ "$EC" = "-20007" ]; then V="arg"
        elif [ "$EC" = "-20001" ]; then V="url"
        else V="???"; fi
        COUNT=$((COUNT+1))
        printf '[%3d/%d] %-3s HTTP %-7s errcode %-7s %s %s%s\n' "$COUNT" "$TOTAL" "$V" "$CODE" "${EC:--}" "$M" "$URL" "${B:+ body=$B}"
        if [ "$V" = "???" ] || [ "$V" = "PEM" ]; then echo "         -> $(echo "$BODY" | tr -d '\n' | head -c 300)"; fi
    }
    local PATHS=("system/certificate.local.download" "system/certificate.local.export" "system/certificate.local.get_certificate")
    local KEYS=(mkey name _id id)
    local TYPES=("" "type=certificate" "type=cert" "type=local" "type=crt" "type=pem" "type=csr" "type=0" "type=1" "format=pem")
    local POST_BODIES=("{\"mkey\":\"$N\"}" "{\"name\":\"$N\"}" "{\"data\":{\"mkey\":\"$N\"}}" "{\"data\":{\"name\":\"$N\",\"type\":\"certificate\"}}" "{\"mkey\":\"$N\",\"type\":\"certificate\"}")
    TOTAL=$(( ${#PATHS[@]} * ${#KEYS[@]} * ${#TYPES[@]} + 2 * ${#POST_BODIES[@]} ))
    echo "== probing $TOTAL variants (each request capped at 15 s; a full run is ~1-2 minutes on a slow appliance) =="
    for P in "${PATHS[@]}"; do
      for K in "${KEYS[@]}"; do
        for T in "${TYPES[@]}"; do
            probe_one GET "$BASE/$P?$K=$N${T:+&$T}"
        done
      done
    done
    for P in "system/certificate.local.download" "system/certificate.local.export"; do
      for B in "${POST_BODIES[@]}"; do
        probe_one POST "$BASE/$P" "$B"
      done
    done
    echo "== done: $HITS variant(s) returned a PEM =="
    [ "$HITS" = "0" ] && echo "No PEM. Any line marked ??? got past argument validation - share those lines so the plugin can be adjusted."
}

# Step 2c - what the plugin's FortiWebSshClient does: one read-only CLI command over SSH.
# Uses the system ssh client (prompts for the password; SSH_PORT defaults to 22).
cmd_cli_certs() {
    local P="${SSH_PORT:-22}"
    echo "ssh -p $P $FWB_USER@$FWB \"$1\"" >&2
    OUT=$(ssh -p "$P" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$FWB_USER@$FWB" "show system certificate local")
    echo "$OUT" | sed -E '/BEGIN (ENCRYPTED )?PRIVATE KEY/,/END (ENCRYPTED )?PRIVATE KEY/d; /set passwd/d'
    echo
    echo "== certificates parsed the way the plugin does it =="
    echo "$OUT" | python3 -c '
import sys, re
out = sys.stdin.read().replace("\r", "")
for m in re.finditer(r"edit\s+\"([^\"]+)\"([\s\S]*?)(?:\n\s*next\b|\n\s*end\b)", out):
    name, body = m.group(1), m.group(2)
    ci, ki = body.find("set certificate"), body.find("set private-key")
    part = body[ci:(ki if ki > ci else len(body))] if ci >= 0 else ""
    pem = re.search(r"-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----", part)
    print(name + ": " + ("PEM found (" + str(len(pem.group())) + " chars)" if pem else "no certificate body (pending CSR?)"))' 2>/dev/null \
        || echo "$OUT" | grep -c "BEGIN CERTIFICATE" | sed 's/^/certificate bodies: /'
}

cmd_tls() {
    need 1 "ip required"; need 2 "port required"
    SNI="${3:-}"
    echo "TLS handshake to $1:$2${SNI:+ (SNI $SNI)}"
    openssl s_client -connect "$1:$2" ${SNI:+-servername "$SNI"} </dev/null 2>/dev/null \
        | openssl x509 -noout -subject -issuer -serial -enddate
}

cmd_csr() {
    need 1 "common name required"
    CN="$1"; SANS="${2:-$1}"; KEYSPEC="${3:-rsa:2048}"
    mkdir -p "$WORK"
    ALG="${KEYSPEC%%:*}"; BITS="${KEYSPEC##*:}"
    SAN_EXT=$(echo "$SANS" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sed 's/^/DNS:/' | paste -sd, -)
    if [ "$ALG" = "ec" ]; then
        case "$BITS" in 384) CURVE=secp384r1;; 521) CURVE=secp521r1;; *) CURVE=prime256v1;; esac
        openssl ecparam -name "$CURVE" -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$WORK/request.key"
        openssl req -new -key "$WORK/request.key" -out "$WORK/request.csr" -subj "/CN=$CN" -addext "subjectAltName=$SAN_EXT"
    else
        openssl req -new -newkey "rsa:$BITS" -nodes -keyout "$WORK/request.key" -out "$WORK/request.csr" \
            -subj "/CN=$CN" -addext "subjectAltName=$SAN_EXT" 2>/dev/null
    fi
    chmod 600 "$WORK/request.key"
    echo "Key : $WORK/request.key (PKCS#8, unencrypted - what the plugin retains per flow)"
    echo "CSR : $WORK/request.csr"
    openssl req -in "$WORK/request.csr" -noout -verify -subject -text | grep -E "verify|Subject:|DNS:|Public Key Algorithm|Public-Key"
    echo "Next: get $WORK/request.csr signed by TLM (save as $WORK/signed.crt), or run 'selfsign' for a dry run."
}

cmd_selfsign() {
    [ -f "$WORK/request.csr" ] || { echo "run 'csr' first"; exit 2; }
    openssl x509 -req -in "$WORK/request.csr" -signkey "$WORK/request.key" -days 30 -out "$WORK/signed.crt" -copy_extensions copyall 2>/dev/null \
        || openssl x509 -req -in "$WORK/request.csr" -signkey "$WORK/request.key" -days 30 -out "$WORK/signed.crt" 2>/dev/null
    echo "Self-signed test certificate: $WORK/signed.crt"
    openssl x509 -in "$WORK/signed.crt" -noout -subject -serial -enddate
}

unique_name() {   # <cert.crt> -> the name CertificateAttributesUtil.buildUniqueName would produce
    local CRT="$1"
    local CN SERIAL BASE_NAME SUFFIX MAXBASE
    CN=$(openssl x509 -in "$CRT" -noout -subject | sed -n 's/.*CN\s*=\s*//p' | sed 's/[,/].*//; s/\s*$//')
    SERIAL=$(openssl x509 -in "$CRT" -noout -serial | cut -d= -f2 | tr 'A-F' 'a-f' | sed 's/[^0-9a-f]//g')
    BASE_NAME=$(echo "${CN:-tlm_cert}" | sed 's/[^A-Za-z0-9_]/_/g; s/__*/_/g; s/^_//; s/_$//')
    SUFFIX=$(echo "$SERIAL" | tail -c 13)
    MAXBASE=$((35 - 1 - ${#SUFFIX}))
    [ ${#BASE_NAME} -gt $MAXBASE ] && BASE_NAME=$(echo "${BASE_NAME:0:$MAXBASE}" | sed 's/_$//')
    echo "${BASE_NAME}_${SUFFIX}"
}

cmd_name() {
    need 1 "certificate file required"
    echo "Unique FortiWeb name the plugin would use: $(unique_name "$1")"
}

cmd_import() {
    need 1 "certificate file required"; need 2 "key file required"
    CRT="$1"; KEY="$2"; NAME="${3:-$(unique_name "$1")}"
    echo "== before =="; BEFORE=$(get "$BASE/system/certificate.local" | names_of); echo "$BEFORE" | tr '\n' ' '; echo
    if echo "$BEFORE" | grep -qx "$NAME"; then echo "WARNING: '$NAME' already exists - FortiWeb will reject a duplicate (plugin would append _2)"; fi
    confirm "Import $CRT + $KEY as '$NAME' on $FWB?" || { echo "aborted"; exit 1; }
    STAGE=$(mktemp -d); chmod 700 "$STAGE"
    cp "$CRT" "$STAGE/$NAME.crt"; cp "$KEY" "$STAGE/$NAME.key"; chmod 600 "$STAGE/$NAME.key"
    echo "POST $BASE/system/certificate.local.import_certificate (certificateFile=$NAME.crt keyFile=$NAME.key type=certificate)"
    curl -k --location -g --silent --show-error -X POST "$BASE/system/certificate.local.import_certificate" \
        "${AUTH[@]}" -H 'Content-Type: multipart/form-data' \
        -F "certificateFile=@$STAGE/$NAME.crt" -F "keyFile=@$STAGE/$NAME.key" \
        -F 'type=certificate' -F 'hsm=undefined' -F 'password=undefined' -w '\nHTTP:%{http_code}\n'
    rm -rf "$STAGE"
    sleep 1
    echo "== after (list diff) =="; AFTER=$(get "$BASE/system/certificate.local" | names_of)
    NEW=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))
    echo "new name(s): ${NEW:-<none - import did not create a certificate>}"
    [ -n "$NEW" ] && cmd_confirm "$(echo "$NEW" | head -n1)"
}

cmd_confirm() {
    need 1 "certificate name required"
    get "$BASE/system/certificate.local" | python3 -c '
import sys, json; n = sys.argv[1]
d = json.load(sys.stdin); res = d.get("results", d); res = res if isinstance(res, list) else [res]
for c in res:
    if c.get("name") == n or c.get("_id") == n:
        print(json.dumps({k: c.get(k) for k in ("name","status","subject","serialNumber","pkey_type","validFrom","validTo","q_ref","can_delete")}, indent=2)); sys.exit(0)
print(f"NOT FOUND: {n}"); sys.exit(1)' "$1"
}

cmd_repoint() {
    need 1 "old cert name required"; need 2 "new cert name required"
    OLD="$1"; NEW="$2"
    REFS=$(scan_refs "$OLD")
    if [ -z "$REFS" ]; then echo "No references to '$OLD' - nothing to repoint (plugin would go straight to the can_delete check)"; return 0; fi
    echo "References to '$OLD':"; echo "$REFS" | sed 's/^/  /'
    NEW_PT=$(get "$BASE/system/certificate.local" | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(c.get("pkey_type",""))' "$NEW" 2>/dev/null)
    OLD_PT=$(get "$BASE/system/certificate.local" | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(c.get("pkey_type",""))' "$OLD" 2>/dev/null)
    echo "pkey_type old=$OLD_PT new=$NEW_PT"
    confirm "Repoint all of the above to '$NEW'?" || { echo "aborted"; exit 1; }
    FAIL=0
    while read -r KIND A B C; do
        case "$KIND" in
            POLICY) URL="$BASE/cmdb/server-policy/policy?mkey=$A"; BODY="{\"data\":{\"certificate\":\"$NEW\"}}";;
            SNI)    URL="$BASE/cmdb/system/certificate.sni/members?mkey=$A&sub_mkey=$B"; BODY="{\"data\":{\"local-cert\":\"$NEW\"}}";;
            MULTI)  if [ -n "$NEW_PT" ] && [ -n "$OLD_PT" ] && [ "$NEW_PT" != "$OLD_PT" ]; then
                        echo "SKIP multi-local '$A' $B: key algorithm differs (plugin refuses this repoint)"; FAIL=1; continue; fi
                    URL="$BASE/cmdb/system/certificate.multi-local?mkey=$A"; BODY="{\"data\":{\"$B\":\"$NEW\"}}";;
            *) continue;;
        esac
        echo "PUT $URL body=$BODY"
        OUT=$(curl -k --location -g --silent --show-error -X PUT "$URL" "${AUTH[@]}" -H 'Content-Type: application/json' --data "$BODY" -w '\nHTTP:%{http_code}\n')
        CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
        if [ "$CODE" = "200" ] && ! echo "$OUT" | grep -qE '"errcode"\s*:\s*-'; then echo "  -> OK"; else echo "  -> FAILED: $OUT"; FAIL=1; fi
    done <<< "$REFS"
    sleep 2
    echo "== remaining references to '$OLD' =="; scan_refs "$OLD" 2>/dev/null || true
    [ "$FAIL" = "0" ] && echo "All references repointed." || echo "Some repoints failed - the plugin would leave '$OLD' in place and report the install as failed."
}

cmd_candelete() {
    need 1 "certificate name required"
    get "$BASE/system/certificate.local" | python3 -c '
import sys, json; n = sys.argv[1]
for c in json.load(sys.stdin).get("results", []):
    if c.get("name") == n:
        ok = c.get("can_delete") if c.get("can_delete") is not None else (c.get("q_ref", 1) == 0)
        print(f"{n}: can_delete={c.get('can_delete')} q_ref={c.get('q_ref')} -> {'DELETABLE' if ok else 'STILL REFERENCED - plugin would skip deletion'}")
        sys.exit(0 if ok else 3)
print(f"{n}: not present"); sys.exit(4)' "$1"
}

cmd_delete() {
    need 1 "certificate name required"
    cmd_candelete "$1" || { echo "refusing to delete"; exit 1; }
    confirm "DELETE certificate '$1' from $FWB?" || { echo "aborted"; exit 1; }
    echo "DELETE $BASE/cmdb/system/certificate.local?mkey=$1"
    curl -k --location -g --silent --show-error -X DELETE "$BASE/cmdb/system/certificate.local?mkey=$1" "${AUTH[@]}" -w '\nHTTP:%{http_code}\n'
    sleep 1
    if get "$BASE/system/certificate.local" | names_of | grep -qx "$1"; then echo "STILL PRESENT"; else echo "Deleted: '$1' no longer listed"; fi
}

cmd_validate() {
    need 1 "certificate name required"
    cmd_confirm "$1" || exit 1
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        LEAF=$(openssl x509 -in "$2" -noout -serial | cut -d= -f2)
        FWB_SERIAL=$(get "$BASE/system/certificate.local" 2>/dev/null | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(c.get("serialNumber",""))' "$1")
        python3 -c '
import sys
a, b = sys.argv[1], sys.argv[2]
norm = lambda s: int(s.replace(":","").replace(" ","").strip() or "0", 16)
print("serial match" if norm(a)==norm(b) else f"SERIAL MISMATCH leaf={a} fortiweb={b}")' "$LEAF" "$FWB_SERIAL"
    fi
}

case "${1:-}" in
    token) cmd_token;;
    test) cmd_test;;
    certs) cmd_certs;;
    refs) cmd_refs "${2:-}";;
    download-test) cmd_download_test "${2:-}";;
    download-probe) cmd_download_probe "${2:-}";;
    cli-certs) cmd_cli_certs;;
    tls) cmd_tls "${2:-}" "${3:-}" "${4:-}";;
    csr) cmd_csr "${2:-}" "${3:-}" "${4:-}";;
    selfsign) cmd_selfsign;;
    name) cmd_name "${2:-}";;
    import) cmd_import "${2:-}" "${3:-}" "${4:-}";;
    confirm) cmd_confirm "${2:-}";;
    repoint) cmd_repoint "${2:-}" "${3:-}";;
    candelete) cmd_candelete "${2:-}";;
    delete) cmd_delete "${2:-}";;
    validate) cmd_validate "${2:-}" "${3:-}";;
    *) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac
