#!/bin/bash
# Script to create Route 53 A record with alias to Load Balancer
# AWS credentials should be set as environment variables
clear
echo
# Configuration
DOMAIN="tlsguru.io"
LB_DNS_NAME="a2b2fe0f53e824336a6671dd9d49a46b-215bf820018906e4.elb.us-east-2.amazonaws.com"
LB_HOSTED_ZONE_ID="ZLMOA37VPKANP"  # Hosted Zone ID for ELB in us-east-2
REGION="us-east-2"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

###############################################################################
# MODE PROMPT: Istio mTLS demo (i) OR Resource certificate issuance (r)
###############################################################################
printf "Q: Demonstrate Istio mTLS Issuance or Resource Certificate issuance or both (i/r/b)? "
IFS= read -r _MODE_RAW
MODE="$(printf '%s' "${_MODE_RAW}" | tr '[:upper:]' '[:lower:]')"
case "${MODE}" in
  i|istio) MODE="istio" ;;
  r|resource|"") MODE="resource" ;;  # default to resource if empty
  b|both) MODE="both" ;;
  *) MODE="resource" ;;
esac

# If Istio demo requested, run that path and EXIT (so Route53/Apache flow doesn't run)
if [ "${MODE}" = "istio" ]; then
  echo
  echo "==> Istio mTLS issuance demo selected"
  echo

  # -----------------------------
  # Generate random 4-digit suffix
  # -----------------------------
  RAND_SEED="$(date +%s%N 2>/dev/null || date +%s)"
  RAND4="$(printf '%04d' $(( (RAND_SEED % 9000) + 1000 )) )"
  APP="nginx-${RAND4}"
  NAMESPACE_APP="default"

  echo "App name (used everywhere unique names are required): ${APP}"
  echo

  # -----------------------------
  # Install nginx test application
  # -----------------------------
  cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NAMESPACE_APP}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP}
  template:
    metadata:
      labels:
        app: ${APP}
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NAMESPACE_APP}
spec:
  selector:
    app: ${APP}
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML

  echo
  echo "==> Waiting for deployment rollout: ${APP} (namespace: ${NAMESPACE_APP})"
  kubectl -n "${NAMESPACE_APP}" rollout status deploy/"${APP}" --timeout=120s || true
  echo

  # -----------------------------
  # CertificateRequest status (istio-system)
  # -----------------------------
  echo "==> CertificateRequest status in istio-system:"
  kubectl get certificaterequests.cert-manager.io -n istio-system || true
  echo

  # -----------------------------
  # Optional: View cert & serial from Istio proxy secret
  # -----------------------------
  # Portable base64 decoder (GNU, macOS, or gbase64)
  decode_b64() {
    if command -v gbase64 >/dev/null 2>&1; then
      gbase64 -d
    elif base64 --help 2>&1 | grep -q -- '--decode'; then
      base64 --decode
    else
      base64 -D
    fi
  }

  printf "View Certificate (Yes/No)? "
  IFS= read -r _VIEW_CERT
  _VIEW_CERT_LC="$(printf '%s' "${_VIEW_CERT}" | tr '[:upper:]' '[:lower:]')"

  case "${_VIEW_CERT_LC}" in
    y|ye|yes)
      # Ensure istioctl and jq are available
      if ! command -v istioctl >/dev/null 2>&1; then
        echo "ERROR: istioctl not found on PATH."
        echo "       Install istioctl to inspect proxy secrets."
        exit 0
      fi
      if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: jq not found on PATH."
        echo "       Install jq to parse proxy secret JSON."
        exit 0
      fi

      # Get pod name by label app=$APP
      POD_NAME="$(kubectl -n "${NAMESPACE_APP}" get pods -l app="${APP}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [ -z "${POD_NAME}" ]; then
        echo "ERROR: Could not find pod for app=${APP} in namespace ${NAMESPACE_APP}."
        exit 0
      fi

      echo
      echo "==> Reading proxy certificate from pod '${POD_NAME}' (namespace: ${NAMESPACE_APP})"
      CERT_PEM="$(istioctl proxy-config secret "${POD_NAME}" -n "${NAMESPACE_APP}" -o json \
        | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes // empty' \
        | decode_b64 2>/dev/null || true)"

      if [ -z "${CERT_PEM}" ]; then
        echo "ERROR: Could not extract certificate chain from proxy secret (possibly not provisioned yet)."
        echo "       Try again after the proxy fetches SDS certs."
        exit 0
      fi

      echo
      echo "==================== Istio mTLS Certificate (openssl x509 -text) ===================="
      printf '%s' "${CERT_PEM}" | openssl x509 -noout -text
      echo "====================================================================================="
      echo

      # Extract serial in hex (no colons) then present both forms
      SERIAL_HEX="$(printf '%s' "${CERT_PEM}" | openssl x509 -noout -serial 2>/dev/null | awk -F= '{print $2}')"
    RESOURCE_SERIAL_HEX="${SERIAL_HEX}"
      if [ -n "${SERIAL_HEX}" ]; then
        SERIAL_COLON="$(printf '%s\n' "${SERIAL_HEX}" | sed 's/../&:/g; s/:$//')"
    RESOURCE_SERIAL_COLON="${SERIAL_COLON}"
        echo "Serial (colon-separated):"
        echo "${SERIAL_COLON}"
        echo
        echo "Serial (no colons):"
        echo "${SERIAL_COLON}" | tr -d ':'
        echo
      else
        echo "WARN: Could not parse certificate serial."
      fi
      ;;
    *)
      echo "Skipping certificate view."
      ;;
  esac

  # Done with Istio path; stop here so the resource (Route53/Ingress) flow does not run.
  exit 0
fi


# --- Function: enumerate pods and parse Istio mTLS serials using istioctl table output ---
read_istio_serials_from_namespace() {
  local ns="${NAMESPACE_APP:-default}"
  echo
  echo "==> Enumerating pods in namespace: ${ns} to read Istio mTLS serial(s)"
  if ! command -v istioctl >/dev/null 2>&1; then
    echo "ERROR: istioctl not found on PATH."
    return 0 2>/dev/null || exit 0
  fi
  # Get all pods in namespace
  local all_pods
  all_pods="$(kubectl -n "${ns}" get pods -o jsonpath='{range.items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sed '/^$/d')"
  if [ -z "${all_pods}" ]; then
    echo "ERROR: No pods found in namespace ${ns}."
    return 0 2>/dev/null || exit 0
  fi

  # Prefer pods that start with APP-; else use all pods
  local pods
  pods="$(printf '%s\n' "${all_pods}" | grep -E "^${APP}-" || true)"
  [ -z "${pods}" ] && pods="${all_pods}"

  local found=""
  while IFS= read -r pod; do
    [ -z "${pod}" ] && continue
    echo
    echo "Pod: ${pod}"
    # Show same details users expect (similar to: kubectl ... | xargs -I{} sh -c 'echo "Pod: {}"; istioctl proxy-config secret {}; echo')
    istioctl proxy-config secret "${pod}" -n "${ns}" || true

    # Parse serial: "RESOURCE NAME  TYPE  STATUS  VALID CERT  SERIAL NUMBER  NOT AFTER  NOT BEFORE"
    # We match any resource name and look for 'Cert Chain  ACTIVE', then print column 6 (serial hex)
    local serial_hex
    serial_hex="$(istioctl proxy-config secret "${pod}" -n "${ns}" 2>/dev/null \
      | awk '/^[[:graph:]]+[[:space:]]+Cert[[:space:]]+Chain[[:space:]]+ACTIVE/ {print $6; exit}')"
    if [ -n "${serial_hex}" ] && [ -z "${found}" ]; then
      found="yes"
      ISTIO_SERIAL_HEX="${serial_hex}"
      ISTIO_SERIAL_COLON="$(printf '%s\n' "${serial_hex}" | sed 's/../&:/g; s/:$//')"
      echo "Istio mTLS Serial (no colons):       ${ISTIO_SERIAL_HEX}"
      echo "Istio mTLS Serial (colon-separated): ${ISTIO_SERIAL_COLON}"
    fi
  done <<EOF
${pods}
EOF

  if [ -z "${found}" ]; then
    echo "WARN: No Istio mTLS serial parsed from any listed pod."
  fi
}

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    print_message "$RED" "Error: AWS CLI is not installed. Please install it first."
    exit 1
fi

# Check if AWS credentials are configured
if ! aws sts get-caller-identity &> /dev/null; then
    print_message "$RED" "Error: AWS credentials are not configured properly."
    print_message "$YELLOW" "Please ensure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are set."
    exit 1
fi

# Prompt for hostname
echo -n "Enter hostname (will be created as hostname.${DOMAIN}): "
read -r HOSTNAME

# Validate hostname input
if [[ -z "$HOSTNAME" ]]; then
    print_message "$RED" "Error: Hostname cannot be empty."
    exit 1
fi

# Validate hostname format (alphanumeric and hyphens only)
if ! [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    print_message "$RED" "Error: Invalid hostname format. Use only alphanumeric characters and hyphens."
    exit 1
fi

# Construct full domain name
FULL_DOMAIN="${HOSTNAME}.${DOMAIN}"

# In BOTH mode, derive APP from the host and use default namespace (no separate APP prompt).
if [ "${MODE}" = "both" ]; then
  APP="$(printf "%s" "${HOSTNAME}" | tr "[:upper:]" "[:lower:]" | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//')"
  NAMESPACE_APP="default"
  echo "==> (BOTH) Using APP derived from host: ${APP} (namespace: ${NAMESPACE_APP})"
fi


print_message "$YELLOW" "\nCreating A record for: ${FULL_DOMAIN}"
print_message "$YELLOW" "Alias target: ${LB_DNS_NAME}"

# Get the hosted zone ID for the domain
print_message "$YELLOW" "\nFetching hosted zone ID for ${DOMAIN}..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id" \
    --output text 2>/dev/null | sed 's/\/hostedzone\///')

if [[ -z "$HOSTED_ZONE_ID" ]]; then
    print_message "$RED" "Error: Could not find hosted zone for ${DOMAIN}"
    print_message "$YELLOW" "Please ensure the domain exists in Route 53."
    exit 1
fi

print_message "$GREEN" "Found hosted zone ID: ${HOSTED_ZONE_ID}"

# Check if record already exists
EXISTING_RECORD=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --query "ResourceRecordSets[?Name=='${FULL_DOMAIN}.'].Name" \
    --output text 2>/dev/null)

if [[ -n "$EXISTING_RECORD" ]]; then
    print_message "$YELLOW" "\nWarning: Record ${FULL_DOMAIN} already exists."
    echo -n "Do you want to update it? (y/n): "
    read -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_message "$YELLOW" "Operation cancelled."
        exit 0
    fi
    ACTION="UPSERT"
else
    ACTION="CREATE"
fi

# Create the change batch JSON
CHANGE_BATCH=$(cat <<EOF
{
    "Comment": "Creating/Updating A record for ${FULL_DOMAIN}",
    "Changes": [
        {
            "Action": "${ACTION}",
            "ResourceRecordSet": {
                "Name": "${FULL_DOMAIN}",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "${LB_HOSTED_ZONE_ID}",
                    "DNSName": "${LB_DNS_NAME}",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
)

# Create/Update the record
print_message "$YELLOW" "\n${ACTION}ing Route 53 record..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "${CHANGE_BATCH}" \
    --query 'ChangeInfo.Id' \
    --output text 2>/dev/null)

if [[ -z "$CHANGE_ID" ]]; then
    print_message "$RED" "Error: Failed to create/update Route 53 record."
    print_message "$YELLOW" "Please check your AWS permissions and try again."
    exit 1
fi

print_message "$GREEN" "\n✓ Successfully ${ACTION}ed A record for ${FULL_DOMAIN}"
print_message "$GREEN" "Change ID: ${CHANGE_ID}"

# Wait for change to propagate (optional)
print_message "$YELLOW" "\nWaiting for DNS change to propagate..."
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}" 2>/dev/null

if [[ $? -eq 0 ]]; then
    print_message "$GREEN" "✓ DNS change has been propagated successfully!"
else
    print_message "$YELLOW" "Note: DNS propagation check timed out, but the record was created."
    print_message "$YELLOW" "It may take a few more minutes for the change to fully propagate."
fi

print_message "$GREEN" "\n=========================================="
print_message "$GREEN" "Summary:"
print_message "$GREEN" "  Domain: ${FULL_DOMAIN}"
print_message "$GREEN" "  Type: A (Alias)"
print_message "$GREEN" "  Target: ${LB_DNS_NAME}"
print_message "$GREEN" "  Region: ${REGION}"
print_message "$GREEN" "=========================================="

###############################################################################
# Kubernetes: Apache + TLS (cert-manager) + Ingress for the same hostname
###############################################################################
# set -euo pipefail

# --- Settings you may customize (defaults match the request) ---
NAMESPACE="default"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
ISSUER_NAME="${ISSUER_NAME:-digicert-apache-acme-issuer}"
ISSUER_KIND="${ISSUER_KIND:-Issuer}"        # or "ClusterIssuer" if that's what you use
REPLICAS="${REPLICAS:-1}"
APACHE_IMAGE="${APACHE_IMAGE:-httpd:2.4}"
# ---------------------------------------------------------------

# Reuse the same hostname from the Route 53 section
if [[ -z "${FULL_DOMAIN:-}" ]]; then
  if [[ -n "${HOSTNAME:-}" && -n "${DOMAIN:-}" ]]; then
    FULL_DOMAIN="${HOSTNAME}.${DOMAIN}"
  else
    echo "ERROR: FULL_DOMAIN not set and HOSTNAME/DOMAIN not found. Aborting." >&2
    exit 1
  fi
fi

# Derive predictable resource names from the hostname
HOST_DASH="${FULL_DOMAIN//./-}"                 # e.g., ingress.tlsguru.io -> ingress-tlsguru-io
APP_BASE="apache-${HOST_DASH}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-${APP_BASE}}"
SERVICE_NAME="${SERVICE_NAME:-${APP_BASE}-svc}"
INGRESS_NAME="${INGRESS_NAME:-${APP_BASE}}"
CONFIGMAP_NAME="${CONFIGMAP_NAME:-${APP_BASE}-index}"
CERT_NAME="${CERT_NAME:-${HOST_DASH}}"
TLS_SECRET="${TLS_SECRET:-${CERT_NAME}-tls}"

echo
echo "==> Using Kubernetes namespace:       ${NAMESPACE}"
echo "==> Reusing DNS hostname (FULL_DOMAIN): ${FULL_DOMAIN}"
echo "==> Resource names will use suffix:   ${HOST_DASH}"
echo

# Create namespace if needed
# kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"

# Optionally warn if Issuer is not present (won't fail the script)
# Optionally warn if Issuer/ClusterIssuer is not present (portable, scope-aware)

LOWER_ISSUER_KIND="$(printf '%s' "${ISSUER_KIND}" | tr '[:upper:]' '[:lower:]')"
if [ "${LOWER_ISSUER_KIND}" = "clusterissuer" ]; then
  if ! kubectl get clusterissuer "${ISSUER_NAME}" >/dev/null 2>&1; then
    echo "WARN: ClusterIssuer '${ISSUER_NAME}' not found (certificate issuance will wait until it exists)."
  fi
else
  if ! kubectl -n "${NAMESPACE}" get issuer "${ISSUER_NAME}" >/dev/null 2>&1; then
    echo "WARN: Issuer '${ISSUER_NAME}' not found in namespace '${NAMESPACE}'."
    echo "      The Certificate will be created but issuance will wait until the Issuer exists."
  fi
fi

# ---------------------------------------------------------------------------
# Put the attached index.html into a ConfigMap, then mount it into each pod
# ---------------------------------------------------------------------------
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat > "${TMP_DIR}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Kubernetes Cert-Manager Webserver Test</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background-color: #f4f4f4;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }

        .container {
            background-color: #ffffff;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 0 20px rgba(0, 0, 0, 0.1);
            text-align: center;
            max-width: 500px;
        }

        h1 {
            color: #2BBA7E;
            font-size: 28px;
            margin-bottom: 20px;
        }

        p {
            color: #666666;
            font-size: 16px;
            line-height: 1.5;
            margin-bottom: 30px;
        }

        .logo {
            max-width: 150px;
            margin-bottom: 30px;
        }
#countdown {
            color: #2BBA7E;
	    font-size: 18px;
            font-weight: bold;
            margin-bottom: 20px;
            height: 24px; /* Set a fixed height for the countdown element */
            line-height: 24px; /* Vertically center the text within the element */
        }
    </style>
</head>
<body>
    <div class="container">
        <img src="https://docs.digicert.com/en/image/uuid-4f2ee06d-5de6-d07d-3d40-86c9b376ac6c.png" alt="Site Logo" class="logo">
        <h1>K8s Cert-Manager Webserver Test</h1>
        <p>Ingress Test Port 80 / HTTP</p>
    
    </div>

    <script>
        let countdownInterval;
        let countdownSeconds = 2;

        function updateCountdown() {
            const countdownDiv = document.getElementById('countdown');
            countdownDiv.textContent = `Refresh in ${countdownSeconds}`;

            if (countdownSeconds === 0) {
                window.location.reload();
            } else {
                countdownSeconds--;
            }
        }

        function startCountdown() {
            countdownInterval = setInterval(updateCountdown, 1000);
        }

        startCountdown();
    </script>
</body>
</html>
HTML

# Create/Update the ConfigMap with index.html
kubectl -n "${NAMESPACE}" create configmap "${CONFIGMAP_NAME}" \
  --from-file=index.html="${TMP_DIR}/index.html" \
  -o yaml --dry-run=client | kubectl apply -f -

# ---------------------------------------------------------------------------
# Apache Deployment + Service (mount index.html into /usr/local/apache2/htdocs)
# ---------------------------------------------------------------------------
cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
spec:
  replicas: ${REPLICAS}
  selector:
    matchLabels:
      app: ${APP_BASE}
  template:
    metadata:
      labels:
        app: ${APP_BASE}
    spec:
      containers:
      - name: httpd
        image: ${APACHE_IMAGE}
        ports:
        - containerPort: 80
        volumeMounts:
        - name: web-root
          mountPath: /usr/local/apache2/htdocs/index.html
          subPath: index.html
          readOnly: true
      volumes:
      - name: web-root
        configMap:
          name: ${CONFIGMAP_NAME}
          items:
          - key: index.html
            path: index.html
---
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: ${APP_BASE}
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML

# Wait until pods are ready (best-effort)
kubectl -n "${NAMESPACE}" rollout status deploy/"${DEPLOYMENT_NAME}" --timeout=120s || true

# ---------------------------------------------------------------------------
# Certificate for the reused hostname
# ---------------------------------------------------------------------------
cat <<YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${NAMESPACE}
spec:
  secretName: ${TLS_SECRET}
  issuerRef:
    name: ${ISSUER_NAME}
    kind: ${ISSUER_KIND}
  dnsNames:
  - ${FULL_DOMAIN}
  privateKey:
    rotationPolicy: Always   # Explicit to avoid the warning
YAML

# ---------------------------------------------------------------------------
# Ingress for the reused hostname (nginx)
# ---------------------------------------------------------------------------
cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${NAMESPACE}
  annotations:
    # Add this later if you want to force HTTPS.
    # nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: ${INGRESS_CLASS}
  tls:
  - hosts:
    - ${FULL_DOMAIN}
    secretName: ${TLS_SECRET}
  rules:
  - host: ${FULL_DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
YAML

echo
echo "Apache deployed and exposed at https://${FULL_DOMAIN}"
echo "(TLS will be served by secret: ${TLS_SECRET}, certificate resource: ${CERT_NAME})"
echo
# temporary wait for cert to be issued
sleep 300
echo
echo
echo "==> TLS Certificate details from secret: ${TLS_SECRET}"
kubectl get secret "${TLS_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.tls\.crt}' \
| base64 -D \
| openssl x509 -noout -subject -serial -issuer 

echo
echo "==> Reading Istio mTLS serial(s) from pods in namespace: ${NAMESPACE}"
kubectl get pods -n "${NAMESPACE}" -o jsonpath='{range.items[*]}{.metadata.name}{"\n"}{end}' | grep "^apache-" | xargs -I{} sh -c 'echo "Pod: {}"; istioctl proxy-config secret {} -n '${NAMESPACE}' | grep "^default" | awk "{print \"Serial:\", \$6}"; echo'