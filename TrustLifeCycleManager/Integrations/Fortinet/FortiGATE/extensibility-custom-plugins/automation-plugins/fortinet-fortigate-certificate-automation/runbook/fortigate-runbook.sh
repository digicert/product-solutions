#!/bin/bash
#
# fortigate-runbook.sh
# --------------------
# Manual companion to RUNBOOK.md: performs, one sub-command at a time, the same
# FortiGate (FortiOS) REST API / CLI calls the TLM FortiGate automation plugin
# makes, so the whole lifecycle can be rehearsed by hand before the plugin is
# uploaded to TLM.
#
# LOCAL/MANUAL USE ONLY - never uploaded to or executed by TLM.
#
# Read-only sub-commands:  info  test  certs  refs  cmdb-cert  download-test  cli-certs  discover  tls  candelete  confirm  validate
# Local-only sub-commands: csr  selfsign  name
# Writing sub-commands (ask for confirmation unless -y is given): import  repoint  delete
#
# Setup:
#   export FGT="fortigate-host"          # host only, no scheme / port
#   export PORT="443"                    # optional, REST API port (443 default; some labs use 8443/10443)
#   export API_TOKEN="<REST API admin token>"      # System > Administrators > Create New > REST API Admin
#   export VDOM="root"                   # optional, VDOM the connector works in (root default)
#   export SCOPE="global"                # optional, certificate scope to manage: global (default) or vdom
#   export SSH_PORT="22"                 # optional, for cli-certs / discover
#   export SSH_USER="admin"; export SSH_PASS='secret'   # optional, an interactive admin (API tokens cannot SSH)
#
# Usage:
#   ./fortigate-runbook.sh info                              # base URL, version/serial of the appliance (GET system/status)
#   ./fortigate-runbook.sh test                              # step 1  - GET certificate list (testConnection)
#   ./fortigate-runbook.sh certs                             # step 2a - local certificates (monitor + cmdb merged), key fields summarised
#   ./fortigate-runbook.sh refs [cert]                       # step 2b - every object referencing local certificates
#   ./fortigate-runbook.sh cmdb-cert <cert>                  # step 2c - the cmdb entry (does it carry the PEM in "certificate"?)
#   ./fortigate-runbook.sh download-test <cert>              # step 2c - monitor system/certificate/download
#   ./fortigate-runbook.sh cli-certs                         # step 2c - SSH "show vpn certificate local" (needs SSH_USER/SSH_PASS)
#   ./fortigate-runbook.sh discover                          # step 2  - run every discovery path and report which return a PEM
#   ./fortigate-runbook.sh tls <ip> <port> [sni]             # step 2c - certificate served by an SSL-VPN / admin / VIP endpoint
#   ./fortigate-runbook.sh csr <cn> [san1,san2,...] [rsa:2048|ec:256]   # step 3 - key + CSR into ./work
#   ./fortigate-runbook.sh selfsign                          # step 3  - dry-run: self-sign ./work/request.csr
#   ./fortigate-runbook.sh name <cert.crt>                   # step 4a - unique name the plugin would use
#   ./fortigate-runbook.sh import <cert.crt> <key> [name]    # step 4b - JSON import under that name
#   ./fortigate-runbook.sh confirm <name>                    # step 4c - entry as stored by FortiGate
#   ./fortigate-runbook.sh repoint <old> <new>               # step 5a - repoint every reference of <old>
#   ./fortigate-runbook.sh candelete <cert>                  # step 5b - q_ref gate
#   ./fortigate-runbook.sh delete <cert>                     # step 5b - DELETE (only if unreferenced)
#   ./fortigate-runbook.sh validate <name> [leaf.crt]        # step 6  - status + serial comparison
#
# Add -y as the FIRST argument to skip confirmation prompts on writing commands.

set -u

YES=0
if [ "${1:-}" = "-y" ]; then YES=1; shift; fi

: "${FGT:?Set FGT to the FortiGate host (no scheme), e.g. export FGT=fw.example.com}"
: "${API_TOKEN:?Set API_TOKEN to a FortiGate REST API admin token}"
PORT="${PORT:-443}"
VDOM="${VDOM:-root}"
SCOPE="${SCOPE:-global}"
SSH_PORT="${SSH_PORT:-22}"

BASE="https://${FGT}:${PORT}/api/v2"
AUTH=(-H "Authorization: Bearer ${API_TOKEN}" -H 'Accept: application/json')
WORK="${WORK:-./work}"

# Query string that selects the certificate scope the plugin manages: global certificates are
# addressed with scope=global, VDOM certificates with vdom=<name>.
if [ "$SCOPE" = "global" ]; then CERT_Q="scope=global"; else CERT_Q="vdom=${VDOM}"; fi
VDOM_Q="vdom=${VDOM}"

have_py() { command -v python3 >/dev/null 2>&1; }
pp() { if have_py; then python3 -m json.tool 2>/dev/null || cat; else cat; fi; }

get() {          # GET helper: URL to stderr, body to stdout
    echo "GET $1" >&2
    curl -k --location -g --silent --show-error --max-time 60 "${AUTH[@]}" "$1"
}
get_status() {   # like get, but appends HTTP:<code>
    echo "GET $1" >&2
    curl -k --location -g --silent --show-error --max-time 60 "${AUTH[@]}" "$1" -w '\nHTTP:%{http_code}\n'
}
put_json() {     # PUT <url> <json>
    echo "PUT $1 body=$2" >&2
    curl -k --location -g --silent --show-error --max-time 60 -X PUT "${AUTH[@]}" -H 'Content-Type: application/json' --data "$2" "$1" -w '\nHTTP:%{http_code}\n'
}
names_of() {     # "name" values from a cmdb / monitor list body on stdin
    python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
res = d.get("results", d); res = res if isinstance(res, list) else [res]
seen = set()
for c in res:
    if isinstance(c, dict):
        n = c.get("name") or c.get("q_origin_key") or c.get("mkey")
        if n and n not in seen: seen.add(n); print(n)' 2>/dev/null
}
confirm() {
    [ "$YES" = "1" ] && return 0
    read -r -p "$1 [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ]
}
need() { [ -n "${!1:-}" ] || { echo "ERROR: $2" >&2; exit 2; }; }
ok_body() {      # true when the FortiOS body reports success (no "status":"error")
    ! echo "$1" | grep -qE '"status"\s*:\s*"error"'
}

# ---------------------------------------------------------------------------
cmd_info() {
    echo "Base URL   : $BASE"
    echo "VDOM       : $VDOM   certificate scope: $SCOPE  (query: $CERT_Q)"
    echo "Token      : (${#API_TOKEN} chars - not printed)"
    OUT=$(get_status "$BASE/monitor/system/status?$VDOM_Q")
    CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2); BODY=$(echo "$OUT" | sed '/^HTTP:/d')
    echo "HTTP $CODE"
    echo "$BODY" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(sys.stdin.read()); sys.exit(0)
r = d.get("results", {})
print("hostname=%s version=%s build=%s serial=%s model=%s %s vdom=%s" % (r.get("hostname"), d.get("version"), d.get("build"), d.get("serial"), r.get("model_name"), r.get("model_number"), d.get("vdom")))' 2>/dev/null || echo "$BODY" | head -c 600
}

cmd_test() {
    OUT=$(get_status "$BASE/cmdb/vpn.certificate/local?$CERT_Q&with_meta=1")
    CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
    BODY=$(echo "$OUT" | sed '/^HTTP:/d')
    echo "HTTP $CODE"
    if [ "$CODE" = "200" ] && ok_body "$BODY"; then
        COUNT=$(echo "$BODY" | names_of | wc -l | tr -d ' ')
        echo "PASS: testConnection would report active ($COUNT local certificate(s) in scope $SCOPE)"
    elif [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
        echo "FAIL: UNAUTHORIZED - check API_TOKEN, the REST API admin's profile and its trusted hosts"
        echo "$BODY" | head -c 600; echo
    else
        echo "FAIL: FORTIGATE_API_ERROR - body follows"; echo "$BODY" | pp
    fi
}

# Merge monitor/system/available-certificates (rich metadata) with cmdb/vpn.certificate/local
# (q_ref, range, and - on most firmware - the PEM itself) the way FortiGateAdapter.listCertificates does.
cmd_certs() {
    MON=$(get "$BASE/monitor/system/available-certificates?$CERT_Q")
    CMDB=$(get "$BASE/cmdb/vpn.certificate/local?$CERT_Q&with_meta=1")
    if have_py; then
        MON="$MON" CMDB="$CMDB" python3 -c '
import os, sys, json
def load(s):
    try: return json.loads(s)
    except Exception: return {}
mon, cmdb = load(os.environ["MON"]), load(os.environ["CMDB"])
mres = mon.get("results", []) if isinstance(mon.get("results"), list) else []
cres = cmdb.get("results", []) if isinstance(cmdb.get("results"), list) else []
print("monitor available-certificates: status=%s entries=%d" % (mon.get("status"), len(mres)))
print("cmdb vpn.certificate/local    : status=%s http_status=%s entries=%d" % (cmdb.get("status"), cmdb.get("http_status"), len(cres)))
print()
# FortiOS 7.6 reports type "local-cer" (server certificate) / "local-ca"; older builds "local".
bymon = {c.get("name"): c for c in mres if isinstance(c, dict) and str(c.get("type", "local")).startswith("local")}
bycmdb = {c.get("name"): c for c in cres if isinstance(c, dict)}
names = list(dict.fromkeys(list(bycmdb) + list(bymon)))
print("%d local certificate(s) (scope %s); the plugin skips type local-ca entries during discovery\n" % (len(names), os.environ.get("SCOPE", "?")))
for n in names:
    m, c = bymon.get(n, {}), bycmdb.get(n, {})
    subj = m.get("subject") or {}
    cn = subj.get("CN") if isinstance(subj, dict) else subj
    # the cmdb LIST view returns "certificate": "" on 7.6 - the single-entry GET and the download endpoint carry the PEM (see discover)
    pem = "yes" if str(c.get("certificate", "")).strip().startswith("-----BEGIN") else "no"
    valid_to = m.get("valid_to_raw") if isinstance(m.get("valid_to_raw"), str) else m.get("valid_to")
    print("name=%r type=%s cn=%r source=%s range=%s key=%s/%s status=%s validTo=%r serial=%r q_ref=%s list_pem=%s is_default=%s builtin=%s ca=%s" % (
          n, m.get("type"), cn, m.get("source") or c.get("source"), c.get("range") or m.get("range"), m.get("key_type"), m.get("key_size"),
          m.get("status"), valid_to, m.get("serial_number"), c.get("q_ref", m.get("q_ref")),
          pem, m.get("is_default_local"), m.get("is_built_in"), m.get("is_ca")))
print("\n-- raw monitor --"); print(json.dumps(mon, indent=2)[:6000])
print("\n-- raw cmdb (PEM/key bodies shortened) --")
for c in cres:
    for k in ("certificate", "private-key"):
        if isinstance(c.get(k), str) and len(c[k]) > 80: c[k] = c[k][:60] + f"...({len(c[k])} chars)"
print(json.dumps(cmdb, indent=2)[:6000])'
    else
        echo "$MON"; echo; echo "$CMDB"
    fi
}

# Every place a local certificate can be referenced. Emits lines the repoint step consumes:
#   SINGLE <label> <cmdb-path> <field> <cert>           (singleton object, string field)
#   TABLE  <label> <cmdb-path> <mkey> <field> <cert> <list|string>
scan_refs() {
    local FILTER="${1:-}"
    scan_single() {   # <label> <path> <field> [query]
        local J; J=$(get "$BASE/cmdb/$2?${4:-$VDOM_Q}")
        J="$J" python3 -c '
import os, sys, json
label, path, field, flt = sys.argv[1:5]
try: d = json.loads(os.environ["J"])
except Exception: sys.exit(0)
r = d.get("results", {})
if isinstance(r, list): r = r[0] if r else {}
v = r.get(field)
names = [v] if isinstance(v, str) else [x.get("name") for x in v if isinstance(x, dict)] if isinstance(v, list) else []
print(f"{label} ({path}) {field}={v!r}", file=sys.stderr)
for n in names:
    if n and (not flt or n == flt): print(f"SINGLE {label} {path} {field} {n}")' "$1" "$2" "$3" "$FILTER"
    }
    scan_table() {    # <label> <path> <field>
        local J; J=$(get "$BASE/cmdb/$2?$VDOM_Q")
        J="$J" python3 -c '
import os, sys, json
label, path, field, flt = sys.argv[1:5]
try: d = json.loads(os.environ["J"])
except Exception: sys.exit(0)
for r in d.get("results", []) if isinstance(d.get("results"), list) else []:
    mkey = r.get("name") or r.get("q_origin_key") or r.get("mkey") or r.get("id")
    v = r.get(field)
    kind = "list" if isinstance(v, list) else "string"
    names = [v] if isinstance(v, str) else [x.get("name") for x in v if isinstance(x, dict)] if isinstance(v, list) else []
    if names: print(f"{label} {mkey!r} {field}={v!r}", file=sys.stderr)
    for n in names:
        if n and (not flt or n == flt): print(f"TABLE {label} {path} {mkey} {field} {n} {kind}")' "$1" "$2" "$3" "$FILTER"
    }
    scan_single ssl-vpn            vpn.ssl/settings              servercert
    scan_single admin-https        system/global                 admin-server-cert   "$VDOM_Q"
    scan_single user-auth          user/setting                  auth-cert
    scan_single ftm-push           system/ftm-push               server-cert
    scan_table  ipsec-phase1-if    vpn.ipsec/phase1-interface    certificate
    scan_table  ipsec-phase1       vpn.ipsec/phase1              certificate
    scan_table  firewall-vip       firewall/vip                  ssl-certificate
    scan_table  ssl-ssh-profile    firewall/ssl-ssh-profile      server-cert
}

cmd_refs() {
    local FILTER="${1:-}"
    echo "== scanning references${FILTER:+ to '$FILTER'} (vdom $VDOM) =="
    REFS=$(scan_refs "$FILTER")
    echo
    if [ -z "$REFS" ]; then
        echo "No references${FILTER:+ to '$FILTER'} found (plugin would skip the repoint phase)."
    else
        echo "References${FILTER:+ to '$FILTER'}:"; echo "$REFS" | sed 's/^/  /'
    fi
}

# Step 2c(1): the cmdb entry. On FortiOS the "certificate" attribute of vpn.certificate/local
# normally carries the PEM (the private key is returned encrypted and is never used).
cmd_cmdb_cert() {
    need 1 "certificate name required"
    OUT=$(get_status "$BASE/cmdb/vpn.certificate/local/$1?$CERT_Q&with_meta=1")
    CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2); BODY=$(echo "$OUT" | sed '/^HTTP:/d')
    echo "HTTP $CODE"
    BODY="$BODY" python3 -c '
import os, json
try: d = json.loads(os.environ["BODY"])
except Exception: print(os.environ["BODY"][:800]); raise SystemExit
r = d.get("results", {}); r = r[0] if isinstance(r, list) and r else r
pem = r.get("certificate") or ""
print("status=%s range=%s source=%s q_ref=%s comments=%r" % (d.get("status"), r.get("range"), r.get("source"), r.get("q_ref"), r.get("comments")))
print("certificate attribute: " + ("PEM (%d chars)" % len(pem) if pem.strip().startswith("-----BEGIN") else repr(pem)[:120]))
print("private-key attribute: " + ("present (encrypted, ignored)" if r.get("private-key") else "absent"))
open("/tmp/fgt_cmdb_%s.pem" % os.path.basename(os.sys.argv[1]), "w").write(pem) if pem.strip().startswith("-----BEGIN") else None' "$1"
    if [ -f "/tmp/fgt_cmdb_$1.pem" ]; then
        echo "-- parsed with openssl --"; openssl x509 -in "/tmp/fgt_cmdb_$1.pem" -noout -subject -issuer -serial -enddate -fingerprint -sha256; rm -f "/tmp/fgt_cmdb_$1.pem"
    fi
}

# Step 2c(2): the GUI's Download button - monitor/system/certificate/download.
cmd_download_test() {
    need 1 "certificate name required"
    for U in "$BASE/monitor/system/certificate/download?mkey=$1&type=local-cer&$CERT_Q" \
             "$BASE/monitor/system/certificate/download?mkey=$1&type=local-cer&scope=global" \
             "$BASE/monitor/system/certificate/download?mkey=$1&type=local-cer&scope=vdom&vdom=$VDOM" \
             "$BASE/monitor/system/certificate/download?mkey=$1&type=local&$CERT_Q"; do
        OUT=$(get_status "$U")
        CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
        if echo "$OUT" | grep -q "BEGIN CERTIFICATE"; then
            echo "HTTP $CODE - PEM FOUND via $U"
            echo "$OUT" | sed '/^HTTP:/d' | sed 's/\\n/\n/g' | grep -A100 "BEGIN CERTIFICATE" | grep -B100 -m1 "END CERTIFICATE" | openssl x509 -noout -subject -serial 2>/dev/null
            return 0
        fi
        echo "HTTP $CODE - no PEM in body: $(echo "$OUT" | sed '/^HTTP:/d' | tr -d '\n' | head -c 200)"
    done
    echo "RESULT: download endpoint did not return a PEM for '$1'"
}

# Step 2c(3): the CLI over SSH - what FortiGateSshClient does. Needs an interactive admin
# (SSH_USER/SSH_PASS); a REST API admin token cannot log in over SSH.
ssh_run() {      # <command...> -> output on stdout
    : "${SSH_USER:?Set SSH_USER (and SSH_PASS) for CLI access}"
    local OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20)
    if [ -n "${SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
        SSHPASS="$SSH_PASS" sshpass -e ssh "${OPTS[@]}" "$SSH_USER@$FGT" "$@"
    else
        ssh "${OPTS[@]}" "$SSH_USER@$FGT" "$@"
    fi
}
cli_show_certs() {
    # Multi-VDOM units keep certificates under "config global"; single-VDOM units reject that
    # prefix, so try both forms and keep whichever produced a config block.
    local OUT
    OUT=$(ssh_run "show vpn certificate local" 2>/dev/null)
    if ! echo "$OUT" | grep -q "config vpn certificate local"; then
        OUT=$(printf 'config global\nshow vpn certificate local\nend\n' | ssh_run 2>/dev/null)
    fi
    if ! echo "$OUT" | grep -q "config vpn certificate local"; then
        OUT=$(ssh_run "show full-configuration vpn certificate local" 2>/dev/null)
    fi
    echo "$OUT"
}
cmd_cli_certs() {
    echo "ssh -p $SSH_PORT $SSH_USER@$FGT \"show vpn certificate local\"" >&2
    OUT=$(cli_show_certs)
    echo "$OUT" | sed -E '/BEGIN (ENCRYPTED )?PRIVATE KEY/,/END (ENCRYPTED )?PRIVATE KEY/d; /set password/d; /set passwd/d' | tr -d '\r'
    echo
    echo "== certificates parsed the way the plugin does it =="
    echo "$OUT" | python3 -c '
import sys, re
out = sys.stdin.read().replace("\r", "")
found = 0
for m in re.finditer(r"edit\s+\"([^\"]+)\"([\s\S]*?)(?:\n\s*next\b|\n\s*end\b)", out):
    name, body = m.group(1), m.group(2)
    ci, ki = body.find("set certificate"), body.find("set private-key")
    part = body[ci:(ki if ki > ci else len(body))] if ci >= 0 else ""
    pem = re.search(r"-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----", part)
    found += 1 if pem else 0
    print(name + ": " + ("PEM found (" + str(len(pem.group())) + " chars)" if pem else "no certificate body in the show output"))
print(f"{found} certificate bod(y/ies) readable over SSH")' 2>/dev/null \
        || echo "$OUT" | grep -c "BEGIN CERTIFICATE" | sed 's/^/certificate bodies: /'
}

# Step 2 in one go: which discovery paths return a certificate body on THIS appliance?
cmd_discover() {
    echo "==================== FortiGate discovery probe ===================="
    cmd_info; echo
    echo "---- (a) monitor/system/available-certificates + cmdb/vpn.certificate/local ----"
    cmd_certs 2>/dev/null | sed -n '1,/^-- raw monitor --/p' | sed '$d'
    NAMES=$(get "$BASE/cmdb/vpn.certificate/local?$CERT_Q" 2>/dev/null | names_of)
    [ -z "$NAMES" ] && NAMES=$(get "$BASE/monitor/system/available-certificates?$CERT_Q" 2>/dev/null | names_of)
    echo
    echo "---- (b) per-certificate: cmdb entry PEM / download endpoint ----"
    local CMDB_OK=0 DL_OK=0 TOTAL=0
    for N in $NAMES; do
        TOTAL=$((TOTAL+1))
        B=$(get "$BASE/cmdb/vpn.certificate/local/$N?$CERT_Q" 2>/dev/null)
        if echo "$B" | grep -q "BEGIN CERTIFICATE"; then C="PEM"; CMDB_OK=$((CMDB_OK+1)); else C="no"; fi
        D=$(get "$BASE/monitor/system/certificate/download?mkey=$N&type=local-cer&$CERT_Q" 2>/dev/null)
        if echo "$D" | grep -q "BEGIN CERTIFICATE"; then W="PEM"; DL_OK=$((DL_OK+1)); else W="no ($(echo "$D" | tr -d '\n' | head -c 80))"; fi
        printf '  %-36s cmdb.certificate=%-4s download=%s\n' "$N" "$C" "$W"
    done
    echo
    echo "---- (c) CLI over SSH ----"
    local SSH_OK="skipped (SSH_USER/SSH_PASS not set)"
    if [ -n "${SSH_USER:-}" ]; then
        OUT=$(cli_show_certs)
        if [ -z "$OUT" ]; then SSH_OK="FAILED (no output - login refused, SSH not enabled on the interface, or port $SSH_PORT closed)";
        else
            CNT=$(echo "$OUT" | grep -c "BEGIN CERTIFICATE")
            SSH_OK="$CNT certificate bod(y/ies) in 'show vpn certificate local'"
            echo "$OUT" | grep -E '^\s*edit "' | sed 's/^/  /'
        fi
    fi
    echo "  $SSH_OK"
    echo
    echo "---- (d) references ----"
    scan_refs 2>/dev/null | sed 's/^/  /'
    echo
    echo "==================== summary ===================="
    echo "certificates in scope ($SCOPE): $TOTAL"
    echo "PEM via cmdb 'certificate' attribute : $CMDB_OK / $TOTAL"
    echo "PEM via monitor download endpoint    : $DL_OK / $TOTAL"
    echo "PEM via CLI over SSH                 : $SSH_OK"
    if [ "$CMDB_OK" -gt 0 ] || [ "$DL_OK" -gt 0 ]; then
        echo "=> REST alone returns certificate bodies on this firmware; SSH is an optional fallback."
    else
        echo "=> REST returned no PEM; the plugin needs SSH (interactive admin) to hand TLM a certificate body."
    fi
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
    BASE_NAME=$(echo "${CN:-tlm_cert}" | sed 's/[^A-Za-z0-9_-]/_/g; s/__*/_/g; s/^[_-]*//; s/[_-]*$//')
    SUFFIX=$(echo "$SERIAL" | tail -c 13)
    MAXBASE=$((35 - 1 - ${#SUFFIX}))
    [ ${#BASE_NAME} -gt $MAXBASE ] && BASE_NAME=$(echo "${BASE_NAME:0:$MAXBASE}" | sed 's/[_-]*$//')
    echo "${BASE_NAME}_${SUFFIX}"
}

cmd_name() {
    need 1 "certificate file required"
    echo "Unique FortiGate name the plugin would use: $(unique_name "$1")"
}

cmd_import() {
    need 1 "certificate file required"; need 2 "key file required"
    CRT="$1"; KEY="$2"; NAME="${3:-$(unique_name "$1")}"
    echo "== before =="; BEFORE=$(get "$BASE/cmdb/vpn.certificate/local?$CERT_Q" | names_of); echo "$BEFORE" | tr '\n' ' '; echo
    if echo "$BEFORE" | grep -qx "$NAME"; then echo "WARNING: '$NAME' already exists - FortiGate will reject a duplicate (plugin would append _2)"; fi
    confirm "Import $CRT + $KEY as '$NAME' (scope $SCOPE) on $FGT?" || { echo "aborted"; exit 1; }
    PAYLOAD=$(python3 -c '
import base64, json, sys
cert = base64.b64encode(open(sys.argv[1], "rb").read()).decode()
key = base64.b64encode(open(sys.argv[2], "rb").read()).decode()
print(json.dumps({"type": "regular", "scope": sys.argv[4], "certname": sys.argv[3], "file_content": cert, "key_file_content": key}))' "$CRT" "$KEY" "$NAME" "$SCOPE")
    URL="$BASE/monitor/vpn-certificate/local/import?$VDOM_Q"
    echo "POST $URL (type=regular scope=$SCOPE certname=$NAME file_content=<b64 cert> key_file_content=<b64 key>)"
    curl -k --location -g --silent --show-error -X POST "$URL" "${AUTH[@]}" -H 'Content-Type: application/json' --data "$PAYLOAD" -w '\nHTTP:%{http_code}\n'
    sleep 1
    echo "== after (list diff) =="; AFTER=$(get "$BASE/cmdb/vpn.certificate/local?$CERT_Q" | names_of)
    NEW=$(comm -13 <(echo "$BEFORE" | sort) <(echo "$AFTER" | sort))
    echo "new name(s): ${NEW:-<none - import did not create a certificate>}"
    [ -n "$NEW" ] && cmd_confirm "$(echo "$NEW" | head -n1)"
}

cmd_confirm() {
    need 1 "certificate name required"
    MON=$(get "$BASE/monitor/system/available-certificates?$CERT_Q&mkey=$1")
    CMDB=$(get "$BASE/cmdb/vpn.certificate/local/$1?$CERT_Q&with_meta=1")
    MON="$MON" CMDB="$CMDB" python3 -c '
import os, sys, json
n = sys.argv[1]
def load(s):
    try: return json.loads(s)
    except Exception: return {}
mon, cmdb = load(os.environ["MON"]), load(os.environ["CMDB"])
m = next((c for c in (mon.get("results") or []) if isinstance(c, dict) and c.get("name") == n), None)
c = cmdb.get("results"); c = c[0] if isinstance(c, list) and c else (c if isinstance(c, dict) else None)
if not m and not c: print(f"NOT FOUND: {n}"); sys.exit(1)
out = {}
if m: out.update({k: m.get(k) for k in ("name","status","source","range","key_type","key_size","valid_from","valid_to","serial_number","subject","issuer","q_ref")})
if c: out.update({"cmdb.range": c.get("range"), "cmdb.q_ref": c.get("q_ref"), "cmdb.certificate": "PEM" if str(c.get("certificate","")).startswith("-----") else c.get("certificate")})
print(json.dumps(out, indent=2))' "$1"
}

cmd_repoint() {
    need 1 "old cert name required"; need 2 "new cert name required"
    OLD="$1"; NEW="$2"
    REFS=$(scan_refs "$OLD" 2>/dev/null)
    if [ -z "$REFS" ]; then echo "No references to '$OLD' - nothing to repoint (plugin would go straight to the q_ref check)"; return 0; fi
    echo "References to '$OLD':"; echo "$REFS" | sed 's/^/  /'
    confirm "Repoint all of the above to '$NEW'?" || { echo "aborted"; exit 1; }
    FAIL=0
    while read -r KIND LABEL PATH_ A B C D; do
        case "$KIND" in
            SINGLE) # SINGLE label path field cert
                Q="$VDOM_Q"; URL="$BASE/cmdb/$PATH_?$Q"; BODY="{\"$A\":\"$NEW\"}";;
            TABLE)  # TABLE label path mkey field cert kind
                ENC=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$A")
                URL="$BASE/cmdb/$PATH_/$ENC?$VDOM_Q"
                if [ "$D" = "list" ]; then BODY="{\"$B\":[{\"name\":\"$NEW\"}]}"; else BODY="{\"$B\":\"$NEW\"}"; fi;;
            *) continue;;
        esac
        OUT=$(put_json "$URL" "$BODY" 2>&1)
        CODE=$(echo "$OUT" | grep '^HTTP:' | cut -d: -f2)
        if [ "$CODE" = "200" ] && ok_body "$OUT"; then echo "  -> OK ($LABEL)"; else echo "  -> FAILED ($LABEL): $(echo "$OUT" | tr -d '\n' | head -c 400)"; FAIL=1; fi
    done <<< "$REFS"
    sleep 2
    echo "== remaining references to '$OLD' =="; scan_refs "$OLD" 2>/dev/null || true
    [ "$FAIL" = "0" ] && echo "All references repointed." || echo "Some repoints failed - the plugin would leave '$OLD' in place and report the install as failed."
}

cmd_candelete() {
    need 1 "certificate name required"
    get "$BASE/cmdb/vpn.certificate/local/$1?$CERT_Q&with_meta=1" | python3 -c '
import sys, json; n = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print(f"{n}: unreadable response"); sys.exit(4)
r = d.get("results"); r = r[0] if isinstance(r, list) and r else (r if isinstance(r, dict) else None)
if not r or d.get("status") == "error": print("%s: not present (%s %s)" % (n, d.get("http_status"), d.get("cli_error", ""))); sys.exit(4)
q = r.get("q_ref")
ok = (q == 0)
verdict = "DELETABLE" if ok else ("STILL REFERENCED - plugin would skip deletion" if q else "q_ref unknown (with_meta unsupported?) - plugin would attempt the delete and rely on FortiGate refusing")
print("%s: q_ref=%s -> %s" % (n, q, verdict))
sys.exit(0 if ok or q is None else 3)' "$1"
}

cmd_delete() {
    need 1 "certificate name required"
    cmd_candelete "$1" || { echo "refusing to delete"; exit 1; }
    confirm "DELETE certificate '$1' (scope $SCOPE) from $FGT?" || { echo "aborted"; exit 1; }
    echo "DELETE $BASE/cmdb/vpn.certificate/local/$1?$CERT_Q"
    curl -k --location -g --silent --show-error -X DELETE "$BASE/cmdb/vpn.certificate/local/$1?$CERT_Q" "${AUTH[@]}" -w '\nHTTP:%{http_code}\n'
    sleep 1
    if get "$BASE/cmdb/vpn.certificate/local?$CERT_Q" | names_of | grep -qx "$1"; then echo "STILL PRESENT"; else echo "Deleted: '$1' no longer listed"; fi
}

cmd_validate() {
    need 1 "certificate name required"
    cmd_confirm "$1" || exit 1
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        LEAF=$(openssl x509 -in "$2" -noout -serial | cut -d= -f2)
        FGT_SERIAL=$(get "$BASE/monitor/system/available-certificates?$CERT_Q&mkey=$1" 2>/dev/null | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(c.get("serial_number",""))' "$1")
        python3 -c '
import sys
a, b = sys.argv[1], sys.argv[2]
norm = lambda s: int(s.replace(":","").replace(" ","").strip() or "0", 16)
print("serial match" if norm(a)==norm(b) else f"SERIAL MISMATCH leaf={a} fortigate={b}")' "$LEAF" "$FGT_SERIAL"
    fi
}

case "${1:-}" in
    info) cmd_info;;
    test) cmd_test;;
    certs) cmd_certs;;
    refs) cmd_refs "${2:-}";;
    cmdb-cert) cmd_cmdb_cert "${2:-}";;
    download-test) cmd_download_test "${2:-}";;
    cli-certs) cmd_cli_certs;;
    discover) cmd_discover;;
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
