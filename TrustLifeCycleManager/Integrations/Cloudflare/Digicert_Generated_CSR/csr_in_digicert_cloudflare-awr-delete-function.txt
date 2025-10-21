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

# Check for command line arguments
RENEWAL_MODE=false
for arg in "$@"; do
    case $arg in
        --renewal)
            RENEWAL_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --renewal    Run in renewal mode (use defaults, no prompts)"
            echo "  --help       Show this help message"
            echo ""
            echo "Without options, the script runs in interactive mode with prompts."
            exit 0
            ;;
    esac
done

if [ "$RENEWAL_MODE" = true ]; then
    echo "Legal Notice accepted. Running in RENEWAL MODE (automated/scheduled execution)..."
    echo ""
fi

# Default values
DEFAULT_ZONE_ID="c3aaef7ffc39aa38f9d33b8dbdaafab8"
DEFAULT_AUTH_TOKEN="REMOVED_SECRET"
DEFAULT_DIGICERT_API_KEY="REMOVED_SECRET"
DEFAULT_PROFILE_ID="f1887d29-ee87-48f7-a873-1a0254dc99a9"
DEFAULT_LOG_FILE="./digicert_cert_automation_$(date +%Y%m%d_%H%M%S).log"
DEFAULT_CSR_RETENTION="5"
DEFAULT_CERT_DELETE_MODE="matching"

# Function to prompt for input with default value
prompt_with_default() {
    local prompt_text="$1"
    local default_value="$2"
    local var_name="$3"
    local hide_input="$4"
    
    if [ "$RENEWAL_MODE" = true ]; then
        # In renewal mode, always use defaults
        eval "$var_name='$default_value'"
    else
        # Interactive mode - prompt for input
        if [ "$hide_input" = "true" ]; then
            echo -n "$prompt_text [default: (hidden)]: "
            read -s input_value
            echo ""
        else
            echo -n "$prompt_text [default: $default_value]: "
            read input_value
        fi
        
        if [ -z "$input_value" ]; then
            eval "$var_name='$default_value'"
        else
            eval "$var_name='$input_value'"
        fi
    fi
}

# Configuration setup
if [ "$RENEWAL_MODE" = false ]; then
    echo "============================================================================"
    echo "CONFIGURATION SETUP"
    echo "============================================================================"
    echo "Press Enter to use default values (shown in brackets)"
    echo ""
fi

# Set configuration values
prompt_with_default "Enter Cloudflare Zone ID" "$DEFAULT_ZONE_ID" "ZONE_ID" "false"
prompt_with_default "Enter Cloudflare Auth Token" "$DEFAULT_AUTH_TOKEN" "AUTH_TOKEN" "true"
prompt_with_default "Enter DigiCert API Key" "$DEFAULT_DIGICERT_API_KEY" "DIGICERT_API_KEY" "true"
prompt_with_default "Enter DigiCert Profile ID" "$DEFAULT_PROFILE_ID" "PROFILE_ID" "false"
prompt_with_default "Enter Log File Location" "$DEFAULT_LOG_FILE" "LOG_FILE" "false"
prompt_with_default "Number of old CSRs to keep (0=delete all old CSRs)" "$DEFAULT_CSR_RETENTION" "CSR_RETENTION" "false"

# Certificate deletion mode prompt
if [ "$RENEWAL_MODE" = false ]; then
    echo ""
    echo "Certificate Deletion Strategy:"
    echo "  none     - Keep all existing certificates (accumulate)"
    echo "  all      - Delete ALL existing certificates before upload"
    echo "  matching - Delete only certificates covering same hostname(s) (recommended)"
    echo ""
fi
prompt_with_default "Certificate deletion mode (none/all/matching)" "$DEFAULT_CERT_DELETE_MODE" "CERT_DELETE_MODE" "false"

# Validate CSR retention input
if ! [[ "$CSR_RETENTION" =~ ^[0-9]+$ ]]; then
    if [ "$RENEWAL_MODE" = false ]; then
        echo "Error: CSR retention must be a number. Using default value of 5."
    fi
    CSR_RETENTION=5
fi

# Validate CERT_DELETE_MODE
if [[ ! "$CERT_DELETE_MODE" =~ ^(none|all|matching)$ ]]; then
    if [ "$RENEWAL_MODE" = false ]; then
        echo "Warning: Invalid certificate deletion mode '$CERT_DELETE_MODE'. Using 'matching'."
    fi
    CERT_DELETE_MODE="matching"
fi

# Configuration summary and confirmation
if [ "$RENEWAL_MODE" = false ]; then
    echo ""
    echo "Configuration Summary:"
    echo "  Zone ID: $ZONE_ID"
    echo "  Auth Token: ***hidden***"
    echo "  DigiCert API Key: ***hidden***"
    echo "  Profile ID: $PROFILE_ID"
    echo "  Log File: $LOG_FILE"
    echo "  CSR Retention: $CSR_RETENTION old CSRs"
    echo "  Certificate Delete Mode: $CERT_DELETE_MODE"
    echo ""
    echo -n "Proceed with these settings? (y/n): "
    read CONFIRM
    
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        echo "Configuration cancelled. Exiting."
        exit 1
    fi
else
    # In renewal mode, always proceed with defaults
    echo "Using default configuration values..."
    echo "  Log File: $LOG_FILE"
    echo "  Certificate Delete Mode: $CERT_DELETE_MODE"
    echo ""
fi

# Create log directory if needed
LOG_DIR=$(dirname "$LOG_FILE")
if [ ! -d "$LOG_DIR" ]; then
    mkdir -p "$LOG_DIR"
fi

# Function to log messages to both console and file
log_message() {
    echo "$@" | tee -a "$LOG_FILE"
}

# Function to log without echo (for sensitive data)
log_to_file_only() {
    echo "$@" >> "$LOG_FILE"
}

# Function to clean up old CSRs
cleanup_old_csrs() {
    log_message ""
    log_message "Step 7: CSR Cleanup..."
    
    # Get all CSRs
    ALL_CSRS=$(curl --location "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_csrs" \
         --header "Authorization: Bearer ${AUTH_TOKEN}" \
         --silent)
    
    log_to_file_only "All CSRs Response: $ALL_CSRS"
    
    # Count CSRs for this domain
    CSR_COUNT=$(echo "$ALL_CSRS" | jq "[.result[] | select(.common_name==\"${DOMAIN}\")] | length")
    
    log_message "  Found $CSR_COUNT total CSRs for $DOMAIN"
    log_message "  Retention policy: Keep $CSR_RETENTION old CSRs"
    
    if [ "$CSR_COUNT" -gt "$CSR_RETENTION" ]; then
        log_message "  Cleaning up old CSRs..."
        
        # Get CSR IDs sorted by created_at
        if [ "$CSR_RETENTION" -eq 0 ]; then
            # Delete all CSRs
            OLD_CSR_IDS=$(echo "$ALL_CSRS" | jq -r "[.result[] | select(.common_name==\"${DOMAIN}\")] | sort_by(.created_at) | .[].id")
            log_message "  Will delete all $CSR_COUNT CSRs (retention set to 0)"
        else
            # Keep the specified number of most recent CSRs
            OLD_CSR_IDS=$(echo "$ALL_CSRS" | jq -r "[.result[] | select(.common_name==\"${DOMAIN}\")] | sort_by(.created_at) | .[0:-${CSR_RETENTION}] | .[].id")
            log_message "  Will delete $(echo "$OLD_CSR_IDS" | wc -w) old CSRs, keeping the $CSR_RETENTION most recent"
        fi
        
        DELETE_COUNT=0
        for OLD_CSR_ID in $OLD_CSR_IDS; do
            if [ ! -z "$OLD_CSR_ID" ] && [ "$OLD_CSR_ID" != "$CSR_ID" ]; then
                log_message "    Deleting CSR: $OLD_CSR_ID"
                DELETE_RESPONSE=$(curl --location --request DELETE "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_csrs/${OLD_CSR_ID}" \
                     --header "Authorization: Bearer ${AUTH_TOKEN}" \
                     --silent)
                
                DELETE_SUCCESS=$(echo "$DELETE_RESPONSE" | jq -r '.success')
                if [ "$DELETE_SUCCESS" = "true" ]; then
                    ((DELETE_COUNT++))
                else
                    log_message "    ⚠ Failed to delete CSR: $OLD_CSR_ID"
                    log_to_file_only "Delete Response: $DELETE_RESPONSE"
                fi
            fi
        done
        
        log_message "  ✓ Deleted $DELETE_COUNT old CSRs"
    else
        if [ "$CSR_RETENTION" -eq 0 ]; then
            log_message "  No old CSRs to delete (current CSR is the only one)"
        else
            log_message "  No cleanup needed (within retention limit)"
        fi
    fi
}

# Initialize log file
echo "============================== Certificate Automation Log ==============================" > "$LOG_FILE"
echo "Started: $(date)" >> "$LOG_FILE"
echo "Mode: $([ "$RENEWAL_MODE" = true ] && echo "RENEWAL (Automated)" || echo "Interactive")" >> "$LOG_FILE"
echo "Configuration: CSR Retention = $CSR_RETENTION, Cert Delete Mode = $CERT_DELETE_MODE" >> "$LOG_FILE"
echo "========================================================================================" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

log_message ""
log_message "Starting certificate automation process..."
log_message "Log file: $LOG_FILE"
log_message "============================================================================"
log_message ""

# Step 0: Get zone details to determine the domain
log_message "Step 0: Fetching zone details from Cloudflare..."
ZONE_DETAILS=$(curl --location "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}" \
     --header "Authorization: Bearer ${AUTH_TOKEN}" \
     --silent)

# Log full response to file only for debugging
log_to_file_only "Zone Details Response: $ZONE_DETAILS"

# Extract domain name from zone
DOMAIN=$(echo "$ZONE_DETAILS" | jq -r '.result.name')
ZONE_STATUS=$(echo "$ZONE_DETAILS" | jq -r '.result.status')

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "null" ]; then
    log_message "Error: Could not fetch zone details"
    echo "$ZONE_DETAILS" | jq '.' | tee -a "$LOG_FILE"
    exit 1
fi

log_message "✓ Zone found:"
log_message "  Domain: $DOMAIN"
log_message "  Status: $ZONE_STATUS"
log_message ""

# Step 1: Check for existing certificates and handle deletion based on mode
log_message "Step 1: Checking for existing certificates for domain: $DOMAIN..."
log_message "  Certificate deletion mode: $CERT_DELETE_MODE"

EXISTING_CERTS=$(curl --location "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates" \
     --header "Authorization: Bearer ${AUTH_TOKEN}" \
     --silent)

log_to_file_only "Existing Certificates Response: $EXISTING_CERTS"

# Count existing certificates
CERT_COUNT=$(echo "$EXISTING_CERTS" | jq '[.result[]] | length')
log_message "  Found $CERT_COUNT existing certificate(s)"

# Handle certificate deletion based on mode
if [ "$CERT_DELETE_MODE" = "none" ]; then
    log_message "  Mode 'none': Keeping all existing certificates"
    log_message "  New certificate will be added alongside existing ones"
    
elif [ "$CERT_DELETE_MODE" = "all" ] || [ "$CERT_DELETE_MODE" = "matching" ]; then
    
    if [ "$CERT_COUNT" -gt 0 ]; then
        
        if [ "$CERT_DELETE_MODE" = "all" ]; then
            # Delete ALL certificates
            log_message "  Mode 'all': Will delete all $CERT_COUNT existing certificate(s)"
            CERT_IDS=$(echo "$EXISTING_CERTS" | jq -r '.result[].id')
            
        elif [ "$CERT_DELETE_MODE" = "matching" ]; then
            # Smart deletion - only delete certs covering the same hostname(s)
            log_message "  Mode 'matching': Will only delete certificates covering $DOMAIN or www.$DOMAIN"
            
            # Expected hostnames for the new certificate
            EXPECTED_HOSTS="${DOMAIN}|www.${DOMAIN}"
            log_message "  Looking for certificates matching: $(echo "$EXPECTED_HOSTS" | tr '|' ', ')"
            
            # Initialize empty list
            CERT_IDS=""
            MATCH_COUNT=0
            
            # Parse each certificate in the response
            while read -r cert_json; do
                if [ -n "$cert_json" ] && [ "$cert_json" != "null" ]; then
                    CURRENT_ID=$(echo "$cert_json" | jq -r '.id')
                    CURRENT_HOSTS=$(echo "$cert_json" | jq -r '.hosts[]' | sort | tr '\n' '|' | sed 's/|$//')
                    
                    if [ -n "$CURRENT_ID" ] && [ -n "$CURRENT_HOSTS" ]; then
                        # Check if any hostname matches
                        MATCH_FOUND=false
                        
                        # Convert pipe-separated lists to arrays for comparison
                        IFS='|' read -ra EXPECTED_HOSTS_ARRAY <<< "$EXPECTED_HOSTS"
                        IFS='|' read -ra CURRENT_HOSTS_ARRAY <<< "$CURRENT_HOSTS"
                        
                        for expected_host in "${EXPECTED_HOSTS_ARRAY[@]}"; do
                            for current_host in "${CURRENT_HOSTS_ARRAY[@]}"; do
                                if [ "$expected_host" = "$current_host" ]; then
                                    MATCH_FOUND=true
                                    break 2
                                fi
                            done
                        done
                        
                        if [ "$MATCH_FOUND" = true ]; then
                            log_message "    Found matching certificate ID $CURRENT_ID covering: $(echo "$CURRENT_HOSTS" | tr '|' ', ')"
                            CERT_IDS="${CERT_IDS}${CURRENT_ID}"$'\n'
                            MATCH_COUNT=$((MATCH_COUNT + 1))
                        fi
                    fi
                fi
            done < <(echo "$EXISTING_CERTS" | jq -c '.result[]')
            
            if [ $MATCH_COUNT -eq 0 ]; then
                log_message "  No certificates found with matching hostnames"
            else
                log_message "  Found $MATCH_COUNT matching certificate(s) to delete"
            fi
        fi
        
        # Perform deletion if we have certificates to delete
        if [ -n "$CERT_IDS" ]; then
            DELETE_COUNT=0
            FAIL_COUNT=0
            
            while IFS= read -r CERT_ID; do
                if [ -n "$CERT_ID" ]; then
                    log_message "    Deleting certificate ID: $CERT_ID"
                    
                    DELETE_RESPONSE=$(curl --location --request DELETE \
                        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates/${CERT_ID}" \
                        --header "Authorization: Bearer ${AUTH_TOKEN}" \
                        --silent)
                    
                    DELETE_SUCCESS=$(echo "$DELETE_RESPONSE" | jq -r '.success')
                    
                    if [ "$DELETE_SUCCESS" = "true" ]; then
                        log_message "      ✓ Successfully deleted certificate"
                        DELETE_COUNT=$((DELETE_COUNT + 1))
                    else
                        log_message "      ✗ Failed to delete certificate"
                        FAIL_COUNT=$((FAIL_COUNT + 1))
                        log_to_file_only "Delete Response: $DELETE_RESPONSE"
                    fi
                fi
            done <<< "$CERT_IDS"
            
            log_message "  Certificate deletion summary: $DELETE_COUNT deleted, $FAIL_COUNT failed"
            
            # Add a small delay to ensure deletion is processed
            if [ $DELETE_COUNT -gt 0 ]; then
                log_message "  Waiting for deletion to process..."
                sleep 2
            fi
        else
            log_message "  No certificates to delete"
        fi
    else
        log_message "  No existing certificates found"
    fi
fi

log_message ""

# Step 2: Create CSR at Cloudflare
log_message "Step 2: Creating CSR at Cloudflare for $DOMAIN..."
RESPONSE=$(curl --location "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_csrs" \
     --header "Authorization: Bearer ${AUTH_TOKEN}" \
     --header "Content-Type: application/json" \
     --silent \
     --data "{
  \"common_name\": \"${DOMAIN}\",
  \"country\": \"US\",
  \"description\": \"\",
  \"key_type\": \"rsa2048\",
  \"locality\": \"Lehi\",
  \"name\": \"\",
  \"organization\": \"Digicert\",
  \"organizational_unit\": \"Product\",
  \"sans\": [\"${DOMAIN}\", \"www.${DOMAIN}\"],
  \"scope\": \"Zone\",
  \"state\": \"Utah\"
}")

# Log full response to file only
log_to_file_only "CSR Creation Response: $RESPONSE"

# Check if the CSR creation was successful
SUCCESS=$(echo "$RESPONSE" | jq -r '.success')
if [ "$SUCCESS" != "true" ]; then
    log_message "Error creating CSR at Cloudflare:"
    echo "$RESPONSE" | jq '.' | tee -a "$LOG_FILE"
    exit 1
fi

log_message "✓ CSR created successfully at Cloudflare"

# Extract CSR ID
CSR_ID=$(echo "$RESPONSE" | jq -r '.result.id')
log_message "  CSR ID: $CSR_ID"
log_message "  SANs: $(echo "$RESPONSE" | jq -c '.result.sans')"

# Step 3: Extract CSR
log_message ""
log_message "Step 3: Extracting CSR..."
CSR=$(echo "$RESPONSE" | \
      jq -r '.result.csr' | \
      sed '/-----BEGIN CERTIFICATE REQUEST-----/d' | \
      sed '/-----END CERTIFICATE REQUEST-----/d' | \
      tr -d '\n')

log_message "✓ CSR extracted (${#CSR} characters)"
log_to_file_only "CSR Content: ${CSR}"

# Step 4: Submit CSR to DigiCert
log_message ""
log_message "Step 4: Submitting CSR to DigiCert for certificate issuance..."
log_message "  Requesting certificate for: $DOMAIN"
log_message "  Including DNS names: ${DOMAIN}, www.${DOMAIN}"

DIGICERT_RESPONSE=$(curl --location 'https://demo.one.digicert.com/mpki/api/v1/certificate' \
     --header 'Content-Type: application/json' \
     --header "x-api-key: ${DIGICERT_API_KEY}" \
     --silent \
     --data "{
    \"profile\": {
        \"id\": \"${PROFILE_ID}\"
    },
    \"seat\": {
        \"seat_id\": \"${DOMAIN}\"
    },
    \"csr\": \"${CSR}\",
    \"attributes\": {
        \"subject\": {
            \"common_name\": \"${DOMAIN}\"
        },
        \"extensions\": {
            \"san\": {
                \"dns_names\": [\"${DOMAIN}\", \"www.${DOMAIN}\"]
            }
        }
    }
}")

# Log full response to file only
log_to_file_only "DigiCert Response: $DIGICERT_RESPONSE"

# Check for certificate
CERTIFICATE=$(echo "$DIGICERT_RESPONSE" | jq -r '.certificate // empty')
if [ -z "$CERTIFICATE" ]; then
    log_message "Error: No certificate received from DigiCert"
    echo "$DIGICERT_RESPONSE" | jq '.' | tee -a "$LOG_FILE"
    exit 1
fi

SERIAL_NUMBER=$(echo "$DIGICERT_RESPONSE" | jq -r '.serial_number // empty')
log_message "✓ Certificate issued successfully!"
log_message "  Serial Number: $SERIAL_NUMBER"

# Display certificate
log_message ""
log_message "========== CERTIFICATE =========="
echo "$CERTIFICATE" | tee -a "$LOG_FILE"
log_message "========== END CERTIFICATE =========="

# Show SANs in the certificate
log_message ""
log_message "Certificate SANs:"
echo "$CERTIFICATE" | openssl x509 -noout -ext subjectAltName 2>/dev/null | tee -a "$LOG_FILE" || log_message "Could not parse SANs"

# Step 5: Upload new certificate to Cloudflare
log_message ""
log_message "Step 5: Uploading new certificate to Cloudflare..."

# Format certificate with proper escaping for JSON
CERT_ESCAPED=$(echo "$CERTIFICATE" | jq -Rs .)

log_message "  Creating new certificate..."
UPLOAD_RESPONSE=$(curl --location --request POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/custom_certificates" \
     --header "Authorization: Bearer ${AUTH_TOKEN}" \
     --header "Content-Type: application/json" \
     --silent \
     --data "{
    \"bundle_method\": \"force\",
    \"certificate\": ${CERT_ESCAPED},
    \"type\": \"sni_custom\",
    \"custom_csr_id\": \"${CSR_ID}\"
}")

# Log full response to file only
log_to_file_only "Upload Response: $UPLOAD_RESPONSE"

UPLOAD_SUCCESS=$(echo "$UPLOAD_RESPONSE" | jq -r '.success')
if [ "$UPLOAD_SUCCESS" = "true" ]; then
    log_message "✓ Certificate uploaded successfully to Cloudflare!"
    log_message ""
    
    # Extract certificate details
    CF_CERT_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.result.id')
    CF_STATUS=$(echo "$UPLOAD_RESPONSE" | jq -r '.result.status')
    CF_EXPIRES=$(echo "$UPLOAD_RESPONSE" | jq -r '.result.expires_on')
    CF_HOSTS=$(echo "$UPLOAD_RESPONSE" | jq -c '.result.hosts')
    
    log_message "Cloudflare Certificate Details:"
    log_message "  Certificate ID: $CF_CERT_ID"
    log_message "  Status: $CF_STATUS"
    log_message "  Hosts: $CF_HOSTS"
    log_message "  Expires: $CF_EXPIRES"
    log_message "  Custom CSR ID: $CSR_ID"
    log_message "  Deletion Mode Used: $CERT_DELETE_MODE"
    
    if [ "$CF_STATUS" = "pending" ]; then
        log_message ""
        log_message "Note: Certificate status is 'pending'. It should become 'active' shortly."
    fi
    
    # Clean up old CSRs after successful certificate deployment
    cleanup_old_csrs
else
    log_message "✗ Error uploading certificate to Cloudflare:"
    echo "$UPLOAD_RESPONSE" | jq '.' | tee -a "$LOG_FILE"
    
    ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.errors[0].message // empty')
    if [ ! -z "$ERROR_MSG" ]; then
        log_message ""
        log_message "Error: $ERROR_MSG"
    fi
fi

# Save files - handle differently for renewal mode
if [ "$RENEWAL_MODE" = true ]; then
    # In renewal mode, always save files without prompting
    SAVE_CERT="y"
    log_message ""
    log_message "Renewal mode: Automatically saving certificate files..."
else
    # Interactive mode - prompt for saving
    log_message ""
    echo -n "Would you like to save the certificate and details to files? (y/n): " | tee -a "$LOG_FILE"
    read -r SAVE_CERT
    echo "$SAVE_CERT" >> "$LOG_FILE"
fi

if [ "$SAVE_CERT" = "y" ] || [ "$SAVE_CERT" = "Y" ]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CERT_FILE="${DOMAIN}_cert_${TIMESTAMP}.pem"
    INFO_FILE="${DOMAIN}_info_${TIMESTAMP}.txt"
    
    echo "$CERTIFICATE" > "$CERT_FILE"
    log_message "✓ Certificate saved to: $CERT_FILE"
    
    cat > "$INFO_FILE" <<EOF
Domain: $DOMAIN
CSR ID: $CSR_ID
DigiCert Serial Number: $SERIAL_NUMBER
Cloudflare Certificate ID: ${CF_CERT_ID:-"N/A"}
Status: ${CF_STATUS:-"N/A"}
Expires: ${CF_EXPIRES:-"N/A"}
Certificate Delete Mode: $CERT_DELETE_MODE
CSR Retention Policy: $CSR_RETENTION
Mode: $([ "$RENEWAL_MODE" = true ] && echo "RENEWAL" || echo "Interactive")
Created: $(date)
EOF
    log_message "✓ Certificate info saved to: $INFO_FILE"
fi

log_message ""
log_message "✅ Process complete!"
log_message ""
log_message "========================================================================================"
log_message "Completed: $(date)"
log_message "========================================================================================"

# Display scheduling instructions if not in renewal mode
if [ "$RENEWAL_MODE" = false ]; then
    echo ""
    echo "========================================================================================"
    echo "SCHEDULING INSTRUCTIONS FOR AUTOMATED CERTIFICATE RENEWAL"
    echo "========================================================================================"
    echo ""
    echo "To set up automated certificate renewal, add a cron job using the --renewal flag."
    echo "Edit your crontab with: crontab -e"
    echo ""
    echo "DAILY RENEWAL (every day at 2:00 AM):"
    echo "0 2 * * * /path/to/$(basename $0) --renewal >> /var/log/cert_renewal.log 2>&1"
    echo ""
    echo "WEEKLY RENEWAL (every Sunday at 2:00 AM):"
    echo "0 2 * * 0 /path/to/$(basename $0) --renewal >> /var/log/cert_renewal.log 2>&1"
    echo ""
    echo "MONTHLY RENEWAL (1st day of each month at 2:00 AM):"
    echo "0 2 1 * * /path/to/$(basename $0) --renewal >> /var/log/cert_renewal.log 2>&1"
    echo ""
    echo "RECOMMENDED: Set up 30 days before expiration (run daily, script checks expiration):"
    echo "0 2 * * * /path/to/$(basename $0) --renewal >> /var/log/cert_renewal.log 2>&1"
    echo ""
    echo "Note: Replace '/path/to/' with the actual path to this script."
    echo "      The --renewal flag ensures the script runs without prompts using default values."
    echo "      Logs are appended to /var/log/cert_renewal.log for monitoring."
    echo ""
    echo "CERTIFICATE DELETION MODES:"
    echo "  none     - Keeps all certificates (accumulates over time)"
    echo "  matching - Replaces only certificates for the same domain (recommended)"
    echo "  all      - Removes all certificates before upload (use with caution)"
    echo ""
    echo "To monitor renewal logs:"
    echo "tail -f /var/log/cert_renewal.log"
    echo "========================================================================================"
fi