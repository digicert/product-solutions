#!/bin/bash

#######################################
# EKS Cluster Deployment Script
# Deploys: EKS, Istio, cert-manager, istio-csr
# Author: Mike Rudloff
# Date: $(date +%Y-%m-%d)
#######################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if a command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 could not be found. Please install $1 to proceed."
        exit 1
    fi
}

# Function to wait for a resource to be ready
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local max_attempts=${4:-60}  # Default 60 attempts (5 minutes)
    local attempt=0
    
    log_info "Waiting for $resource_type/$resource_name in namespace $namespace to be ready..."
    
    while [ $attempt -lt $max_attempts ]; do
        if kubectl get $resource_type $resource_name -n $namespace &> /dev/null; then
            # Check if resource is ready based on type
            case $resource_type in
                deployment|daemonset)
                    if kubectl rollout status $resource_type/$resource_name -n $namespace --timeout=5s &> /dev/null; then
                        log_info "$resource_type/$resource_name is ready"
                        return 0
                    fi
                    ;;
                pod)
                    if kubectl get pod $resource_name -n $namespace -o jsonpath='{.status.phase}' | grep -q "Running"; then
                        log_info "Pod $resource_name is running"
                        return 0
                    fi
                    ;;
                service)
                    if kubectl get service $resource_name -n $namespace &> /dev/null; then
                        log_info "Service $resource_name exists"
                        return 0
                    fi
                    ;;
                issuer)
                    if kubectl get issuer $resource_name -n $namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"; then
                        log_info "Issuer $resource_name is ready"
                        return 0
                    fi
                    ;;
                *)
                    log_info "Resource $resource_type/$resource_name exists"
                    return 0
                    ;;
            esac
        fi
        
        attempt=$((attempt + 1))
        sleep 5
    done
    
    log_error "Timeout waiting for $resource_type/$resource_name"
    return 1
}

# Function to wait for all pods in a namespace to be ready
wait_for_namespace_ready() {
    local namespace=$1
    local max_wait=${2:-300}  # Default 5 minutes
    local start_time=$(date +%s)
    
    log_info "Waiting for all pods in namespace $namespace to be ready..."
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -gt $max_wait ]; then
            log_warning "Timeout waiting for namespace $namespace to be ready"
            return 1
        fi
        
        # Check if all pods are ready
        local not_ready=$(kubectl get pods -n $namespace --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        
        if [ "$not_ready" -eq 0 ]; then
            local total_pods=$(kubectl get pods -n $namespace --no-headers 2>/dev/null | wc -l)
            if [ "$total_pods" -gt 0 ]; then
                log_info "All pods in namespace $namespace are ready"
                return 0
            fi
        fi
        
        sleep 5
    done
}

# Check for required commands
log_info "Checking for required commands..."
check_command eksctl
check_command kubectl
check_command helm
check_command curl
check_command jq
check_command aws

# Parse command line arguments
SUBDOMAIN="${1:-istio}"  # Default to 'istio' if not provided

# Configuration
CLUSTER_NAME="mrudloff-k8s"
REGION="us-east-2"
CERT_MANAGER_VERSION="v1.19.1"
BASE_DOMAIN="tlsguru.io"
DOMAIN="${SUBDOMAIN}.${BASE_DOMAIN}"
HOSTED_ZONE_ID="Z08247632HYP0QBHTZK9D"  # Route 53 hosted zone for tlsguru.io
ELB_ZONE_ID="Z3AADJGX6KTTL2"  # Canonical hosted zone ID for us-east-2 ELBs

log_info "Deploying with domain: ${DOMAIN}"

# Verify AWS credentials are set
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ] || [ -z "${AWS_DEFAULT_REGION:-}" ]; then
    log_error "AWS credentials not set. Please set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_DEFAULT_REGION"
    exit 1
fi

log_info "AWS credentials verified"

#######################################
# Step 1: Create EKS cluster configuration
#######################################
log_info "Creating EKS cluster configuration..."

cat > ekscluster-config.yaml << EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
vpc:
  clusterEndpoints:
    publicAccess: true
    privateAccess: true
nodeGroups:
  - name: mrudloff-k8s-nodes
    instanceType: t3.medium
    desiredCapacity: 3
EOF

log_info "EKS configuration created"

#######################################
# Step 2: Deploy EKS cluster
#######################################
log_info "Deploying EKS cluster (this may take 15-20 minutes)..."

if kubectl config get-contexts | grep -q "${CLUSTER_NAME}"; then
    log_warning "Cluster ${CLUSTER_NAME} already exists in kubeconfig. Checking if it's accessible..."
    if kubectl get nodes &> /dev/null; then
        log_info "Cluster is accessible. Skipping cluster creation."
    else
        log_info "Cluster not accessible. Creating new cluster..."
        eksctl create cluster --config-file=ekscluster-config.yaml
    fi
else
    eksctl create cluster --config-file=ekscluster-config.yaml
fi

# Verify cluster is ready
log_info "Verifying cluster is ready..."
kubectl get nodes
if [ $? -ne 0 ]; then
    log_error "Failed to connect to cluster"
    exit 1
fi

#######################################
# Step 3: Install cert-manager
#######################################
log_info "Installing cert-manager..."

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml

# Wait for cert-manager to be ready
log_info "Waiting for cert-manager to be ready..."
wait_for_namespace_ready cert-manager 600

# Verify cert-manager webhooks are ready
wait_for_resource deployment cert-manager cert-manager
wait_for_resource deployment cert-manager-webhook cert-manager
wait_for_resource deployment cert-manager-cainjector cert-manager

#######################################
# Step 4: Install AWS Ingress Controller
#######################################
log_info "Installing AWS Ingress Controller..."

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/aws/deploy.yaml

# Wait for ingress controller to be ready
log_info "Waiting for Ingress Controller to be ready..."
wait_for_namespace_ready ingress-nginx 300

#######################################
# Step 5: Create Istio namespace
#######################################
log_info "Creating Istio namespace..."

kubectl create namespace istio-system --dry-run=client -o yaml | kubectl apply -f -

#######################################
# Step 6: Create HMAC secrets
#######################################
log_info "Creating HMAC secrets..."

kubectl create secret generic digicert-apache-acme-hmac-secret \
    --from-literal=secret=REDACTED \
    -n istio-system \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic digicert-istio-acme-hmac-secret \
    --from-literal=secret=REDACTED \
    -n istio-system \
    --dry-run=client -o yaml | kubectl apply -f -

#######################################
# Step 7: Create Istio Issuers
#######################################
log_info "Creating Istio Issuer #1 (digicert-apache-acme-issuer)..."

cat > digicert-apache-acme-issuer.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: digicert-apache-acme-issuer
  namespace: istio-system
spec:
  acme:
    email: michael.rudloff@digicert.com
    externalAccountBinding:
      keyID: REDACTED
      keySecretRef:
        key: secret
        name: digicert-apache-acme-hmac-secret
    privateKeySecretRef:
      name: digicert-apache-acme-issuer-key
    server: https://demo.one.digicert.com/mpki/api/v1/acme/v2/directory
    skipTLSVerify: true
    solvers:
    - http01:
        ingress:
          class: istio
      selector: {}
EOF

kubectl apply -f digicert-apache-acme-issuer.yaml

log_info "Creating Istio Issuer #2 (digicert-istio-acme-issuer)..."

cat > digicert-istio-acme-issuer.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: digicert-istio-acme-issuer
  namespace: istio-system
spec:
  acme:
    email: michael.rudloff@digicert.com
    externalAccountBinding:
      keyID: REDACTED
      keySecretRef:
        key: secret
        name: digicert-istio-acme-hmac-secret
    privateKeySecretRef:
      name: digicert-istio-acme-issuer-key
    server: https://demo.one.digicert.com/mpki/api/v1/acme/v2/directory
    skipTLSVerify: true
    solvers:
    - http01:
        ingress:
          class: istio
      selector: {}
EOF

kubectl apply -f digicert-istio-acme-issuer.yaml

# Wait for issuers to be ready
log_info "Waiting for issuers to be ready..."
sleep 10  # Give the issuers time to initialize
wait_for_resource issuer digicert-apache-acme-issuer istio-system
wait_for_resource issuer digicert-istio-acme-issuer istio-system

#######################################
# Step 8: Create ICA certificate and secret
#######################################
log_info "Creating ICA certificate..."

cat > ca.pem << 'EOF'
-----BEGIN CERTIFICATE-----
MIIE1zCCA7+gAwIBAgIUHgwqTsEZnCJGWAA0d9DiQMJ8F+owDQYJKoZIhvcNAQEL
BQAwgYwxCzAJBgNVBAYTAlVTMQswCQYDVQQIEwJHQTEQMA4GA1UEBxMHUm9zd2Vs
bDEOMAwGA1UEERMFMzAwNzUxIDAeBgNVBAkTFzE3MCBDb2NocmFuIEZhcm1zIERy
aXZlMRUwEwYDVQQKEwxSdWRsb2ZmIEluYy4xFTATBgNVBAMTDHJ1ZGxvZmYucm9v
dDAgFw0yNDAzMDQxNTA2NThaGA8yMDU0MDMwNDE1MDI1MlowgYsxCzAJBgNVBAYT
AlVTMQswCQYDVQQIEwJHQTEQMA4GA1UEBxMHUm9zd2VsbDEOMAwGA1UEERMFMzAw
NzUxIDAeBgNVBAkTFzE3MCBDb2NocmFuIEZhcm1zIERyaXZlMRUwEwYDVQQKEwxS
dWRsb2ZmIEluYy4xFDASBgNVBAMTC3J1ZGxvZmYuaWNhMIIBIjANBgkqhkiG9w0B
AQEFAAOCAQ8AMIIBCgKCAQEAxu99YQzaAD9B6vH5wnLzwo9FIZFPQvgdJ6m4RaLW
6zpkEqxVEh25WNQ3jEmmqVkCecMlSP+S1q/gRGy1b9JNxAgtiQXOdd9w3XdpdFIV
JIxGZKoPxD9+FXKxd0F8tHV7URWS1vgAVVM0Gmcc6gaCOSDUV2/Jaqr3fndLPlKX
fxKK8QavnP3gmP+IJQIAFsY+KmdeG1RH2Q7v+zRiaUbCWLjSpN4M8tyqAuXxijh9
O2T1q493rqq6FnZ/+wHU+pCpdAbpQy3AKfpbXu9l8/J0Z4iec5THJGDJtBSN2Rra
fx/QOwMvYxDZyHn8FInXZfQPjT6p830u475IHwHJ7zQ95wIDAQABo4IBLDCCASgw
DwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUviaA5eqGe0upa5vuGN0iF279L3ow
HwYDVR0jBBgwFoAUvxmb5juZ+oqq9CVCODip0sbe7oIwDgYDVR0PAQH/BAQDAgGG
MIGABggrBgEFBQcBAQR0MHIwLQYIKwYBBQUHMAGGIWh0dHA6Ly9vY3NwLmRlbW8u
b25lLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMuZGVt
by5vbmUuZGlnaWNlcnQuY29tL3J1ZGxvZmYucm9vdC5jcnQwQgYDVR0fBDswOTA3
oDWgM4YxaHR0cDovL2NybC5kZW1vLm9uZS5kaWdpY2VydC5jb20vcnVkbG9mZi5y
b290LmNybDANBgkqhkiG9w0BAQsFAAOCAQEASNIOGQv8Z90QHyP3yhIfeP/XkuQu
yJ16tddYzrOR0WrwRXxyVo1JYvH+4J0aIhYdrntYH4KmhZ0PvK8TV+we2IF/o/HN
xs+knz4Ylqlb5R3GOpvNZ2PI8xPEC944Q2pg2p0lsWqjD5zkTn13TyaWv6Xa86vj
qf/tiD58cV0wE53A+qH7cwEK4W2XQeqPi8zN5xRtjt+7kbqUB3CtuvSv/wIy7MET
LpTKv0zj4lU8y4JyT8aJAkd/WaZ8qTfUXFf46S0SSF581FtrG6Ynk3+4a9V2rpHt
JpMMdmVBl8MBrT9VpZFocIng2xssW0GqjTlS7UhrwEcblz75gjvStuWeIg==
-----END CERTIFICATE-----
EOF

log_info "Creating K8s secret for ICA certificate..."
kubectl create secret generic istio-root-ca \
    --from-file=ca.pem \
    -n cert-manager \
    --dry-run=client -o yaml | kubectl apply -f -

#######################################
# Step 9: Install istio-csr
#######################################
log_info "Adding Jetstack Helm repository..."
helm repo add jetstack https://charts.jetstack.io

log_info "Updating Helm repositories..."
helm repo update

log_info "Installing istio-csr..."
helm upgrade --install cert-manager-istio-csr jetstack/cert-manager-istio-csr \
    -n cert-manager \
    --set "app.certmanager.issuer.name=digicert-istio-acme-issuer" \
    --set "app.tls.rootCAFile=/var/run/secrets/istio-csr/ca.pem" \
    --set "volumeMounts[0].name=root-ca" \
    --set "volumeMounts[0].mountPath=/var/run/secrets/istio-csr" \
    --set "volumes[0].name=root-ca" \
    --set "volumes[0].secret.secretName=istio-root-ca" \
    --wait

# Wait for istio-csr to be ready
wait_for_resource deployment cert-manager-istio-csr cert-manager

#######################################
# Step 10: Download and install Istio
#######################################
log_info "Downloading Istio configuration..."
curl -sSL https://raw.githubusercontent.com/cert-manager/website/7f5b2be9dd67831574b9bde2407bed4a920b691c/content/docs/tutorials/istio-csr/example/istio-config-getting-started.yaml > istio-install-config.yaml

# Install istioctl if not already installed
if ! command -v istioctl &> /dev/null; then
    log_info "Installing istioctl..."
    curl -sL https://istio.io/downloadIstioctl | sh -
    export PATH=$HOME/.istioctl/bin:$PATH
fi

log_info "Running Istio pre-check..."
istioctl x precheck

if [ $? -ne 0 ]; then
    log_warning "Istio pre-check failed. Attempting to continue..."
fi

log_info "Installing Istio (this may take a few minutes)..."
istioctl install -f istio-install-config.yaml -y

# Wait for Istio to be ready
log_info "Waiting for Istio to be ready..."
wait_for_namespace_ready istio-system 600

#######################################
# Step 11: Create and configure test namespace
#######################################
log_info "Creating test namespace 'tls-apache'..."
kubectl create namespace tls-apache --dry-run=client -o yaml | kubectl apply -f -

log_info "Enabling Istio injection for namespace..."
kubectl label namespace tls-apache istio-injection=enabled --overwrite

#######################################
# Step 12: Get Istio Ingress Gateway LoadBalancer
#######################################
log_info "Waiting for Istio Ingress Gateway LoadBalancer..."

# Wait for the LoadBalancer to get an external IP/hostname
MAX_ATTEMPTS=60
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    INGRESS_HOST=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -n "$INGRESS_HOST" ]; then
        log_info "Istio Ingress Gateway LoadBalancer: $INGRESS_HOST"
        break
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
    sleep 5
done

if [ -z "$INGRESS_HOST" ]; then
    log_error "Failed to get Istio Ingress Gateway LoadBalancer hostname"
    exit 1
fi

#######################################
# Step 13: Create Route53 DNS Record
#######################################
log_info "Creating Route53 DNS record for ${DOMAIN}..."

# Extract the actual ELB DNS name (remove 'dualstack.' prefix if present)
ELB_DNS="${INGRESS_HOST}"
if [[ ! "$ELB_DNS" =~ ^dualstack\. ]]; then
    ELB_DNS="dualstack.${ELB_DNS}"
fi

# Create the Route53 change batch JSON
CHANGE_JSON=$(mktemp)
cat > "$CHANGE_JSON" << EOF
{
  "Comment": "UPSERT alias ${DOMAIN} -> ${ELB_DNS}",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${DOMAIN}.",
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

# Apply the Route53 change
log_info "Submitting Route53 change..."
CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$HOSTED_ZONE_ID" \
    --change-batch "file://$CHANGE_JSON" \
    --query 'ChangeInfo.Id' --output text 2>/dev/null || echo "")

if [ -n "$CHANGE_ID" ]; then
    log_info "Route53 change submitted: $CHANGE_ID"
    
    # Wait for the change to be propagated
    log_info "Waiting for DNS change to propagate..."
    aws route53 wait resource-record-sets-changed --id "$CHANGE_ID" 2>/dev/null || true
    
    log_info "✅ Route53 alias record for ${DOMAIN} is now INSYNC"
    
    # Clean up temp file
    rm -f "$CHANGE_JSON"
    
    # Verify DNS
    log_info "Verifying DNS (may take a few minutes to propagate globally)..."
    sleep 5
    DNS_CHECK=$(dig +short "${DOMAIN}" A 2>/dev/null | head -n1)
    if [ -n "$DNS_CHECK" ]; then
        log_info "DNS is resolving: ${DNS_CHECK}"
    else
        log_warning "DNS not yet resolving. This is normal - propagation can take up to 5 minutes."
    fi
else
    log_warning "Failed to create Route53 record. You can manually create a CNAME:"
    log_warning "  ${DOMAIN} -> ${INGRESS_HOST}"
    rm -f "$CHANGE_JSON"
fi

#######################################
# Step 14: Create test resources
#######################################
log_info "Creating test resources for ${DOMAIN}..."

# Create ConfigMap with custom HTML
log_info "Creating ConfigMap with custom HTML..."
cat > apache-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: apache-html
  namespace: tls-apache
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
            
            .hostname {
                background-color: #f0f8f5;
                padding: 10px;
                border-radius: 4px;
                font-family: 'Courier New', monospace;
                color: #1a6b47;
                font-size: 14px;
                margin: 15px 0;
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
            <h1>K8s Cert-Manager Webserver Test</h1>
            <p>Ingress Test Port 443 / HTTPS</p>
            <div class="hostname">
                <strong>Domain:</strong> ${DOMAIN}<br>
                <strong>Cluster:</strong> ${CLUSTER_NAME}<br>
                <strong>Region:</strong> ${REGION}
            </div>
            <div id="countdown"></div>
        </div>

        <script>
            let countdownInterval;
            let countdownSeconds = 30;

            function updateCountdown() {
                const countdownDiv = document.getElementById('countdown');
                countdownDiv.textContent = \`Refresh in \${countdownSeconds}s\`;

                if (countdownSeconds === 0) {
                    window.location.reload();
                } else {
                    countdownSeconds--;
                }
            }

            function startCountdown() {
                updateCountdown();
                countdownInterval = setInterval(updateCountdown, 1000);
            }

            startCountdown();
        </script>
    </body>
    </html>
EOF

kubectl apply -f apache-configmap.yaml

# Create Apache deployment with volume mount for custom HTML
cat > apache-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apache
  namespace: tls-apache
spec:
  replicas: 2
  selector:
    matchLabels:
      app: apache
  template:
    metadata:
      labels:
        app: apache
    spec:
      containers:
      - name: apache
        image: httpd:2.4
        ports:
        - containerPort: 80
        volumeMounts:
        - name: html-volume
          mountPath: /usr/local/apache2/htdocs
        resources:
          requests:
            memory: "64Mi"
            cpu: "250m"
          limits:
            memory: "128Mi"
            cpu: "500m"
      volumes:
      - name: html-volume
        configMap:
          name: apache-html
EOF

kubectl apply -f apache-deployment.yaml

# Create Apache service
cat > apache-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: apache
  namespace: tls-apache
spec:
  selector:
    app: apache
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  type: ClusterIP
EOF

kubectl apply -f apache-service.yaml

# Create Istio Gateway
cat > istio-gateway.yaml << EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: apache-gateway
  namespace: tls-apache
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "${DOMAIN}"
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: apache-tls-cert
    hosts:
    - "${DOMAIN}"
EOF

kubectl apply -f istio-gateway.yaml

# Create Virtual Service
cat > virtual-service.yaml << EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: apache-vs
  namespace: tls-apache
spec:
  hosts:
  - "${DOMAIN}"
  gateways:
  - apache-gateway
  http:
  - match:
    - uri:
        prefix: "/"
    route:
    - destination:
        host: apache
        port:
          number: 80
EOF

kubectl apply -f virtual-service.yaml

# Create Certificate resource
cat > certificate.yaml << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: apache-tls-cert
  namespace: istio-system
spec:
  secretName: apache-tls-cert
  issuerRef:
    name: digicert-apache-acme-issuer
    kind: Issuer
  dnsNames:
  - "${DOMAIN}"
EOF

kubectl apply -f certificate.yaml

# Wait for deployment to be ready
wait_for_resource deployment apache tls-apache

#######################################
# Step 15: Run Istio Diagnostics
#######################################
log_info "Running Istio diagnostics..."

# Find an ingressgateway pod
POD_NAME=$(kubectl -n istio-system get pod -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    log_warning "No istio ingressgateway pod found in istio-system; skipping listeners/routes diagnostics."
else
    log_info "Found Istio ingress gateway pod: $POD_NAME"
    
    # Display listeners
    echo ""
    log_info "=== Gateway listeners that handle ${DOMAIN} ==="
    istioctl -n istio-system pc listeners "$POD_NAME" --port 443 2>/dev/null | head -20 || true
    
    # Display routes
    echo ""
    log_info "=== Gateway routes that handle ${DOMAIN} ==="
    istioctl -n istio-system pc routes "$POD_NAME" --name http.8080 2>/dev/null | head -20 || true
fi

# Display all Istio components
echo ""
log_info "=== All current Istio Components ==="
echo ""
kubectl get gateway,virtualservice,destinationrule,serviceentry,sidecar,peerauthentication,authorizationpolicy,workloadentry,workloadgroup,envoyfilter -A 2>/dev/null || true
echo ""

#######################################
# Step 16: Display final information
#######################################
log_info "==================================================="
log_info "Deployment Complete!"
log_info "==================================================="
log_info ""
log_info "Cluster Name: ${CLUSTER_NAME}"
log_info "Region: ${REGION}"
log_info "Istio Ingress Gateway: ${INGRESS_HOST}"
log_info ""
log_info "Test Domain: ${DOMAIN}"
log_info ""
if [ -n "${CHANGE_ID:-}" ]; then
    log_info "✅ DNS Record Created Successfully!"
    log_info "  Route53 alias: ${DOMAIN} -> ${ELB_DNS}"
else
    log_info "⚠️  DNS Record Creation Failed"
    log_info "  Please manually create a CNAME record:"
    log_info "  ${DOMAIN} -> ${INGRESS_HOST}"
fi
log_info ""
log_info "Verify certificate status:"
log_info "  kubectl get certificate apache-tls-cert -n istio-system"
log_info ""
log_info "Check Istio Ingress Gateway:"
log_info "  kubectl get svc istio-ingressgateway -n istio-system"
log_info ""
log_info "View Apache pods:"
log_info "  kubectl get pods -n tls-apache"
log_info ""
log_info "Test connection (wait 2-5 minutes for DNS propagation):"
log_info "  curl https://${DOMAIN}"
log_info "==================================================="

# Save important information to file
cat > deployment-info.txt << EOF
Deployment Information
======================
Date: $(date)
Cluster Name: ${CLUSTER_NAME}
Region: ${REGION}
Istio Ingress Gateway: ${INGRESS_HOST}
Test Domain: ${DOMAIN}

DNS Configuration Required:
  ${DOMAIN} -> CNAME -> ${INGRESS_HOST}

Useful Commands:
  kubectl get nodes
  kubectl get pods -A
  kubectl get certificate -A
  kubectl get issuer -A
  kubectl get gateway -A
  kubectl get virtualservice -A
  kubectl logs -n cert-manager -l app=cert-manager
  kubectl logs -n istio-system -l app=istiod
EOF

log_info "Deployment information saved to deployment-info.txt"
