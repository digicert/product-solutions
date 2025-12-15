bash#!/usr/bin/env bash
#set -euo pipefail
clear
# -------- Config you can override --------
BASE_DOMAIN="${BASE_DOMAIN:-tlsguru.io}"
APP_NS="${APP_NS:-tls-apache}"
ISTIO_NS="${ISTIO_NS:-istio-system}"
ISSUER_NAME="${ISSUER_NAME:-digicert-apache-acme-issuer}"
IMAGE="${IMAGE:-httpd:2.4}"
GW_SELECTOR_KEY="${GW_SELECTOR_KEY:-istio}"            
GW_SELECTOR_VAL="${GW_SELECTOR_VAL:-ingressgateway}"   

# --- DNS constants (hardcoded as requested)
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z08247632HYP0QBHTZK9D}"
ELB_DNS_BASE="${ELB_DNS_BASE:-aed919e694e6c482bab1eeca312398a4-2092444533.us-east-2.elb.amazonaws.com}"
ELB_DNS="dualstack.${ELB_DNS_BASE}"
ELB_ZONE_ID="${ELB_ZONE_ID:-Z3AADJGX6KTTL2}"
# ----------------------------------------

read -rp "Enter subdomain prefix (e.g., mike for mike.${BASE_DOMAIN}): " PREFIX
if [[ -z "${PREFIX}" ]]; then
  echo "Prefix cannot be empty." >&2
  exit 1
fi

# Derived names
FQDN="${PREFIX}.${BASE_DOMAIN}"
APP_NAME="${PREFIX}-apache"
SVC_NAME="${PREFIX}-apache-svc"
SA_NAME="${PREFIX}-apache-sa"
CERT_NAME="${PREFIX}-${BASE_DOMAIN//./-}"
TLS_SECRET="${CERT_NAME}-tls"
GW_NAME="${PREFIX}-public-gw"
VS_NAME="${PREFIX}-apache"

echo "=== Creating resources for https://${FQDN} ==="
echo "Namespaces: app=${APP_NS}, istio=${ISTIO_NS}"
echo

# --- Create ConfigMap with custom index.html
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${APP_NAME}-html
  namespace: ${APP_NS}
data:
  index.html: |
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
                height: 24px;
                line-height: 24px;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <img src="https://docs.digicert.com/en/image/uuid-4f2ee06d-5de6-d07d-3d40-86c9b376ac6c.png" alt="Site Logo" class="logo">
            <h1>Cert-Manager with Istio (CSR) Webserver Test </h1>
            <h1>${FQDN}</h1>
            <p>Istio Gateway Test Port 443 / HTTPS</p>
        </div>

    </body>
    </html>
EOF

# --- App identity + workload (CORRECTED VERSION)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${APP_NS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  namespace: ${APP_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      serviceAccountName: ${SA_NAME}
      automountServiceAccountToken: true
      containers:
      - name: httpd
        image: ${IMAGE}
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html-content
          mountPath: /usr/local/apache2/htdocs
          readOnly: true
        # Add a startup command to ensure the content is properly served
        command: ["/bin/sh"]
        args: 
          - -c
          - |
            # Copy the mounted content to ensure proper permissions
            cp -f /usr/local/apache2/htdocs/index.html /tmp/index.html 2>/dev/null || true
            # Start Apache in foreground
            httpd-foreground
      volumes:
      - name: html-content
        configMap:
          name: ${APP_NAME}-html
          items:
          - key: index.html
            path: index.html
---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${APP_NS}
spec:
  type: ClusterIP
  selector:
    app: ${APP_NAME}
  ports:
  - name: http
    port: 80
    targetPort: 80
EOF

# --- Public cert (produces secret ${TLS_SECRET} in istio-system)
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${ISTIO_NS}
spec:
  secretName: ${TLS_SECRET}
  issuerRef:
    name: ${ISSUER_NAME}
    kind: Issuer
  dnsNames:
  - ${FQDN}
  privateKey:
    rotationPolicy: Always
EOF

echo "Waiting for Certificate/${CERT_NAME} in ${ISTIO_NS} to be Ready..."
kubectl -n "${ISTIO_NS}" wait certificate/${CERT_NAME} --for=condition=Ready --timeout=5m

# --- Gateway (HTTP 80 + HTTPS 443 with credentialName)
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: ${GW_NAME}
  namespace: ${ISTIO_NS}
spec:
  selector:
    ${GW_SELECTOR_KEY}: ${GW_SELECTOR_VAL}
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - ${FQDN}
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - ${FQDN}
    tls:
      mode: SIMPLE
      credentialName: ${TLS_SECRET}
EOF

# --- VirtualService
cat <<EOF | kubectl apply -f -
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ${VS_NAME}
  namespace: ${APP_NS}
spec:
  hosts:
  - ${FQDN}
  gateways:
  - ${ISTIO_NS}/${GW_NAME}
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: ${SVC_NAME}.${APP_NS}.svc.cluster.local
        port:
          number: 80
EOF

echo
echo "=== Basic readiness checks ==="
kubectl -n "${APP_NS}" get pods -l app="${APP_NAME}"
kubectl -n "${ISTIO_NS}" get certificate "${CERT_NAME}" -o wide
kubectl -n "${ISTIO_NS}" get secret "${TLS_SECRET}" >/dev/null && echo "Secret present: ${TLS_SECRET}"

# ---------- Route53 DNS (ALIAS to dualstack ELB) ----------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
need aws

echo
echo "=== Creating/Updating Route53 A/ALIAS for ${FQDN} → ${ELB_DNS} ==="
CHANGE_JSON="$(mktemp)"
cat >"$CHANGE_JSON" <<EOF
{
  "Comment": "UPSERT alias ${FQDN} -> ${ELB_DNS}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${FQDN}.",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "${ELB_ZONE_ID}",
          "DNSName": "${ELB_DNS}",
          "EvaluateTargetHealth": true
        }
      }
    }
  ]
}
EOF

CHANGE_ID="$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${CHANGE_JSON}" \
  --query 'ChangeInfo.Id' --output text)"

echo "Submitted change: ${CHANGE_ID}"
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"
echo "✅ Route53 alias for ${FQDN} is INSYNC."

# ---------- Certificate visibility checks ----------
need openssl
need jq
need istioctl

echo
echo "=== Locating a pod for Envoy cert check ==="
POD="$(kubectl -n "${APP_NS}" get pod -l app="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "${POD}" ]]; then
  echo "No pod found with label app=${APP_NAME} in ${APP_NS}" >&2
  exit 1
fi
echo "Using pod: ${POD}"

echo
echo "=== Envoy (sidecar) cert ==="
istioctl -n "${APP_NS}" proxy-config secret "${POD}" -o json \
  | jq -r '.dynamicActiveSecrets[]?.secret?.tlsCertificate?.certificateChain?.inlineBytes' \
  | { base64 -d 2>/dev/null || true; } \
  | openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName || {
      echo "Note: If this prints nothing, the pod may not have istio-proxy injected." >&2
    }

echo
echo "=== Public cert (K8s secret used by Gateway) ==="
kubectl -n "${ISTIO_NS}" get secret "${TLS_SECRET}" -o jsonpath='{.data.tls\.crt}' \
  | base64 -d \
  | openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName

echo
echo "=== Public cert (from live endpoint via DNS) ==="
# quick DNS resolution summary (A + AAAA) then cert
command -v dig >/dev/null 2>&1 && { echo "A records:"; dig +short "${FQDN}" A || true; echo "AAAA records:"; dig +short "${FQDN}" AAAA || true; }
openssl s_client -connect "${FQDN}:443" -servername "${FQDN}" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -serial -ext subjectAltName || echo "Note: Could not retrieve cert from live endpoint yet (DNS may still be propagating)"
echo

echo
echo
# Be forgiving: default to "b" if /dev/tty isn't available or user just hits Enter
if ! read -rp "Do you want to display all current listeners, routes, or both? (l/r/b) [b]: " choice </dev/tty; then
  choice=""
fi
choice="${choice:-b}"
echo

# Find an ingressgateway pod (use your existing selector/namespace if you prefer)
POD_NAME="$(kubectl -n istio-system get pod -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -z "$POD_NAME" ]]; then
  echo "No istio ingressgateway pod found in istio-system; skipping listeners/routes."
else
  case "$choice" in
    l|L)
      echo "=== Gateway listeners that handle ${FQDN} ==="
      istioctl -n istio-system pc listeners "$POD_NAME" || true
      ;;
    r|R)
      echo "=== Gateway routes that handle ${FQDN} ==="
      istioctl -n istio-system pc routes "$POD_NAME" || true
      ;;
    b|B)
      echo "=== Gateway listeners that handle ${FQDN} ==="
      istioctl -n istio-system pc listeners "$POD_NAME" || true
      echo
      echo "=== Gateway routes that handle ${FQDN} ==="
      istioctl -n istio-system pc routes "$POD_NAME" || true
      ;;
    *)
      echo "Unrecognized choice '${choice}'. Showing both."
      echo "=== Gateway listeners that handle ${FQDN} ==="
      istioctl -n istio-system pc listeners "$POD_NAME" || true
      echo
      echo "=== Gateway routes that handle ${FQDN} ==="
      istioctl -n istio-system pc routes "$POD_NAME" || true
      ;;
  esac
fi

# This always runs, regardless of the choice or any failures above
echo
echo "=== All current Istio Components ==="
echo
kubectl get gateway,virtualservice,destinationrule,serviceentry,sidecar,peerauthentication,authorizationpolicy,workloadentry,workloadgroup,envoyfilter -A || true
echo

echo
read -p "Do you want to open Kiali dashboard? (y/n): " open_kiali </dev/tty

case $open_kiali in
  y|Y|yes|Yes|YES)
    echo "Opening Kiali dashboard..."
    istioctl dashboard kiali
    ;;
  *)
    echo "Skipping Kiali. Exiting."
    exit 0
    ;;
esac

echo
echo
echo
echo
echo "✅ Finished. Test in browser: https://${FQDN}"
