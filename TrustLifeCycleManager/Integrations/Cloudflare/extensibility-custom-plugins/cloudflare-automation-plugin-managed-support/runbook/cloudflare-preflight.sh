#!/usr/bin/env bash
# Preflight for the Cloudflare automation plugin: proves, read-only, that every piece of data the
# plugin needs is actually retrievable from a real zone with the token you intend to give TLM.
#
#   export CF_ZONE_ID=023e105f4ecef8ad9ca31a8372d0c353
#   export CF_API_TOKEN='v1.0-...'
#   ./cloudflare-preflight.sh              # read-only checks
#   ./cloudflare-preflight.sh --write-test # additionally creates and deletes one throwaway CSR
#                                          # (proves POST /custom_csrs + key_type, needed for CSR mode "cloudflare")
#
# Checks (plugin operation that depends on it):
#   1 API reachable from this host                            all
#   2 token verifies and is active                            testConnection
#   3 zone readable: id, name, status, plan                   testConnection / discovery (managementIp = zone name)
#   4 custom certificates listable (+ pagination fields)      discovery / install / validate
#   5 per certificate: id, hosts, status, expires_on present  discovery endpoint model, validate expiry check
#   6 per active certificate: body retrievable from the edge  discovery (TLM shows an asset only with the PEM)
#   7 single certificate readable by id                       install (wait for active), validate
#   8 custom CSRs listable                                    CSR retention clean-up (CSR mode "cloudflare")
#   9 [--write-test] CSR create + delete round-trip           generateCsr (CSR mode "cloudflare")
#  10 certificate packs listable; Universal SSL / Total TLS    discovery of Cloudflare-managed certificates (Universal SSL /
#     settings readable; per managed pack: hosts, expiry,      Advanced), their replacement by a custom certificate and the
#     body from the edge                                       optional retirement (connector setting "discover_retire")
#
# Needs curl, jq, openssl. Works with bash 3.2+ (macOS) and GNU/BSD date.
# Exit code: 0 when nothing FAILed (WARNs allowed), 1 otherwise.
set -u

API="${CF_API_BASE_URL:-https://api.cloudflare.com/client/v4}"
WRITE_TEST=false
if [ "${1:-}" = "--write-test" ]; then WRITE_TEST=true; fi

PASS=0; WARN=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

for t in curl jq openssl; do
  if ! command -v "$t" >/dev/null 2>&1; then echo "missing tool: $t" >&2; exit 1; fi
done
if [ -z "${CF_ZONE_ID:-}" ]; then echo "set CF_ZONE_ID" >&2; exit 1; fi
if [ -z "${CF_API_TOKEN:-}" ]; then echo "set CF_API_TOKEN" >&2; exit 1; fi
Z="$API/zones/$CF_ZONE_ID"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TO=""; if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; fi

# cf METHOD URL [BODY]  -> sets BODY and HTTP_STATUS (no subshell, so the globals survive)
cf() {
  local m="$1" u="$2" b="${3:-}"
  if [ -n "$b" ]; then
    HTTP_STATUS=$(curl -sS -m 60 -o "$TMP/body" -w '%{http_code}' -X "$m" "$u" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$b" 2>"$TMP/err") || HTTP_STATUS="000"
  else
    HTTP_STATUS=$(curl -sS -m 60 -o "$TMP/body" -w '%{http_code}' -X "$m" "$u" -H "Authorization: Bearer $CF_API_TOKEN" 2>"$TMP/err") || HTTP_STATUS="000"
  fi
  if [ -s "$TMP/body" ]; then BODY=$(cat "$TMP/body"); else BODY="{}"; fi
  if [ "$HTTP_STATUS" = "000" ]; then BODY="{\"success\":false,\"errors\":[{\"code\":0,\"message\":\"curl: $(tr -d '"' < "$TMP/err")\"}]}"; fi
}
ok()   { case "$HTTP_STATUS" in 2??) [ "$(printf '%s' "$BODY" | jq -r '.success' 2>/dev/null)" = "true" ];; *) false;; esac; }
errs() { printf '%s' "$BODY" | jq -r '[.errors[]? | "code \(.code): \(.message)"] | join("; ")' 2>/dev/null; }
field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# epoch conversion for "2027-11-06T12:15:39Z" and openssl "Nov  6 12:15:39 2027 GMT" (GNU and BSD date)
to_epoch_iso() {
  local s="${1%%.*}"; s="${s%Z}"; s="${s%%+*}"
  date -u -d "${s}Z" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null
}
to_epoch_ssl() {
  local s; s=$(printf '%s' "$1" | tr -s ' ')
  date -u -d "$s" +%s 2>/dev/null || date -j -u -f '%b %d %H:%M:%S %Y %Z' "$s" +%s 2>/dev/null
}
# served certificate for host/sni -> PEM on stdout (empty on failure)
probe() {
  echo | $TO openssl s_client -connect "$1:443" -servername "$2" 2>/dev/null | openssl x509 2>/dev/null
}
sans_of() { openssl x509 -noout -text 2>/dev/null | grep -A1 'Subject Alternative Name' | tail -n1 | tr ',' '\n' | sed 's/^ *DNS://' | tr '\n' ' '; }

# ------------------------------------------------------------------ 1 API reachable
API_HOST="${API#*://}"; API_HOST="${API_HOST%%/*}"
section "1. Cloudflare API reachable ($API_HOST:443)"
if curl -sS -m 15 -o /dev/null "$API/" 2>"$TMP/err"; then
  pass "TCP/TLS to $API_HOST:443 works from this host"
else
  fail "cannot reach the API: $(cat "$TMP/err")"; echo; echo "Summary: $PASS pass, $WARN warn, $FAIL fail"; exit 1
fi

# ------------------------------------------------------------------ 2 token
section "2. API token (GET /user/tokens/verify)"
cf GET "$API/user/tokens/verify"
if ok; then
  ST=$(field "$BODY" '.result.status')
  if [ "$ST" = "active" ]; then pass "token is active (id $(field "$BODY" '.result.id'))"; else fail "token status is '$ST'"; fi
  EXP=$(field "$BODY" '.result.expires_on // empty')
  if [ -n "$EXP" ]; then warn "token expires on $EXP - TLM renewals after that date will fail"; fi
else
  fail "HTTP $HTTP_STATUS $(errs)"
fi

# ------------------------------------------------------------------ 3 zone
section "3. Zone (GET /zones/$CF_ZONE_ID)"
cf GET "$Z"
ZONE_NAME=""
if ok; then
  ZONE_NAME=$(field "$BODY" '.result.name'); ZS=$(field "$BODY" '.result.status'); PLAN=$(field "$BODY" '.result.plan.name // "unknown"')
  pass "zone '$ZONE_NAME' readable (status $ZS, type $(field "$BODY" '.result.type'), plan '$PLAN')"
  if [ "$ZS" != "active" ]; then warn "zone status is '$ZS' (not active)"; fi
  case "$PLAN" in
    *Business*|*Enterprise*) pass "plan '$PLAN' allows custom certificates" ;;
    *) warn "plan '$PLAN' may not allow custom certificates (Business or Enterprise required); the upload step would fail" ;;
  esac
else
  fail "HTTP $HTTP_STATUS $(errs) - token needs Zone > Zone > Read on this zone, and the zone id must be right"
fi

# ------------------------------------------------------------------ 4 list certificates
section "4. Custom certificates (GET /zones/$CF_ZONE_ID/custom_certificates?page=1&per_page=50)"
cf GET "$Z/custom_certificates?page=1&per_page=50"
CERTS="[]"
if ok; then
  CERTS=$(field "$BODY" '.result')
  N=$(field "$CERTS" 'length'); TP=$(field "$BODY" '.result_info.total_pages // "absent"'); TC=$(field "$BODY" '.result_info.total_count // "absent"')
  pass "list works: $N certificate(s) on page 1 (result_info.total_pages=$TP, total_count=$TC)"
  if [ "$TP" = "absent" ]; then warn "result_info.total_pages missing - the plugin would stop after page 1 (fine for up to 50 certificates)"; fi
  if [ "$N" = "0" ]; then warn "the zone has no custom certificates - discovery will return an empty inventory (expected if nothing was uploaded yet)"; fi
  if [ "$TP" != "absent" ] && [ "$TP" -gt 1 ] 2>/dev/null; then
    p=2
    while [ "$p" -le "$TP" ]; do
      cf GET "$Z/custom_certificates?page=$p&per_page=50"
      CERTS=$(jq -c -n --argjson a "$CERTS" --argjson b "$(field "$BODY" '.result // []')" '$a + $b')
      p=$((p+1))
    done
    pass "pagination: $(field "$CERTS" 'length') certificate(s) over $TP pages"
  fi
else
  fail "HTTP $HTTP_STATUS $(errs) - token needs Zone > SSL and Certificates > Edit (or Read) on this zone"
fi

# ------------------------------------------------------------------ 5 + 6 per certificate
section "5./6. Per-certificate data and certificate body from the edge"
NCERTS=$(field "$CERTS" 'length'); [ -n "$NCERTS" ] || NCERTS=0
i=0
while [ "$i" -lt "$NCERTS" ]; do
  c=$(field "$CERTS" ".[$i]"); i=$((i+1))
  ID=$(field "$c" '.id // empty'); STATUS=$(field "$c" '.status // empty'); EXP=$(field "$c" '.expires_on // empty')
  HOSTS=$(field "$c" '.hosts[]?' | tr '\n' ' '); HOSTS="${HOSTS% }"
  echo "  -- $ID"
  info "hosts=[$HOSTS] status=$STATUS expires_on=$EXP issuer=$(field "$c" '.issuer // "?"') signature=$(field "$c" '.signature // "?"') priority=$(field "$c" '.priority // "?"') bundle=$(field "$c" '.bundle_method // "?"') csr=$(field "$c" '.custom_csr_id // "none"')"
  PRIMARY=$(field "$c" '[.hosts[]? | select(startswith("*") | not)] | min_by(length) // empty')
  if [ -z "$PRIMARY" ]; then
    W=$(field "$c" '.hosts[0] // empty'); if [ -n "$W" ]; then PRIMARY="wildcard.${W#\*.}"; else PRIMARY="cert-${ID:0:8}.$ZONE_NAME"; fi
  fi
  if [ -n "$ID" ] && [ -n "$STATUS" ] && [ -n "$EXP" ] && [ -n "$HOSTS" ]; then
    pass "id, hosts, status, expires_on present (discovery endpoint would be $PRIMARY:443, alias $ID)"
  else
    fail "missing one of id/hosts/status/expires_on - the plugin cannot build the endpoint or validate expiry"
  fi
  if [ "$(field "$c" 'has("type")')" = "true" ]; then info "note: 'type' is reported ($(field "$c" '.type'))"; else info "note: 'type' (sni_custom/legacy_custom) not reported, as expected"; fi
  if [ "$(field "$c" '(.certificate // "") | length > 0')" = "true" ]; then info "note: a certificate body IS returned by the API (unexpected but welcome)"; fi
  if [ "$STATUS" != "active" ]; then
    warn "status '$STATUS': the edge does not serve it, so no body can be fetched - TLM will not show this asset until it is active"
    continue
  fi
  WANT=$(to_epoch_iso "$EXP")
  CANDIDATES=""
  for h in $HOSTS; do
    case "$h" in
      \*.*) base="${h#\*.}"; CANDIDATES="$CANDIDATES www.$base|www.$base ${ZONE_NAME:-$base}|www.$base ${ZONE_NAME:-$base}|$base" ;;
      *)    CANDIDATES="$CANDIDATES $h|$h ${ZONE_NAME:-$h}|$h" ;;
    esac
  done
  FOUND=""
  for cand in $CANDIDATES; do
    CONNECT="${cand%%|*}"; SNI="${cand##*|}"
    PEM=$(probe "$CONNECT" "$SNI")
    if [ -z "$PEM" ]; then info "probe $CONNECT (SNI $SNI): no TLS handshake"; continue; fi
    GOT=$(to_epoch_ssl "$(printf '%s' "$PEM" | openssl x509 -noout -enddate | sed 's/notAfter=//')")
    if [ -n "$WANT" ] && [ -n "$GOT" ] && [ "$WANT" = "$GOT" ]; then
      FOUND="$CONNECT (SNI $SNI)"
      info "probe $FOUND: notAfter matches expires_on; serial $(printf '%s' "$PEM" | openssl x509 -noout -serial | sed 's/serial=//'); SANs: $(printf '%s' "$PEM" | sans_of)"
      break
    else
      info "probe $CONNECT (SNI $SNI): served a different certificate (notAfter epoch ${GOT:-?} vs expires_on ${WANT:-?}; issuer $(printf '%s' "$PEM" | openssl x509 -noout -issuer | sed 's/issuer=//'))"
    fi
  done
  if [ -n "$FOUND" ]; then
    pass "certificate body retrievable from the edge via $FOUND - TLM will receive the PEM"
  else
    warn "no probe served this certificate - the plugin would surface it WITHOUT a body (TLM shows no asset). Causes: another certificate/Universal SSL has priority for these hosts, host not proxied, or no outbound 443 from here"
  fi
done

# ------------------------------------------------------------------ 7 single certificate by id
section "7. Single certificate by id (GET /zones/$CF_ZONE_ID/custom_certificates/{id})"
FIRST=$(field "$CERTS" '.[0].id // empty')
if [ -n "$FIRST" ]; then
  cf GET "$Z/custom_certificates/$FIRST"
  if ok && [ "$(field "$BODY" '.result.id')" = "$FIRST" ]; then
    pass "GET by id returns the same record (status $(field "$BODY" '.result.status'))"
  else
    fail "HTTP $HTTP_STATUS $(errs)"
  fi
  cf GET "$Z/custom_certificates/00000000-0000-0000-0000-000000000000"
  if [ "$HTTP_STATUS" = "404" ] || ! ok; then
    pass "unknown id answers HTTP $HTTP_STATUS ($(errs)) - treated as 'not present'"
  else
    warn "unknown id answered HTTP $HTTP_STATUS with success=true (unexpected)"
  fi
else
  warn "no certificate to read by id (zone is empty)"
fi

# ------------------------------------------------------------------ 8 CSRs
section "8. Custom CSRs (GET /zones/$CF_ZONE_ID/custom_csrs)"
cf GET "$Z/custom_csrs?page=1&per_page=50"
if ok; then
  NC=$(field "$BODY" '.result | length')
  pass "CSR list works: $NC CSR(s)"
  if [ "$NC" != "0" ]; then
    if [ "$(field "$BODY" '.result[0] | has("created_at") and has("common_name") and has("id")')" = "true" ]; then
      pass "CSR records carry id, common_name, created_at (needed for retention clean-up)"
    else
      warn "CSR records lack id/common_name/created_at - retention clean-up would not work"
    fi
    printf '%s' "$BODY" | jq -r '.result[]? | "        \(.id)  cn=\(.common_name)  key_type=\(.key_type)  created=\(.created_at)  sans=\((.sans // []) | join(","))"'
    LEFT=$(printf '%s' "$BODY" | jq -r '[.result[]? | select(.common_name | startswith("tlm-preflight-")) | .id] | join(" ")')
    if [ -n "$LEFT" ]; then warn "leftover preflight CSR(s) from an earlier --write-test: $LEFT (re-run with --write-test to delete them, or: cloudflare-runbook.sh delete-csr <id>)"; fi
  fi
else
  fail "HTTP $HTTP_STATUS $(errs) - CSR mode 'cloudflare' needs this (SSL and Certificates > Edit)"
fi

# ------------------------------------------------------------------ 9 write test
if $WRITE_TEST; then
  section "9. CSR create + delete round-trip (POST/DELETE /zones/$CF_ZONE_ID/custom_csrs) [--write-test]"
  cf GET "$Z/custom_csrs?page=1&per_page=50"
  for old in $(printf '%s' "$BODY" | jq -r '.result[]? | select(.common_name | startswith("tlm-preflight-")) | .id' 2>/dev/null); do
    cf DELETE "$Z/custom_csrs/$old"
    if ok; then pass "deleted leftover preflight CSR $old"; else warn "could not delete leftover preflight CSR $old: HTTP $HTTP_STATUS $(errs)"; fi
  done
  CN="tlm-preflight-$(date +%s).${ZONE_NAME:-example.com}"
  REQ=$(jq -n --arg cn "$CN" '{common_name:$cn,country:"US",state:"Utah",locality:"Lehi",organization:"DigiCert",key_type:"rsa2048",sans:[$cn]}')
  cf POST "$Z/custom_csrs" "$REQ"
  CID=""
  if ok; then
    CID=$(field "$BODY" '.result.id // empty'); CSR=$(field "$BODY" '.result.csr // empty')
    if [ -n "$CID" ] && printf '%s' "$CSR" | grep -q 'BEGIN CERTIFICATE REQUEST'; then
      pass "CSR created (HTTP $HTTP_STATUS): id $CID, key_type $(field "$BODY" '.result.key_type')"
      printf '%s\n' "$CSR" | openssl req -noout -text 2>/dev/null | grep -E 'Subject:|Public Key Algorithm|Public-Key|DNS:' | sed 's/^ */        /'
      if printf '%s\n' "$CSR" | openssl req -noout -verify >/dev/null 2>&1; then pass "CSR signature verifies"; else warn "openssl could not verify the CSR signature"; fi
    else
      fail "CSR created but id/csr missing: $(field "$BODY" '.result')"
    fi
  else
    fail "CSR creation failed: HTTP $HTTP_STATUS $(errs)"
  fi
  if [ -n "$CID" ]; then
    cf DELETE "$Z/custom_csrs/$CID"
    if ok; then pass "CSR $CID deleted again (retention clean-up works)"; else fail "could not delete CSR $CID: HTTP $HTTP_STATUS $(errs) - delete it by hand"; fi
  fi
  cf POST "$Z/custom_csrs" "$(jq -n --arg cn "$CN" '{common_name:$cn,country:"US",state:"Utah",locality:"Lehi",organization:"DigiCert",key_type:"rsa4096",sans:[$cn]}')"
  if ok; then
    warn "key_type rsa4096 was ACCEPTED (schema says rsa2048|p256v1 only) - the plugin's key mapping could be relaxed; deleting it"
    cf DELETE "$Z/custom_csrs/$(field "$BODY" '.result.id')"
  else
    pass "key_type rsa4096 rejected (HTTP $HTTP_STATUS $(errs)) - the plugin never sends it; other sizes are mapped to rsa2048/p256v1"
  fi
else
  section "9. CSR create + delete round-trip - skipped (run with --write-test to create and delete one throwaway CSR)"
fi

# ------------------------------------------------------------------ 10 Cloudflare-managed certificates
section "10. Cloudflare-managed certificates (GET /zones/$CF_ZONE_ID/ssl/certificate_packs?status=all, /ssl/universal/settings, /acm/total_tls)"
cf GET "$Z/ssl/certificate_packs?status=all&page=1&per_page=50"
PACKS="[]"
if ok; then
  PACKS=$(field "$BODY" '[.result[] | select(.type=="universal" or .type=="advanced" or .type=="total_tls")]')
  NPACKS=$(field "$PACKS" 'length'); NALL=$(field "$BODY" '.result | length')
  pass "pack list works: $NALL pack(s), $NPACKS Cloudflare-managed (universal/advanced/total_tls) - the plugin surfaces those as assets 'pack-<id>'"
  if [ "$(field "$BODY" '.result_info.total_pages // "absent"')" = "absent" ]; then warn "result_info.total_pages missing on the pack list - the plugin would stop after page 1"; fi
  i=0
  while [ "$i" -lt "${NPACKS:-0}" ]; do
    c=$(field "$PACKS" ".[$i]"); i=$((i+1))
    ID=$(field "$c" '.id // empty'); TYPE=$(field "$c" '.type'); STATUS=$(field "$c" '.status // empty'); CA=$(field "$c" '.certificate_authority // "?"')
    HOSTS=$(field "$c" '.hosts[]?' | tr '\n' ' '); HOSTS="${HOSTS% }"
    EXPS=$(field "$c" '[.certificates[]?.expires_on // empty] | join(" ")')
    echo "  -- pack-$ID ($TYPE, CA $CA)"
    info "hosts=[$HOSTS] status=$STATUS certificates expire: ${EXPS:-?} issuers: $(field "$c" '[.certificates[]?.issuer // empty] | join(", ")')"
    if [ -n "$ID" ] && [ -n "$HOSTS" ] && [ -n "$EXPS" ]; then
      pass "id, hosts and certificate expiries present (asset alias pack-$ID)"
    else
      fail "missing id/hosts/expires_on on the pack - the plugin cannot build the endpoint or match the served certificate"
    fi
    if [ "$TYPE" = "universal" ]; then info "retirement = PATCH /ssl/universal/settings enabled:false (only when the custom certificate covers [$HOSTS])"; else info "retirement = DELETE /ssl/certificate_packs/$ID (only when the custom certificate covers [$HOSTS])"; fi
    if [ "$STATUS" != "active" ]; then warn "pack status '$STATUS': not served by the edge, surfaced without body"; continue; fi
    FOUND=""
    for h in $HOSTS; do
      case "$h" in \*.*) CONNECT="www.${h#\*.}";; *) CONNECT="$h";; esac
      PEM=$(probe "$CONNECT" "$CONNECT")
      if [ -z "$PEM" ]; then info "probe $CONNECT: no TLS handshake"; continue; fi
      GOT=$(to_epoch_ssl "$(printf '%s' "$PEM" | openssl x509 -noout -enddate | sed 's/notAfter=//')")
      for e in $EXPS; do
        if [ -n "$GOT" ] && [ "$(to_epoch_iso "$e")" = "$GOT" ]; then FOUND="$CONNECT"; break; fi
      done
      if [ -n "$FOUND" ]; then
        info "probe $FOUND: notAfter matches one of the pack's certificates; issuer $(printf '%s' "$PEM" | openssl x509 -noout -issuer | sed 's/issuer=//'); SANs: $(printf '%s' "$PEM" | sans_of)"
        break
      else
        info "probe $CONNECT: served a different certificate (notAfter epoch ${GOT:-?}; issuer $(printf '%s' "$PEM" | openssl x509 -noout -issuer | sed 's/issuer=//'))"
      fi
    done
    if [ -n "$FOUND" ]; then pass "managed certificate body retrievable from the edge via $FOUND - TLM will receive the PEM"; else warn "no probe served this pack's certificate - surfaced WITHOUT a body (a custom certificate with higher priority may already serve these hostnames)"; fi
  done
else
  fail "HTTP $HTTP_STATUS $(errs) - the managed-certificate features need this (SSL and Certificates > Edit); set the connector to 'ignore' otherwise"
fi
cf GET "$Z/ssl/universal/settings"
if ok; then
  UEN=$(field "$BODY" '.result.enabled')
  pass "Universal SSL settings readable: enabled=$UEN"
  if [ "$UEN" = "false" ] && [ "$(field "$CERTS" 'length')" = "0" ]; then warn "Universal SSL is disabled and the zone has no custom certificate - hostnames without an Advanced certificate have no TLS"; fi
else
  warn "Universal SSL settings not readable (HTTP $HTTP_STATUS $(errs)) - the plugin cannot disable Universal SSL after a switch; 'discover_retire' would keep Universal packs"
fi
cf GET "$Z/acm/total_tls"
if ok; then
  TEN=$(field "$BODY" '.result.enabled')
  if [ "$TEN" = "true" ]; then
    warn "Total TLS is ENABLED: Cloudflare keeps ordering hostname-specific Advanced certificates (CA $(field "$BODY" '.result.certificate_authority')); exact-name certificates outrank a wildcard custom certificate"
  else
    pass "Total TLS readable: enabled=$TEN"
  fi
else
  info "Total TLS settings not readable (HTTP $HTTP_STATUS) - normal for a zone without Advanced Certificate Manager"
fi

echo
echo "Summary: $PASS pass, $WARN warn, $FAIL fail"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
