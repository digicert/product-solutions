#!/bin/bash

#######################################
# Istio Diagnostics Script
# Provides detailed Istio configuration and routing information
# Author: Mike Rudloff
#######################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Configuration
BASE_DOMAIN="tlsguru.io"
SUBDOMAIN="${1:-istio}"
FQDN="${SUBDOMAIN}.${BASE_DOMAIN}"

echo "================================================"
echo "Istio Diagnostics for ${FQDN}"
echo "================================================"
echo ""

# Check if kubectl is available and cluster is accessible
if ! kubectl get nodes > /dev/null 2>&1; then
    log_error "Cannot connect to Kubernetes cluster"
    exit 1
fi

# Check if istioctl is available
if ! command -v istioctl &> /dev/null; then
    log_error "istioctl is not installed"
    exit 1
fi

# Find an ingressgateway pod
POD_NAME=$(kubectl -n istio-system get pod -l istio=ingressgateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -z "$POD_NAME" ]; then
    log_error "No istio ingressgateway pod found in istio-system"
    echo ""
    echo "Current pods in istio-system namespace:"
    kubectl get pods -n istio-system
    echo ""
else
    log_info "Found Istio ingress gateway pod: $POD_NAME"
    echo ""
    
    # Ask user what to display
    echo "What would you like to see?"
    echo "  [L] - Gateway listeners"
    echo "  [R] - Gateway routes"
    echo "  [B] - Both listeners and routes"
    echo "  [C] - Full configuration dump"
    echo "  [S] - Service endpoints"
    echo "  [A] - All of the above"
    echo ""
    read -p "Enter your choice [L/R/B/C/S/A]: " choice
    echo ""
    
    case "$choice" in
        l|L)
            log_info "=== Gateway listeners that handle ${FQDN} ==="
            istioctl -n istio-system pc listeners "$POD_NAME" || true
            ;;
        r|R)
            log_info "=== Gateway routes that handle ${FQDN} ==="
            istioctl -n istio-system pc routes "$POD_NAME" || true
            ;;
        b|B)
            log_info "=== Gateway listeners that handle ${FQDN} ==="
            istioctl -n istio-system pc listeners "$POD_NAME" || true
            echo ""
            log_info "=== Gateway routes that handle ${FQDN} ==="
            istioctl -n istio-system pc routes "$POD_NAME" || true
            ;;
        c|C)
            log_info "=== Full configuration dump ==="
            istioctl -n istio-system pc all "$POD_NAME" || true
            ;;
        s|S)
            log_info "=== Service endpoints ==="
            istioctl -n istio-system pc endpoints "$POD_NAME" || true
            ;;
        a|A)
            log_info "=== Gateway listeners that handle ${FQDN} ==="
            istioctl -n istio-system pc listeners "$POD_NAME" || true
            echo ""
            log_info "=== Gateway routes that handle ${FQDN} ==="
            istioctl -n istio-system pc routes "$POD_NAME" || true
            echo ""
            log_info "=== Service endpoints ==="
            istioctl -n istio-system pc endpoints "$POD_NAME" || true
            echo ""
            log_info "=== Clusters configuration ==="
            istioctl -n istio-system pc clusters "$POD_NAME" || true
            ;;
        *)
            log_warning "Unrecognized choice '${choice}'. Showing both listeners and routes."
            log_info "=== Gateway listeners that handle ${FQDN} ==="
            istioctl -n istio-system pc listeners "$POD_NAME" || true
            echo ""
            log_info "=== Gateway routes that handle ${FQDN} ==="
            istioctl -n istio-system pc routes "$POD_NAME" || true
            ;;
    esac
fi

# Always show Istio components
echo ""
log_info "=== All current Istio Components ==="
echo ""
kubectl get gateway,virtualservice,destinationrule,serviceentry,sidecar,peerauthentication,authorizationpolicy,workloadentry,workloadgroup,envoyfilter -A 2>/dev/null || true

# Show certificate status
echo ""
log_info "=== Certificate Status ==="
kubectl get certificate -A 2>/dev/null || true

# Show ingress gateway service
echo ""
log_info "=== Ingress Gateway Service ==="
kubectl get svc istio-ingressgateway -n istio-system

# Check if the domain is reachable
echo ""
log_info "=== Testing HTTPS connectivity to ${FQDN} ==="

# Check DNS resolution
DNS_RESULT=$(dig +short ${FQDN} 2>/dev/null | head -n1)
if [ -n "$DNS_RESULT" ]; then
    echo "DNS resolves to: $DNS_RESULT"
    
    # Test HTTPS connection
    echo ""
    echo "Testing HTTPS connection..."
    if curl -sSf -o /dev/null -w "HTTP Status: %{http_code}\n" https://${FQDN} --max-time 5 2>/dev/null; then
        log_info "✓ HTTPS connection successful"
    else
        log_warning "HTTPS connection failed or timed out"
    fi
else
    log_warning "DNS not resolving for ${FQDN}"
fi

# Show useful commands
echo ""
echo "================================================"
echo "Useful debugging commands:"
echo "================================================"
echo "# Check Istio injection in namespace:"
echo "kubectl get namespace tls-apache -o jsonpath='{.metadata.labels.istio-injection}'"
echo ""
echo "# View Istio proxy logs:"
echo "kubectl logs -n tls-apache -l app=apache -c istio-proxy --tail=50"
echo ""
echo "# View ingress gateway logs:"
echo "kubectl logs -n istio-system -l istio=ingressgateway --tail=50"
echo ""
echo "# Check certificate details:"
echo "kubectl describe certificate apache-tls-cert -n istio-system"
echo ""
echo "# Test from inside the cluster:"
echo "kubectl run test-curl --image=curlimages/curl -it --rm -- curl -v https://${FQDN}"
echo "================================================"