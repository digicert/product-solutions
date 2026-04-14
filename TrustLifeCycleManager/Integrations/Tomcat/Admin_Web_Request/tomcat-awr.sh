#!/bin/bash
#===============================================================================
# Legal Notice (version January 1, 2026)
#===============================================================================
# Copyright © 2026 DigiCert. All rights reserved.
# DigiCert and its logo are registered trademarks of DigiCert, Inc.
# Other names may be trademarks of their respective owners.
#
# For the purposes of this Legal Notice, "DigiCert" refers to:
# - DigiCert, Inc., if you are located in the United States;
# - DigiCert Ireland Limited, if you are located outside of the United States or Japan;
# - DigiCert Japan G.K., if you are located in Japan.
#
# The software described in this notice is provided by DigiCert and distributed under licenses
# restricting its use, copying, distribution, and decompilation or reverse engineering.
# No part of the software may be reproduced in any form by any means without prior written authorization
# of DigiCert and its licensors, if any.
#
# Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
# any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
# your agreement and, in the event of conflict, these terms control.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
# INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
# ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
#
# Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
# are subject to the import and export laws of the United States, specifically the U.S. Export Administration
# Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
#
# US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
# disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
# Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
# subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
# as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
# The contractor/manufacturer is DIGICERT, INC.
#===============================================================================

#===============================================================================
# DEPLOYMENT NOTES
#===============================================================================
#
# This is a DigiCert Trust Lifecycle Manager (TLM) AWR (Admin Web Request)
# post-enrollment script for Apache Tomcat on Linux. It runs automatically
# after TLM issues or renews a certificate.
#
# HARD-CODED VALUE (must be set before deployment):
#   LEGAL_NOTICE_ACCEPT  - Set to "true" below to accept the legal notice
#                          and allow the script to execute.
#
# AUTOMATICALLY PROVIDED BY TLM (no manual entry needed):
#   The DC1_POST_SCRIPT_DATA environment variable is populated by the TLM
#   agent at runtime. It contains a Base64-encoded JSON payload with:
#     - certfolder          : Directory where TLM places the certificate files
#     - files[0]            : The JKS filename delivered by TLM
#     - password            : Certificate password
#     - keystorepassword    : JKS keystore password
#     - truststorepassword  : Truststore password
#   The key alias is derived automatically from the JKS filename (without
#   the .jks extension).
#
# ENVIRONMENT / SYSTEM REQUIREMENTS:
#   - CATALINA_HOME env var : If set, used as the Tomcat home directory.
#                             If not set, the script searches common Linux
#                             paths (see possible_paths array below).
#                             Add your custom path to the array if needed.
#   - Tomcat service name   : The script tries systemd services "tomcat",
#                             "tomcat10", "tomcat9". If yours differs,
#                             update the service_names array.
#                             Falls back to catalina.sh if no systemd
#                             service is found.
#   - Dependencies          : jq (JSON parsing), perl (XML replacement),
#                             base64 (decoding). All standard on most
#                             Linux distributions.
#
#===============================================================================

# Legal notice acceptance variable (user must set to "true" to accept and allow script execution)
LEGAL_NOTICE_ACCEPT="false"  # <<< CHANGE TO "true" TO ACCEPT THE LEGAL NOTICE AND RUN THE SCRIPT

# Configuration
LOG_FILE="/opt/digicert/TomcatCertificateImport.log"

# ──────────────────────────────────────────────────────────────────────────────
# Function: write_log
# ──────────────────────────────────────────────────────────────────────────────
write_log() {
    local message="$1"
    local log_message="$(date '+%Y-%m-%d %H:%M:%S'): $message"
    echo "$log_message" >> "$LOG_FILE"
    echo "$message"
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: mask_credential
# Masks sensitive values for safe logging. Shows only the first and last 2
# characters (e.g. "my****rd"). Passwords are NEVER logged in plaintext.
# ──────────────────────────────────────────────────────────────────────────────
mask_credential() {
    local value="$1"
    local len=${#value}
    if [ "$len" -le 4 ]; then
        echo "****"
    else
        echo "${value:0:2}$(printf '*%.0s' $(seq 1 $((len - 4))))${value: -2}"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Function: update_tomcat_server_xml
# Updates the <Certificate .../> element in Tomcat's conf/server.xml with the
# new keystore path, password, and alias provided by TLM. Creates a timestamped
# backup before making any changes and restores it on failure.
# Uses perl for reliable multi-line XML element replacement.
# ──────────────────────────────────────────────────────────────────────────────
update_tomcat_server_xml() {
    local server_xml_path="$1"
    local keystore_file="$2"
    local keystore_password="$3"
    local key_alias="$4"

    write_log "Starting Tomcat server.xml update"
    write_log "Server.xml path: $server_xml_path"
    write_log "Keystore file: $keystore_file"
    write_log "Key alias: $key_alias"

    # Check if server.xml exists
    if [ ! -f "$server_xml_path" ]; then
        write_log "ERROR: Server.xml file not found at: $server_xml_path"
        return 1
    fi

    # Create backup of server.xml
    local backup_path="${server_xml_path}.backup_$(date '+%Y%m%d_%H%M%S')"
    cp "$server_xml_path" "$backup_path"
    if [ $? -ne 0 ]; then
        write_log "ERROR: Failed to create backup of server.xml"
        return 1
    fi
    write_log "Created backup: $backup_path"

    # Read current server.xml content
    local xml_content
    xml_content=$(cat "$server_xml_path")

    # Build the replacement Certificate element
    local new_certificate="<Certificate certificateKeystoreFile=\"${keystore_file}\" certificateKeystorePassword=\"${keystore_password}\" certificateKeyAlias=\"${key_alias}\" type=\"RSA\" />"

    # Escape special characters in the replacement string for sed
    local escaped_keystore_file
    escaped_keystore_file=$(printf '%s\n' "$keystore_file" | sed 's/[&/\]/\\&/g')
    local escaped_keystore_password
    escaped_keystore_password=$(printf '%s\n' "$keystore_password" | sed 's/[&/\]/\\&/g')
    local escaped_new_certificate="<Certificate certificateKeystoreFile=\"${escaped_keystore_file}\" certificateKeystorePassword=\"${escaped_keystore_password}\" certificateKeyAlias=\"${key_alias}\" type=\"RSA\" \/>"

    # Try to match and replace the Certificate element
    if grep -qP '<Certificate\s+certificateKeystoreFile=' "$server_xml_path"; then
        # Use perl for reliable multi-attribute XML element replacement
        perl -i -0pe "s|<Certificate\s[^>]*/>|${new_certificate}|gs" "$server_xml_path"
        if [ $? -eq 0 ]; then
            write_log "Successfully updated Certificate element in server.xml"
        else
            write_log "ERROR: perl replacement failed"
            # Restore backup
            cp "$backup_path" "$server_xml_path"
            return 1
        fi
    else
        write_log "ERROR: Could not find Certificate element in server.xml"
        # Restore backup
        cp "$backup_path" "$server_xml_path"
        return 1
    fi

    write_log "Successfully wrote updated server.xml"
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# Main script execution
# ══════════════════════════════════════════════════════════════════════════════

write_log "Script execution started"

# Check legal notice acceptance
if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
    write_log "ERROR: Script execution halted - Legal notice not accepted"
    write_log "User must set LEGAL_NOTICE_ACCEPT=\"true\" to proceed"
    write_log "Script terminated due to legal notice non-acceptance"
    exit 1
fi

write_log "Legal notice accepted - proceeding with script execution"

# Retrieve base64 encoded JSON input from DC1_POST_SCRIPT_DATA
# This environment variable is automatically populated by the TLM agent at
# runtime — no manual entry is needed. It contains the certificate data,
# passwords, and file paths as a Base64-encoded JSON payload.
base64_json="${DC1_POST_SCRIPT_DATA}"
if [ -z "$base64_json" ]; then
    write_log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set or empty"
    exit 1
fi
write_log "Retrieved environment variable DC1_POST_SCRIPT_DATA"

# Decode the base64 encoded JSON
json_string=$(echo "$base64_json" | base64 -d 2>/dev/null)
if [ $? -ne 0 ]; then
    write_log "ERROR: Failed to decode base64 string"
    exit 1
fi
write_log "Decoded base64 string successfully"

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    write_log "ERROR: jq is required but not installed. Install with: sudo apt-get install jq / sudo yum install jq"
    exit 1
fi

# Parse JSON values extracted from the TLM-provided payload:
#   certfolder         - Directory where TLM placed the certificate files
#   files[0]           - The JKS filename (first file in the delivery)
#   password           - Certificate / private key password
#   keystorepassword   - Password for the JKS keystore (used in server.xml)
#   truststorepassword - Truststore password (available if needed)
write_log "Parsing JSON data"
args=$(echo "$json_string" | jq -r '.args // empty')
cert_folder=$(echo "$json_string" | jq -r '.certfolder // empty')
jks_filename=$(echo "$json_string" | jq -r '.files[0] // empty')
password=$(echo "$json_string" | jq -r '.password // empty')
keystore_password=$(echo "$json_string" | jq -r '.keystorepassword // empty')
truststore_password=$(echo "$json_string" | jq -r '.truststorepassword // empty')

write_log "Arguments: $args"

# Build JKS file path
jks_file="${cert_folder}/${jks_filename}"

write_log "Certificate folder: $cert_folder"
write_log "JKS file path: $jks_file"

# Log masked passwords
write_log "Password: $(mask_credential "$password")"
write_log "Keystore Password: $(mask_credential "$keystore_password")"
write_log "Truststore Password: $(mask_credential "$truststore_password")"

# Validate inputs
if [ ! -f "$jks_file" ]; then
    write_log "ERROR: The JKS file does not exist at path: $jks_file"
    exit 1
fi

# Extract the key alias from the JKS filename (filename without extension).
# For example, if TLM delivers "mydomain.com.jks", the key alias becomes
# "mydomain.com". This alias is written into server.xml as the
# certificateKeyAlias attribute.
jks_file_basename=$(basename "$jks_file")
key_alias="${jks_file_basename%.*}"
write_log "Extracted key alias: $key_alias"

# Determine Tomcat home directory.
# First checks the CATALINA_HOME environment variable. If not set, it
# searches the common Linux installation paths listed below.
# >>> If your Tomcat is installed elsewhere, either set CATALINA_HOME or
#     add your path to the possible_paths array. <<<
tomcat_home="${CATALINA_HOME:-}"

if [ -z "$tomcat_home" ]; then
    # Default Tomcat installation paths on Linux
    possible_paths=(
        "/opt/tomcat"
        "/opt/tomcat10"
        "/opt/tomcat9"
        "/usr/share/tomcat"
        "/usr/share/tomcat10"
        "/usr/share/tomcat9"
        "/var/lib/tomcat"
        "/var/lib/tomcat10"
        "/var/lib/tomcat9"
        "/etc/tomcat"
        "/etc/tomcat10"
        "/etc/tomcat9"
    )

    for path in "${possible_paths[@]}"; do
        if [ -d "$path" ]; then
            tomcat_home="$path"
            write_log "Auto-detected Tomcat home: $tomcat_home"
            break
        fi
    done
fi

if [ -z "$tomcat_home" ]; then
    write_log "ERROR: Could not determine Tomcat installation directory. Please set CATALINA_HOME environment variable."
    exit 1
fi

server_xml_path="${tomcat_home}/conf/server.xml"
write_log "Tomcat home: $tomcat_home"
write_log "Server.xml path: $server_xml_path"

# Update Tomcat server.xml
update_tomcat_server_xml "$server_xml_path" "$jks_file" "$keystore_password" "$key_alias"
update_result=$?

if [ $update_result -ne 0 ]; then
    write_log "ERROR: Failed to update Tomcat server.xml"
    exit 1
fi

write_log "Successfully updated Tomcat server.xml"

# ──────────────────────────────────────────────────────────────────────────────
# Restart Tomcat service.
# The script checks for systemd services in this order. If your Tomcat
# service has a different name (e.g. "apache-tomcat"), add it here.
# If no systemd service is found, falls back to catalina.sh shutdown/startup.
# ──────────────────────────────────────────────────────────────────────────────
service_names=("tomcat" "tomcat10" "tomcat9")  # <<< ADD YOUR SERVICE NAME IF DIFFERENT
service_restarted=false

write_log "Attempting to restart Tomcat service..."

for service_name in "${service_names[@]}"; do
    write_log "Checking for service: $service_name"

    # Check if systemd service exists
    if systemctl list-unit-files "${service_name}.service" &>/dev/null; then
        service_status=$(systemctl is-active "$service_name" 2>/dev/null)
        write_log "Found Tomcat service: $service_name (Status: $service_status)"

        # Restart the service
        write_log "Restarting Tomcat service: $service_name"
        systemctl restart "$service_name" 2>/dev/null

        if [ $? -eq 0 ]; then
            # Wait and verify the service is running
            timeout=30
            elapsed=0
            while [ $elapsed -lt $timeout ]; do
                sleep 1
                elapsed=$((elapsed + 1))
                service_status=$(systemctl is-active "$service_name" 2>/dev/null)
                if [ "$service_status" = "active" ]; then
                    break
                fi
                write_log "Waiting for service to start... (Status: $service_status)"
            done

            service_status=$(systemctl is-active "$service_name" 2>/dev/null)
            if [ "$service_status" = "active" ]; then
                write_log "Tomcat service $service_name restarted successfully"
                service_restarted=true
                break
            else
                write_log "WARNING: Service $service_name did not start within $timeout seconds"
            fi
        else
            write_log "ERROR: Could not restart service $service_name"
        fi
    else
        write_log "Service $service_name not found on this system"
    fi
done

# Fallback: try catalina.sh if no systemd service was found.
# This covers manual/tarball installs that don't register a systemd unit.
if [ "$service_restarted" = false ] && [ -f "${tomcat_home}/bin/catalina.sh" ]; then
    write_log "No systemd service found. Attempting restart via catalina.sh..."
    "${tomcat_home}/bin/shutdown.sh" 2>/dev/null
    sleep 5
    "${tomcat_home}/bin/startup.sh" 2>/dev/null
    if [ $? -eq 0 ]; then
        write_log "Tomcat restarted via catalina.sh"
        service_restarted=true
    else
        write_log "ERROR: Failed to restart Tomcat via catalina.sh"
    fi
fi

if [ "$service_restarted" = false ]; then
    write_log "WARNING: No Tomcat service could be restarted. Please restart Tomcat manually for changes to take effect."
    write_log "Checked for services: ${service_names[*]}"
fi

write_log "Script execution completed successfully"
write_log "Script execution finished"
exit 0