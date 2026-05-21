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
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

######################################################################################################################
# Usage:
#
#   This script is intended to be executed by DigiCert Trust Lifecycle Manager
#   as an Admin Web Request (AWR) post-script.
#
#   It is not normally run manually unless you are testing with a simulated
#   DC1_POST_SCRIPT_DATA environment variable.
#
#  Minimum supported Tomcat version:
#     Apache Tomcat 8.5.x
#
#  AWR arguments:
#   ARGUMENT_1:
#     Path to the Tomcat base directory.
#
#     Example:
#       /opt/tomcat
#
#     The script will automatically look for:
#       /opt/tomcat/conf/server.xml
#
#   ARGUMENT_2:
#     Command used to restart or reload Tomcat after certificate deployment.
#
#     Examples:
#       systemctl restart tomcat.service
#       systemctl restart tomcat
#       service tomcat restart
#
# AWR-delivered files:
#   The AWR process must provide:
#     - one .key file
#     - one .crt file
#
#   The .crt file is expected to be a PEM bundle containing:
#     - the leaf/end-entity certificate first
#     - followed by intermediate/root chain certificates, if applicable
#
# Tomcat server.xml requirements:
#   The script expects exactly one active SSL Connector using PEM file-based
#   certificate configuration.
#
#   Supported example:
#
#     <Connector
#         protocol="org.apache.coyote.http11.Http11NioProtocol"
#         port="8443"
#         SSLEnabled="true">
#       <SSLHostConfig>
#         <Certificate
#             certificateKeyFile="conf/ssl/server.key"
#             certificateFile="conf/ssl/server.crt"
#             certificateChainFile="conf/ssl/chain.pem"
#             type="RSA" />
#       </SSLHostConfig>
#     </Connector>
#
#   Also supported when no separate chain file is configured:
#
#     <Certificate
#         certificateKeyFile="conf/ssl/server.key"
#         certificateFile="conf/ssl/server.crt"
#         type="RSA" />
#
# Deployment behavior:
#   If certificateChainFile is configured in server.xml:
#     - The delivered .key file is copied to certificateKeyFile
#     - The first certificate in the delivered .crt file is copied to certificateFile
#     - The remaining certificates are copied to certificateChainFile
#
#   If certificateChainFile is not configured in server.xml:
#     - The delivered .key file is copied to certificateKeyFile
#     - The full delivered .crt bundle is copied to certificateFile
#
# Backup behavior:
#   Existing target files are backed up before replacement.
#
#   Backup files are created beside the original files using this format:
#     original-file-YYYYMMDD_HHMMSS.bak
#
# Permissions and ownership:
#   If a target file already exists:
#     - existing ownership is preserved
#     - existing permissions are preserved
#
#   If a target file does not already exist:
#     - key file default mode is 600
#     - certificate file default mode is 644
#     - chain file default mode is 644
#
# Unsupported configurations:
#   The script fails gracefully without making changes if server.xml uses
#   unsupported keystore-based TLS configuration, including:
#     - certificateKeystoreFile
#     - certificateKeystoreType
#     - keystoreFile
#     - keystoreType
#     - JKS
#     - PKCS12
#     - PFX
#     - .jks
#     - .p12
#     - .pfx
#     - .pkcs12
#
#   This script supports PEM-based Tomcat certificate configuration only.
#
# Failure conditions:
#   The script will fail if:
#     - LEGAL_NOTICE_ACCEPT is not set to "true"
#     - DC1_POST_SCRIPT_DATA is missing or cannot be decoded
#     - ARGUMENT_1 is missing
#     - ARGUMENT_2 is missing
#     - server.xml cannot be found or read
#     - no active PEM SSL Connector is found
#     - more than one active PEM SSL Connector is found
#     - unsupported JKS/PFX/PKCS12 configuration is found
#     - delivered .key or .crt files are missing
#     - certificateChainFile is configured but the delivered .crt contains
#       only one certificate
#     - backup, copy, checksum verification, permission restoration, or restart
#       command execution fails
#
# Log file:
#   Default log location:
#     /var/log/digicert-awr-tomcat-serverxml-script.log
#
#   If /var/log is not writable, the script falls back to:
#     /tmp/digicert-awr-tomcat-serverxml-script.log
#
# Before deployment:
#   Edit the script and set:
#
#     LEGAL_NOTICE_ACCEPT="true"
#
# Example AWR configuration:
#   ARGUMENT_1:
#     /opt/tomcat
#
#   ARGUMENT_2:
#     systemctl restart tomcat.service
#
######################################################################################################################

# Configuration
LEGAL_NOTICE_ACCEPT="false"

LOGFILE="/var/log/digicert-awr-tomcat-serverxml-script.log"

DEFAULT_CRT_MODE="644"
DEFAULT_KEY_MODE="600"
DEFAULT_CHAIN_MODE="644"

###############################################################################
# Logging and failure handling
###############################################################################

init_logging() {
    mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true
    touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/digicert-awr-tomcat-serverxml-script.log"
    touch "$LOGFILE" 2>/dev/null || exit 1

    exec >> "$LOGFILE" 2>&1
}

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

fail() {
    log_message "ERROR: $1"
    exit "${2:-2}"
}

###############################################################################
# Basic helpers
###############################################################################

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1" 127
}

get_abs_path() {
    local base_dir="$1"
    local file_path="$2"

    if [ -z "$file_path" ]; then
        echo ""
        return 0
    fi

    case "$file_path" in
        /*)
            echo "$file_path"
            ;;
        *)
            echo "${base_dir}/${file_path}"
            ;;
    esac
}

describe_exit_code() {
    case "$1" in
        0) echo "success" ;;
        1) echo "general error" ;;
        2) echo "script-defined failure" ;;
        10) echo "no PEM certificate-file-based SSL connector found" ;;
        11) echo "multiple PEM certificate-file-based SSL connectors found" ;;
        12) echo "unsupported JKS, PFX, or PKCS12 keystore-based SSL connector found" ;;
        126) echo "command found but not executable or permission denied" ;;
        127) echo "command not found" ;;
        130) echo "terminated by SIGINT" ;;
        137) echo "killed by SIGKILL" ;;
        143) echo "terminated by SIGTERM" ;;
        *) echo "application-specific failure" ;;
    esac
}

###############################################################################
# Metadata, backup, copy, and verification helpers
###############################################################################

capture_metadata() {
    local filepath="$1"
    local prefix="$2"

    if [ -f "$filepath" ]; then
        local mode
        local owner
        local group

        mode=$(stat -c '%a' "$filepath") || return 1
        owner=$(stat -c '%U' "$filepath") || return 1
        group=$(stat -c '%G' "$filepath") || return 1

        printf -v "${prefix}_EXISTED" '%s' "true"
        printf -v "${prefix}_MODE" '%s' "$mode"
        printf -v "${prefix}_OWNER" '%s' "$owner"
        printf -v "${prefix}_GROUP" '%s' "$group"

        log_message "Captured metadata for [$filepath]: mode=$mode, owner=$owner, group=$group"
    else
        printf -v "${prefix}_EXISTED" '%s' "false"
        log_message "No existing file at [$filepath]; default permissions will be applied after deployment"
    fi
}

apply_metadata() {
    local filepath="$1"
    local prefix="$2"
    local default_mode="$3"

    local existed_var="${prefix}_EXISTED"
    local mode_var="${prefix}_MODE"
    local owner_var="${prefix}_OWNER"
    local group_var="${prefix}_GROUP"

    local existed="${!existed_var}"

    if [ ! -f "$filepath" ]; then
        log_message "ERROR: Cannot apply metadata because file does not exist: $filepath"
        return 1
    fi

    if [ "$existed" = "true" ]; then
        local mode="${!mode_var}"
        local owner="${!owner_var}"
        local group="${!group_var}"

        chmod "$mode" "$filepath" || return 1
        chown "$owner:$group" "$filepath" || return 1

        log_message "Restored metadata on [$filepath]: mode=$mode, owner=$owner:$group"
    else
        chmod "$default_mode" "$filepath" || return 1
        log_message "Applied default mode [$default_mode] to new file [$filepath]"
    fi

    log_message "Verified metadata for [$filepath]: mode=$(stat -c '%a' "$filepath"), owner=$(stat -c '%U:%G' "$filepath")"
}

verify_same_hash() {
    local src="$1"
    local dest="$2"
    local label="$3"

    local src_hash
    local dest_hash

    src_hash=$(sha256sum "$src" | awk '{print $1}') || return 1
    dest_hash=$(sha256sum "$dest" | awk '{print $1}') || return 1

    log_message "Checksum source [$src] = [$src_hash]"
    log_message "Checksum target  [$dest] = [$dest_hash]"

    if [ "$src_hash" != "$dest_hash" ]; then
        log_message "ERROR: Checksum mismatch during $label"
        return 1
    fi

    return 0
}

backup_file_if_exists() {
    local filepath="$1"
    local label="$2"
    local backup_file

    if [ -f "$filepath" ]; then
        backup_file="${filepath}-$(date '+%Y%m%d_%H%M%S').bak"

        log_message "Existing $label file found: $filepath"
        log_message "Creating backup: $backup_file"

        cp -pf "$filepath" "$backup_file" || fail "Failed to backup $filepath"

        verify_same_hash "$filepath" "$backup_file" "backup verification for $label" \
            || fail "Backup verification failed for $filepath"

        log_message "Backup verified successfully for $label file"
    else
        log_message "No existing $label file found at: $filepath"
    fi
}

copy_and_verify() {
    local src="$1"
    local dest="$2"
    local label="$3"
    local dest_dir

    dest_dir=$(dirname "$dest")

    [ -d "$dest_dir" ] || fail "Destination directory does not exist for $label: $dest_dir"

    cp -f "$src" "$dest" || fail "Failed to copy $label from [$src] to [$dest]"

    log_message "Copied $label from [$src] to [$dest]"

    verify_same_hash "$src" "$dest" "copy verification for $label" \
        || fail "Copy verification failed for $label"

    log_message "Copy verified successfully for $label"
}

###############################################################################
# AWR JSON helpers
###############################################################################

extract_json_value() {
    local key="$1"

    printf '%s\n' "$JSON_STRING" \
        | tr -d '\n' \
        | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        | head -n 1
}

extract_arg_number() {
    local arg_num="$1"
    local args_payload

    args_payload=$(
        printf '%s\n' "$JSON_STRING" \
            | tr -d '\n' \
            | sed -n 's/.*"args"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p'
    )

    printf '%s\n' "$args_payload" | awk -v n="$arg_num" '
        BEGIN { FS="," }
        {
            value=$n
            gsub(/^[[:space:]]*"/, "", value)
            gsub(/"[[:space:]]*$/, "", value)
            gsub(/^[[:space:]]*/, "", value)
            gsub(/[[:space:]]*$/, "", value)
            print value
        }
    '
}

extract_file_by_extension() {
    local extension="$1"
    local files_payload

    files_payload=$(
        printf '%s\n' "$JSON_STRING" \
            | tr -d '\n' \
            | sed -n 's/.*"files"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p'
    )

    printf '%s\n' "$files_payload" \
        | tr ',' '\n' \
        | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//' \
        | grep "\.${extension}$" \
        | head -n 1
}

###############################################################################
# Certificate bundle helpers
###############################################################################

count_pem_certs() {
    grep -c -- "-----BEGIN CERTIFICATE-----" "$1"
}

detect_key_type() {
    local keyfile="$1"

    if grep -q "BEGIN RSA PRIVATE KEY" "$keyfile"; then
        echo "RSA"
    elif grep -q "BEGIN EC PRIVATE KEY" "$keyfile"; then
        echo "ECC"
    elif grep -q "BEGIN PRIVATE KEY" "$keyfile"; then
        echo "PKCS#8 format (generic)"
    else
        echo "Unknown"
    fi
}

split_leaf_and_chain() {
    local bundle="$1"
    local leaf_out="$2"
    local chain_out="$3"

    awk -v leaf="$leaf_out" -v chain="$chain_out" '
        /-----BEGIN CERTIFICATE-----/ {
            cert_count++
        }

        cert_count == 1 {
            print > leaf
            next
        }

        cert_count > 1 {
            print > chain
            next
        }
    ' "$bundle"
}

###############################################################################
# Tomcat server.xml discovery
###############################################################################

extract_tomcat_ssl_cert_paths() {
    local tomcat_path="$1"
    local discovery_output_file="$2"
    local discovery_log_file="$3"
    local server_xml_file_path="${tomcat_path}/conf/server.xml"

    [ -d "$tomcat_path" ] || fail "Tomcat path does not exist or is not a directory: $tomcat_path"
    [ -f "$server_xml_file_path" ] || fail "server.xml not found at: $server_xml_file_path"
    [ -r "$server_xml_file_path" ] || fail "server.xml exists but is not readable: $server_xml_file_path"

    log_message "Scanning server.xml: $server_xml_file_path"

    awk '
    function dlog(msg) {
        print msg
    }

    function extract_attr(block, attr_name,    pattern, work, value) {
        work = block

        pattern = attr_name "[[:space:]]*=[[:space:]]*\"[^\"]+\""
        if (match(work, pattern)) {
            value = substr(work, RSTART, RLENGTH)
            sub(/^[^=]+=[[:space:]]*\"/, "", value)
            sub(/\"$/, "", value)
            return value
        }

        pattern = attr_name "[[:space:]]*=[[:space:]]*'\''[^'\'']+'\''"
        if (match(work, pattern)) {
            value = substr(work, RSTART, RLENGTH)
            sub(/^[^=]+=[[:space:]]*'\''/, "", value)
            sub(/'\''$/, "", value)
            return value
        }

        return ""
    }

    function reset_connector_state() {
        in_ssl_connector = 0
        in_sslhostconfig = 0
        in_certificate = 0
        cert_block = ""
    }

    function is_keystore_type(value) {
        value = tolower(value)
        return value == "jks" || value == "pkcs12" || value == "p12" || value == "pfx"
    }

    function is_keystore_file(value) {
        value = tolower(value)
        return value ~ /\.jks$/ || value ~ /\.p12$/ || value ~ /\.pfx$/ || value ~ /\.pkcs12$/
    }

    BEGIN {
        in_comment = 0
        in_connector = 0
        in_ssl_connector = 0
        in_sslhostconfig = 0
        in_certificate = 0

        connector_block = ""
        cert_block = ""

        connector_count = 0
        ssl_connector_count = 0
        cert_config_count = 0
        unsupported_keystore_count = 0
    }

    {
        original_line = $0
        line = $0

        while (line ~ /<!--.*-->/) {
            sub(/<!--.*-->/, "", line)
        }

        if (line ~ /<!--/) {
            in_comment = 1
            sub(/<!--.*/, "", line)
        }

        if (in_comment) {
            if (original_line ~ /-->/) {
                in_comment = 0
                line = original_line
                sub(/.*-->/, "", line)
            } else {
                next
            }
        }

        if (line ~ /<Connector([[:space:]>]|$)/) {
            in_connector = 1
            connector_block = line
            connector_count++
        } else if (in_connector) {
            connector_block = connector_block " " line
        }

        if (in_connector && connector_block ~ />/) {
            connector_port = extract_attr(connector_block, "port")
            connector_protocol = extract_attr(connector_block, "protocol")
            connector_ssl_enabled = extract_attr(connector_block, "SSLEnabled")
            connector_scheme = extract_attr(connector_block, "scheme")
            connector_secure = extract_attr(connector_block, "secure")

            dlog("CONNECTOR_FOUND|" connector_count "|" connector_port "|" connector_protocol "|" connector_ssl_enabled "|" connector_scheme "|" connector_secure)

            if (tolower(connector_ssl_enabled) == "true" ||
                tolower(connector_scheme) == "https" ||
                tolower(connector_secure) == "true") {

                in_ssl_connector = 1
                ssl_connector_count++
                active_port = connector_port
                active_protocol = connector_protocol

                dlog("SSL_CONNECTOR_FOUND|" ssl_connector_count "|" active_port "|" active_protocol)
            } else {
                reset_connector_state()
            }

            in_connector = 0
            connector_block = ""
        }

        if (line ~ /<SSLHostConfig([[:space:]>]|$)/ && in_ssl_connector) {
            in_sslhostconfig = 1
            dlog("SSLHOSTCONFIG_FOUND|" NR)
        }

        if (line ~ /<Certificate([[:space:]>]|$)/ &&
            in_ssl_connector &&
            in_sslhostconfig) {

            in_certificate = 1
            cert_block = line
        } else if (in_certificate) {
            cert_block = cert_block " " line
        }

        if (in_certificate && cert_block ~ />/) {
            key_file = extract_attr(cert_block, "certificateKeyFile")
            cert_file = extract_attr(cert_block, "certificateFile")
            chain_file = extract_attr(cert_block, "certificateChainFile")

            keystore_file = extract_attr(cert_block, "certificateKeystoreFile")
            keystore_type = extract_attr(cert_block, "certificateKeystoreType")

            legacy_keystore_file = extract_attr(cert_block, "keystoreFile")
            legacy_keystore_type = extract_attr(cert_block, "keystoreType")

            cert_type = extract_attr(cert_block, "type")

            if (keystore_file != "" ||
                legacy_keystore_file != "" ||
                is_keystore_type(keystore_type) ||
                is_keystore_type(legacy_keystore_type) ||
                is_keystore_file(keystore_file) ||
                is_keystore_file(legacy_keystore_file)) {

                unsupported_keystore_count++

                found_unsupported_port = active_port
                found_unsupported_type = cert_type
                found_unsupported_keystore_file = keystore_file
                found_unsupported_keystore_type = keystore_type
                found_unsupported_legacy_keystore_file = legacy_keystore_file
                found_unsupported_legacy_keystore_type = legacy_keystore_type

                dlog("UNSUPPORTED_KEYSTORE_CONFIG_FOUND|" unsupported_keystore_count "|" active_port "|" cert_type "|" keystore_file "|" keystore_type "|" legacy_keystore_file "|" legacy_keystore_type)
            }

            if (key_file != "" || cert_file != "" || chain_file != "") {
                cert_config_count++

                found_port = active_port
                found_protocol = active_protocol
                found_type = cert_type
                found_key_file = key_file
                found_cert_file = cert_file
                found_chain_file = chain_file

                dlog("CERTIFICATE_CONFIG_FOUND|" cert_config_count "|" found_port "|" found_type "|" found_key_file "|" found_cert_file "|" found_chain_file)
            }

            in_certificate = 0
            cert_block = ""
        }

        if (line ~ /<\/SSLHostConfig>/) {
            in_sslhostconfig = 0
        }

        if (line ~ /<\/Connector>/) {
            reset_connector_state()
        }
    }

    END {
        print "CONNECTOR_COUNT=" connector_count > result_file
        print "SSL_CONNECTOR_COUNT=" ssl_connector_count > result_file
        print "CERT_CONFIG_COUNT=" cert_config_count > result_file
        print "UNSUPPORTED_KEYSTORE_COUNT=" unsupported_keystore_count > result_file

        print "TOMCAT_SSL_CONNECTOR_PORT=" found_port > result_file
        print "CERTIFICATE_TYPE=" found_type > result_file
        print "certificateKeyFile=" found_key_file > result_file
        print "certificateFile=" found_cert_file > result_file
        print "certificateChainFile=" found_chain_file > result_file

        print "UNSUPPORTED_SSL_CONNECTOR_PORT=" found_unsupported_port > result_file
        print "UNSUPPORTED_CERTIFICATE_TYPE=" found_unsupported_type > result_file
        print "UNSUPPORTED_CERTIFICATE_KEYSTORE_FILE=" found_unsupported_keystore_file > result_file
        print "UNSUPPORTED_CERTIFICATE_KEYSTORE_TYPE=" found_unsupported_keystore_type > result_file
        print "UNSUPPORTED_LEGACY_KEYSTORE_FILE=" found_unsupported_legacy_keystore_file > result_file
        print "UNSUPPORTED_LEGACY_KEYSTORE_TYPE=" found_unsupported_legacy_keystore_type > result_file

        if (unsupported_keystore_count > 0) {
            exit 12
        }

        if (cert_config_count == 0) {
            exit 10
        }

        if (cert_config_count > 1) {
            exit 11
        }
    }
    ' result_file="$discovery_output_file" "$server_xml_file_path" > "$discovery_log_file" 2>&1
}

###############################################################################
# Restart command helper
###############################################################################

run_post_update_command() {
    local cmd="$1"
    local command_name
    local command_output_file
    local command_status
    local exit_description

    if [ -z "$cmd" ]; then
        log_message "No post-update command provided; skipping restart"
        return 0
    fi

    log_message "Running post-update command: $cmd"

    command_name=$(printf '%s' "$cmd" | awk '{print $1}')

    command -v "$command_name" >/dev/null 2>&1 \
        || fail "Command not found: $command_name" 127

    command_output_file=$(mktemp /tmp/tomcat-awr-command-output.XXXXXX) \
        || fail "Unable to create temporary command output file"

    bash -c "$cmd" > "$command_output_file" 2>&1
    command_status=$?

    if [ -s "$command_output_file" ]; then
        log_message "Post-update command output:"
        while IFS= read -r line; do
            log_message "$line"
        done < "$command_output_file"
    fi

    rm -f "$command_output_file"

    exit_description=$(describe_exit_code "$command_status")

    if [ "$command_status" -eq 0 ]; then
        log_message "Post-update command completed successfully. Exit code: 0 - $exit_description."
    else
        fail "Post-update command failed. Exit code: $command_status - $exit_description." "$command_status"
    fi
}

###############################################################################
# Main
###############################################################################

main() {
    init_logging

    log_message "=========================================="
    log_message "Starting DigiCert AWR Tomcat server.xml certificate deployment script"
    log_message "All stdout and stderr are redirected to: $LOGFILE"
    log_message "=========================================="

    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        usage
        exit 0
    fi

    # Check legal notice acceptance
    log_message "Checking legal notice acceptance..."
    if [ "$LEGAL_NOTICE_ACCEPT" != "true" ]; then
        fail "Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed." 1
    else
        log_message "Legal notice accepted, proceeding with script execution."
    fi

    # Log initial configuration
    log_message "Configuration:"
    log_message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
    log_message "  LOGFILE: $LOGFILE"
    log_message "  DEFAULT_KEY_MODE: $DEFAULT_KEY_MODE"
    log_message "  DEFAULT_CRT_MODE: $DEFAULT_CRT_MODE"
    log_message "  DEFAULT_CHAIN_MODE: $DEFAULT_CHAIN_MODE"

    require_command awk
    require_command sed
    require_command grep
    require_command base64
    require_command stat
    require_command sha256sum
    require_command cp
    require_command chmod
    require_command chown
    require_command dirname
    require_command mktemp
    require_command bash
    require_command tr
    require_command head
    require_command date

    # Log environment variable check
    log_message "Checking DC1_POST_SCRIPT_DATA environment variable..."
    if [ -z "$DC1_POST_SCRIPT_DATA" ]; then
        fail "DC1_POST_SCRIPT_DATA environment variable is not set" 1
    else
        log_message "DC1_POST_SCRIPT_DATA is set (length: ${#DC1_POST_SCRIPT_DATA} characters)"
    fi

    # Read the Base64-encoded JSON string from the environment variable
    CERT_INFO=${DC1_POST_SCRIPT_DATA}
    log_message "CERT_INFO length: ${#CERT_INFO} characters"

    # Decode JSON string
    JSON_STRING=$(printf '%s' "$CERT_INFO" | base64 -d 2>/dev/null) \
        || fail "Failed to base64 decode DC1_POST_SCRIPT_DATA" 1

    log_message "JSON_STRING decoded successfully"

    # Log the raw JSON for debugging
    log_message "=========================================="
    log_message "Raw JSON content:"
    log_message "$JSON_STRING"
    log_message "=========================================="

    # Extract arguments from JSON
    log_message "Extracting arguments from JSON..."

    ARGUMENT_1=$(trim "$(extract_arg_number 1)")
    ARGUMENT_2=$(trim "$(extract_arg_number 2)")

    log_message "ARGUMENT_1 extracted: '$ARGUMENT_1' (length: ${#ARGUMENT_1})"
    log_message "ARGUMENT_2 extracted: '$ARGUMENT_2' (length: ${#ARGUMENT_2})"

    TOMCAT_PATH="$ARGUMENT_1"
    APP_SERVICE_COMMAND="$ARGUMENT_2"

    # Extract cert folder (support multiple naming conventions)
    CERT_FOLDER=$(trim "$(extract_json_value certfolder)")

    if [ -z "$CERT_FOLDER" ]; then
        CERT_FOLDER=$(trim "$(extract_json_value certFolder)")
    fi

    if [ -z "$CERT_FOLDER" ]; then
        CERT_FOLDER=$(trim "$(extract_json_value cert_folder)")
    fi

    # Extract delivered files
    CRT_FILE=$(trim "$(extract_file_by_extension crt)")
    KEY_FILE=$(trim "$(extract_file_by_extension key)")

    CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
    KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

    # Extract all files from the files array (for logging/debugging)
    FILES_ARRAY=$(
        printf '%s\n' "$JSON_STRING" \
            | tr -d '\n' \
            | sed -n 's/.*"files"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p'
    )

    # Log summary
    log_message "=========================================="
    log_message "EXTRACTION SUMMARY:"
    log_message "=========================================="
    log_message "Arguments extracted:"
    log_message "  ARGUMENT_1 / Tomcat path: $TOMCAT_PATH"
    log_message "  ARGUMENT_2 / restart command: $APP_SERVICE_COMMAND"
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

    [ -n "$TOMCAT_PATH" ] || fail "ARGUMENT_1 Tomcat path is empty"
    [ -n "$APP_SERVICE_COMMAND" ] || fail "ARGUMENT_2 restart command is empty"
    [ -n "$CERT_FOLDER" ] || fail "certfolder was not found in AWR JSON"
    [ -n "$CRT_FILE" ] || fail "No .crt file was found in AWR files array"
    [ -n "$KEY_FILE" ] || fail "No .key file was found in AWR files array"

    [ -f "$CRT_FILE_PATH" ] || fail "Delivered CRT file not found: $CRT_FILE_PATH"
    [ -f "$KEY_FILE_PATH" ] || fail "Delivered KEY file not found: $KEY_FILE_PATH"

    # Inspect certificate bundle and key
    log_message "Certificate file exists: $CRT_FILE_PATH"
    log_message "Certificate file size: $(stat -c%s "$CRT_FILE_PATH") bytes"

    CERT_COUNT=$(count_pem_certs "$CRT_FILE_PATH")
    log_message "Total certificates in file: $CERT_COUNT"

    [ "$CERT_COUNT" -ge 1 ] \
        || fail "Delivered CRT file does not contain any PEM certificate blocks"

    log_message "Private key file exists: $KEY_FILE_PATH"
    log_message "Private key file size: $(stat -c%s "$KEY_FILE_PATH") bytes"

    KEY_TYPE=$(detect_key_type "$KEY_FILE_PATH")
    log_message "Key type: $KEY_TYPE"

    # Discover Tomcat SSL configuration
    TMP_DISCOVERY_OUTPUT=$(mktemp /tmp/tomcat-awr-discovery-output.XXXXXX) \
        || fail "Unable to create temporary discovery output file"

    TMP_DISCOVERY_LOG=$(mktemp /tmp/tomcat-awr-discovery-log.XXXXXX) \
        || fail "Unable to create temporary discovery log file"

    extract_tomcat_ssl_cert_paths "$TOMCAT_PATH" "$TMP_DISCOVERY_OUTPUT" "$TMP_DISCOVERY_LOG"
    DISCOVERY_RC=$?

    if [ -s "$TMP_DISCOVERY_LOG" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && log_message "server.xml discovery log: $line"
        done < "$TMP_DISCOVERY_LOG"
    fi

    if [ -s "$TMP_DISCOVERY_OUTPUT" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && log_message "server.xml discovery output: $line"
        done < "$TMP_DISCOVERY_OUTPUT"
    fi

    DISCOVERY_OUTPUT=$(cat "$TMP_DISCOVERY_OUTPUT")

    rm -f "$TMP_DISCOVERY_OUTPUT" "$TMP_DISCOVERY_LOG"

    if [ "$DISCOVERY_RC" -eq 10 ]; then
        fail "No active PEM certificate-file-based SSL Connector was found in ${TOMCAT_PATH}/conf/server.xml" 10
    elif [ "$DISCOVERY_RC" -eq 11 ]; then
        fail "Multiple active PEM certificate-file-based SSL Connectors were found. Expected exactly one." 11
    elif [ "$DISCOVERY_RC" -eq 12 ]; then
        UNSUPPORTED_SSL_CONNECTOR_PORT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_SSL_CONNECTOR_PORT=//p')
        UNSUPPORTED_CERTIFICATE_TYPE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_CERTIFICATE_TYPE=//p')
        UNSUPPORTED_CERTIFICATE_KEYSTORE_FILE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_CERTIFICATE_KEYSTORE_FILE=//p')
        UNSUPPORTED_CERTIFICATE_KEYSTORE_TYPE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_CERTIFICATE_KEYSTORE_TYPE=//p')
        UNSUPPORTED_LEGACY_KEYSTORE_FILE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_LEGACY_KEYSTORE_FILE=//p')
        UNSUPPORTED_LEGACY_KEYSTORE_TYPE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_LEGACY_KEYSTORE_TYPE=//p')

        log_message "Unsupported Tomcat SSL certificate configuration detected:"
        log_message "  SSL connector port: $UNSUPPORTED_SSL_CONNECTOR_PORT"
        log_message "  Certificate type: $UNSUPPORTED_CERTIFICATE_TYPE"
        log_message "  certificateKeystoreFile: $UNSUPPORTED_CERTIFICATE_KEYSTORE_FILE"
        log_message "  certificateKeystoreType: $UNSUPPORTED_CERTIFICATE_KEYSTORE_TYPE"
        log_message "  keystoreFile: $UNSUPPORTED_LEGACY_KEYSTORE_FILE"
        log_message "  keystoreType: $UNSUPPORTED_LEGACY_KEYSTORE_TYPE"

        fail "Unsupported Tomcat SSL configuration found. This script supports PEM certificateKeyFile/certificateFile/certificateChainFile only. JKS, PFX, and PKCS12 keystore-based configurations are not supported." 12
    elif [ "$DISCOVERY_RC" -ne 0 ]; then
        fail "server.xml discovery failed with return code $DISCOVERY_RC - $(describe_exit_code "$DISCOVERY_RC")" "$DISCOVERY_RC"
    fi

    CONNECTOR_COUNT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^CONNECTOR_COUNT=//p')
    SSL_CONNECTOR_COUNT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^SSL_CONNECTOR_COUNT=//p')
    CERT_CONFIG_COUNT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^CERT_CONFIG_COUNT=//p')
    UNSUPPORTED_KEYSTORE_COUNT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^UNSUPPORTED_KEYSTORE_COUNT=//p')

    TOMCAT_SSL_CONNECTOR_PORT=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^TOMCAT_SSL_CONNECTOR_PORT=//p')
    CERTIFICATE_TYPE=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^CERTIFICATE_TYPE=//p')

    CERT_KEY_FILE_RAW=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^certificateKeyFile=//p')
    CERT_FILE_RAW=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^certificateFile=//p')
    CERT_CHAIN_FILE_RAW=$(printf '%s\n' "$DISCOVERY_OUTPUT" | sed -n 's/^certificateChainFile=//p')

    log_message "server.xml discovery summary:"
    log_message "  Connectors found: $CONNECTOR_COUNT"
    log_message "  SSL connectors found: $SSL_CONNECTOR_COUNT"
    log_message "  PEM certificate-file configs found: $CERT_CONFIG_COUNT"
    log_message "  Unsupported keystore configs found: $UNSUPPORTED_KEYSTORE_COUNT"
    log_message "  SSL connector port: $TOMCAT_SSL_CONNECTOR_PORT"
    log_message "  Certificate type: $CERTIFICATE_TYPE"
    log_message "  certificateKeyFile: $CERT_KEY_FILE_RAW"
    log_message "  certificateFile: $CERT_FILE_RAW"
    log_message "  certificateChainFile: $CERT_CHAIN_FILE_RAW"

    [ -n "$CERT_KEY_FILE_RAW" ] \
        || fail "server.xml Certificate entry does not define certificateKeyFile"

    [ -n "$CERT_FILE_RAW" ] \
        || fail "server.xml Certificate entry does not define certificateFile"

    APP_KEY_FILE_PATH=$(get_abs_path "$TOMCAT_PATH" "$CERT_KEY_FILE_RAW")
    APP_CRT_FILE_PATH=$(get_abs_path "$TOMCAT_PATH" "$CERT_FILE_RAW")
    APP_CHAIN_FILE_PATH=$(get_abs_path "$TOMCAT_PATH" "$CERT_CHAIN_FILE_RAW")

    log_message "Resolved Tomcat target paths:"
    log_message "  Key target: $APP_KEY_FILE_PATH"
    log_message "  Certificate target: $APP_CRT_FILE_PATH"

    if [ -n "$APP_CHAIN_FILE_PATH" ]; then
        log_message "  Chain target: $APP_CHAIN_FILE_PATH"
    else
        log_message "  Chain target: not configured; full CRT bundle will be deployed to certificateFile"
    fi

    capture_metadata "$APP_KEY_FILE_PATH" "KEY" \
        || fail "Failed to capture metadata for key target"

    capture_metadata "$APP_CRT_FILE_PATH" "CRT" \
        || fail "Failed to capture metadata for certificate target"

    if [ -n "$APP_CHAIN_FILE_PATH" ]; then
        capture_metadata "$APP_CHAIN_FILE_PATH" "CHAIN" \
            || fail "Failed to capture metadata for chain target"
    fi

    backup_file_if_exists "$APP_KEY_FILE_PATH" "key"
    backup_file_if_exists "$APP_CRT_FILE_PATH" "certificate"

    if [ -n "$APP_CHAIN_FILE_PATH" ]; then
        backup_file_if_exists "$APP_CHAIN_FILE_PATH" "chain"
    fi

    copy_and_verify "$KEY_FILE_PATH" "$APP_KEY_FILE_PATH" "private key"

    if [ -n "$APP_CHAIN_FILE_PATH" ]; then
        if [ "$CERT_COUNT" -lt 2 ]; then
            fail "server.xml has certificateChainFile configured, but delivered CRT contains only $CERT_COUNT certificate(s)"
        fi

        TMP_LEAF=$(mktemp /tmp/tomcat-awr-leaf.XXXXXX) \
            || fail "Unable to create temporary leaf certificate file"

        TMP_CHAIN=$(mktemp /tmp/tomcat-awr-chain.XXXXXX) \
            || fail "Unable to create temporary chain certificate file"

        split_leaf_and_chain "$CRT_FILE_PATH" "$TMP_LEAF" "$TMP_CHAIN"

        [ -s "$TMP_LEAF" ] \
            || fail "Leaf certificate split failed; temporary leaf file is empty"

        [ -s "$TMP_CHAIN" ] \
            || fail "Chain certificate split failed; temporary chain file is empty"

        log_message "Split delivered CRT into leaf and chain because certificateChainFile is configured"

        copy_and_verify "$TMP_LEAF" "$APP_CRT_FILE_PATH" "leaf certificate"
        copy_and_verify "$TMP_CHAIN" "$APP_CHAIN_FILE_PATH" "certificate chain"

        rm -f "$TMP_LEAF" "$TMP_CHAIN"
    else
        copy_and_verify "$CRT_FILE_PATH" "$APP_CRT_FILE_PATH" "certificate bundle"
    fi

    apply_metadata "$APP_KEY_FILE_PATH" "KEY" "$DEFAULT_KEY_MODE" \
        || fail "Failed to apply metadata to key target"

    apply_metadata "$APP_CRT_FILE_PATH" "CRT" "$DEFAULT_CRT_MODE" \
        || fail "Failed to apply metadata to certificate target"

    if [ -n "$APP_CHAIN_FILE_PATH" ]; then
        apply_metadata "$APP_CHAIN_FILE_PATH" "CHAIN" "$DEFAULT_CHAIN_MODE" \
            || fail "Failed to apply metadata to chain target"
    fi

    if command -v restorecon >/dev/null 2>&1; then
        if [ -n "$APP_CHAIN_FILE_PATH" ]; then
            restorecon -v "$APP_KEY_FILE_PATH" "$APP_CRT_FILE_PATH" "$APP_CHAIN_FILE_PATH" \
                || log_message "WARNING: restorecon returned non-zero"
        else
            restorecon -v "$APP_KEY_FILE_PATH" "$APP_CRT_FILE_PATH" \
                || log_message "WARNING: restorecon returned non-zero"
        fi

        log_message "SELinux restorecon step completed"
    else
        log_message "restorecon not available; skipping SELinux context restoration"
    fi

    # ============================================================================
    # CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
    # ============================================================================
    #
    # This section runs AFTER certificate files have been deployed and verified,
    # but BEFORE the Tomcat restart command is executed. Add any pre-restart
    # hooks here (notifications, additional permission tweaks, validation,
    # secondary file deployments, etc.).
    #
    # Available variables for your custom logic:
    #
    # Certificate-related variables (delivered by AWR):
    #   $CERT_FOLDER         - The folder path where AWR-delivered certificates are stored
    #   $CRT_FILE            - The delivered certificate filename (.crt)
    #   $KEY_FILE            - The delivered private key filename (.key)
    #   $CRT_FILE_PATH       - Full path to the delivered certificate file
    #   $KEY_FILE_PATH       - Full path to the delivered private key file
    #   $FILES_ARRAY         - All files listed in the JSON files array
    #
    # Certificate inspection variables:
    #   $CERT_COUNT          - Number of certificates in the delivered CRT file
    #   $KEY_TYPE            - Type of key (RSA, ECC, PKCS#8 format, or Unknown)
    #
    # Tomcat-resolved target paths (where certs were just deployed):
    #   $TOMCAT_PATH                 - Tomcat base directory (ARGUMENT_1)
    #   $TOMCAT_SSL_CONNECTOR_PORT   - SSL connector port discovered in server.xml
    #   $CERTIFICATE_TYPE            - Certificate type attribute (e.g. RSA)
    #   $APP_KEY_FILE_PATH           - Deployed key file path on Tomcat
    #   $APP_CRT_FILE_PATH           - Deployed certificate file path on Tomcat
    #   $APP_CHAIN_FILE_PATH         - Deployed chain file path on Tomcat (may be empty)
    #
    # Argument variables (from JSON args array):
    #   $ARGUMENT_1          - Tomcat base directory
    #   $ARGUMENT_2          - Restart command
    #   $APP_SERVICE_COMMAND - Same as $ARGUMENT_2
    #
    # JSON-related variables:
    #   $JSON_STRING         - The complete decoded JSON string
    #
    # Utility functions:
    #   log_message "text"   - Write a timestamped message to the log
    #   fail "msg" [code]    - Log an error and exit with the given code (default 2)
    #
    # ============================================================================

    log_message "=========================================="
    log_message "Starting custom script section..."
    log_message "=========================================="


    # ADD CUSTOM LOGIC HERE:
    # ----------------------------------------




    # ----------------------------------------
    # END CUSTOM LOGIC

    log_message "Custom script section completed"
    log_message "=========================================="

    # ============================================================================
    # END OF CUSTOM SCRIPT SECTION
    # ============================================================================

    run_post_update_command "$APP_SERVICE_COMMAND"

    log_message "=========================================="
    log_message "Tomcat certificate deployment completed successfully"
    log_message "=========================================="

    exit 0
}

main "$@"