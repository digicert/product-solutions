#!/bin/bash
clear
: <<'SCRIPT_INFO'
Demo Wrapper Script for TLM Agent Post-Script Testing
======================================================
This script simulates the TLM agent by:
1. Prompting for certificate and argument inputs
2. Generating a self-signed certificate with OpenSSL
3. Building the JSON payload structure
4. Base64 encoding it into DC1_POST_SCRIPT_DATA
5. Executing the target post-script

Usage: ./awr-demo-wrapper.sh <path-to-post-script>
Example: ./awr-demo-wrapper.sh ./awr-template-crt.sh
SCRIPT_INFO

# Header
echo ""
echo "========================================="
echo "  TLM Agent Demo Wrapper Script"
echo "========================================="
echo ""

# Check if target script is provided
if [ -z "$1" ]; then
    echo "ERROR: No target script specified"
    echo ""
    echo "Usage: $0 <path-to-post-script>"
    echo "Example: $0 ./awr-template-crt.sh"
    echo ""
    exit 1
fi

TARGET_SCRIPT="$1"

# Check if target script exists and is executable
if [ ! -f "$TARGET_SCRIPT" ]; then
    echo "ERROR: Target script not found: $TARGET_SCRIPT"
    exit 1
fi

if [ ! -x "$TARGET_SCRIPT" ]; then
    echo "WARNING: Target script is not executable. Attempting to make it executable..."
    chmod +x "$TARGET_SCRIPT"
fi

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    echo "ERROR: OpenSSL is not installed or not in PATH"
    exit 1
fi

echo "Target Script: $TARGET_SCRIPT"
echo ""
echo "Enter values for JSON payload (press Enter to accept defaults):"
echo ""

# --- Certificate Information ---
echo "--- Certificate Information ---"
echo ""

# Common Name
read -p "Common Name [awr-demo.com]: " COMMON_NAME
COMMON_NAME=${COMMON_NAME:-awr-demo.com}

# Certificate Folder
read -p "Certificate Folder [/home/ubuntu/tlm_agent_3.1.2_linux64/.secrets/${COMMON_NAME}]: " CERT_FOLDER
CERT_FOLDER=${CERT_FOLDER:-/home/ubuntu/tlm_agent_3.1.2_linux64/.secrets/${COMMON_NAME}}

# Remove trailing slash if present
CERT_FOLDER=${CERT_FOLDER%/}

# Auto-generate certificate and key filenames from common name
CERT_FILE="${COMMON_NAME}.crt"
KEY_FILE="${COMMON_NAME}.key"

echo ""
echo "Certificate file will be: ${CERT_FILE}"
echo "Private key file will be: ${KEY_FILE}"
echo ""

# --- Script Arguments ---
echo "--- Script Arguments ---"
echo ""

read -p "Argument 1 [Argument-1]: " ARG_1
ARG_1=${ARG_1:-Argument-1}

read -p "Argument 2 [Argument-2]: " ARG_2
ARG_2=${ARG_2:-Argument-2}

read -p "Argument 3 [Argument-3]: " ARG_3
ARG_3=${ARG_3:-Argument-3}

read -p "Argument 4 [Argument-4]: " ARG_4
ARG_4=${ARG_4:-Argument-4}

read -p "Argument 5 [Argument-5]: " ARG_5
ARG_5=${ARG_5:-Argument-5}

echo ""
echo "========================================="
echo "  Generating Self-Signed Certificate"
echo "========================================="
echo ""

# Create certificate folder if it doesn't exist
if [ ! -d "$CERT_FOLDER" ]; then
    echo "Creating certificate folder: $CERT_FOLDER"
    mkdir -p "$CERT_FOLDER"
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to create certificate folder"
        exit 1
    fi
    echo "Certificate folder created successfully"
else
    echo "Certificate folder already exists: $CERT_FOLDER"
fi

# Build the subject string
SUBJECT="/C=US/ST=Utah/L=Lehi/O=Digicert/OU=Product/CN=${COMMON_NAME}"

echo ""
echo "Certificate Subject: $SUBJECT"
echo ""

# Generate self-signed certificate
CERT_PATH="${CERT_FOLDER}/${CERT_FILE}"
KEY_PATH="${CERT_FOLDER}/${KEY_FILE}"

echo "Generating certificate and private key..."
echo "  Certificate: $CERT_PATH"
echo "  Private Key: $KEY_PATH"
echo ""

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY_PATH" \
    -out "$CERT_PATH" \
    -subj "$SUBJECT" \
    2>&1

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to generate certificate"
    exit 1
fi

echo ""
echo "Certificate generated successfully!"
echo ""

# Display certificate info
echo "Certificate Details:"
openssl x509 -in "$CERT_PATH" -noout -subject -dates
echo ""

echo "========================================="
echo "  Building JSON Payload"
echo "========================================="
echo ""

# Build the JSON payload (matching actual TLM agent format)
JSON_PAYLOAD="{\"args\":[\"${ARG_1}\",\"${ARG_2}\",\"${ARG_3}\",\"${ARG_4}\",\"${ARG_5}\"],\"certfolder\":\"${CERT_FOLDER}\",\"files\":[\"${CERT_FILE}\",\"${KEY_FILE}\"]}"

echo "Raw JSON Payload:"
echo "$JSON_PAYLOAD"
echo ""

# Pretty print JSON if jq is available
if command -v jq &> /dev/null; then
    echo "Formatted JSON:"
    echo "$JSON_PAYLOAD" | jq .
    echo ""
fi

# Base64 encode the JSON
ENCODED_PAYLOAD=$(echo -n "$JSON_PAYLOAD" | base64 -w 0)

echo "Base64 Encoded Payload:"
echo "$ENCODED_PAYLOAD"
echo ""

echo "========================================="
echo "  Executing Target Script"
echo "========================================="
echo ""

# Export the environment variable and execute the target script
export DC1_POST_SCRIPT_DATA="$ENCODED_PAYLOAD"

echo "DC1_POST_SCRIPT_DATA has been set (${#ENCODED_PAYLOAD} characters)"
echo ""
echo "Executing: ${TARGET_SCRIPT}"
echo ""
echo "--- Script Output Below ---"
echo ""

# Execute the target script
"$TARGET_SCRIPT"
EXIT_CODE=$?

echo ""
echo "--- End of Script Output ---"
echo ""
echo "========================================="
echo "  Execution Complete"
echo "========================================="
echo ""
echo "Target script exit code: $EXIT_CODE"
echo ""

exit $EXIT_CODE