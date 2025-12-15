#!/bin/bash

#######################################
# EKS Cluster Cleanup Script
# Removes: EKS cluster and associated resources
# Author: Mike Rudloff
# Date: $(date +%Y-%m-%d)
#######################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#######################################
# Logging functions
#######################################
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

#######################################
# Check required commands
#######################################
REQUIRED_CMDS=("aws" "eksctl" "kubectl")

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

#######################################
# Validate AWS credentials
#######################################
if ! aws sts get-caller-identity &>/dev/null; then
    log_error "AWS credentials are not configured or invalid."
    exit 1
fi

log_info "AWS credentials verified"

#######################################
# Select AWS region
#######################################
DEFAULT_REGION="us-east-2"
read -r -p "Enter AWS region [${DEFAULT_REGION}]: " REGION
REGION=${REGION:-$DEFAULT_REGION}

log_info "Scanning EKS clusters in region: ${REGION}"
echo ""

CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters' --output text)

if [ -z "$CLUSTERS" ]; then
    log_warn "No EKS clusters found in region: ${REGION}"
    exit 0
fi

echo "Found the following clusters in ${REGION}:"
echo ""

i=1
TMP=$(mktemp)
for c in $CLUSTERS; do
    echo "  ${i}) ${c}"
    echo "$c" >> "$TMP"
    i=$((i+1))
done

echo ""
read -r -p "Enter the number of the cluster you want to delete (or 'q' to quit): " SEL

if [ "$SEL" = "q" ] || [ "$SEL" = "Q" ]; then
    log_info "Aborting per user request."
    rm -f "$TMP"
    exit 0
fi

if ! [[ "$SEL" =~ ^[0-9]+$ ]]; then
    log_error "Invalid selection."
    rm -f "$TMP"
    exit 1
fi

TOTAL=$(wc -l < "$TMP" | tr -d ' ')
if [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$TOTAL" ]; then
    log_error "Selection out of range."
    rm -f "$TMP"
    exit 1
fi

# Get selected cluster name
CLUSTER_NAME=$(awk -v n="$SEL" 'NR==n{print $1}' "$TMP")
rm -f "$TMP"

echo ""
log_warning "================================================"
log_warning "You selected: ${CLUSTER_NAME} (region: ${REGION})"
log_warning "================================================"
log_warning "This will DELETE:"
log_warning "  - EKS Cluster: ${CLUSTER_NAME}"
log_warning "  - Associated resources created with the cluster"
log_warning "  - Possibly related DNS records (if you confirm)"
log_warning "================================================"
echo ""

# Confirm deletion
read -r -p "Type the cluster name '${CLUSTER_NAME}' to confirm deletion: " CONFIRM
if [ "$CONFIRM" != "$CLUSTER_NAME" ]; then
    log_error "Confirmation did not match. Aborting."
    exit 1
fi

#######################################
# Step 1: Update kubeconfig
#######################################
log_info "Starting cleanup process for cluster: ${CLUSTER_NAME}"
log_info "Updating kubeconfig for cluster ${CLUSTER_NAME}..."

aws eks update-kubeconfig \
    --name "$CLUSTER_NAME" \
    --region "$REGION"

#######################################
# Step 2: Optional DNS cleanup (Route 53)
#######################################
# Try to infer Hosted Zone ID automatically, but allow override
DEFAULT_HOSTED_ZONE_ID=""
read -r -p "Enter Route53 Hosted Zone ID (or leave blank to skip DNS cleanup): " HOSTED_ZONE_ID
HOSTED_ZONE_ID=${HOSTED_ZONE_ID:-$DEFAULT_HOSTED_ZONE_ID}

if [ -z "$HOSTED_ZONE_ID" ]; then
    log_warn "No Hosted Zone ID provided. Skipping DNS cleanup."
else
    if command -v jq &> /dev/null 2>&1; then
        log_info "Looking for DNS records associated with this cluster..."
        
        # Try to get the LoadBalancer hostname from Istio ingress
        LB_HOSTNAME=$(kubectl get svc istio-ingressgateway -n istio-system \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        
        if [ -n "$LB_HOSTNAME" ]; then
            log_info "Found LoadBalancer: ${LB_HOSTNAME}"
            
            # Find all A records that might point to this LoadBalancer
            RECORDS=$(aws route53 list-resource-record-sets \
                --hosted-zone-id "$HOSTED_ZONE_ID" \
                --query "ResourceRecordSets[?Type=='A' && AliasTarget]" \
                --output json 2>/dev/null || echo "[]")
            
            # Process each record to find matches using process substitution
            while read -r record; do
                RECORD_NAME=$(echo "$record" | jq -r '.Name')
                ALIAS_DNS=$(echo "$record" | jq -r '.AliasTarget.DNSName')
                
                # Check if this record points to our LoadBalancer
                if [[ "$ALIAS_DNS" == *"$LB_HOSTNAME"* ]] || [[ "$ALIAS_DNS" == *"elb.amazonaws.com"* ]]; then
                    log_info "Found DNS record: ${RECORD_NAME}"
                    
                    # Read user confirmation from the terminal, not from the jq pipeline
                    read -r -p "Delete DNS record ${RECORD_NAME}? (y/N): " DELETE_DNS < /dev/tty || true
                    
                    if [ "$DELETE_DNS" = "y" ] || [ "$DELETE_DNS" = "Y" ]; then
                        DELETE_JSON=$(mktemp)
                        cat > "$DELETE_JSON" << EOF
{
  "Comment": "Delete ${RECORD_NAME} DNS record",
  "Changes": [
    {
      "Action": "DELETE",
      "ResourceRecordSet": $record
    }
  ]
}
EOF
                        CHANGE_ID=$(aws route53 change-resource-record-sets \
                            --hosted-zone-id "$HOSTED_ZONE_ID" \
                            --change-batch "file://$DELETE_JSON" \
                            --query 'ChangeInfo.Id' --output text 2>/dev/null || echo "")
                        
                        if [ -n "$CHANGE_ID" ]; then
                            log_info "DNS deletion submitted for ${RECORD_NAME}"
                        fi
                        rm -f "$DELETE_JSON"
                    fi
                fi
            done < <(echo "$RECORDS" | jq -c '.[]')
        else
            log_warn "Could not determine LoadBalancer hostname from istio-ingressgateway. Skipping DNS record scan."
        fi
    else
        log_warning "jq not found. Skipping DNS record cleanup."
    fi
fi

#######################################
# Step 3 (formerly 9): Delete EKS cluster
#######################################
echo ""
log_warning "Ready to delete EKS cluster '${CLUSTER_NAME}' in region '${REGION}'"
log_warning "This operation will take several minutes and cannot be undone!"
echo ""

read -r -p "Final confirmation - type 'DELETE' to proceed: " FINAL_CONFIRM
if [ "$FINAL_CONFIRM" != "DELETE" ]; then
    log_error "Final confirmation not received. Aborting."
    exit 1
fi

log_info "Deleting EKS cluster ${CLUSTER_NAME}..."
eksctl delete cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --disable-nodegroup-eviction \
    --wait

#######################################
# Step 4 (formerly 10): Clean up local files
#######################################
log_info "Cleaning up local configuration files..."

FILES_TO_REMOVE=(
    "ekscluster-config.yaml"
    "digicert-apache-acme-issuer.yaml"
    "digicert-istio-acme-issuer.yaml"
    "ca.pem"
    "tls.key"
    "tls.crt"
)

for f in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        log_info "Removed local file: $f"
    fi
done

echo ""
log_info "================================================"
log_info "Cleanup Complete!"
log_info "================================================"
log_info ""
log_info "The following have been deleted:"
log_info "  - EKS Cluster: ${CLUSTER_NAME}"
log_info "  - (Optionally) Associated DNS records you confirmed"
log_info "  - Local configuration files"
log_info ""
log_info "Note: CloudFormation stacks and AWS resources may"
log_info "continue deleting in the background for a few minutes."
log_info "================================================"