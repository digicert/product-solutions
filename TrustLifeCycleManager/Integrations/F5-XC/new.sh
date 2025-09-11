#!/bin/bash

# Configuration
TENANT="digicert"
NAMESPACE="default"
CERT_NAME="tls"
API_TOKEN="<token>"
CERT_FILE="f5.tlsguru.io.crt"
KEY_FILE="f5.tlsguru.io.key"
BASE_URL="https://${TENANT}.console.ves.volterra.io/api/config/namespaces/${NAMESPACE}/certificates"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if certificate exists
check_certificate_exists() {
    local response
    response=$(curl -s -w "\n%{http_code}" -X GET \
        "${BASE_URL}/${CERT_NAME}" \
        -H "Authorization: APIToken ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ]; then
        return 0  # Certificate exists
    else
        return 1  # Certificate doesn't exist
    fi
}

# Function to upload new certificate
upload_certificate() {
    print_message "$YELLOW" "Uploading new certificate '${CERT_NAME}'..."
    
    local cert_b64=$(cat ${CERT_FILE} | base64 -w 0)
    local key_b64=$(cat ${KEY_FILE} | base64 -w 0)
    
    local response
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "${BASE_URL}" \
        -H "Authorization: APIToken ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{
            "metadata": {
                "name": "'"${CERT_NAME}"'",
                "namespace": "'"${NAMESPACE}"'"
            },
            "spec": {
                "certificate_url": "string:///'"${cert_b64}"'",
                "private_key": {
                    "clear_secret_info": {
                        "url": "string:///'"${key_b64}"'"
                    }
                }
            }
        }')
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        print_message "$GREEN" "✓ Certificate uploaded successfully!"
        return 0
    else
        print_message "$RED" "✗ Failed to upload certificate. HTTP Code: ${http_code}"
        echo "Response: $body"
        return 1
    fi
}

# Function to replace existing certificate
replace_certificate() {
    print_message "$YELLOW" "Replacing existing certificate '${CERT_NAME}'..."
    
    local cert_b64=$(cat ${CERT_FILE} | base64 -w 0)
    local key_b64=$(cat ${KEY_FILE} | base64 -w 0)
    
    local response
    response=$(curl -s -w "\n%{http_code}" -X PUT \
        "${BASE_URL}/${CERT_NAME}" \
        -H "Authorization: APIToken ${API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{
            "metadata": {
                "name": "'"${CERT_NAME}"'",
                "namespace": "'"${NAMESPACE}"'"
            },
            "spec": {
                "certificate_url": "string:///'"${cert_b64}"'",
                "private_key": {
                    "clear_secret_info": {
                        "url": "string:///'"${key_b64}"'"
                    }
                }
            }
        }')
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        print_message "$GREEN" "✓ Certificate replaced successfully!"
        return 0
    else
        print_message "$RED" "✗ Failed to replace certificate. HTTP Code: ${http_code}"
        echo "Response: $body"
        return 1
    fi
}

# Function to verify certificate
verify_certificate() {
    print_message "$YELLOW" "Verifying certificate..."
    
    local response
    response=$(curl -s -X GET \
        "${BASE_URL}/${CERT_NAME}" \
        -H "Authorization: APIToken ${API_TOKEN}" \
        -H "Content-Type: application/json")
    
    # Extract relevant information using grep and sed (works without jq)
    local cert_name=$(echo "$response" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"\([^"]*\)"/\1/')
    local expiry=$(echo "$response" | grep -o '"expiry_timestamp":"[^"]*"' | sed 's/"expiry_timestamp":"\([^"]*\)"/\1/')
    
    if [ -n "$cert_name" ]; then
        print_message "$GREEN" "✓ Certificate verified:"
        echo "  Name: ${cert_name}"
        if [ -n "$expiry" ]; then
            echo "  Expiry: ${expiry}"
        fi
    else
        print_message "$YELLOW" "Could not parse certificate details"
    fi
}

# Main script execution
main() {
    print_message "$GREEN" "=== F5 XC Certificate Management Script ==="
    echo ""
    
    # Check if certificate and key files exist
    if [ ! -f "$CERT_FILE" ]; then
        print_message "$RED" "Error: Certificate file '$CERT_FILE' not found!"
        exit 1
    fi
    
    if [ ! -f "$KEY_FILE" ]; then
        print_message "$RED" "Error: Key file '$KEY_FILE' not found!"
        exit 1
    fi
    
    print_message "$YELLOW" "Checking certificate files..."
    print_message "$GREEN" "✓ Certificate file: $CERT_FILE"
    print_message "$GREEN" "✓ Key file: $KEY_FILE"
    echo ""
    
    # Check if certificate exists
    print_message "$YELLOW" "Checking if certificate '${CERT_NAME}' exists in namespace '${NAMESPACE}'..."
    
    if check_certificate_exists; then
        print_message "$GREEN" "✓ Certificate exists. Proceeding with replacement..."
        echo ""
        
        if replace_certificate; then
            echo ""
            verify_certificate
        else
            print_message "$RED" "Failed to replace certificate!"
            exit 1
        fi
    else
        print_message "$YELLOW" "○ Certificate does not exist. Proceeding with upload..."
        echo ""
        
        if upload_certificate; then
            echo ""
            verify_certificate
        else
            print_message "$RED" "Failed to upload certificate!"
            exit 1
        fi
    fi
    
    echo ""
    print_message "$GREEN" "=== Operation completed successfully! ==="
}

# Run the main function
main