#!/bin/bash

: <<'LEGAL_NOTICE'
Legal Notice (version January 1, 2026)
Copyright © 2026 DigiCert. All rights reserved.
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
# HAPROXY OSS CERTIFICATE DEPLOYMENT SCRIPT
# DigiCert Trust Lifecycle Manager Integration
# ============================================================================
#
# This script automates certificate deployment to HAProxy (Open Source).
# It extracts certificate data from TLM Agent's DC1_POST_SCRIPT_DATA,
# creates combined PEM files, and optionally restarts HAProxy.
#
# MULTI-ENDPOINT SUPPORT:
# The script discovers ALL certificate paths referenced by the HAProxy
# configuration (every bind line across every frontend/listen section, all
# crt-list entries, and directory-based crt definitions). It then matches the
# renewed certificate to the existing certificate(s) on disk by CN/SAN and
# deploys ONLY to the endpoint(s) that serve the same name(s). This prevents
# overwriting an unrelated certificate when several are configured.
#
# ============================================================================

# ============================================================================
# CONFIGURATION SECTION - MODIFY THESE SETTINGS AS REQUIRED
# ============================================================================

# Legal notice acceptance (required)
LEGAL_NOTICE_ACCEPT="false" # Set to "true" to accept the legal notice and allow script execution

# Log file location
LOGFILE="/home/ubuntu/tlmagent/tlm_agent_3.1.7_linux64/log/haproxy-oss-awr.log"

# ----------------------------------------------------------------------------
# HAPROXY CONFIGURATION PATHS
# ----------------------------------------------------------------------------
# HAProxy configuration file location
# Standard locations:
#   - Debian/Ubuntu: /etc/haproxy/haproxy.cfg
#   - RHEL/CentOS: /etc/haproxy/haproxy.cfg
#   - Docker: /usr/local/etc/haproxy/haproxy.cfg
HAPROXY_CONFIG_FILE="/etc/haproxy/haproxy.cfg"

# HAProxy base directory (where config and certs are stored)
HAPROXY_BASE_DIR="/etc/haproxy"

# Certificate directory
HAPROXY_CERTS_DIR="/etc/haproxy/certs"

# ----------------------------------------------------------------------------
# CERTIFICATE DEPLOYMENT SETTINGS
# ----------------------------------------------------------------------------
# Certificate backup behavior: "backup" or "overwrite"
# - backup: Creates timestamped backup folder before replacing certificate (DEFAULT)
# - overwrite: Directly overwrites existing certificate without backup
CERT_BACKUP_MODE="backup"

# Directory for certificate backups
BACKUP_DIR="/etc/haproxy/certs-backup"

# ----------------------------------------------------------------------------
# MULTI-ENDPOINT MATCHING SETTINGS
# ----------------------------------------------------------------------------
# How the renewed certificate is matched to the endpoint(s) it should replace:
#   "cn-san" - (DEFAULT, RECOMMENDED) Only deploy to discovered certificate
#              paths whose existing on-disk certificate shares a CN or DNS SAN
#              with the renewed certificate. This is the safe option for hosts
#              that serve multiple distinct certificates; a renewal for one
#              domain will not overwrite another domain's certificate.
#   "all"    - Deploy the renewed certificate to EVERY discovered path. Only use
#              this when every endpoint is expected to serve the same single
#              certificate. This will overwrite all discovered certificates.
MATCH_STRATEGY="cn-san"

# ----------------------------------------------------------------------------
# CERTIFICATE LOCATION SETTINGS
# ----------------------------------------------------------------------------
# Where is the certificate configured in HAProxy?
# Options:
#   "global"   - Certificate path(s) defined in global section (ssl-default-bind-crt)
#   "frontend" - Certificate paths defined on frontend/listen bind lines
#   "crt-list" - Certificate(s) managed via a crt-list file
CERT_CONFIG_LOCATION="frontend"

# Frontend name (used only when CERT_CONFIG_LOCATION="frontend")
# - Set to a specific name to restrict discovery to that one frontend.
# - LEAVE EMPTY to scan ALL frontend AND listen sections (recommended when
#   multiple endpoints are configured).
# Example: FRONTEND_NAME="https_front"
FRONTEND_NAME=""

# CRT-list file path (required if CERT_CONFIG_LOCATION="crt-list")
# Full path to the crt-list file that references the certificate(s)
# Example: CRT_LIST_FILE="/etc/haproxy/crt-list.txt"
CRT_LIST_FILE=""

# OPTIONAL single-target override.
# When set, discovery and matching are SKIPPED and the renewed certificate is
# deployed only to this exact path. Leave empty to use multi-endpoint discovery.
# Example: TARGET_CERT_PATH="/etc/haproxy/certs/haproxy.pem"
TARGET_CERT_PATH=""

# ----------------------------------------------------------------------------
# SERVICE RESTART SETTINGS
# ----------------------------------------------------------------------------
# Whether to restart/reload HAProxy after certificate deployment
# Options: "yes" or "no" (DEFAULT: no)
RESTART_HAPROXY="yes"

# Restart method: "reload" or "restart"
# - reload: Graceful reload, no dropped connections (RECOMMENDED, especially when
#           multiple endpoints/frontends are configured on the same instance)
# - restart: Full restart, may briefly interrupt connections on ALL frontends
RESTART_METHOD="reload"

# Whether to use Runtime API for hot certificate update (no reload needed)
# This updates the certificate in memory without any service interruption
# Note: Changes are NOT persistent until files are also updated on disk
# Requires HAProxy 2.1+ and stats socket configured with admin level
# Applied per matched target.
# Options: "yes" or "no" (DEFAULT: no)
USE_RUNTIME_API="no"

# Runtime API socket path
# Common locations:
#   - /run/haproxy/admin.sock
#   - /var/run/haproxy/admin.sock
#   - /var/lib/haproxy/stats
RUNTIME_API_SOCKET="/run/haproxy/admin.sock"

# ----------------------------------------------------------------------------
# SERVICE MANAGEMENT SETTINGS
# ----------------------------------------------------------------------------
# Service name for systemctl commands
# Standard: "haproxy"
HAPROXY_SERVICE="haproxy"

# Path to haproxy binary (for config validation)
# Standard locations:
#   - /usr/sbin/haproxy
#   - /usr/local/sbin/haproxy
HAPROXY_BINARY="/usr/sbin/haproxy"

# ============================================================================
# END OF CONFIGURATION SECTION
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Function to detect HAProxy version
detect_haproxy_version() {
    log_message "Detecting HAProxy version..."

    if [ -x "$HAPROXY_BINARY" ]; then
        local version=$("$HAPROXY_BINARY" -v 2>/dev/null | head -1)
        log_message "HAProxy version: $version"

        # Extract version number
        local version_num=$(echo "$version" | grep -oP 'version\s+\K[0-9]+\.[0-9]+' | head -1)
        if [ -n "$version_num" ]; then
            echo "$version_num"
            return 0
        fi
    fi

    # Try alternative binary locations
    for bin in /usr/sbin/haproxy /usr/local/sbin/haproxy /usr/bin/haproxy; do
        if [ -x "$bin" ]; then
            local version=$("$bin" -v 2>/dev/null | head -1)
            local version_num=$(echo "$version" | grep -oP 'version\s+\K[0-9]+\.[0-9]+' | head -1)
            if [ -n "$version_num" ]; then
                HAPROXY_BINARY="$bin"
                log_message "Found HAProxy at $bin, version: $version_num"
                echo "$version_num"
                return 0
            fi
        fi
    done

    log_message "WARNING: Could not detect HAProxy version"
    return 1
}

# Function to verify HAProxy installation
verify_haproxy_installation() {
    log_message "Verifying HAProxy installation..."

    # Check binary exists
    if [ ! -x "$HAPROXY_BINARY" ]; then
        log_message "ERROR: HAProxy binary not found at: $HAPROXY_BINARY"
        return 1
    fi
    log_message "HAProxy binary found: $HAPROXY_BINARY"

    # Check config file exists
    if [ ! -f "$HAPROXY_CONFIG_FILE" ]; then
        log_message "ERROR: HAProxy configuration file not found: $HAPROXY_CONFIG_FILE"
        return 1
    fi
    log_message "HAProxy configuration file found: $HAPROXY_CONFIG_FILE"

    # Check service exists
    if systemctl list-unit-files | grep -q "^${HAPROXY_SERVICE}.service"; then
        log_message "HAProxy service found: $HAPROXY_SERVICE"
    else
        log_message "WARNING: HAProxy service '$HAPROXY_SERVICE' not found in systemd"
    fi

    return 0
}

# ----------------------------------------------------------------------------
# CERTIFICATE IDENTITY / MATCHING HELPERS
# ----------------------------------------------------------------------------

# Extract normalized DNS identities (CN + SAN dnsNames) from a PEM file.
# Output: one lowercased, unique, sorted name per line.
get_cert_dns_names() {
    local pem="$1"

    if [ ! -f "$pem" ]; then
        return 1
    fi

    if ! command -v openssl &> /dev/null; then
        log_message "ERROR: openssl not found; cannot read certificate identities"
        return 1
    fi

    local txt
    txt=$(openssl x509 -in "$pem" -noout -text 2>/dev/null)
    if [ -z "$txt" ]; then
        return 1
    fi

    {
        # CN from the Subject line
        # DNS SANs (can span multiple continuation lines in openssl output)
        echo "$txt" | awk '/Subject Alternative Name/ {in_san=1; next} in_san && /^[[:space:]]/ {print; next} in_san {exit}' | grep -oP 'DNS:\K[^,]+'
    } | sed 's/[[:space:]]//g' | tr 'A-Z' 'a-z' | grep -v '^$' | sort -u
}

# Decide whether a renewed certificate should replace an existing on-disk cert.
# Match when the two certificates share at least one CN/SAN DNS name.
# Args: <file containing renewed cert names (sorted)> <path to existing PEM>
cert_matches() {
    local new_names_file="$1"
    local existing_pem="$2"

    local existing_names
    existing_names=$(get_cert_dns_names "$existing_pem")
    if [ -z "$existing_names" ]; then
        return 1
    fi

    # comm -12 prints names common to both sorted sets
    local common
    common=$(comm -12 "$new_names_file" <(printf '%s\n' "$existing_names"))
    if [ -n "$common" ]; then
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# MULTI-ENDPOINT DISCOVERY
# ----------------------------------------------------------------------------

# Expand a list of raw entries into concrete certificate file paths.
# Each input line is either "CRT\t<path>", "CRTLIST\t<path>", or a bare path.
# crt-list files are expanded to their first-column entries; directory targets
# are expanded to the *.pem / *.crt files they contain. Output is de-duplicated.
expand_and_normalize_paths() {
    local input="$1"
    local intermediate=""

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local tag path
        if printf '%s' "$entry" | grep -q $'\t'; then
            tag=$(printf '%s' "$entry" | cut -f1)
            path=$(printf '%s' "$entry" | cut -f2-)
        else
            tag="CRT"
            path="$entry"
        fi

        case "$tag" in
            CRTLIST)
                if [ -f "$path" ]; then
                    while IFS= read -r cl; do
                        intermediate="${intermediate}${cl}"$'\n'
                    done < <(grep -v '^#' "$path" | grep -v '^[[:space:]]*$' | awk '{print $1}')
                else
                    log_message "WARNING: crt-list referenced but not found: $path"
                fi
                ;;
            CRT)
                intermediate="${intermediate}${path}"$'\n'
                ;;
        esac
    done < <(printf '%s\n' "$input")

    # Expand directories into the PEM/CRT files they contain
    local final=""
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if [ -d "$p" ]; then
            while IFS= read -r f; do
                final="${final}${f}"$'\n'
            done < <(find "$p" -maxdepth 1 -type f \( -name '*.pem' -o -name '*.crt' \) 2>/dev/null)
        else
            final="${final}${p}"$'\n'
        fi
    done < <(printf '%s\n' "$intermediate")

    printf '%s\n' "$final" | grep -v '^[[:space:]]*$' | sort -u
}

# Discover ALL certificate paths referenced by the HAProxy configuration.
# Output: one normalized certificate file path per line.
discover_all_cert_paths() {
    if [ ! -f "$HAPROXY_CONFIG_FILE" ]; then
        log_message "ERROR: HAProxy config file not found: $HAPROXY_CONFIG_FILE"
        return 1
    fi

    local raw_paths=""

    case "$CERT_CONFIG_LOCATION" in
        "global")
            log_message "Scanning global section for ssl-default-bind-crt..."
            # ssl-default-bind-crt may list several space-separated paths/dirs
            local global_line
            global_line=$(grep -oP '^\s*ssl-default-bind-crt\s+\K.*' "$HAPROXY_CONFIG_FILE" | head -1)
            local p
            for p in $global_line; do
                raw_paths="${raw_paths}CRT"$'\t'"${p}"$'\n'
            done
            ;;
        "frontend")
            # Restrict to a single frontend if FRONTEND_NAME is set; otherwise scan
            # every frontend AND listen section. Captures all crt and crt-list
            # tokens across all bind lines (multiple binds, multiple crt per line).
            if [ -n "$FRONTEND_NAME" ]; then
                log_message "Scanning frontend '$FRONTEND_NAME' for certificate paths..."
            else
                log_message "Scanning all frontend and listen sections for certificate paths..."
            fi

            raw_paths=$(awk -v want="$FRONTEND_NAME" '
                function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
                {
                    line = trim($0)
                    if (line ~ /^(frontend|backend|defaults|global|listen)([[:space:]]|$)/) {
                        n = split(line, a, /[[:space:]]+/)
                        sect = a[1]; name = a[2]
                        if (sect == "frontend" || sect == "listen") {
                            if (want == "" || name == want) intarget = 1; else intarget = 0
                        } else {
                            intarget = 0
                        }
                        next
                    }
                    if (intarget && line ~ /^bind([[:space:]]|$)/) {
                        n = split(line, t, /[[:space:]]+/)
                        for (i = 1; i <= n; i++) {
                            if (t[i] == "crt" && i < n)      print "CRT\t"     t[i+1]
                            if (t[i] == "crt-list" && i < n) print "CRTLIST\t" t[i+1]
                        }
                    }
                }
            ' "$HAPROXY_CONFIG_FILE")
            ;;
        "crt-list")
            log_message "Scanning crt-list file for certificate paths: $CRT_LIST_FILE"
            if [ -n "$CRT_LIST_FILE" ] && [ -f "$CRT_LIST_FILE" ]; then
                local cl
                while IFS= read -r cl; do
                    raw_paths="${raw_paths}CRT"$'\t'"${cl}"$'\n'
                done < <(grep -v '^#' "$CRT_LIST_FILE" | grep -v '^[[:space:]]*$' | awk '{print $1}')
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

    expand_and_normalize_paths "$raw_paths"
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
    local backup_folder="${BACKUP_DIR}/${timestamp}"

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

    # Guard against a target that is actually a directory
    if [ -d "$output_file" ]; then
        log_message "ERROR: Target path is a directory, not a file: $output_file"
        return 1
    fi

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

    # Set ownership to haproxy user if it exists
    if id "haproxy" &>/dev/null; then
        chown haproxy:haproxy "$output_file" 2>/dev/null || true
    fi

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
        log_message "Ensure 'stats socket' is configured in haproxy.cfg with 'level admin'"
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

# Function to restart/reload HAProxy
restart_haproxy() {
    log_message "Preparing to ${RESTART_METHOD} HAProxy..."

    # Validate configuration before restart
    log_message "Validating HAProxy configuration..."
    local validation_result=$("$HAPROXY_BINARY" -c -f "$HAPROXY_CONFIG_FILE" 2>&1)
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
            log_message "Executing: systemctl reload ${HAPROXY_SERVICE}"
            systemctl reload "$HAPROXY_SERVICE"
            ;;
        "restart")
            log_message "Executing: systemctl restart ${HAPROXY_SERVICE}"
            systemctl restart "$HAPROXY_SERVICE"
            ;;
        *)
            log_message "ERROR: Invalid RESTART_METHOD: $RESTART_METHOD"
            return 1
            ;;
    esac

    local restart_status=$?

    if [ $restart_status -ne 0 ]; then
        log_message "ERROR: Failed to ${RESTART_METHOD} HAProxy (exit code: $restart_status)"
        return 1
    fi

    # Wait a moment and check service status
    sleep 2

    if systemctl is-active --quiet "$HAPROXY_SERVICE"; then
        log_message "HAProxy ${RESTART_METHOD}ed successfully"
        log_message "Service status: active"
    else
        log_message "WARNING: HAProxy may not be running properly after ${RESTART_METHOD}"
        local status=$(systemctl status "$HAPROXY_SERVICE" 2>&1)
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
log_message "Starting HAProxy OSS Certificate Deployment Script"
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
log_message "  LOGFILE: $LOGFILE"
log_message "  HAPROXY_CONFIG_FILE: $HAPROXY_CONFIG_FILE"
log_message "  HAPROXY_BASE_DIR: $HAPROXY_BASE_DIR"
log_message "  HAPROXY_CERTS_DIR: $HAPROXY_CERTS_DIR"
log_message "  HAPROXY_BINARY: $HAPROXY_BINARY"
log_message "  HAPROXY_SERVICE: $HAPROXY_SERVICE"
log_message "  CERT_BACKUP_MODE: $CERT_BACKUP_MODE"
log_message "  BACKUP_DIR: $BACKUP_DIR"
log_message "  MATCH_STRATEGY: $MATCH_STRATEGY"
log_message "  CERT_CONFIG_LOCATION: $CERT_CONFIG_LOCATION"
log_message "  FRONTEND_NAME: ${FRONTEND_NAME:-'(all frontend/listen sections)'}"
log_message "  CRT_LIST_FILE: ${CRT_LIST_FILE:-'(not set)'}"
log_message "  TARGET_CERT_PATH: ${TARGET_CERT_PATH:-'(discover from config)'}"
log_message "  RESTART_HAPROXY: $RESTART_HAPROXY"
log_message "  RESTART_METHOD: $RESTART_METHOD"
log_message "  USE_RUNTIME_API: $USE_RUNTIME_API"
log_message "  RUNTIME_API_SOCKET: $RUNTIME_API_SOCKET"
log_message "=========================================="

# Detect HAProxy version
HAPROXY_VERSION=$(detect_haproxy_version)
if [ -n "$HAPROXY_VERSION" ]; then
    log_message "Detected HAProxy version: $HAPROXY_VERSION"

    # Check if Runtime API is supported (requires 2.1+)
    if [ "$USE_RUNTIME_API" = "yes" ]; then
        major_version=$(echo "$HAPROXY_VERSION" | cut -d. -f1)
        minor_version=$(echo "$HAPROXY_VERSION" | cut -d. -f2)
        if [ "$major_version" -lt 2 ] || ([ "$major_version" -eq 2 ] && [ "$minor_version" -lt 1 ]); then
            log_message "WARNING: Runtime API certificate updates require HAProxy 2.1+"
            log_message "Detected version $HAPROXY_VERSION may not support this feature"
        fi
    fi
fi

# Verify HAProxy installation
verify_haproxy_installation
if [ $? -ne 0 ]; then
    log_message "ERROR: HAProxy installation verification failed"
    exit 1
fi

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
# CERTIFICATE DEPLOYMENT SECTION (MULTI-ENDPOINT)
# ============================================================================

log_message "=========================================="
log_message "Determining deployment target(s)..."
log_message "=========================================="

# Compute the renewed certificate's identities once for matching
NEW_NAMES_FILE=$(mktemp) || { log_message "ERROR: mktemp failed"; exit 1; }
if ! get_cert_dns_names "$CRT_FILE_PATH" > "$NEW_NAMES_FILE"; then
    log_message "ERROR: Failed to read renewed certificate identities from: $CRT_FILE_PATH"
    rm -f "$NEW_NAMES_FILE"
    exit 1
fi
RENEWED_NAMES=$(tr '\n' ' ' < "$NEW_NAMES_FILE")
log_message "Renewed certificate covers name(s): ${RENEWED_NAMES:-'(none detected)'}"

# Build the list of target paths to deploy to
TARGETS=()

if [ -n "$TARGET_CERT_PATH" ]; then
    # Explicit single-target override: skip discovery and matching
    log_message "TARGET_CERT_PATH explicitly set; deploying to a single target."
    log_message "  Target: $TARGET_CERT_PATH"
    TARGETS+=("$TARGET_CERT_PATH")
else
    # Discover every certificate path referenced by the configuration
    log_message "Discovering certificate paths from HAProxy configuration..."
    mapfile -t CANDIDATES < <(discover_all_cert_paths)

    log_message "Discovered ${#CANDIDATES[@]} candidate certificate path(s):"
    for c in "${CANDIDATES[@]}"; do
        log_message "  - $c"
    done

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        log_message "=========================================="
        log_message "ERROR: No certificate paths found in the HAProxy configuration."
        log_message "=========================================="
        log_message "Check your configuration, e.g.:"
        log_message "  grep -E 'bind.*ssl.*crt' $HAPROXY_CONFIG_FILE"
        log_message "Or set TARGET_CERT_PATH manually for a single endpoint."
        rm -f "$NEW_NAMES_FILE"
        exit 1
    fi

    case "$MATCH_STRATEGY" in
        "cn-san")
            log_message "Matching renewed certificate to discovered endpoints by CN/SAN..."
            for c in "${CANDIDATES[@]}"; do
                if [ ! -f "$c" ]; then
                    log_message "  SKIP (no existing certificate on disk to match): $c"
                    continue
                fi
                EXISTING_NAMES=$(get_cert_dns_names "$c" | tr '\n' ' ')
                if cert_matches "$NEW_NAMES_FILE" "$c"; then
                    log_message "  MATCH: $c  [names: ${EXISTING_NAMES}]"
                    TARGETS+=("$c")
                else
                    log_message "  no match: $c  [names: ${EXISTING_NAMES}]"
                fi
            done
            ;;
        "all")
            log_message "MATCH_STRATEGY=all: deploying renewed certificate to ALL discovered paths."
            TARGETS=("${CANDIDATES[@]}")
            ;;
        *)
            log_message "ERROR: Invalid MATCH_STRATEGY: $MATCH_STRATEGY"
            rm -f "$NEW_NAMES_FILE"
            exit 1
            ;;
    esac

    if [ "${#TARGETS[@]}" -eq 0 ]; then
        log_message "=========================================="
        log_message "ERROR: No endpoint matched the renewed certificate (strategy: $MATCH_STRATEGY)."
        log_message "=========================================="
        log_message "Renewed certificate name(s): ${RENEWED_NAMES}"
        log_message "Refusing to deploy to avoid overwriting an unrelated certificate."
        log_message "If every endpoint should serve this certificate, set MATCH_STRATEGY=\"all\"."
        log_message "For a specific target, set TARGET_CERT_PATH."
        rm -f "$NEW_NAMES_FILE"
        exit 1
    fi
fi

rm -f "$NEW_NAMES_FILE"

log_message "=========================================="
log_message "Deploying renewed certificate to ${#TARGETS[@]} target(s)."
log_message "=========================================="

DEPLOY_SUCCESS=0
DEPLOY_FAILURES=0

for TGT in "${TARGETS[@]}"; do
    log_message "------------------------------------------"
    log_message "Deploying to target: $TGT"
    log_message "------------------------------------------"

    # Ensure the target directory exists
    TGT_DIR=$(dirname "$TGT")
    if [ ! -d "$TGT_DIR" ]; then
        log_message "Creating certificate directory: $TGT_DIR"
        if ! mkdir -p "$TGT_DIR"; then
            log_message "ERROR: Failed to create directory $TGT_DIR; skipping this target"
            DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
            continue
        fi
    fi

    # Handle backup or overwrite for this target
    case "$CERT_BACKUP_MODE" in
        "backup")
            if ! backup_certificate "$TGT"; then
                log_message "ERROR: Backup failed for $TGT; skipping this target for safety"
                DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
                continue
            fi
            ;;
        "overwrite")
            if [ -f "$TGT" ]; then
                log_message "WARNING: Existing certificate will be overwritten without backup: $TGT"
            fi
            ;;
        *)
            log_message "ERROR: Invalid CERT_BACKUP_MODE: $CERT_BACKUP_MODE"
            exit 1
            ;;
    esac

    # Write the combined PEM for this target
    if ! create_combined_pem "$CRT_FILE_PATH" "$KEY_FILE_PATH" "$TGT"; then
        log_message "ERROR: Failed to write combined PEM to $TGT"
        DEPLOY_FAILURES=$((DEPLOY_FAILURES + 1))
        continue
    fi

    log_message "Certificate deployed successfully to: $TGT"
    DEPLOY_SUCCESS=$((DEPLOY_SUCCESS + 1))

    # Optional per-target hot update via Runtime API
    if [ "$USE_RUNTIME_API" = "yes" ]; then
        if update_cert_via_runtime_api "$TGT" "$TGT"; then
            log_message "Certificate hot-updated via Runtime API: $TGT"
        else
            log_message "WARNING: Runtime API update failed for $TGT (file on disk is updated)"
        fi
    fi
done

log_message "=========================================="
log_message "Deployment results: ${DEPLOY_SUCCESS} succeeded, ${DEPLOY_FAILURES} failed."
log_message "=========================================="

if [ "$DEPLOY_SUCCESS" -eq 0 ]; then
    log_message "ERROR: No targets were deployed successfully. Skipping service restart."
    exit 1
fi

# Restart/reload HAProxy ONCE after all targets are deployed
if [ "$RESTART_HAPROXY" = "yes" ]; then
    log_message "=========================================="
    log_message "Reloading/restarting HAProxy (once for all targets)..."
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
    log_message "IMPORTANT: New certificate(s) have been deployed to ${DEPLOY_SUCCESS} target(s)."
    log_message "To apply the new certificate(s), you must either:"
    log_message "  1. Reload HAProxy: systemctl reload ${HAPROXY_SERVICE}"
    log_message "  2. Restart HAProxy: systemctl restart ${HAPROXY_SERVICE}"
    log_message "  3. Use Runtime API to update certificate(s) in memory"
    log_message "=========================================="
fi

# Final summary
log_message "=========================================="
log_message "DEPLOYMENT SUMMARY:"
log_message "=========================================="
log_message "  HAProxy version: ${HAPROXY_VERSION:-'unknown'}"
log_message "  Source certificate: $CRT_FILE_PATH"
log_message "  Source private key: $KEY_FILE_PATH"
log_message "  Renewed certificate name(s): ${RENEWED_NAMES}"
log_message "  Match strategy: $MATCH_STRATEGY"
log_message "  Backup mode: $CERT_BACKUP_MODE"
log_message "  Certificate location mode: $CERT_CONFIG_LOCATION"
if [ "$CERT_CONFIG_LOCATION" = "frontend" ]; then
    log_message "  Frontend scope: ${FRONTEND_NAME:-'(all frontend/listen sections)'}"
fi
log_message "  Targets deployed: $DEPLOY_SUCCESS"
log_message "  Targets failed: $DEPLOY_FAILURES"
for TGT in "${TARGETS[@]}"; do
    log_message "    -> $TGT"
done
log_message "  Runtime API update: $USE_RUNTIME_API"
log_message "  Service restart: $RESTART_HAPROXY"
if [ "$RESTART_HAPROXY" = "yes" ]; then
    log_message "  Restart method: $RESTART_METHOD"
fi
log_message "=========================================="
log_message "Script execution completed successfully"
log_message "=========================================="

exit 0