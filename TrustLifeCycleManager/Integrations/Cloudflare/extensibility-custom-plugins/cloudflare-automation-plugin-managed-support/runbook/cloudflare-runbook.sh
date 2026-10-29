#!/usr/bin/env bash
# Manual companion to the Cloudflare automation plugin: issues the same Cloudflare API calls, with
# the same paths and bodies, so each plugin step can be exercised by hand before (or while) driving
# it from TLM. Read-only sub-commands never change the zone.
#
#   export CF_ZONE_ID=023e105f4ecef8ad9ca31a8372d0c353
#   export CF_API_TOKEN='v1.0-…'          # Zone > SSL and Certificates > Edit, Zone > Zone > Read
#   ./cloudflare-runbook.sh discover      # verify + zone + certs + edge probe for every host
#
# Sub-commands (read-only):
#   verify                      GET /user/tokens/verify
#   zone                        GET /zones/{zone}
#   certs                       GET /zones/{zone}/custom_certificates (all pages)
#   cert <id>                   GET /zones/{zone}/custom_certificates/{id}
#   csrs                        GET /zones/{zone}/custom_csrs
#   packs                       GET /zones/{zone}/ssl/certificate_packs?status=all (Universal SSL / Advanced / Total TLS packs)
#   pack <id>                   GET /zones/{zone}/ssl/certificate_packs/{id}
#   universal                   GET /zones/{zone}/ssl/universal/settings (Universal SSL enabled?)
#   total-tls                   GET /zones/{zone}/acm/total_tls (Total TLS enabled?)
#   probe <host> [sni]          TLS handshake against the edge: served certificate summary
#   discover                    verify + zone + certs + packs + probe of every listed host
# Sub-commands (modifying):
#   csr <cn> [san ...]          POST /zones/{zone}/custom_csrs (C/ST/L/O from CF_CSR_C/ST/L/O, defaults US/Utah/Lehi/DigiCert)
#   upload <cert.pem> <key.pem|csr:ID> [sni_custom|legacy_custom] [force|ubiquitous|optimal]
#   update <id> <cert.pem> <key.pem|csr:ID> [force|ubiquitous|optimal]
#   delete <id>                 DELETE /zones/{zone}/custom_certificates/{id}
#   delete-csr <id>             DELETE /zones/{zone}/custom_csrs/{id}
#   delete-pack <id>            DELETE /zones/{zone}/ssl/certificate_packs/{id}   (Advanced / Total TLS packs only)
#   disable-universal           PATCH /zones/{zone}/ssl/universal/settings {"enabled":false}  (make sure a custom
#                               certificate covering every hostname is ACTIVE first - otherwise TLS breaks)
#   enable-universal            PATCH /zones/{zone}/ssl/universal/settings {"enabled":true}
set -euo pipefail

API="${CF_API_BASE_URL:-https://api.cloudflare.com/client/v4}"
: "${CF_ZONE_ID:?set CF_ZONE_ID}"
: "${CF_API_TOKEN:?set CF_API_TOKEN}"
Z="$API/zones/$CF_ZONE_ID"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }
need curl; need jq; need openssl

cf() { # cf METHOD URL [JSON-BODY]
  local m="$1" u="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$u" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$b"
  else
    curl -sS -X "$m" "$u" -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}
show() { jq . ; }
pem_json() { jq -Rs . < "$1"; }   # file → JSON string with \n escapes

cmd_verify() { echo "## GET /user/tokens/verify"; cf GET "$API/user/tokens/verify" | show; }
cmd_zone()   { echo "## GET /zones/$CF_ZONE_ID"; cf GET "$Z" | jq '{id:.result.id,name:.result.name,status:.result.status,type:.result.type,plan:.result.plan.name,account:.result.account.name,success,errors}'; }
cmd_certs() {
  echo "## GET $Z/custom_certificates (paged, per_page=50)"
  local page=1 total=1
  while :; do
    local r; r=$(cf GET "$Z/custom_certificates?page=$page&per_page=50")
    echo "$r" | jq -c '.result[] | {id,hosts,issuer,signature,status,bundle_method,priority,expires_on,custom_csr_id,uploaded_on}'
    total=$(echo "$r" | jq -r '.result_info.total_pages // 1')
    [ "$page" -ge "$total" ] && break
    page=$((page+1))
  done
}
cmd_cert()  { echo "## GET $Z/custom_certificates/$1"; cf GET "$Z/custom_certificates/$1" | show; }
cmd_packs() {
  echo "## GET $Z/ssl/certificate_packs?status=all (paged, per_page=50) - the plugin surfaces type universal/advanced/total_tls as 'pack-<id>'"
  local page=1 total=1
  while :; do
    local r; r=$(cf GET "$Z/ssl/certificate_packs?status=all&page=$page&per_page=50")
    echo "$r" | jq -c '.result[] | {id,type,status,hosts,certificate_authority,primary_certificate,certificates:[.certificates[]? | {id,issuer,signature,status,expires_on}]}'
    total=$(echo "$r" | jq -r '.result_info.total_pages // 1')
    [ "$page" -ge "$total" ] && break
    page=$((page+1))
  done
}
cmd_pack()      { echo "## GET $Z/ssl/certificate_packs/$1"; cf GET "$Z/ssl/certificate_packs/$1" | show; }
cmd_universal() { echo "## GET $Z/ssl/universal/settings"; cf GET "$Z/ssl/universal/settings" | show; }
cmd_total_tls() { echo "## GET $Z/acm/total_tls"; cf GET "$Z/acm/total_tls" | show; }
cmd_csrs()  { echo "## GET $Z/custom_csrs"; cf GET "$Z/custom_csrs?per_page=50" | jq -c '.result[]? | {id,common_name,sans,key_type,created_at}'; }
cmd_probe() {
  local host="$1" sni="${2:-$1}"
  echo "## TLS $host:443 (SNI $sni)"
  local pem; pem=$(echo | openssl s_client -connect "$host:443" -servername "$sni" 2>/dev/null | openssl x509 2>/dev/null) || { echo "   handshake failed"; return 0; }
  echo "$pem" | openssl x509 -noout -subject -issuer -serial -enddate -fingerprint -sha256 | sed 's/^/   /'
  echo "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^/   /'
}
cmd_discover() {
  cmd_verify; cmd_zone; cmd_certs; cmd_packs; cmd_universal; cmd_total_tls
  echo "## edge probes (the plugin accepts the served certificate when notAfter == expires_on of the custom certificate or of one of the pack's certificates, and a host overlaps)"
  local zone; zone=$(cf GET "$Z" | jq -r '.result.name')
  { cf GET "$Z/custom_certificates?per_page=50" | jq -r '.result[] | .hosts[]';
    cf GET "$Z/ssl/certificate_packs?status=all&per_page=50" | jq -r '.result[] | select(.type=="universal" or .type=="advanced" or .type=="total_tls") | .hosts[]'; } | sort -u | while read -r h; do
    case "$h" in
      \*.*) cmd_probe "www.${h#\*.}"; cmd_probe "$zone" "www.${h#\*.}" ;;
      *)    cmd_probe "$h"; cmd_probe "$zone" "$h" ;;
    esac
  done
}
cmd_csr() {
  local cn="$1"; shift
  local sans; sans=$(printf '%s\n' "$cn" "$@" | awk 'NF' | sort -u | jq -R . | jq -s .)
  local body; body=$(jq -n --arg cn "$cn" --arg c "${CF_CSR_C:-US}" --arg st "${CF_CSR_ST:-Utah}" --arg l "${CF_CSR_L:-Lehi}" --arg o "${CF_CSR_O:-DigiCert}" --arg kt "${CF_CSR_KEY_TYPE:-rsa2048}" --argjson sans "$sans" \
    '{common_name:$cn,country:$c,state:$st,locality:$l,organization:$o,key_type:$kt,sans:$sans}')
  echo "## POST $Z/custom_csrs $body"
  cf POST "$Z/custom_csrs" "$body" | jq '{success,errors,id:.result.id,key_type:.result.key_type,csr:.result.csr}'
}
key_or_csr() { # prints the JSON fragment for private_key or custom_csr_id
  case "$1" in
    csr:*) jq -n --arg id "${1#csr:}" '{custom_csr_id:$id}' ;;
    *)     jq -n --arg k "$(cat "$1")" '{private_key:$k}' ;;
  esac
}
cmd_upload() {
  local cert="$1" key="$2" type="${3:-sni_custom}" bundle="${4:-force}"
  local body; body=$(jq -n --arg c "$(cat "$cert")" --arg t "$type" --arg b "$bundle" '{certificate:$c,type:$t,bundle_method:$b}' | jq -s '.[0] + .[1]' - <(key_or_csr "$key"))
  echo "## POST $Z/custom_certificates (type=$type bundle_method=$bundle key=$key)"
  cf POST "$Z/custom_certificates" "$body" | jq '{success,errors,id:.result.id,status:.result.status,hosts:.result.hosts,expires_on:.result.expires_on}'
}
cmd_update() {
  local id="$1" cert="$2" key="$3" bundle="${4:-force}"
  local body; body=$(jq -n --arg c "$(cat "$cert")" --arg b "$bundle" '{certificate:$c,bundle_method:$b}' | jq -s '.[0] + .[1]' - <(key_or_csr "$key"))
  echo "## PATCH $Z/custom_certificates/$id (bundle_method=$bundle key=$key)"
  cf PATCH "$Z/custom_certificates/$id" "$body" | jq '{success,errors,id:.result.id,status:.result.status,hosts:.result.hosts,expires_on:.result.expires_on}'
}
cmd_delete()     { echo "## DELETE $Z/custom_certificates/$1"; cf DELETE "$Z/custom_certificates/$1" | show; }
cmd_delete_csr() { echo "## DELETE $Z/custom_csrs/$1"; cf DELETE "$Z/custom_csrs/$1" | show; }
cmd_delete_pack() { echo "## DELETE $Z/ssl/certificate_packs/$1"; cf DELETE "$Z/ssl/certificate_packs/$1" | show; }
cmd_universal_set() {
  echo "## PATCH $Z/ssl/universal/settings {\"enabled\":$1}"
  if [ "$1" = "false" ]; then
    echo "   WARNING: Cloudflare removes the Universal certificate from the edge at once. Hostnames without an active custom/advanced certificate lose TLS."
  fi
  cf PATCH "$Z/ssl/universal/settings" "{\"enabled\":$1}" | show
}

case "${1:-}" in
  verify)     cmd_verify ;;
  zone)       cmd_zone ;;
  certs)      cmd_certs ;;
  cert)       cmd_cert "${2:?id}" ;;
  csrs)       cmd_csrs ;;
  packs)      cmd_packs ;;
  pack)       cmd_pack "${2:?id}" ;;
  universal)  cmd_universal ;;
  total-tls)  cmd_total_tls ;;
  probe)      cmd_probe "${2:?host}" "${3:-}" ;;
  discover)   cmd_discover ;;
  csr)        shift; cmd_csr "${1:?cn}" "${@:2}" ;;
  upload)     cmd_upload "${2:?cert.pem}" "${3:?key.pem|csr:ID}" "${4:-sni_custom}" "${5:-force}" ;;
  update)     cmd_update "${2:?id}" "${3:?cert.pem}" "${4:?key.pem|csr:ID}" "${5:-force}" ;;
  delete)     cmd_delete "${2:?id}" ;;
  delete-csr) cmd_delete_csr "${2:?id}" ;;
  delete-pack) cmd_delete_pack "${2:?id}" ;;
  disable-universal) cmd_universal_set false ;;
  enable-universal)  cmd_universal_set true ;;
  *) sed -n '2,33p' "$0"; exit 1 ;;
esac
