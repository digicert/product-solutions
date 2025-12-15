#!/usr/bin/env bash
set -euo pipefail

# -------- Config (must match your deployment script) --------
BASE_DOMAIN="${BASE_DOMAIN:-tlsguru.io}"
APP_NS="${APP_NS:-tls-apache}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

# DNS constants (must match deployment script)
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z08247632HYP0QBHTZK9D}"
# ----------------------------------------

# Check for required argument
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <subdomain-prefix>" >&2
  echo "Example: $0 milo" >&2
  echo "This will delete all resources for milo.${BASE_DOMAIN}" >&2
  exit 1
fi

PREFIX="$1"

# Derived names (must match deployment script logic)
FQDN="${PREFIX}.${BASE_DOMAIN}"
APP_NAME="${PREFIX}-apache"
SVC_NAME="${PREFIX}-apache-svc"
SA_NAME="${PREFIX}-apache-sa"
CERT_NAME="${PREFIX}-${BASE_DOMAIN//./-}"     # e.g. milo-tlsguru-io
TLS_SECRET="${CERT_NAME}-tls"                 # e.g. milo-tlsguru-io-tls
GW_NAME="${PREFIX}-public-gw"
VS_NAME="${PREFIX}-apache"

echo "========================================"
echo "DELETION SCRIPT FOR: ${FQDN}"
echo "========================================"
echo "This will delete the following resources:"
echo "  • VirtualService: ${VS_NAME} (${APP_NS})"
echo "  • Gateway: ${GW_NAME} (${ISTIO_NS})"
echo "  • Certificate: ${CERT_NAME} (${ISTIO_NS})"
echo "  • Secret: ${TLS_SECRET} (${ISTIO_NS})"
echo "  • Service: ${SVC_NAME} (${APP_NS})"
echo "  • Deployment: ${APP_NAME} (${APP_NS})"
echo "  • ServiceAccount: ${SA_NAME} (${APP_NS})"
echo "  • Route53 A record: ${FQDN}"
echo "========================================"
echo

read -rp "Are you sure you want to delete these resources? (yes/no): " CONFIRM
if [[ "${CONFIRM}" != "yes" ]]; then
  echo "Deletion cancelled."
  exit 0
fi

echo
echo "=== Starting deletion process ==="
echo

# Check for required tools
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need kubectl
need aws

# Delete in reverse order of dependencies

echo "1. Deleting VirtualService: ${VS_NAME} in ${APP_NS}..."
if kubectl -n "${APP_NS}" get virtualservice "${VS_NAME}" >/dev/null 2>&1; then
  kubectl -n "${APP_NS}" delete virtualservice "${VS_NAME}" && echo "   ✅ Deleted VirtualService" || echo "   ⚠️  Failed to delete VirtualService"
else
  echo "   ℹ️  VirtualService not found (may already be deleted)"
fi
echo

echo "2. Deleting Gateway: ${GW_NAME} in ${ISTIO_NS}..."
if kubectl -n "${ISTIO_NS}" get gateway "${GW_NAME}" >/dev/null 2>&1; then
  kubectl -n "${ISTIO_NS}" delete gateway "${GW_NAME}" && echo "   ✅ Deleted Gateway" || echo "   ⚠️  Failed to delete Gateway"
else
  echo "   ℹ️  Gateway not found (may already be deleted)"
fi
echo

echo "3. Deleting Certificate: ${CERT_NAME} in ${ISTIO_NS}..."
if kubectl -n "${ISTIO_NS}" get certificate "${CERT_NAME}" >/dev/null 2>&1; then
  kubectl -n "${ISTIO_NS}" delete certificate "${CERT_NAME}" && echo "   ✅ Deleted Certificate" || echo "   ⚠️  Failed to delete Certificate"
  echo "   (TLS secret ${TLS_SECRET} should be automatically removed by cert-manager)"
else
  echo "   ℹ️  Certificate not found (may already be deleted)"
fi
echo

echo "4. Checking/Deleting Secret: ${TLS_SECRET} in ${ISTIO_NS} (if still present)..."
if kubectl -n "${ISTIO_NS}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
  kubectl -n "${ISTIO_NS}" delete secret "${TLS_SECRET}" && echo "   ✅ Deleted Secret" || echo "   ⚠️  Failed to delete Secret"
else
  echo "   ℹ️  Secret not found (likely removed with Certificate)"
fi
echo

echo "5. Deleting Service: ${SVC_NAME} in ${APP_NS}..."
if kubectl -n "${APP_NS}" get service "${SVC_NAME}" >/dev/null 2>&1; then
  kubectl -n "${APP_NS}" delete service "${SVC_NAME}" && echo "   ✅ Deleted Service" || echo "   ⚠️  Failed to delete Service"
else
  echo "   ℹ️  Service not found (may already be deleted)"
fi
echo

echo "6. Deleting Deployment: ${APP_NAME} in ${APP_NS}..."
if kubectl -n "${APP_NS}" get deployment "${APP_NAME}" >/dev/null 2>&1; then
  kubectl -n "${APP_NS}" delete deployment "${APP_NAME}" && echo "   ✅ Deleted Deployment" || echo "   ⚠️  Failed to delete Deployment"
else
  echo "   ℹ️  Deployment not found (may already be deleted)"
fi
echo

echo "7. Deleting ServiceAccount: ${SA_NAME} in ${APP_NS}..."
if kubectl -n "${APP_NS}" get serviceaccount "${SA_NAME}" >/dev/null 2>&1; then
  kubectl -n "${APP_NS}" delete serviceaccount "${SA_NAME}" && echo "   ✅ Deleted ServiceAccount" || echo "   ⚠️  Failed to delete ServiceAccount"
else
  echo "   ℹ️  ServiceAccount not found (may already be deleted)"
fi
echo

echo "8. Deleting Route53 A record for ${FQDN}..."
CHANGE_JSON="$(mktemp)"
cat >"$CHANGE_JSON" <<EOF
{
  "Comment": "DELETE A record for ${FQDN}",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": {
        "Name": "${FQDN}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ELB_ZONE_ID:-Z3AADJGX6KTTL2}",
          "DNSName": "dualstack.${ELB_DNS_BASE:-a98bf6607383447a4bce82c60dfe93ea-1635590432.us-east-2.elb.amazonaws.com}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

# Check if the record exists first
RECORD_EXISTS=$(aws route53 list-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --query "ResourceRecordSets[?Name=='${FQDN}.'].Name" \
  --output text 2>/dev/null || echo "")

if [[ -n "${RECORD_EXISTS}" ]]; then
  if CHANGE_ID="$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "file://${CHANGE_JSON}" \
    --query 'ChangeInfo.Id' --output text 2>/dev/null)"; then
    echo "   Submitted change: ${CHANGE_ID}"
    aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}" 2>/dev/null || true
    echo "   ✅ Route53 A record deleted"
  else
    echo "   ⚠️  Failed to delete Route53 record (may not exist or already deleted)"
  fi
else
  echo "   ℹ️  Route53 A record not found (may already be deleted)"
fi

rm -f "$CHANGE_JSON"
echo

echo "========================================"
echo "✅ DELETION COMPLETE FOR: ${FQDN}"
echo "========================================"
echo
echo "Verification commands:"
echo "  kubectl -n ${APP_NS} get deploy,svc,sa,vs"
echo "  kubectl -n ${ISTIO_NS} get gateway,certificate,secret | grep ${PREFIX}"
echo "  dig ${FQDN}"
echo