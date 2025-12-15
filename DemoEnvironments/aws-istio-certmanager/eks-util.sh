#!/bin/bash

#######################################
# EKS Cluster Selection Utility
# Lists and allows selection of EKS clusters
# Author: Mike Rudloff
#######################################

set -e

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

log_blue() {
    echo -e "${BLUE}$1${NC}"
}

# Check for required commands
require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "'$1' is required but not found. Please install it."
        exit 1
    fi
}

# Check requirements
require aws
require kubectl

# Parse command line arguments
ACTION="${1:-list}"  # Default to 'list' if not provided

# Resolve region
REGION="${AWS_DEFAULT_REGION:-}"
if [ -z "$REGION" ]; then
    REGION="$(aws configure get region 2>/dev/null || true)"
fi
if [ -z "$REGION" ]; then
    log_error "No region set. Export AWS_DEFAULT_REGION or set a default with 'aws configure'."
    exit 1
fi

# Function to list all clusters
list_clusters() {
    log_info "Scanning EKS clusters in region: ${REGION}"
    
    CLUSTERS=$(aws eks list-clusters --region "$REGION" --query 'clusters[]' --output text 2>/dev/null || echo "")
    
    if [ -z "$CLUSTERS" ]; then
        log_warning "No EKS clusters found in region: ${REGION}"
        return 1
    fi
    
    echo ""
    log_blue "EKS Clusters in ${REGION}:"
    echo ""
    
    i=1
    for CLUSTER in $CLUSTERS; do
        # Get cluster details
        STATUS=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
            --query 'cluster.status' --output text 2>/dev/null || echo "UNKNOWN")
        
        NODEGROUPS=$(aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" \
            --query 'nodegroups | length(@)' --output text 2>/dev/null || echo "0")
        
        printf " %2d) %-30s [Status: %-10s Nodegroups: %s]\n" "$i" "$CLUSTER" "$STATUS" "$NODEGROUPS"
        i=$((i+1))
    done
    echo ""
    
    return 0
}

# Function to select and configure kubectl for a cluster
select_cluster() {
    # First list clusters
    if ! list_clusters; then
        exit 0
    fi
    
    # Get cluster array
    CLUSTERS=($CLUSTERS)
    TOTAL=${#CLUSTERS[@]}
    
    # Get user selection
    read -r -p "Enter the number of the cluster to configure kubectl (or 'q' to quit): " SEL
    
    if [ "$SEL" = "q" ] || [ "$SEL" = "Q" ]; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Validate selection
    case "$SEL" in
        ''|*[!0-9]*) 
            log_error "Invalid selection."
            exit 1
            ;;
    esac
    
    if [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$TOTAL" ]; then
        log_error "Selection out of range."
        exit 1
    fi
    
    # Get selected cluster name (arrays are 0-indexed)
    CLUSTER_NAME=${CLUSTERS[$((SEL-1))]}
    
    echo ""
    log_info "Selected cluster: ${CLUSTER_NAME}"
    log_info "Updating kubeconfig..."
    
    aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
    
    if [ $? -eq 0 ]; then
        echo ""
        log_info "Successfully configured kubectl for cluster: ${CLUSTER_NAME}"
        echo ""
        log_info "Current context:"
        kubectl config current-context
        echo ""
        log_info "Cluster nodes:"
        kubectl get nodes
    else
        log_error "Failed to update kubeconfig"
        exit 1
    fi
}

# Function to show detailed cluster information
show_cluster_info() {
    if ! list_clusters; then
        exit 0
    fi
    
    # Get cluster array
    CLUSTERS=($CLUSTERS)
    TOTAL=${#CLUSTERS[@]}
    
    # Get user selection
    read -r -p "Enter the number of the cluster to inspect (or 'q' to quit): " SEL
    
    if [ "$SEL" = "q" ] || [ "$SEL" = "Q" ]; then
        log_info "Cancelled"
        exit 0
    fi
    
    # Validate selection
    case "$SEL" in
        ''|*[!0-9]*) 
            log_error "Invalid selection."
            exit 1
            ;;
    esac
    
    if [ "$SEL" -lt 1 ] || [ "$SEL" -gt "$TOTAL" ]; then
        log_error "Selection out of range."
        exit 1
    fi
    
    # Get selected cluster name
    CLUSTER_NAME=${CLUSTERS[$((SEL-1))]}
    
    echo ""
    log_info "Cluster Details for: ${CLUSTER_NAME}"
    echo "================================================"
    
    # Get cluster info
    aws eks describe-cluster --region "$REGION" --name "$CLUSTER_NAME" \
        --output table
    
    echo ""
    log_info "Nodegroups:"
    aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER_NAME" \
        --output table
    
    echo ""
    log_info "Add-ons:"
    aws eks list-addons --region "$REGION" --cluster-name "$CLUSTER_NAME" \
        --output table 2>/dev/null || echo "No add-ons found"
}

# Main menu
show_menu() {
    echo ""
    log_blue "EKS Cluster Management Utility"
    echo "================================================"
    echo "Region: ${REGION}"
    echo ""
    echo "Options:"
    echo "  1) List all clusters"
    echo "  2) Select cluster and update kubeconfig"
    echo "  3) Show detailed cluster information"
    echo "  4) Exit"
    echo ""
    read -r -p "Select an option [1-4]: " CHOICE
    
    case $CHOICE in
        1)
            list_clusters
            show_menu
            ;;
        2)
            select_cluster
            ;;
        3)
            show_cluster_info
            show_menu
            ;;
        4)
            log_info "Goodbye!"
            exit 0
            ;;
        *)
            log_error "Invalid option"
            show_menu
            ;;
    esac
}

# Handle command line arguments
case "$ACTION" in
    list)
        list_clusters
        ;;
    select)
        select_cluster
        ;;
    info)
        show_cluster_info
        ;;
    menu)
        show_menu
        ;;
    *)
        echo "Usage: $0 [list|select|info|menu]"
        echo "  list   - List all EKS clusters"
        echo "  select - Select a cluster and update kubeconfig"
        echo "  info   - Show detailed cluster information"
        echo "  menu   - Show interactive menu (default)"
        exit 1
        ;;
esac