#!/usr/bin/env bash
#set -euo pipefail

# -------- Config (must match your deployment script) --------
BASE_DOMAIN="${BASE_DOMAIN:-tlsguru.io}"
APP_NS="${APP_NS:-tls-apache}"
ISTIO_NS="${ISTIO_NS:-istio-system}"

# DNS constants (must match deployment script)
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z08247632HYP0QBHTZK9D}"
# ----------------------------------------

# Check for required argument
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <subdomain-prefix> [<subdomain-prefix> ...]" >&2
  echo "Example: $0 milo" >&2
  echo "Example: $0 demo001 demo002 demo003" >&2
  echo "This will delete all resources for the specified subdomains under ${BASE_DOMAIN}" >&2
  exit 1
fi

# Check for required tools once
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need kubectl
need aws

# Store all prefixes
PREFIXES=("$@")

echo "========================================"
echo "DELETION SCRIPT FOR MULTIPLE DOMAINS"
echo "========================================"
echo "Configuration:"
echo "  Base Domain: ${BASE_DOMAIN}"
echo "  App Namespace: ${APP_NS}"
echo "  Istio Namespace: ${ISTIO_NS}"
echo ""
echo "Will delete resources for:"
for prefix in "${PREFIXES[@]}"; do
  echo "  • ${prefix}.${BASE_DOMAIN}"
done
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

# Track success/failure
FAILED_DELETIONS=()
SUCCESSFUL_DELETIONS=()

# Process each prefix
for PREFIX in "${PREFIXES[@]}"; do
  
  # Derived names (must match deployment script logic)
  FQDN="${PREFIX}.${BASE_DOMAIN}"
  APP_NAME="${PREFIX}-apache"
  SVC_NAME="${PREFIX}-apache-svc"
  SA_NAME="${PREFIX}-apache-sa"
  CERT_NAME="${PREFIX}-${BASE_DOMAIN//./-}"     # e.g. milo-tlsguru-io
  TLS_SECRET="${CERT_NAME}-tls"                 # e.g. milo-tlsguru-io-tls
  GW_NAME="${PREFIX}-public-gw"
  VS_NAME="${PREFIX}-apache"
  
  echo
  echo "========================================"
  echo "PROCESSING: ${FQDN}"
  echo "========================================"
  
  # Track if this deletion had any errors
  HAS_ERROR=false
  
  echo "1. Deleting VirtualService: ${VS_NAME} in ${APP_NS}..."
  if kubectl -n "${APP_NS}" get virtualservice "${VS_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${APP_NS}" delete virtualservice "${VS_NAME}"; then
      echo "   ✅ Deleted VirtualService"
    else
      echo "   ⚠️  Failed to delete VirtualService"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  VirtualService not found (may already be deleted)"
  fi
  
  echo "2. Deleting Gateway: ${GW_NAME} in ${ISTIO_NS}..."
  if kubectl -n "${ISTIO_NS}" get gateway "${GW_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${ISTIO_NS}" delete gateway "${GW_NAME}"; then
      echo "   ✅ Deleted Gateway"
    else
      echo "   ⚠️  Failed to delete Gateway"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  Gateway not found (may already be deleted)"
  fi
  
  echo "3. Deleting Certificate: ${CERT_NAME} in ${ISTIO_NS}..."
  if kubectl -n "${ISTIO_NS}" get certificate "${CERT_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${ISTIO_NS}" delete certificate "${CERT_NAME}"; then
      echo "   ✅ Deleted Certificate"
      echo "   (TLS secret ${TLS_SECRET} should be automatically removed by cert-manager)"
    else
      echo "   ⚠️  Failed to delete Certificate"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  Certificate not found (may already be deleted)"
  fi
  
  echo "4. Checking/Deleting Secret: ${TLS_SECRET} in ${ISTIO_NS} (if still present)..."
  if kubectl -n "${ISTIO_NS}" get secret "${TLS_SECRET}" >/dev/null 2>&1; then
    if kubectl -n "${ISTIO_NS}" delete secret "${TLS_SECRET}"; then
      echo "   ✅ Deleted Secret"
    else
      echo "   ⚠️  Failed to delete Secret"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  Secret not found (likely removed with Certificate)"
  fi
  
  echo "5. Deleting Service: ${SVC_NAME} in ${APP_NS}..."
  if kubectl -n "${APP_NS}" get service "${SVC_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${APP_NS}" delete service "${SVC_NAME}"; then
      echo "   ✅ Deleted Service"
    else
      echo "   ⚠️  Failed to delete Service"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  Service not found (may already be deleted)"
  fi
  
  echo "6. Deleting Deployment: ${APP_NAME} in ${APP_NS}..."
  if kubectl -n "${APP_NS}" get deployment "${APP_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${APP_NS}" delete deployment "${APP_NAME}"; then
      echo "   ✅ Deleted Deployment"
    else
      echo "   ⚠️  Failed to delete Deployment"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  Deployment not found (may already be deleted)"
  fi
  
  echo "7. Deleting ServiceAccount: ${SA_NAME} in ${APP_NS}..."
  if kubectl -n "${APP_NS}" get serviceaccount "${SA_NAME}" >/dev/null 2>&1; then
    if kubectl -n "${APP_NS}" delete serviceaccount "${SA_NAME}"; then
      echo "   ✅ Deleted ServiceAccount"
    else
      echo "   ⚠️  Failed to delete ServiceAccount"
      HAS_ERROR=true
    fi
  else
    echo "   ℹ️  ServiceAccount not found (may already be deleted)"
  fi
  
  echo "8. Deleting Route53 A record for ${FQDN}..."
  
  # Get the ELB DNS (you may need to adjust this based on your setup)
  ELB_DNS_BASE="${ELB_DNS_BASE:-$(kubectl -n ${ISTIO_NS} get svc istio-ingressgateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")}"
  ELB_ZONE_ID="${ELB_ZONE_ID:-Z3AADJGX6KTTL2}"  # Default for us-east-2
  
  # Check if the record exists first
  RECORD_EXISTS=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Name=='${FQDN}.'].Name" \
    --output text 2>/dev/null || echo "")
  
  if [[ -n "${RECORD_EXISTS}" ]]; then
    # Create temporary file for this specific change
    CHANGE_JSON="$(mktemp)"
    
    # If we have ELB_DNS_BASE, use it; otherwise use a placeholder
    if [[ -n "${ELB_DNS_BASE}" ]]; then
      DNS_NAME="dualstack.${ELB_DNS_BASE}"
    else
      DNS_NAME="dualstack.aed919e694e6c482bab1eeca312398a4-2092444533.us-east-2.elb.amazonaws.com"
    fi
    
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
          "HostedZoneId": "${ELB_ZONE_ID}",
          "DNSName": "${DNS_NAME}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF
    
    if CHANGE_ID="$(aws route53 change-resource-record-sets \
      --hosted-zone-id "${HOSTED_ZONE_ID}" \
      --change-batch "file://${CHANGE_JSON}" \
      --query 'ChangeInfo.Id' --output text 2>/dev/null)"; then
      echo "   Submitted change: ${CHANGE_ID}"
      aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}" 2>/dev/null || true
      echo "   ✅ Route53 A record deleted"
    else
      echo "   ⚠️  Failed to delete Route53 record (may require manual deletion)"
      HAS_ERROR=true
    fi
    
    rm -f "$CHANGE_JSON"
  else
    echo "   ℹ️  Route53 A record not found (may already be deleted)"
  fi
  
  # Track result
  if [[ "${HAS_ERROR}" == "true" ]]; then
    FAILED_DELETIONS+=("${FQDN}")
    echo "⚠️  Completed with warnings for: ${FQDN}"
  else
    SUCCESSFUL_DELETIONS+=("${FQDN}")
    echo "✅ Successfully completed deletion for: ${FQDN}"
  fi
  
done

echo
echo "========================================"
echo "DELETION SUMMARY"
echo "========================================"

if [[ ${#SUCCESSFUL_DELETIONS[@]} -gt 0 ]]; then
  echo "✅ Successfully deleted (${#SUCCESSFUL_DELETIONS[@]}):"
  for domain in "${SUCCESSFUL_DELETIONS[@]}"; do
    echo "   • ${domain}"
  done
fi

if [[ ${#FAILED_DELETIONS[@]} -gt 0 ]]; then
  echo ""
  echo "⚠️  Deletions with warnings (${#FAILED_DELETIONS[@]}):"
  for domain in "${FAILED_DELETIONS[@]}"; do
    echo "   • ${domain}"
  done
fi

echo
echo "========================================"
echo "Verification commands:"
echo "  kubectl -n ${APP_NS} get deploy,svc,sa,vs"
echo "  kubectl -n ${ISTIO_NS} get gateway,certificate,secret"
echo "  For DNS checks:"
for prefix in "${PREFIXES[@]}"; do
  echo "    dig ${prefix}.${BASE_DOMAIN}"
done
echo

# Exit with error if any deletions failed
if [[ ${#FAILED_DELETIONS[@]} -gt 0 ]]; then
  exit 1
fi

exit 0
