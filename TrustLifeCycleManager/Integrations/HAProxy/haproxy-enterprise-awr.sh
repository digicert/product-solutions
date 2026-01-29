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
subparagraphs (c)(1) and (2) of the Commercial Computer Software–Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# ============================================================================
# HAPROXY ENTERPRISE CERTIFICATE DEPLOYMENT SCRIPT
# DigiCert Trust Lifecycle Manager Integration
# ============================================================================
#
# This script automates certificate deployment to HAProxy Enterprise.
# It extracts certificate data from TLM Agent's DC1_POST_SCRIPT_DATA,
# creates combined PEM files, and optionally restarts HAProxy Enterprise.
#
# ============================================================================

# ============================================================================
# CONFIGURATION SECTION - MODIFY THESE SETTINGS AS REQUIRED
# ============================================================================

# Legal notice acceptance (required)
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/home/ubuntu/tlm_agent/tlm_agent_3.1.7_linux64/log/haproxy.log"

# ----------------------------------------------------------------------------
# HAPROXY ENTERPRISE VERSION SETTINGS
# ----------------------------------------------------------------------------
# HAProxy Enterprise version (e.g., "3.2", "3.1", "3.0", "2.9", "2.8")
# Leave empty for auto-detection
# Example: HAPEE_VERSION="3.2"
HAPEE_VERSION=""

# Manual override for HAProxy Enterprise base directory
# Leave empty to use auto-detected path based on version
# Standard path: /etc/hapee-<VERSION>/
# Example: HAPEE_BASE_DIR="/etc/hapee-3.2"
HAPEE_BASE_DIR=""

# ----------------------------------------------------------------------------
# CERTIFICATE DEPLOYMENT SETTINGS
# ----------------------------------------------------------------------------
# Certificate backup behavior: "backup" or "overwrite"
# - backup: Creates timestamped backup folder before replacing certificate (DEFAULT)
# - overwrite: Directly overwrites existing certificate without backup
CERT_BACKUP_MODE="backup"

# Directory for certificate backups (relative to HAProxy config directory)
# Example: If HAPEE_BASE_DIR is /etc/hapee-3.2, backups go to /etc/hapee-3.2/certs-backup/
BACKUP_SUBDIR="certs-backup"

# ----------------------------------------------------------------------------
# CERTIFICATE LOCATION SETTINGS
# ----------------------------------------------------------------------------
# Where is the certificate configured in HAProxy?
# Options:
#   "global"   - Certificate path defined in global section (ssl-default-bind-crt)
#   "frontend" - Certificate path defined on a specific frontend bind line
#   "crt-list" - Certificate is managed via a crt-list file
CERT_CONFIG_LOCATION="frontend"

# Frontend name (required if CERT_CONFIG_LOCATION="frontend")
# This is the name of the frontend section in hapee-lb.cfg where the certificate is bound
# Example: FRONTEND_NAME="fe_https"
FRONTEND_NAME="fe_http"

# CRT-list file path (required if CERT_CONFIG_LOCATION="crt-list")
# Full path to the crt-list file that references the certificate
# Example: CRT_LIST_FILE="/etc/hapee-3.2/certificate-list.txt"
CRT_LIST_FILE=""

# Target certificate path and filename
# This is where the combined PEM file will be deployed
# Leave empty to auto-detect from HAProxy configuration
# Example: TARGET_CERT_PATH="/etc/hapee-3.2/certs/site.pem"
TARGET_CERT_PATH=""

# ----------------------------------------------------------------------------
# SERVICE RESTART SETTINGS
# ----------------------------------------------------------------------------
# Whether to restart/reload HAProxy Enterprise after certificate deployment
# Options: "yes" or "no" (DEFAULT: no)
RESTART_HAPROXY="yes"

# Restart method: "reload" or "restart"
# - reload: Graceful reload, no dropped connections (RECOMMENDED)
# - restart: Full restart, may briefly interrupt connections
RESTART_METHOD="restart"

# Whether to use Runtime API for hot certificate update (no reload needed)
# This updates the certificate in memory without any service interruption
# Note: Changes are NOT persistent until files are also updated on disk
# Options: "yes" or "no" (DEFAULT: no)
USE_RUNTIME_API="no"

# Runtime API socket path (auto-detected if empty)
# Example: RUNTIME_API_SOCKET="/var/run/hapee-3.2/hapee-lb.sock"
RUNTIME_API_SOCKET=""

# ============================================================================
# END OF CONFIGURATION SECTION
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to detect HAProxy Enterprise version
detect_hapee_version() {
    log_message "Attempting to auto-detect HAProxy Enterprise version..."
    
    # Method 1: Check for installed hapee-lb binary in standard locations
    for version in "3.2" "3.1" "3.0" "2.9" "2.8" "2.7" "2.6" "2.5" "2.4"; do
        if [ -f "/opt/hapee-${version}/sbin/hapee-lb" ]; then
            log_message "Found HAProxy Enterprise ${version} binary at /opt/hapee-${version}/sbin/hapee-lb"
            echo "$version"
            return 0
        fi
    done
    
    # Method 2: Check for config directories
    for version in "3.2" "3.1" "3.0" "2.9" "2.8" "2.7" "2.6" "2.5" "2.4"; do
        if [ -d "/etc/hapee-${version}" ]; then
            log_message "Found HAProxy Enterprise ${version} config directory at /etc/hapee-${version}"
            echo "$version"
            return 0
        fi
    done
    
    # Method 3: Check running process
    local running_version=$(ps aux | grep -oP 'hapee-\K[0-9]+\.[0-9]+' | head -1)
    if [ -n "$running_version" ]; then
        log_message "Detected HAProxy Enterprise ${running_version} from running process"
        echo "$running_version"
        return 0
    fi
    
    # Method 4: Check systemd services
    local systemd_version=$(systemctl list-units --type=service | grep -oP 'hapee-\K[0-9]+\.[0-9]+' | head -1)
    if [ -n "$systemd_version" ]; then
        log_message "Detected HAProxy Enterprise ${systemd_version} from systemd service"
        echo "$systemd_version"
        return 0
    fi
    
    log_message "ERROR: Could not auto-detect HAProxy Enterprise version"
    return 1
}

# Function to get HAProxy Enterprise paths
get_hapee_paths() {
    local version="$1"
    
    # Set base directory
    if [ -z "$HAPEE_BASE_DIR" ]; then
        HAPEE_BASE_DIR="/etc/hapee-${version}"
    fi
    
    # Set other paths
    HAPEE_CONFIG_FILE="${HAPEE_BASE_DIR}/hapee-lb.cfg"
    HAPEE_CERTS_DIR="${HAPEE_BASE_DIR}/certs"
    HAPEE_BACKUP_DIR="${HAPEE_BASE_DIR}/${BACKUP_SUBDIR}"
    
    # Runtime API socket
    if [ -z "$RUNTIME_API_SOCKET" ]; then
        RUNTIME_API_SOCKET="/var/run/hapee-${version}/hapee-lb.sock"
    fi
    
    # Service name
    HAPEE_SERVICE="hapee-${version}-lb"
    
    log_message "HAProxy Enterprise paths configured:"
    log_message "  Base directory: $HAPEE_BASE_DIR"
    log_message "  Config file: $HAPEE_CONFIG_FILE"
    log_message "  Certificates directory: $HAPEE_CERTS_DIR"
    log_message "  Backup directory: $HAPEE_BACKUP_DIR"
    log_message "  Runtime API socket: $RUNTIME_API_SOCKET"
    log_message "  Service name: $HAPEE_SERVICE"
}

# Function to find certificate path from HAProxy configuration
find_cert_path_from_config() {
    log_message "Searching for certificate path in HAProxy configuration..."
    
    if [ ! -f "$HAPEE_CONFIG_FILE" ]; then
        log_message "ERROR: HAProxy config file not found: $HAPEE_CONFIG_FILE"
        return 1
    fi
    
    local cert_path=""
    
    case "$CERT_CONFIG_LOCATION" in
        "global")
            # Look for ssl-default-bind-crt in global section
            cert_path=$(grep -oP '^\s*ssl-default-bind-crt\s+\K[^\s]+' "$HAPEE_CONFIG_FILE" | head -1)
            log_message "Searching global section for ssl-default-bind-crt..."
            ;;
        "frontend")
            # Look for crt on bind line in specific frontend
            log_message "Searching frontend '$FRONTEND_NAME' for certificate path..."
            
            # Extract the frontend section using line numbers (more reliable than awk with variables)
            local start_line=$(grep -n "^frontend[[:space:]]\+${FRONTEND_NAME}[[:space:]]*$" "$HAPEE_CONFIG_FILE" | head -1 | cut -d: -f1)
            
            if [ -z "$start_line" ]; then
                # Try without strict end-of-line match
                start_line=$(grep -n "^frontend[[:space:]]\+${FRONTEND_NAME}" "$HAPEE_CONFIG_FILE" | head -1 | cut -d: -f1)
            fi
            
            if [ -n "$start_line" ]; then
                log_message "Found frontend '$FRONTEND_NAME' at line $start_line"
                
                # Find the next section (frontend, backend, defaults, global, listen) after start_line
                local end_line=$(tail -n +$((start_line + 1)) "$HAPEE_CONFIG_FILE" | grep -n "^[[:space:]]*\(frontend\|backend\|defaults\|global\|listen\)[[:space:]]" | head -1 | cut -d: -f1)
                
                local frontend_section=""
                if [ -n "$end_line" ]; then
                    local actual_end=$((start_line + end_line - 1))
                    frontend_section=$(sed -n "${start_line},${actual_end}p" "$HAPEE_CONFIG_FILE")
                    log_message "Frontend section: lines $start_line to $actual_end"
                else
                    # No next section found, take rest of file
                    frontend_section=$(tail -n +${start_line} "$HAPEE_CONFIG_FILE")
                    log_message "Frontend section: line $start_line to end of file"
                fi
                
                # Log the bind lines for debugging
                log_message "Bind lines in frontend:"
                echo "$frontend_section" | grep -E '^\s*bind' | while read line; do
                    log_message "  $line"
                done
                
                # Extract certificate path from bind line with ssl and crt
                # Pattern: find line with 'bind' and 'ssl' and 'crt', then extract path after 'crt'
                cert_path=$(echo "$frontend_section" | grep -E '^\s*bind.*ssl.*crt' | sed -n 's/.*[[:space:]]crt[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -1)
                
                if [ -z "$cert_path" ]; then
                    # Try alternative: crt might come before ssl in some configs
                    cert_path=$(echo "$frontend_section" | grep -E '^\s*bind.*crt' | sed -n 's/.*[[:space:]]crt[[:space:]]\+\([^[:space:]]\+\).*/\1/p' | head -1)
                fi
                
                log_message "Extracted certificate path: '$cert_path'"
            else
                log_message "WARNING: Frontend '$FRONTEND_NAME' not found in configuration"
            fi
            
            # Also check for crt-list in frontend if no direct crt found
            if [ -z "$cert_path" ] && [ -n "$frontend_section" ]; then
                local crt_list=$(echo "$frontend_section" | grep -oP 'crt-list\s+\K[^\s]+' | head -1)
                if [ -n "$crt_list" ]; then
                    log_message "Frontend uses crt-list: $crt_list"
                    CRT_LIST_FILE="$crt_list"
                    # Get first certificate from crt-list
                    if [ -f "$crt_list" ]; then
                        cert_path=$(grep -v '^#' "$crt_list" | grep -v '^\s*$' | head -1 | awk '{print $1}')
                    fi
                fi
            fi
            ;;
        "crt-list")
            log_message "Searching crt-list file for certificate path..."
            if [ -n "$CRT_LIST_FILE" ] && [ -f "$CRT_LIST_FILE" ]; then
                cert_path=$(grep -v '^#' "$CRT_LIST_FILE" | grep -v '^\s*$' | head -1 | awk '{print $1}')
            else
                log_message "ERROR: CRT-list file not specified or not found: $CRT_LIST_FILE"
                return 1
            fi
            ;;
        *)
            log_message "ERROR: Invalid CERT_CONFIG_LOCATION: $CERT_CONFIG_LOCATION"
            return 1
            ;;
    esac
    
    if [ -n "$cert_path" ]; then
        log_message "Found certificate path: $cert_path"
        echo "$cert_path"
        return 0
    else
        log_message "WARNING: Could not find certificate path in configuration"
        return 1
    fi
}

# Function to create backup of existing certificate
backup_certificate() {
    local cert_file="$1"
    
    if [ ! -f "$cert_file" ]; then
        log_message "No existing certificate to backup at: $cert_file"
        return 0
    fi
    
    # Create backup directory with timestamp
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_folder="${HAPEE_BACKUP_DIR}/${timestamp}"
    
    log_message "Creating backup directory: $backup_folder"
    mkdir -p "$backup_folder"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create backup directory: $backup_folder"
        return 1
    fi
    
    # Get the certificate filename
    local cert_filename=$(basename "$cert_file")
    
    # Copy certificate to backup folder
    log_message "Backing up certificate: $cert_file -> ${backup_folder}/${cert_filename}"
    cp -p "$cert_file" "${backup_folder}/${cert_filename}"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to backup certificate"
        return 1
    fi
    
    # Also backup any associated files (key, ocsp, etc.)
    local cert_dir=$(dirname "$cert_file")
    local cert_base="${cert_filename%.*}"
    
    for ext in key ocsp issuer sctl; do
        if [ -f "${cert_dir}/${cert_base}.${ext}" ]; then
            log_message "Backing up associated file: ${cert_base}.${ext}"
            cp -p "${cert_dir}/${cert_base}.${ext}" "${backup_folder}/"
        fi
    done
    
    log_message "Backup completed successfully to: $backup_folder"
    return 0
}

# Function to create combined PEM file (certificate + key)
create_combined_pem() {
    local cert_file="$1"
    local key_file="$2"
    local output_file="$3"
    
    log_message "Creating combined PEM file..."
    log_message "  Certificate: $cert_file"
    log_message "  Private key: $key_file"
    log_message "  Output: $output_file"
    
    # Create output directory if it doesn't exist
    local output_dir=$(dirname "$output_file")
    if [ ! -d "$output_dir" ]; then
        log_message "Creating output directory: $output_dir"
        mkdir -p "$output_dir"
        if [ $? -ne 0 ]; then
            log_message "ERROR: Failed to create output directory"
            return 1
        fi
    fi
    
    # Combine certificate and key into single PEM file
    # HAProxy expects: certificate chain first, then private key
    cat "$cert_file" "$key_file" > "$output_file"
    
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create combined PEM file"
        return 1
    fi
    
    # Set appropriate permissions
    chmod 600 "$output_file"
    
    # Verify the combined file
    local cert_count=$(grep -c "BEGIN CERTIFICATE" "$output_file")
    local key_count=$(grep -c "BEGIN.*PRIVATE KEY" "$output_file")
    
    log_message "Combined PEM file created successfully:"
    log_message "  Certificates in file: $cert_count"
    log_message "  Private keys in file: $key_count"
    
    if [ "$cert_count" -eq 0 ] || [ "$key_count" -eq 0 ]; then
        log_message "WARNING: Combined PEM file may be incomplete"
    fi
    
    return 0
}

# Function to update certificate via Runtime API (hot update)
update_cert_via_runtime_api() {
    local cert_path="$1"
    local new_cert_file="$2"
    
    log_message "Updating certificate via Runtime API..."
    log_message "  Socket: $RUNTIME_API_SOCKET"
    log_message "  Certificate path: $cert_path"
    
    # Check if socat is available
    if ! command -v socat &> /dev/null; then
        log_message "ERROR: socat is not installed. Cannot use Runtime API."
        log_message "Please install socat or set USE_RUNTIME_API='no'"
        return 1
    fi
    
    # Check if socket exists
    if [ ! -S "$RUNTIME_API_SOCKET" ]; then
        log_message "ERROR: Runtime API socket not found: $RUNTIME_API_SOCKET"
        return 1
    fi
    
    # Read the new certificate content
    local cert_content=$(cat "$new_cert_file")
    
    # Start transaction: set ssl cert
    log_message "Starting certificate update transaction..."
    local result=$(echo -e "set ssl cert ${cert_path} <<\n${cert_content}\n" | \
                   socat stdio "unix-connect:${RUNTIME_API_SOCKET}" 2>&1)
    
    log_message "Set ssl cert response: $result"
    
    if echo "$result" | grep -qi "error\|failed"; then
        log_message "ERROR: Failed to set SSL certificate via Runtime API"
        return 1
    fi
    
    # Commit the transaction
    log_message "Committing certificate update..."
    result=$(echo "commit ssl cert ${cert_path}" | \
             socat stdio "unix-connect:${RUNTIME_API_SOCKET}" 2>&1)
    
    log_message "Commit ssl cert response: $result"
    
    if echo "$result" | grep -qi "error\|failed"; then
        log_message "ERROR: Failed to commit SSL certificate via Runtime API"
        return 1
    fi
    
    log_message "Certificate updated successfully via Runtime API"
    return 0
}

# Function to restart/reload HAProxy Enterprise
restart_haproxy() {
    log_message "Preparing to ${RESTART_METHOD} HAProxy Enterprise..."
    
    # Validate configuration before restart
    log_message "Validating HAProxy configuration..."
    local validation_result=$(/opt/hapee-${DETECTED_VERSION}/sbin/hapee-lb -c -f "$HAPEE_CONFIG_FILE" 2>&1)
    local validation_status=$?
    
    if [ $validation_status -ne 0 ]; then
        log_message "ERROR: Configuration validation failed:"
        log_message "$validation_result"
        log_message "Aborting ${RESTART_METHOD} to prevent service disruption"
        return 1
    fi
    
    log_message "Configuration validation passed"
    
    # Perform restart or reload
    case "$RESTART_METHOD" in
        "reload")
            log_message "Executing: systemctl reload ${HAPEE_SERVICE}"
            systemctl reload "$HAPEE_SERVICE"
            ;;
        "restart")
            log_message "Executing: systemctl restart ${HAPEE_SERVICE}"
            systemctl restart "$HAPEE_SERVICE"
            ;;
        *)
            log_message "ERROR: Invalid RESTART_METHOD: $RESTART_METHOD"
            return 1
            ;;
    esac
    
    local restart_status=$?
    
    if [ $restart_status -ne 0 ]; then
        log_message "ERROR: Failed to ${RESTART_METHOD} HAProxy Enterprise (exit code: $restart_status)"
        return 1
    fi
    
    # Wait a moment and check service status
    sleep 2
    
    if systemctl is-active --quiet "$HAPEE_SERVICE"; then
        log_message "HAProxy Enterprise ${RESTART_METHOD}ed successfully"
        log_message "Service status: active"
    else
        log_message "WARNING: HAProxy Enterprise may not be running properly after ${RESTART_METHOD}"
        local status=$(systemctl status "$HAPEE_SERVICE" 2>&1)
        log_message "Service status output:"
        log_message "$status"
        return 1
    fi
    
    return 0
}

# ============================================================================
# MAIN SCRIPT EXECUTION
# ============================================================================

# Start logging
log_message "=========================================="
log_message "Starting HAProxy Enterprise Certificate Deployment Script"
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

# Log configuration settings
log_message "=========================================="
log_message "Configuration Settings:"
log_message "=========================================="
log_message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
log_message "  LOGFILE: $LOGFILE"
log_message "  HAPEE_VERSION: ${HAPEE_VERSION:-'(auto-detect)'}"
log_message "  HAPEE_BASE_DIR: ${HAPEE_BASE_DIR:-'(auto-detect)'}"
log_message "  CERT_BACKUP_MODE: $CERT_BACKUP_MODE"
log_message "  CERT_CONFIG_LOCATION: $CERT_CONFIG_LOCATION"
log_message "  FRONTEND_NAME: $FRONTEND_NAME"
log_message "  CRT_LIST_FILE: ${CRT_LIST_FILE:-'(not set)'}"
log_message "  TARGET_CERT_PATH: ${TARGET_CERT_PATH:-'(auto-detect)'}"
log_message "  RESTART_HAPROXY: $RESTART_HAPROXY"
log_message "  RESTART_METHOD: $RESTART_METHOD"
log_message "  USE_RUNTIME_API: $USE_RUNTIME_API"
log_message "=========================================="

# Detect or use configured HAProxy Enterprise version
if [ -z "$HAPEE_VERSION" ]; then
    DETECTED_VERSION=$(detect_hapee_version)
    if [ $? -ne 0 ] || [ -z "$DETECTED_VERSION" ]; then
        log_message "ERROR: Failed to detect HAProxy Enterprise version"
        log_message "Please set HAPEE_VERSION manually in the configuration section"
        exit 1
    fi
else
    DETECTED_VERSION="$HAPEE_VERSION"
    log_message "Using configured HAProxy Enterprise version: $DETECTED_VERSION"
fi

log_message "HAProxy Enterprise version: $DETECTED_VERSION"

# Set HAProxy Enterprise paths
get_hapee_paths "$DETECTED_VERSION"

# Verify HAProxy Enterprise installation
if [ ! -f "$HAPEE_CONFIG_FILE" ]; then
    log_message "ERROR: HAProxy Enterprise configuration file not found: $HAPEE_CONFIG_FILE"
    log_message "Please verify HAProxy Enterprise is installed and HAPEE_VERSION is correct"
    exit 1
fi

log_message "HAProxy Enterprise configuration file found: $HAPEE_CONFIG_FILE"

# Log environment variable check
log_message "=========================================="
log_message "Processing DC1_POST_SCRIPT_DATA..."
log_message "=========================================="

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

# Extract the args array
ARGS_ARRAY=$(echo "$JSON_STRING" | grep -oP '"args":\[\K[^]]*')
log_message "Raw args array: $ARGS_ARRAY"

# Extract individual arguments
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | tr -d '"' | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | tr -d '"' | tr -d '[:space:]')

log_message "Arguments extracted:"
log_message "  Argument 1: '$ARGUMENT_1'"
log_message "  Argument 2: '$ARGUMENT_2'"
log_message "  Argument 3: '$ARGUMENT_3'"
log_message "  Argument 4: '$ARGUMENT_4'"
log_message "  Argument 5: '$ARGUMENT_5'"

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

# Log extraction summary
log_message "=========================================="
log_message "EXTRACTION SUMMARY:"
log_message "=========================================="
log_message "  Certificate folder: $CERT_FOLDER"
log_message "  Certificate file: $CRT_FILE"
log_message "  Private key file: $KEY_FILE"
log_message "  Certificate path: $CRT_FILE_PATH"
log_message "  Private key path: $KEY_FILE_PATH"
log_message "  All files: $FILES_ARRAY"
log_message "=========================================="

# Verify source files exist
if [ ! -f "$CRT_FILE_PATH" ]; then
    log_message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
fi
log_message "Certificate file exists: $CRT_FILE_PATH"
log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"

# Count certificates in the file
CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CRT_FILE_PATH")
log_message "Total certificates in file: $CERT_COUNT"

if [ ! -f "$KEY_FILE_PATH" ]; then
    log_message "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
fi
log_message "Private key file exists: $KEY_FILE_PATH"
log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"

# Determine key type
if grep -q "BEGIN RSA PRIVATE KEY" "$KEY_FILE_PATH"; then
    KEY_TYPE="RSA"
elif grep -q "BEGIN EC PRIVATE KEY" "$KEY_FILE_PATH"; then
    KEY_TYPE="ECC"
elif grep -q "BEGIN PRIVATE KEY" "$KEY_FILE_PATH"; then
    KEY_TYPE="PKCS#8"
else
    KEY_TYPE="Unknown"
fi
log_message "Key type: $KEY_TYPE"

# ============================================================================
# CERTIFICATE DEPLOYMENT SECTION
# ============================================================================

log_message "=========================================="
log_message "Starting certificate deployment..."
log_message "=========================================="

# Determine target certificate path
if [ -z "$TARGET_CERT_PATH" ]; then
    log_message "Auto-detecting target certificate path from HAProxy configuration..."
    DETECTED_CERT_PATH=$(find_cert_path_from_config)
    if [ $? -eq 0 ] && [ -n "$DETECTED_CERT_PATH" ]; then
        TARGET_CERT_PATH="$DETECTED_CERT_PATH"
        log_message "Auto-detected certificate path: $TARGET_CERT_PATH"
    else
        # Auto-detection failed - this is a configuration error
        log_message "=========================================="
        log_message "ERROR: Could not auto-detect certificate path from HAProxy configuration"
        log_message "=========================================="
        log_message "Please set TARGET_CERT_PATH in the script configuration."
        log_message ""
        log_message "To find the correct path, check your HAProxy config:"
        log_message "  grep -E 'bind.*ssl.*crt' $HAPEE_CONFIG_FILE"
        log_message ""
        log_message "Then set TARGET_CERT_PATH to match the 'crt' value."
        log_message "Example: TARGET_CERT_PATH=\"/etc/hapee-3.1/certs/haproxy.pem\""
        log_message "=========================================="
        exit 1
    fi
fi

log_message "Target certificate path: $TARGET_CERT_PATH"

# Create certs directory if it doesn't exist
CERT_DIR=$(dirname "$TARGET_CERT_PATH")
if [ ! -d "$CERT_DIR" ]; then
    log_message "Creating certificate directory: $CERT_DIR"
    mkdir -p "$CERT_DIR"
    if [ $? -ne 0 ]; then
        log_message "ERROR: Failed to create certificate directory"
        exit 1
    fi
fi

# Handle backup or overwrite
case "$CERT_BACKUP_MODE" in
    "backup")
        log_message "Backup mode enabled - creating backup of existing certificate..."
        backup_certificate "$TARGET_CERT_PATH"
        if [ $? -ne 0 ]; then
            log_message "ERROR: Backup failed. Aborting deployment for safety."
            exit 1
        fi
        ;;
    "overwrite")
        log_message "Overwrite mode enabled - existing certificate will be replaced without backup"
        if [ -f "$TARGET_CERT_PATH" ]; then
            log_message "WARNING: Existing certificate will be overwritten: $TARGET_CERT_PATH"
        fi
        ;;
    *)
        log_message "ERROR: Invalid CERT_BACKUP_MODE: $CERT_BACKUP_MODE"
        exit 1
        ;;
esac

# Create combined PEM file
log_message "Creating combined PEM file for HAProxy..."
create_combined_pem "$CRT_FILE_PATH" "$KEY_FILE_PATH" "$TARGET_CERT_PATH"
if [ $? -ne 0 ]; then
    log_message "ERROR: Failed to create combined PEM file"
    exit 1
fi

log_message "Certificate deployed successfully to: $TARGET_CERT_PATH"

# Update via Runtime API if enabled
if [ "$USE_RUNTIME_API" = "yes" ]; then
    log_message "=========================================="
    log_message "Updating certificate via Runtime API..."
    log_message "=========================================="
    
    update_cert_via_runtime_api "$TARGET_CERT_PATH" "$TARGET_CERT_PATH"
    if [ $? -eq 0 ]; then
        log_message "Certificate hot-updated via Runtime API"
        log_message "Note: HAProxy is now using the new certificate in memory"
    else
        log_message "WARNING: Runtime API update failed"
        log_message "Certificate file has been updated on disk"
        if [ "$RESTART_HAPROXY" = "yes" ]; then
            log_message "Will proceed with service ${RESTART_METHOD}..."
        else
            log_message "A manual reload/restart may be required for HAProxy to use the new certificate"
        fi
    fi
fi

# Restart/reload HAProxy if enabled
if [ "$RESTART_HAPROXY" = "yes" ]; then
    log_message "=========================================="
    log_message "Restarting HAProxy Enterprise..."
    log_message "=========================================="
    
    restart_haproxy
    if [ $? -ne 0 ]; then
        log_message "ERROR: HAProxy ${RESTART_METHOD} failed"
        log_message "Please check HAProxy status manually"
        exit 1
    fi
else
    log_message "=========================================="
    log_message "HAProxy restart/reload is disabled"
    log_message "=========================================="
    log_message "IMPORTANT: The new certificate has been deployed to: $TARGET_CERT_PATH"
    log_message "To apply the new certificate, you must either:"
    log_message "  1. Reload HAProxy: systemctl reload ${HAPEE_SERVICE}"
    log_message "  2. Restart HAProxy: systemctl restart ${HAPEE_SERVICE}"
    log_message "  3. Use Runtime API to update certificate in memory"
    log_message "=========================================="
fi

# Final summary
log_message "=========================================="
log_message "DEPLOYMENT SUMMARY:"
log_message "=========================================="
log_message "  HAProxy Enterprise version: $DETECTED_VERSION"
log_message "  Source certificate: $CRT_FILE_PATH"
log_message "  Source private key: $KEY_FILE_PATH"
log_message "  Target PEM file: $TARGET_CERT_PATH"
log_message "  Backup mode: $CERT_BACKUP_MODE"
log_message "  Certificate location: $CERT_CONFIG_LOCATION"
if [ "$CERT_CONFIG_LOCATION" = "frontend" ]; then
    log_message "  Frontend name: $FRONTEND_NAME"
fi
log_message "  Runtime API update: $USE_RUNTIME_API"
log_message "  Service restart: $RESTART_HAPROXY"
if [ "$RESTART_HAPROXY" = "yes" ]; then
    log_message "  Restart method: $RESTART_METHOD"
fi
log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0