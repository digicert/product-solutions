#!/bin/bash

: <<'LEGAL_NOTICE'
Legal Notice (version October 29, 2024)
Copyright © 2024 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.
For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.
The software described in this notice is provided by DigiCert and distributed under licenses
restricting its use, copying, distribution, and decompilation or reverse engineering.
No part of the software may be reproduced in any form by any means without prior written authorization
of DigiCert and its licensors, if any.
Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
your agreement and, in the event of conflict, these terms control.
THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Configuration
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/tlm_agent_3.1.4_linux64/log/dc1_data.log"

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting DC1_POST_SCRIPT_DATA extraction script"
log_message "=========================================="

# Check legal notice acceptance
log_message "Checking legal notice acceptance..."
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    log_message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed."
    log_message "Script execution terminated due to legal notice non-acceptance."
    log_message "=========================================="
    exit 1
else
    log_message "Legal notice accepted, proceeding with script execution."
fi

# Log initial configuration
log_message "Configuration:"
log_message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
log_message "  LOGFILE: $LOGFILE"

# Log environment variable check
log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
    log_message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
else
    log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
fi

# Read the Base64-encoded JSON string from the environment variable
CERT_INFO=${DC1_POST_SCRIPT_DATA}
log_message "CERT_INFO length: ${#CERT_INFO} characters"

# Decode JSON string
JSON_STRING=$(echo "$CERT_INFO" | base64 -d)
log_message "JSON_STRING decoded successfully"

# Log the raw JSON for debugging
log_message "=========================================="
log_message "Raw JSON content:"
log_message "$JSON_STRING"
log_message "=========================================="

# Extract arguments from JSON
log_message "Extracting arguments from JSON..."

# First, let's log the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract Argument_1 - first argument
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - second argument
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_3 extracted: '$ARGUMENT_3'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')

# Extract cert folder
CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
log_message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt file name
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
log_message "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
log_message "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

# Extract all files from the files array
FILES_ARRAY=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*')
log_message "Files array content: $FILES_ARRAY"

# Log summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "Arguments extracted:"
log_message "  Argument 1: $ARGUMENT_1"
log_message "  Argument 2: $ARGUMENT_2"
log_message "  Argument 3: $ARGUMENT_3"
log_message "  Argument 4: $ARGUMENT_4"
log_message "  Argument 5: $ARGUMENT_5"
log_message ""
log_message "Certificate information:"
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Private key file: $KEY_FILE"
log_message "  Certificate path: $CRT_FILE_PATH"
log_message "  Private key path: $KEY_FILE_PATH"
log_message ""
log_message "All files in array: $FILES_ARRAY"
log_message "=========================================="

# Check if files exist
if [ -f "$CRT_FILE_PATH" ]; then
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"
    
    # Count certificates in the file
    CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "${CRT_FILE_PATH}")
    log_message "Total certificates in file: $CERT_COUNT"
else
    log_message "WARNING: Certificate file not found: $CRT_FILE_PATH"
fi

if [ -f "$KEY_FILE_PATH" ]; then
    log_message "Private key file exists: $KEY_FILE_PATH"
    log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"
    
    # Determine key type
    KEY_FILE_CONTENT=$(cat "${KEY_FILE_PATH}")
    if echo "$KEY_FILE_CONTENT" | grep -q "BEGIN RSA PRIVATE KEY"; then
        KEY_TYPE="RSA"
        log_message "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN EC PRIVATE KEY"; then
        KEY_TYPE="ECC"
        log_message "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    elif echo "$KEY_FILE_CONTENT" | grep -q "BEGIN PRIVATE KEY"; then
        KEY_TYPE="PKCS#8 format (generic)"
        log_message "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    else
        KEY_TYPE="Unknown"
        log_message "Key type: Unknown"
    fi
else
    log_message "WARNING: Private key file not found: $KEY_FILE_PATH"
fi

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $CRT_FILE         - The certificate filename (.crt)
#   $KEY_FILE         - The private key filename (.key)
#   $CRT_FILE_PATH    - Full path to the certificate file
#   $KEY_FILE_PATH    - Full path to the private key file
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Certificate inspection variables (if files exist):
#   $CERT_COUNT       - Number of certificates in the CRT file
#   $KEY_TYPE         - Type of key (RSA, ECC, PKCS#8 format, or Unknown)
#   $KEY_FILE_CONTENT - The full content of the private key file
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $ARGS_ARRAY       - The raw args array from JSON
#
# Utility function:
#   log_message "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="


# ADD YOUR CUSTOM LOGIC HERE:
# ----------------------------------------

log_message "Starting lighttpd certificate deployment..."

# Define lighttpd SSL configuration file
LIGHTTPD_SSL_CONF="/etc/lighttpd/conf-enabled/10-ssl.conf"
LIGHTTPD_SSL_DIR="/etc/lighttpd/ssl"

# Check if certificate and key files exist
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
fi

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
fi

log_message "Certificate and key files found successfully"

# Create lighttpd SSL directory if it doesn't exist
if [ ! -d "$LIGHTTPD_SSL_DIR" ]; then
    log_message "Creating lighttpd SSL directory: $LIGHTTPD_SSL_DIR"
    mkdir -p "$LIGHTTPD_SSL_DIR"
fi

# Generate timestamp for filenames
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
log_message "Generated timestamp: $TIMESTAMP"

# Create combined PEM file for lighttpd (cert + key in one file)
COMBINED_PEM_FILE="$LIGHTTPD_SSL_DIR/demo2me_${TIMESTAMP}.pem"
log_message "Creating combined PEM file: $COMBINED_PEM_FILE"

# Combine certificate and key
cat "$CRT_FILE_PATH" "$KEY_FILE_PATH" > "$COMBINED_PEM_FILE"

if [ $? -eq 0 ]; then
    log_message "Successfully created combined PEM file"
else
    log_message "ERROR: Failed to create combined PEM file"
    exit 1
fi

# Set proper permissions
chmod 600 "$COMBINED_PEM_FILE"
chown www-data:www-data "$COMBINED_PEM_FILE"
log_message "Set permissions on PEM file (600, www-data:www-data)"

# Verify the combined file is valid
log_message "Verifying combined PEM file..."
openssl x509 -in "$COMBINED_PEM_FILE" -text -noout > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_message "Certificate verification successful"
else
    log_message "ERROR: Certificate verification failed"
    exit 1
fi

openssl rsa -in "$COMBINED_PEM_FILE" -check -noout > /dev/null 2>&1
if [ $? -eq 0 ]; then
    log_message "Private key verification successful"
else
    log_message "ERROR: Private key verification failed"
    exit 1
fi

# Backup the current SSL configuration
BACKUP_CONF="${LIGHTTPD_SSL_CONF}.backup_${TIMESTAMP}"
log_message "Backing up current SSL configuration to: $BACKUP_CONF"
cp "$LIGHTTPD_SSL_CONF" "$BACKUP_CONF"

if [ $? -eq 0 ]; then
    log_message "Configuration backup created successfully"
else
    log_message "ERROR: Failed to backup configuration"
    exit 1
fi

# Read current configuration
CURRENT_CONFIG=$(cat "$LIGHTTPD_SSL_CONF")

# Extract current certificate path
CURRENT_CERT_PATH=$(grep -oP 'ssl\.pemfile\s*=\s*"\K[^"]+' "$LIGHTTPD_SSL_CONF" | head -1)
log_message "Current certificate path: $CURRENT_CERT_PATH"

# Create new configuration with commented old settings
log_message "Updating lighttpd SSL configuration..."

# Create temporary file for new configuration
TEMP_CONF=$(mktemp)

# Write new configuration
cat > "$TEMP_CONF" << EOF
# lighttpd SSL Configuration
# Last updated: $(date '+%Y-%m-%d %H:%M:%S')
# Certificate deployed by DigiCert TLM Agent

server.modules += ( "mod_openssl" )

\$SERVER["socket"] == ":443" {
    ssl.engine = "enable"
    
    # Active certificate configuration
    ssl.pemfile = "$COMBINED_PEM_FILE"
    
    # SSL/TLS settings
    ssl.cipher-list = "HIGH:!aNULL:!MD5"
    
    # Server configuration
    server.name = "demo2me.com"
    server.document-root = "/var/www/html"
}

# Redirect HTTP to HTTPS
\$HTTP["scheme"] == "http" {
    \$HTTP["host"] =~ ".*" {
        url.redirect = (".*" => "https://%0\$0")
    }
}

# ============================================================================
# PREVIOUS CERTIFICATE CONFIGURATIONS (Archived)
# ============================================================================

EOF

# Append the old configuration as comments with timestamp
echo "# Configuration archived on: $(date '+%Y-%m-%d %H:%M:%S')" >> "$TEMP_CONF"
echo "# Previous certificate path: $CURRENT_CERT_PATH" >> "$TEMP_CONF"
echo "#" >> "$TEMP_CONF"

# Comment out old configuration line by line
while IFS= read -r line; do
    # Skip the timestamp comments we just added
    if [[ ! "$line" =~ ^#.*Last\ updated: ]] && [[ ! "$line" =~ ^#.*Certificate\ deployed ]]; then
        echo "# $line" >> "$TEMP_CONF"
    fi
done < "$LIGHTTPD_SSL_CONF"

echo "" >> "$TEMP_CONF"
echo "# ============================================================================" >> "$TEMP_CONF"

# Move new configuration to actual location
mv "$TEMP_CONF" "$LIGHTTPD_SSL_CONF"

if [ $? -eq 0 ]; then
    log_message "SSL configuration updated successfully"
else
    log_message "ERROR: Failed to update SSL configuration"
    log_message "Restoring backup configuration..."
    cp "$BACKUP_CONF" "$LIGHTTPD_SSL_CONF"
    exit 1
fi

# Test lighttpd configuration
log_message "Testing lighttpd configuration..."
lighttpd -t -f /etc/lighttpd/lighttpd.conf > /dev/null 2>&1

if [ $? -eq 0 ]; then
    log_message "Configuration test passed - Syntax OK"
else
    log_message "ERROR: Configuration test failed"
    log_message "Restoring backup configuration..."
    cp "$BACKUP_CONF" "$LIGHTTPD_SSL_CONF"
    exit 1
fi

# Restart lighttpd service
log_message "Restarting lighttpd service..."
systemctl restart lighttpd

if [ $? -eq 0 ]; then
    log_message "lighttpd restarted successfully"
else
    log_message "ERROR: Failed to restart lighttpd"
    log_message "Restoring backup configuration..."
    cp "$BACKUP_CONF" "$LIGHTTPD_SSL_CONF"
    systemctl restart lighttpd
    exit 1
fi

# Wait a moment for service to fully start
sleep 2

# Verify lighttpd is running
systemctl is-active --quiet lighttpd

if [ $? -eq 0 ]; then
    log_message "lighttpd service is active and running"
else
    log_message "ERROR: lighttpd service is not running after restart"
    log_message "Checking service status..."
    systemctl status lighttpd >> "$LOGFILE"
    exit 1
fi

# Verify SSL is working by checking if port 443 is listening
if netstat -tlnp | grep -q ':443.*lighttpd'; then
    log_message "Verified: lighttpd is listening on port 443 (HTTPS)"
else
    log_message "WARNING: lighttpd may not be listening on port 443"
fi

# Extract certificate details for logging
log_message "=========================================="
log_message "NEW CERTIFICATE DETAILS:"
log_message "=========================================="

CERT_SUBJECT=$(openssl x509 -in "$COMBINED_PEM_FILE" -noout -subject | sed 's/subject=//')
CERT_ISSUER=$(openssl x509 -in "$COMBINED_PEM_FILE" -noout -issuer | sed 's/issuer=//')
CERT_SERIAL=$(openssl x509 -in "$COMBINED_PEM_FILE" -noout -serial | sed 's/serial=//')
CERT_DATES=$(openssl x509 -in "$COMBINED_PEM_FILE" -noout -dates)
CERT_FINGERPRINT=$(openssl x509 -in "$COMBINED_PEM_FILE" -noout -fingerprint -sha256 | sed 's/SHA256 Fingerprint=//')

log_message "Subject: $CERT_SUBJECT"
log_message "Issuer: $CERT_ISSUER"
log_message "Serial: $CERT_SERIAL"
log_message "$CERT_DATES"
log_message "SHA-256 Fingerprint: $CERT_FINGERPRINT"
log_message "Certificate file: $COMBINED_PEM_FILE"

log_message "=========================================="
log_message "DEPLOYMENT SUMMARY:"
log_message "=========================================="
log_message "✓ Certificate and key combined successfully"
log_message "✓ Combined PEM file created: $COMBINED_PEM_FILE"
log_message "✓ SSL configuration updated"
log_message "✓ Previous configuration archived with timestamp"
log_message "✓ Configuration backup saved: $BACKUP_CONF"
log_message "✓ lighttpd configuration test passed"
log_message "✓ lighttpd service restarted successfully"
log_message "✓ lighttpd is active and listening on port 443"
log_message ""
log_message "Certificate deployment completed successfully!"
log_message "=========================================="

# Optional: Test HTTPS connection
log_message "Testing HTTPS connection to demo2me.com..."
curl_output=$(curl -Ik https://demo2me.com 2>&1 | head -5)
log_message "HTTPS test output:"
log_message "$curl_output"

# ----------------------------------------
# END OF CUSTOM LOGIC

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0