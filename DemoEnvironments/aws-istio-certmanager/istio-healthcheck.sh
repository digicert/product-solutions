#!/bin/bash

#######################################
# EKS Istio Deployment Health Check Script
# Verifies: Cluster, Istio, cert-manager, certificates
# Author: Mike Rudloff
# Date: $(date +%Y-%m-%d)
#######################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_failure() {
    echo -e "${RED}✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Initialize counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

# Function to perform a check
perform_check() {
    local check_name=$1
    local check_command=$2
    local expected_result=${3:-0}
    
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    
    echo -n "Checking $check_name... "
    
    if eval $check_command > /dev/null 2>&1; then
        if [ $? -eq $expected_result ]; then
            log_success "OK"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
            return 0
        fi
    fi
    
    log_failure "FAILED"
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
    return 1
}

# Function to check resource status
check_resource_ready() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    
    case $resource_type in
        deployment)
            kubectl get deployment $resource_name -n $namespace -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"
            ;;
        pod)
            kubectl get pods -n $namespace -l app=$resource_name --no-headers | grep -q "Running"
            ;;
        service)
            kubectl get service $resource_name -n $namespace > /dev/null 2>&1
            ;;
        issuer)
            kubectl get issuer $resource_name -n $namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"
            ;;
        certificate)
            kubectl get certificate $resource_name -n $namespace -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q "True"
            ;;
        *)
            kubectl get $resource_type $resource_name -n $namespace > /dev/null 2>&1
            ;;
    esac
}

echo "================================================"
echo "EKS Istio Deployment Health Check"
echo "================================================"
echo ""

#######################################
# Check Prerequisites
#######################################
echo "=== Prerequisites ==="

perform_check "kubectl installed" "command -v kubectl"
perform_check "eksctl installed" "command -v eksctl"
perform_check "helm installed" "command -v helm"
perform_check "istioctl installed" "command -v istioctl"
perform_check "AWS credentials" "test -n '$AWS_ACCESS_KEY_ID' && test -n '$AWS_SECRET_ACCESS_KEY'"

echo ""

#######################################
# Check Cluster
#######################################
echo "=== EKS Cluster ==="

perform_check "Kubernetes cluster accessible" "kubectl get nodes > /dev/null 2>&1 && echo 'success'"
perform_check "Cluster nodes ready" "kubectl get nodes --no-headers | grep -v NotReady"

# Get node information
if kubectl get nodes > /dev/null 2>&1; then
    NODE_COUNT=$(kubectl get nodes --no-headers | wc -l)
    log_info "Cluster has $NODE_COUNT nodes"
    kubectl get nodes --no-headers | while read line; do
        NODE_NAME=$(echo $line | awk '{print $1}')
        NODE_STATUS=$(echo $line | awk '{print $2}')
        if [ "$NODE_STATUS" == "Ready" ]; then
            echo "  ${GREEN}✓${NC} Node: $NODE_NAME (Ready)"
        else
            echo "  ${RED}✗${NC} Node: $NODE_NAME ($NODE_STATUS)"
        fi
    done
fi

echo ""

#######################################
# Check cert-manager
#######################################
echo "=== cert-manager ==="

perform_check "cert-manager namespace exists" "kubectl get namespace cert-manager"
perform_check "cert-manager deployment" "check_resource_ready deployment cert-manager cert-manager"
perform_check "cert-manager-webhook deployment" "check_resource_ready deployment cert-manager-webhook cert-manager"
perform_check "cert-manager-cainjector deployment" "check_resource_ready deployment cert-manager-cainjector cert-manager"

echo ""

#######################################
# Check Istio
#######################################
echo "=== Istio ==="

perform_check "istio-system namespace exists" "kubectl get namespace istio-system"
perform_check "istiod deployment" "check_resource_ready deployment istiod istio-system"
perform_check "istio-ingressgateway deployment" "check_resource_ready deployment istio-ingressgateway istio-system"

# Check Istio version
if command -v istioctl > /dev/null 2>&1; then
    ISTIO_VERSION=$(istioctl version --short 2>/dev/null | head -n1)
    if [ -n "$ISTIO_VERSION" ]; then
        log_info "Istio version: $ISTIO_VERSION"
    fi
fi

# Get LoadBalancer status
LB_HOST=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ -n "$LB_HOST" ]; then
    log_info "Istio Ingress LoadBalancer: $LB_HOST"
else
    log_warning "Istio Ingress LoadBalancer not ready or not found"
fi

echo ""

#######################################
# Check istio-csr
#######################################
echo "=== istio-csr ==="

perform_check "cert-manager-istio-csr deployment" "check_resource_ready deployment cert-manager-istio-csr cert-manager"
perform_check "istio-root-ca secret" "kubectl get secret istio-root-ca -n cert-manager"

echo ""

#######################################
# Check Issuers
#######################################
echo "=== Certificate Issuers ==="

perform_check "digicert-apache-acme-issuer" "check_resource_ready issuer digicert-apache-acme-issuer istio-system"
perform_check "digicert-istio-acme-issuer" "check_resource_ready issuer digicert-istio-acme-issuer istio-system"
perform_check "HMAC secret (apache)" "kubectl get secret digicert-apache-acme-hmac-secret -n istio-system"
perform_check "HMAC secret (istio)" "kubectl get secret digicert-istio-acme-hmac-secret -n istio-system"

echo ""

#######################################
# Check Test Application
#######################################
echo "=== Test Application (tls-apache) ==="

perform_check "tls-apache namespace exists" "kubectl get namespace tls-apache"
perform_check "Apache deployment" "check_resource_ready deployment apache tls-apache"
perform_check "Apache service" "check_resource_ready service apache tls-apache"
perform_check "Apache HTML ConfigMap" "kubectl get configmap apache-html -n tls-apache"
perform_check "Istio injection enabled" "kubectl get namespace tls-apache -o jsonpath='{.metadata.labels.istio-injection}' | grep -q enabled"

# Check for Gateway and VirtualService
perform_check "Istio Gateway" "kubectl get gateway apache-gateway -n tls-apache"
perform_check "Istio VirtualService" "kubectl get virtualservice apache-vs -n tls-apache"

echo ""

#######################################
# Check Certificates
#######################################
echo "=== Certificates ==="

perform_check "Apache TLS certificate" "kubectl get certificate apache-tls-cert -n istio-system"

# Check certificate status details
CERT_STATUS=$(kubectl get certificate apache-tls-cert -n istio-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
if [ "$CERT_STATUS" == "True" ]; then
    log_info "Certificate is ready and issued"
    
    # Get certificate details
    CERT_DNS=$(kubectl get certificate apache-tls-cert -n istio-system -o jsonpath='{.spec.dnsNames[0]}' 2>/dev/null)
    if [ -n "$CERT_DNS" ]; then
        log_info "Certificate DNS: $CERT_DNS"
    fi
else
    log_warning "Certificate not ready yet (this may take a few minutes)"
    
    # Show certificate events for troubleshooting
    echo "  Recent certificate events:"
    kubectl describe certificate apache-tls-cert -n istio-system | grep -A5 "Events:" | tail -n 5
fi

echo ""

#######################################
# Check Ingress Controller
#######################################
echo "=== AWS Ingress Controller ==="

perform_check "ingress-nginx namespace exists" "kubectl get namespace ingress-nginx"
perform_check "ingress-nginx-controller deployment" "kubectl get deployment ingress-nginx-controller -n ingress-nginx"

echo ""

#######################################
# Summary
#######################################
echo "================================================"
echo "Health Check Summary"
echo "================================================"
echo ""
echo "Total Checks: $TOTAL_CHECKS"
echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
echo -e "${RED}Failed: $FAILED_CHECKS${NC}"
echo ""

if [ $FAILED_CHECKS -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! Deployment is healthy.${NC}"
    EXIT_CODE=0
else
    echo -e "${RED}✗ Some checks failed. Please review the output above.${NC}"
    EXIT_CODE=1
    
    echo ""
    echo "Troubleshooting tips:"
    echo "  • Check pod logs: kubectl logs -n <namespace> <pod-name>"
    echo "  • Describe resources: kubectl describe <resource-type> <resource-name> -n <namespace>"
    echo "  • Check events: kubectl get events -A --sort-by='.lastTimestamp'"
    echo "  • Verify DNS configuration for certificate domain"
fi

echo "================================================"

# Display connection information if everything is healthy
if [ $EXIT_CODE -eq 0 ] && [ -n "$LB_HOST" ] && [ -n "$CERT_DNS" ]; then
    echo ""
    echo "Connection Information:"
    echo "----------------------"
    echo "Domain: $CERT_DNS"
    echo "LoadBalancer: $LB_HOST"
    echo ""
    echo "Next steps:"
    echo "1. Update DNS: Create CNAME record"
    echo "   $CERT_DNS -> $LB_HOST"
    echo "2. Wait for DNS propagation (5-10 minutes)"
    echo "3. Test connection:"
    echo "   curl https://$CERT_DNS"
fi

exit $EXIT_CODE