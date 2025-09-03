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

# Configuration - MUST BE SET TO "true" TO ACCEPT THE LEGAL NOTICE AND RUN THE SCRIPT
LEGAL_NOTICE_ACCEPT="true"

# Auto-commit configuration - Set to "true" to automatically commit changes, "false" to skip
AUTO_COMMIT="true"

# Check legal notice acceptance
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    echo "============================================================================"
    echo "LEGAL NOTICE NOT ACCEPTED"
    echo "============================================================================"
    echo ""
    echo "To use this script, you must accept the DigiCert Legal Notice."
    echo ""
    echo "Please review the legal notice at the beginning of this script,"
    echo "and if you accept the terms, change the line:"
    echo "  LEGAL_NOTICE_ACCEPT=\"false\""
    echo "to:"
    echo "  LEGAL_NOTICE_ACCEPT=\"true\""
    echo ""
    echo "Script execution terminated."
    echo "============================================================================"
    exit 1
fi

# PAN-OS Configuration
FIREWALL_IP="ec2-3-145-216-176.us-east-2.compute.amazonaws.com"
API_KEY="LUFRPT1FbHhwTEFkNHhaMWZkQy9jR2hINnk1ZkdoOWs9dEdlQVg1OXVOMkFUVHdFSkRVNjhqWTMrSDJmNXNYWVRSSDJmS0tTR1ZreUVBMkFNc3hxWEVVeWdyWlNtUVhERA=="
CERT_NAME="tlsguru.io"
COMMON_NAME="tlsguru.io"
ORGANIZATION="Digicert"
LOCALITY="Lehi"
STATE="Utah"
COUNTRY="US"

# DigiCert API Configuration
DIGICERT_API_KEY="01e615c60f4e874a1a6d0d66dc_87d297ee13fb16ac4bade5b94bb6486043532397c921f665b09a1ff689c7ea5c"
DIGICERT_PROFILE_ID="f1887d29-ee87-48f7-a873-1a0254dc99a9"
DIGICERT_SEAT_ID="tlsguru.io"

# File Path Configuration
OUTPUT_DIR="./certs"
CSR_CLEAN_FILE="${OUTPUT_DIR}/${CERT_NAME}_clean.csr"
CSR_SINGLE_LINE_FILE="${OUTPUT_DIR}/${CERT_NAME}_single_line.txt"
DIGICERT_RESPONSE_FILE="${OUTPUT_DIR}/${CERT_NAME}_digicert_response.json"
SIGNED_CERT_FILE="${OUTPUT_DIR}/${CERT_NAME}_signed_certificate.crt"
RAW_RESPONSE_FILE="${OUTPUT_DIR}/${CERT_NAME}_raw_response.xml"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

echo "=== PAN-OS Certificate Automation Script ==="
echo "Certificate Name: $CERT_NAME"
echo "Common Name: $COMMON_NAME"
echo "Auto-commit: $AUTO_COMMIT"
echo ""

# Step 1: Generate CSR in PAN-OS
echo "Step 1: Generating CSR in PAN-OS..."
CSR_RESPONSE=$(curl --insecure -s -X POST \
  "https://$FIREWALL_IP/api/?type=op&key=$API_KEY" \
  --data-urlencode "cmd=<request><certificate><generate><certificate-name>$CERT_NAME</certificate-name><name>CN=$COMMON_NAME,O=$ORGANIZATION,L=$LOCALITY,ST=$STATE,C=$COUNTRY</name><algorithm><RSA><rsa-nbits>2048</rsa-nbits></RSA></algorithm><signed-by>external</signed-by></generate></certificate></request>")

if [[ $CSR_RESPONSE == *"success"* ]]; then
    echo "✅ CSR generated successfully in PAN-OS"
else
    echo "❌ Failed to generate CSR in PAN-OS"
    echo "Response: $CSR_RESPONSE"
    exit 1
fi

# Step 2: Extract CSR from PAN-OS
echo ""
echo "Step 2: Extracting CSR from PAN-OS..."
curl --insecure -s -X POST \
  "https://$FIREWALL_IP/api/" \
  -d "key=$API_KEY" \
  -d "type=config" \
  -d "action=get" \
  --data-urlencode "xpath=/config/shared/certificate/entry[@name='$CERT_NAME']" | \
  tee "$RAW_RESPONSE_FILE" | \
  sed -n '/<csr[^>]*>/,/<\/csr>/p' | \
  sed 's/<csr[^>]*>//g' | \
  sed 's/<\/csr>//g' | \
  sed '/^[[:space:]]*$/d' | \
  awk '{gsub(/^[ \t]+/, ""); print}' > "$CSR_CLEAN_FILE"

if [ -s "$CSR_CLEAN_FILE" ]; then
    echo "✅ CSR extracted to $CSR_CLEAN_FILE"
else
    echo "❌ Failed to extract CSR"
    exit 1
fi

# Create single-line CSR for DigiCert API
grep -v "BEGIN CERTIFICATE REQUEST" "$CSR_CLEAN_FILE" | \
grep -v "END CERTIFICATE REQUEST" | \
tr -d '\n' > "$CSR_SINGLE_LINE_FILE"

if [ -s "$CSR_SINGLE_LINE_FILE" ]; then
    echo "✅ Single-line CSR saved to $CSR_SINGLE_LINE_FILE"
    CSR_CONTENT=$(cat "$CSR_SINGLE_LINE_FILE")
else
    echo "❌ Failed to create single-line CSR"
    exit 1
fi

# Step 3: Submit CSR to DigiCert and get signed certificate
echo ""
echo "Step 3: Submitting CSR to DigiCert..."
DIGICERT_RESPONSE=$(curl --location -s 'https://demo.one.digicert.com/mpki/api/v1/certificate' \
--header 'Content-Type: application/json' \
--header "x-api-key: $DIGICERT_API_KEY" \
--data "{
    \"profile\": {
        \"id\": \"$DIGICERT_PROFILE_ID\"
    },
    \"seat\": {
        \"seat_id\": \"$DIGICERT_SEAT_ID\"
    },
    \"csr\": \"$CSR_CONTENT\",
    \"attributes\": {
        \"subject\": {
            \"common_name\": \"$COMMON_NAME\"
        }
    }
}")

# Save DigiCert response
echo "$DIGICERT_RESPONSE" > "$DIGICERT_RESPONSE_FILE"

# Check if DigiCert request was successful
if [[ $DIGICERT_RESPONSE == *"certificate"* ]]; then
    echo "✅ Certificate issued by DigiCert"
    
    # Extract serial number for logging
    SERIAL_NUMBER=$(echo "$DIGICERT_RESPONSE" | grep -o '"serial_number":"[^"]*"' | sed 's/"serial_number":"//; s/"//')
    echo "Certificate Serial: $SERIAL_NUMBER"
else
    echo "❌ Failed to get certificate from DigiCert"
    echo "Response: $DIGICERT_RESPONSE"
    exit 1
fi

# Step 4: Extract certificate from JSON response
echo ""
echo "Step 4: Extracting certificate from DigiCert response..."
if command -v jq >/dev/null 2>&1; then
    # Use jq if available
    jq -r '.certificate' "$DIGICERT_RESPONSE_FILE" | sed 's/\\n/\n/g' > "$SIGNED_CERT_FILE"
else
    # Fallback: use grep/sed
    grep -o '"certificate":"[^"]*"' "$DIGICERT_RESPONSE_FILE" | \
      sed 's/"certificate":"//; s/"$//; s/\\n/\n/g' > "$SIGNED_CERT_FILE"
fi

if [ -s "$SIGNED_CERT_FILE" ]; then
    echo "✅ Certificate extracted to $SIGNED_CERT_FILE"
    
    # Verify certificate
    if openssl x509 -in "$SIGNED_CERT_FILE" -noout -text >/dev/null 2>&1; then
        echo "✅ Certificate is valid"
        CERT_EXPIRY=$(openssl x509 -in "$SIGNED_CERT_FILE" -noout -enddate | sed 's/notAfter=//')
        echo "Certificate expires: $CERT_EXPIRY"
    else
        echo "⚠️  Certificate validation failed"
    fi
else
    echo "❌ Failed to extract certificate"
    exit 1
fi

# Step 5: Import signed certificate back to PAN-OS
echo ""
echo "Step 5: Importing signed certificate to PAN-OS..."
IMPORT_RESPONSE=$(curl --insecure -s -F "file=@$SIGNED_CERT_FILE" \
  "https://$FIREWALL_IP/api/?key=$API_KEY&type=import&category=certificate&certificate-name=$CERT_NAME&format=pem")

if [[ $IMPORT_RESPONSE == *"success"* ]]; then
    echo "✅ Certificate imported to PAN-OS successfully"
else
    echo "❌ Failed to import certificate to PAN-OS"
    echo "Response: $IMPORT_RESPONSE"
    exit 1
fi

# Step 6: Commit configuration (optional)
if [ "$AUTO_COMMIT" = "true" ]; then
    echo ""
    echo "Step 6: Committing PAN-OS configuration..."
    COMMIT_RESPONSE=$(curl --insecure -s \
      "https://$FIREWALL_IP/api/?type=commit&cmd=<commit></commit>&key=$API_KEY")

    if [[ $COMMIT_RESPONSE == *"success"* ]]; then
        echo "✅ Configuration committed successfully"
    else
        echo "❌ Failed to commit configuration"
        echo "Response: $COMMIT_RESPONSE"
    fi
else
    echo ""
    echo "Step 6: Skipping configuration commit (AUTO_COMMIT is set to false)"
    echo "⚠️  Remember to commit the configuration manually in PAN-OS to activate the certificate"
fi

# Step 7: Verify final certificate installation
echo ""
echo "Step 7: Verifying certificate installation..."
VERIFY_RESPONSE=$(curl --insecure -s -X POST \
  "https://$FIREWALL_IP/api/" \
  -d "key=$API_KEY" \
  -d "type=config" \
  -d "action=get" \
  --data-urlencode "xpath=/config/shared/certificate/entry[@name='$CERT_NAME']")

if [[ $VERIFY_RESPONSE == *"private-key"* ]] && [[ $VERIFY_RESPONSE == *"common-name"* ]]; then
    echo "✅ Certificate with private key verified in PAN-OS"
else
    echo "⚠️  Certificate verification incomplete"
fi

echo ""
echo "=== Certificate Installation Complete ==="
echo "Certificate Name: $CERT_NAME"
echo "Common Name: $COMMON_NAME"
echo "Serial Number: $SERIAL_NUMBER"
echo "Output Directory: $OUTPUT_DIR"
echo "Auto-commit: $AUTO_COMMIT"
if [ "$AUTO_COMMIT" = "false" ]; then
    echo ""
    echo "⚠️  IMPORTANT: Configuration was NOT committed automatically."
    echo "   You must manually commit the configuration in PAN-OS to activate the certificate."
fi
echo ""
echo "Files created:"
echo "- $CSR_CLEAN_FILE (original CSR)"
echo "- $CSR_SINGLE_LINE_FILE (single-line CSR for APIs)"
echo "- $DIGICERT_RESPONSE_FILE (DigiCert API response)"
echo "- $SIGNED_CERT_FILE (final signed certificate)"
echo "- $RAW_RESPONSE_FILE (PAN-OS API response)"
echo ""
echo "The certificate is now ready for use in SSL/TLS configurations!"