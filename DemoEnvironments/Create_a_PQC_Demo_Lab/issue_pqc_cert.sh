#!/bin/bash

clear

# Script to create ML-DSA65 key, CSR and make DigiCert API call
# Usage: ./digicert_csr_api.sh

echo "=== DigiCert Post-Quantum Certificate Request Tool ==="

# Interactive prompts with defaults
echo ""
echo "=== Certificate Configuration ==="

# Common Name
read -p "Common Name (digicert.local): " COMMON_NAME
COMMON_NAME=${COMMON_NAME:-digicert.local}

# File names (all files will be created in /home/pqc/certs)
OUTPUT_DIR="/home/pqc/certs"
read -p "Private Key filename (${COMMON_NAME}_key.pem): " KEY_FILE
KEY_FILE=${KEY_FILE:-${COMMON_NAME}_key.pem}
KEY_FILE="${OUTPUT_DIR}/${KEY_FILE}"

read -p "CSR filename (${COMMON_NAME}_csr.pem): " CSR_FILE
CSR_FILE=${CSR_FILE:-${COMMON_NAME}_csr.pem}
CSR_FILE="${OUTPUT_DIR}/${CSR_FILE}"

read -p "Certificate filename (${COMMON_NAME}_cert.pem): " CERT_FILE
CERT_FILE=${CERT_FILE:-${COMMON_NAME}_cert.pem}
CERT_FILE="${OUTPUT_DIR}/${CERT_FILE}"

# Root and Intermediate Certificate Configuration
echo ""
echo "=== Root and Intermediate Certificate Configuration ==="

read -p "Root Certificate (/home/pqc/root-certs/ < Change Me > .pem): " ROOT_CERT
ROOT_CERT=${ROOT_CERT:-/home/pqc/root-certs/rudloff-pqc.root_2025-07-15.pem}

read -p "Intermediate Certificate (/home/pqc/root-certs/ < Change Me > .pem): " ICA_CERT
ICA_CERT=${ICA_CERT:-/home/pqc/root-certs/rudloff-pqc.ica_2025-07-15.pem}

# Full chain filename
FULLCHAIN_FILE="${OUTPUT_DIR}/${COMMON_NAME}_fullchain.pem"

echo ""
echo "=== Nginx Configuration ==="

# Nginx configuration file
NGINX_CONF="/opt/nginx/conf.d/pqc.conf"

read -p "Update Nginx configuration? (y/n) [y]: " UPDATE_NGINX
UPDATE_NGINX=${UPDATE_NGINX:-y}

if [[ "$UPDATE_NGINX" =~ ^[Yy]$ ]]; then
    echo "✓ Nginx configuration will be updated"
    NGINX_UPDATE_ENABLED=true
else
    echo "✗ Nginx configuration will not be updated"
    NGINX_UPDATE_ENABLED=false
fi

echo ""
echo "=== DigiCert API Configuration ==="

# TLM URL
read -p "TLM URL (https:// < Change Me > digicert.com/mpki/api/v1/certificate): " TLM_URL
TLM_URL=${TLM_URL:-https:// < Change Me > digicert.com/mpki/api/v1/certificate}

# TLM Profile ID
read -p "TLM Profile ID (27559841-9785 < Change Me > 3f9ec41114e5): " PROFILE_ID
PROFILE_ID=${PROFILE_ID:-27559841-9785 < Change Me > 3f9ec41114e5}

# API Key
read -p "API Key (013b98d6c0e3415 < Change Me > 9a704965c0d41): " API_KEY
API_KEY=${API_KEY:-013b98d6c0e3415 < Change Me > 9a704965c0d41}

echo ""
echo "=== Configuration Summary ==="
echo "Common Name: $COMMON_NAME"
echo "Private Key: $KEY_FILE"
echo "CSR File: $CSR_FILE"
echo "Certificate File: $CERT_FILE"
echo "Root Certificate: $ROOT_CERT"
echo "Intermediate Certificate: $ICA_CERT"
echo "Full Chain Certificate: $FULLCHAIN_FILE"
echo "Update Nginx: $UPDATE_NGINX"
echo "Nginx Config File: $NGINX_CONF"
echo "TLM URL: $TLM_URL"
echo "Profile ID: $PROFILE_ID"
echo "API Key: ${API_KEY:0:20}...${API_KEY: -10}"
echo ""

# Create output directory if it doesn't exist
echo "Ensuring output directory exists..."
if [ ! -d "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    echo "✓ Created directory: $OUTPUT_DIR"
else
    echo "✓ Directory exists: $OUTPUT_DIR"
fi

# Verify root and intermediate certificates exist
echo "Verifying certificate chain files..."
if [ ! -f "$ROOT_CERT" ]; then
    echo "⚠ Warning: Root certificate not found at $ROOT_CERT"
    echo "  Full chain creation will be skipped if certificate is issued successfully"
fi

if [ ! -f "$ICA_CERT" ]; then
    echo "⚠ Warning: Intermediate certificate not found at $ICA_CERT"
    echo "  Full chain creation will be skipped if certificate is issued successfully"
fi

# Create csr.conf file with the specified common name in the output directory
echo "Creating CSR configuration file (${OUTPUT_DIR}/csr.conf)..."
cat > "${OUTPUT_DIR}/csr.conf" << EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no
[ req_distinguished_name ]
CN = $COMMON_NAME
O = Digicert
C = US
EOF

echo "✓ Created ${OUTPUT_DIR}/csr.conf"

# Generate ML-DSA65 private key
echo "Generating ML-DSA65 private key ($KEY_FILE)..."
if openssl genpkey -algorithm MLDSA65 -out "$KEY_FILE"; then
    echo "✓ Private key generated successfully"
else
    echo "✗ Error generating private key"
    exit 1
fi

# Generate CSR
echo "Generating Certificate Signing Request ($CSR_FILE)..."
if openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -config "${OUTPUT_DIR}/csr.conf"; then
    echo "✓ CSR generated successfully"
else
    echo "✗ Error generating CSR"
    exit 1
fi

# Extract CSR content (remove headers and newlines) - using sed method
echo "Extracting CSR content for API call..."
CSR_CONTENT=$(sed '/-----BEGIN/d; /-----END/d' "$CSR_FILE" | tr -d '\n')

# Check if CSR content was extracted
if [ -z "$CSR_CONTENT" ]; then
    echo "✗ Error: Could not extract CSR content from '$CSR_FILE'"
    exit 1
fi

echo "✓ CSR content extracted (${#CSR_CONTENT} characters)"
echo "Making API call to DigiCert..."

# Create a temporary JSON file to avoid escaping issues
TEMP_JSON=$(mktemp)
cat > "$TEMP_JSON" << EOF
{
    "profile": {
        "id": "$PROFILE_ID"
    },
    "seat": {
        "seat_id": "$COMMON_NAME"
    },
    "csr": "$CSR_CONTENT",
    "attributes": {
        "subject": {
            "common_name": "$COMMON_NAME"
        }
    }
}
EOF

# Function to update nginx configuration
update_nginx_config() {
    local fullchain_file="$1"
    local key_file="$2"
    local nginx_conf="$3"
    
    echo "Updating Nginx configuration..."
    
    # Check if nginx config file exists
    if [ ! -f "$nginx_conf" ]; then
        echo "✗ Nginx configuration file not found: $nginx_conf"
        return 1
    fi
    
    # Create backup of original config
    local backup_file="${nginx_conf}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$nginx_conf" "$backup_file"
    echo "✓ Backup created: $backup_file"
    
    # Update ssl_certificate and ssl_certificate_key paths
    sed -i "s|ssl_certificate .*;|ssl_certificate $fullchain_file;|g" "$nginx_conf"
    sed -i "s|ssl_certificate_key .*;|ssl_certificate_key $key_file;|g" "$nginx_conf"
    
    echo "✓ Updated ssl_certificate to: $fullchain_file"
    echo "✓ Updated ssl_certificate_key to: $key_file"
    
    # Test nginx configuration
    echo "Testing Nginx configuration..."
    if nginx -t 2>/dev/null; then
        echo "✓ Nginx configuration test passed"
        
        # Restart nginx
        echo "Restarting Nginx..."
        if systemctl restart nginx 2>/dev/null; then
            echo "✓ Nginx restarted successfully"
            return 0
        else
            echo "✗ Failed to restart Nginx"
            echo "  Restoring backup configuration..."
            cp "$backup_file" "$nginx_conf"
            return 1
        fi
    else
        echo "✗ Nginx configuration test failed"
        echo "  Restoring backup configuration..."
        cp "$backup_file" "$nginx_conf"
        return 1
    fi
}

# Function to create full chain certificate
create_fullchain() {
    local cert_file="$1"
    local ica_cert="$2"
    local root_cert="$3"
    local fullchain_file="$4"
    
    echo "Creating full chain certificate..."
    
    # Check if all required files exist
    if [ ! -f "$cert_file" ]; then
        echo "✗ Certificate file not found: $cert_file"
        return 1
    fi
    
    if [ ! -f "$ica_cert" ]; then
        echo "✗ Intermediate certificate not found: $ica_cert"
        return 1
    fi
    
    if [ ! -f "$root_cert" ]; then
        echo "✗ Root certificate not found: $root_cert"
        return 1
    fi
    
    # Create full chain: Certificate + Intermediate + Root
    cat "$cert_file" "$ica_cert" "$root_cert" > "$fullchain_file"
    
    if [ $? -eq 0 ]; then
        echo "✓ Full chain certificate created: $fullchain_file"
        return 0
    else
        echo "✗ Error creating full chain certificate"
        return 1
    fi
}

# Function to process API response and extract certificate
process_api_response() {
    local response="$1"
    local cert_file="$2"
    
    # Check if cert_file is empty
    if [ -z "$cert_file" ]; then
        echo "✗ Certificate filename is empty"
        return 1
    fi
    
    # Extract serial number from response
    SERIAL_NUMBER=$(echo "$response" | grep -o '"serial_number":"[^"]*"' | sed 's/"serial_number":"//' | sed 's/"$//')
    
    # Check if response contains certificate field
    if echo "$response" | grep -q '"certificate":'; then
        # Extract certificate from JSON response
        local cert_content=$(echo "$response" | grep -o '"certificate":"[^"]*"' | sed 's/"certificate":"//' | sed 's/"$//')
        
        # Check if we extracted any content
        if [ -z "$cert_content" ]; then
            echo "✗ Could not extract certificate content from response"
            return 1
        fi
        
        # Replace \\n with actual newlines and save to file
        echo "$cert_content" | sed 's/\\n/\n/g' > "$cert_file"
        
        echo "✓ Certificate saved as: $cert_file"
        if [ -n "$SERIAL_NUMBER" ]; then
            echo "✓ Certificate serial number: $SERIAL_NUMBER"
        fi
        return 0
    else
        echo "✗ No certificate found in API response"
        echo "Response preview: ${response:0:200}..."
        return 1
    fi
}

# Make the API call using the temporary file
echo ""
echo "=== API Response ==="
API_RESPONSE=$(curl --silent --location "$TLM_URL" \
--header 'Content-Type: application/json' \
--header "x-api-key: $API_KEY" \
--data @"$TEMP_JSON")

# Display the API response
echo "$API_RESPONSE"

# Process the response and extract certificate
echo ""
echo "=== Processing Certificate ==="
if process_api_response "$API_RESPONSE" "$CERT_FILE"; then
    echo ""
    echo "=== Creating Full Chain Certificate ==="
    if create_fullchain "$CERT_FILE" "$ICA_CERT" "$ROOT_CERT" "$FULLCHAIN_FILE"; then
        FULLCHAIN_CREATED=true
        
        # Update Nginx configuration if requested
        if [ "$NGINX_UPDATE_ENABLED" = true ]; then
            echo ""
            echo "=== Updating Nginx Configuration ==="
            if update_nginx_config "$FULLCHAIN_FILE" "$KEY_FILE" "$NGINX_CONF"; then
                NGINX_UPDATED=true
            else
                NGINX_UPDATED=false
            fi
        else
            NGINX_UPDATED="skipped"
        fi
    else
        FULLCHAIN_CREATED=false
        NGINX_UPDATED="skipped"
    fi
    
    echo ""
    echo "=== Summary ==="
    echo "✓ Certificate request completed"
    echo "✓ Private key saved as: $KEY_FILE"
    echo "✓ CSR saved as: $CSR_FILE"
    echo "✓ Certificate saved as: $CERT_FILE"
    if [ "$FULLCHAIN_CREATED" = true ]; then
        echo "✓ Full chain certificate saved as: $FULLCHAIN_FILE"
    else
        echo "✗ Full chain certificate creation failed"
    fi
    if [ "$NGINX_UPDATED" = true ]; then
        echo "✓ Nginx configuration updated and service restarted"
    elif [ "$NGINX_UPDATED" = false ]; then
        echo "✗ Nginx configuration update failed"
    else
        echo "○ Nginx configuration update skipped"
    fi
    echo "✓ Configuration saved as: ${OUTPUT_DIR}/csr.conf"
else
    echo ""
    echo "=== Summary ==="
    echo "✓ Certificate request submitted"
    echo "✓ Private key saved as: $KEY_FILE"
    echo "✓ CSR saved as: $CSR_FILE"
    echo "✗ Certificate extraction failed"
    echo "✗ Full chain certificate not created (certificate extraction failed)"
    echo "✗ Nginx configuration not updated (certificate extraction failed)"
    echo "✓ Configuration saved as: ${OUTPUT_DIR}/csr.conf"
fi

# Clean up temporary file
rm "$TEMP_JSON"
echo
echo