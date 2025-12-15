#!/bin/bash

# Script to summarize cert-manager Issuers and ClusterIssuers
# Shows: Name, KID, Server URL, and HMAC secret (masked or full)

SHOW_SECRETS=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--show-secrets)
            SHOW_SECRETS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [-s|--show-secrets]"
            echo ""
            echo "Options:"
            echo "  -s, --show-secrets    Show full secret values (by default masked showing last 6 chars)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

echo "======================================================================"
echo "Cert-Manager Issuer Summary"
if [ "$SHOW_SECRETS" = true ]; then
    echo "⚠️  WARNING: Showing FULL secret values (unmasked)"
else
    echo "(Secret values masked - use --show-secrets to reveal)"
fi
echo "======================================================================"
echo ""

# Function to mask string showing only last 6 characters
mask_string() {
    local str="$1"
    local length=${#str}
    if [ $length -gt 6 ]; then
        local masked=$(printf '%.0s*' $(seq 1 $((length-6))))
        echo "${masked}${str: -6}"
    else
        echo "$str"
    fi
}

# Function to get secret value
get_secret_value() {
    local secret_name="$1"
    local namespace="$2"
    local key="${3:-hmacEncoded}"
    
    # Try to get the secret
    local secret_json=$(kubectl get secret "$secret_name" -n "$namespace" -o json 2>/dev/null)
    
    if [ $? -ne 0 ]; then
        echo "Error: Unable to retrieve secret"
        return 1
    fi
    
    # Try common key names
    for key_name in "$key" "hmacEncoded" "hmac" "key" "secret"; do
        local value=$(echo "$secret_json" | jq -r ".data.\"$key_name\" // empty" 2>/dev/null)
        if [ -n "$value" ]; then
            # Decode base64
            echo "$value" | base64 -d 2>/dev/null
            return 0
        fi
    done
    
    # If no common key found, list available keys
    local keys=$(echo "$secret_json" | jq -r '.data | keys[]' 2>/dev/null)
    if [ -n "$keys" ]; then
        echo "Available keys: $keys"
    else
        echo "No data found in secret"
    fi
    return 1
}

# Function to process issuer data
process_issuer() {
    local type="$1"  # "ClusterIssuer" or "Issuer"
    local namespace="$2"
    
    # Get issuers based on type
    if [ "$type" == "ClusterIssuer" ]; then
        issuers=$(kubectl get clusterissuers -o json 2>/dev/null)
    else
        if [ -n "$namespace" ]; then
            issuers=$(kubectl get issuers -n "$namespace" -o json 2>/dev/null)
        else
            issuers=$(kubectl get issuers --all-namespaces -o json 2>/dev/null)
        fi
    fi
    
    # Check if we got any results
    if [ -z "$issuers" ] || [ "$(echo "$issuers" | jq '.items | length')" -eq 0 ]; then
        return
    fi
    
    # Process each issuer
    echo "$issuers" | jq -r '.items[] | @json' | while read -r issuer; do
        name=$(echo "$issuer" | jq -r '.metadata.name')
        ns=$(echo "$issuer" | jq -r '.metadata.namespace // "cluster-wide"')
        
        # Extract ACME configuration
        keyID=$(echo "$issuer" | jq -r '.spec.acme.externalAccountBinding.keyID // empty')
        server=$(echo "$issuer" | jq -r '.spec.acme.server // empty')
        hmac_secret_name=$(echo "$issuer" | jq -r '.spec.acme.externalAccountBinding.keySecretRef.name // empty')
        hmac_secret_ns=$(echo "$issuer" | jq -r '.spec.acme.externalAccountBinding.keySecretRef.namespace // .metadata.namespace // "cluster-wide"')
        hmac_secret_key=$(echo "$issuer" | jq -r '.spec.acme.externalAccountBinding.keySecretRef.key // "hmacEncoded"')
        
        # Only display if we have ACME configuration
        if [ -n "$keyID" ] || [ -n "$server" ]; then
            echo "----------------------------------------------------------------------"
            if [ "$type" == "ClusterIssuer" ]; then
                echo "Type: ClusterIssuer"
                echo "Name: $name"
            else
                echo "Type: Issuer"
                echo "Name: $name"
                echo "Namespace: $ns"
            fi
            
            if [ -n "$keyID" ]; then
                if [ "$SHOW_SECRETS" = true ]; then
                    echo "Key ID: $keyID"
                else
                    masked_keyID=$(mask_string "$keyID")
                    echo "Key ID: $masked_keyID"
                fi
            fi
            
            if [ -n "$server" ]; then
                echo "Server: $server"
            fi
            
            if [ -n "$hmac_secret_name" ]; then
                echo "HMAC Secret Name: $hmac_secret_ns/$hmac_secret_name"
                echo "  Retrieving secret value..."
                secret_value=$(get_secret_value "$hmac_secret_name" "$hmac_secret_ns" "$hmac_secret_key")
                if [ $? -eq 0 ]; then
                    echo "  Secret Key: $hmac_secret_key"
                    if [ "$SHOW_SECRETS" = true ]; then
                        echo "  Secret Value: $secret_value"
                    else
                        masked_value=$(mask_string "$secret_value")
                        echo "  Secret Value: $masked_value"
                    fi
                else
                    echo "  $secret_value"
                fi
            fi
            echo ""
        fi
    done
}

# Check if cert-manager CRDs exist
if ! kubectl get crd clusterissuers.cert-manager.io &>/dev/null; then
    echo "Error: cert-manager CRDs not found. Is cert-manager installed?"
    exit 1
fi

# Process ClusterIssuers
echo "Scanning ClusterIssuers..."
echo ""
process_issuer "ClusterIssuer" ""

# Process Issuers in all namespaces
echo "Scanning Issuers in all namespaces..."
echo ""
process_issuer "Issuer" ""

echo "======================================================================"
echo "Summary Complete"
echo "======================================================================"