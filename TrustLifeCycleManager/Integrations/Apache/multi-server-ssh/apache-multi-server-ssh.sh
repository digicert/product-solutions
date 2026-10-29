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


# Configuration
LEGAL_NOTICE_ACCEPT="false"  # Must be set to "true" to accept the legal notice and allow script execution
LOGFILE="/home/ubuntu/awr-apache-multi-server.log"

# ============================================================================
# APACHE MULTI-SERVER DEPLOYMENT CONFIGURATION
# ============================================================================
# The certificate and private key that TLM just issued are copied over SSH to
# every server listed in SERVERS, installed at the configured paths and,
# optionally, Apache is reloaded. Everything runs non-interactively.
#
# Each SERVERS entry is one target. Fields are "key=value" pairs separated by
# SERVER_FIELD_SEP (default "|"). Only "host" is required; every other field
# falls back to the matching DEFAULT_* value below.
#
#   host=<name or IP>         SSH target (required)
#   port=<n>                  SSH port
#   user=<name>               SSH login user
#   auth=key|password         SSH authentication method
#   keyfile=<path>            private key on THIS host (auth=key)
#   pass=<secret>             SSH password inline (auth=password)
#   pass_file=<path>          file on THIS host holding the SSH password (preferred over pass=)
#   sudo_pass=<secret>        password for sudo on the target (install + reload)
#   sudo_pass_file=<path>     file on THIS host holding the sudo password
#                             If neither is given: auth=password reuses the SSH
#                             password; auth=key uses "sudo -n" (needs NOPASSWD).
#   use_sudo=true|false       prefix install/reload commands with sudo (false if user is root)
#   cert_dest=<path>          full path of the certificate file on the target
#   key_dest=<path>           full path of the private key file on the target
#   backup=true|false         keep a timestamped copy of the files being replaced
#   reload=true|false         reload Apache after the install
#   configtest_cmd=<cmd>      run before the reload; reload is skipped if it fails ("" = skip)
#   reload_cmd=<cmd>          command that reloads Apache on the target
#
# Values must not contain SERVER_FIELD_SEP. If a password does, change
# SERVER_FIELD_SEP (for example to "§") or use pass_file / sudo_pass_file.
#
# Examples (remove or replace them):
SERVERS=(
    "host=web1.example.com|auth=key|keyfile=/home/ubuntu/.ssh/tlm_deploy_ed25519"
    "host=web2.example.com|port=2222|user=deploy|auth=password|pass_file=/home/ubuntu/.tlm/web2.pass|reload_cmd=systemctl reload httpd|configtest_cmd=httpd -t"
    "host=10.0.0.15|auth=password|pass=ChangeMe123|sudo_pass=ChangeMe123|cert_dest=/etc/httpd/ssl/www.crt|key_dest=/etc/httpd/ssl/www.key|reload=false"
)

# Optional: read additional server entries from a file (one entry per line,
# "#" comments and blank lines ignored). Keeps passwords out of this script.
SERVER_LIST_FILE=""

# Defaults applied to every entry that does not set the field itself
DEFAULT_SSH_PORT="22"
DEFAULT_SSH_USER="ubuntu"
DEFAULT_AUTH="key"                                   # key | password
DEFAULT_SSH_KEYFILE="/home/ubuntu/.ssh/id_ed25519"   # private key on THIS host
DEFAULT_SSH_PASS=""                                  # auth=password without pass/pass_file in the entry
DEFAULT_SSH_PASS_FILE=""
DEFAULT_SUDO_PASS=""
DEFAULT_SUDO_PASS_FILE=""
DEFAULT_USE_SUDO="true"
DEFAULT_CERT_DEST="/etc/ssl/certs/tlm-apache.crt"    # must match SSLCertificateFile
DEFAULT_KEY_DEST="/etc/ssl/private/tlm-apache.key"   # must match SSLCertificateKeyFile
DEFAULT_BACKUP="true"
DEFAULT_RELOAD="true"
DEFAULT_CONFIGTEST_CMD="apachectl configtest"        # RHEL/Rocky: "httpd -t"
DEFAULT_RELOAD_CMD="systemctl reload apache2"        # RHEL/Rocky: "systemctl reload httpd"

# SSH behaviour
SSH_CONNECT_TIMEOUT="15"
STRICT_HOST_KEY_CHECKING="accept-new"   # accept-new | yes | no   ("yes" needs known_hosts pre-populated)
KNOWN_HOSTS_FILE=""                     # "" = ssh default (~/.ssh/known_hosts of the user running the agent)
STOP_ON_FIRST_FAILURE="false"           # true = do not touch the remaining servers after a failure
SERVER_FIELD_SEP="|"
# ============================================================================

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# Start logging
log_message "=========================================="
log_message "Starting Apache multi-server SSH deployment script"
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

# Extract Argument_6 - sixth argument
ARGUMENT_6=$(echo "$ARGS_ARRAY" | awk -F',' '{print $6}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_6 extracted: '$ARGUMENT_6'"
log_message "ARGUMENT_6 length: ${#ARGUMENT_6}"

# Extract Argument_7 - seventh argument
ARGUMENT_7=$(echo "$ARGS_ARRAY" | awk -F',' '{print $7}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_7 extracted: '$ARGUMENT_7'"
log_message "ARGUMENT_7 length: ${#ARGUMENT_7}"

# Extract Argument_8 - eighth argument
ARGUMENT_8=$(echo "$ARGS_ARRAY" | awk -F',' '{print $8}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_8 extracted: '$ARGUMENT_8'"
log_message "ARGUMENT_8 length: ${#ARGUMENT_8}"

# Extract Argument_9 - ninth argument
ARGUMENT_9=$(echo "$ARGS_ARRAY" | awk -F',' '{print $9}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_9 extracted: '$ARGUMENT_9'"
log_message "ARGUMENT_9 length: ${#ARGUMENT_9}"

# Extract Argument_10 - tenth argument
ARGUMENT_10=$(echo "$ARGS_ARRAY" | awk -F',' '{print $10}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_10 extracted: '$ARGUMENT_10'"
log_message "ARGUMENT_10 length: ${#ARGUMENT_10}"

# Extract Argument_11 - eleventh argument
ARGUMENT_11=$(echo "$ARGS_ARRAY" | awk -F',' '{print $11}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_11 extracted: '$ARGUMENT_11'"
log_message "ARGUMENT_11 length: ${#ARGUMENT_11}"

# Extract Argument_12 - twelfth argument
ARGUMENT_12=$(echo "$ARGS_ARRAY" | awk -F',' '{print $12}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_12 extracted: '$ARGUMENT_12'"
log_message "ARGUMENT_12 length: ${#ARGUMENT_12}"

# Extract Argument_13 - thirteenth argument
ARGUMENT_13=$(echo "$ARGS_ARRAY" | awk -F',' '{print $13}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_13 extracted: '$ARGUMENT_13'"
log_message "ARGUMENT_13 length: ${#ARGUMENT_13}"

# Extract Argument_14 - fourteenth argument
ARGUMENT_14=$(echo "$ARGS_ARRAY" | awk -F',' '{print $14}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_14 extracted: '$ARGUMENT_14'"
log_message "ARGUMENT_14 length: ${#ARGUMENT_14}"

# Extract Argument_15 - fifteenth argument
ARGUMENT_15=$(echo "$ARGS_ARRAY" | awk -F',' '{print $15}' | tr -d '"' | tr -d ' ' | tr -d '\n' | tr -d '\r')
log_message "ARGUMENT_15 extracted: '$ARGUMENT_15'"
log_message "ARGUMENT_15 length: ${#ARGUMENT_15}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(echo "$ARGUMENT_1" | tr -d '[:space:]')
ARGUMENT_2=$(echo "$ARGUMENT_2" | tr -d '[:space:]')
ARGUMENT_3=$(echo "$ARGUMENT_3" | tr -d '[:space:]')
ARGUMENT_4=$(echo "$ARGUMENT_4" | tr -d '[:space:]')
ARGUMENT_5=$(echo "$ARGUMENT_5" | tr -d '[:space:]')
ARGUMENT_6=$(echo "$ARGUMENT_6" | tr -d '[:space:]')
ARGUMENT_7=$(echo "$ARGUMENT_7" | tr -d '[:space:]')
ARGUMENT_8=$(echo "$ARGUMENT_8" | tr -d '[:space:]')
ARGUMENT_9=$(echo "$ARGUMENT_9" | tr -d '[:space:]')
ARGUMENT_10=$(echo "$ARGUMENT_10" | tr -d '[:space:]')
ARGUMENT_11=$(echo "$ARGUMENT_11" | tr -d '[:space:]')
ARGUMENT_12=$(echo "$ARGUMENT_12" | tr -d '[:space:]')
ARGUMENT_13=$(echo "$ARGUMENT_13" | tr -d '[:space:]')
ARGUMENT_14=$(echo "$ARGUMENT_14" | tr -d '[:space:]')
ARGUMENT_15=$(echo "$ARGUMENT_15" | tr -d '[:space:]')

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
log_message "  Argument 6: $ARGUMENT_6"
log_message "  Argument 7: $ARGUMENT_7"
log_message "  Argument 8: $ARGUMENT_8"
log_message "  Argument 9: $ARGUMENT_9"
log_message "  Argument 10: $ARGUMENT_10"
log_message "  Argument 11: $ARGUMENT_11"
log_message "  Argument 12: $ARGUMENT_12"
log_message "  Argument 13: $ARGUMENT_13"
log_message "  Argument 14: $ARGUMENT_14"
log_message "  Argument 15: $ARGUMENT_15"
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
# Argument variables (from JSON args array, up to 15):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
#   $ARGUMENT_6       - Sixth argument from args array
#   $ARGUMENT_7       - Seventh argument from args array
#   $ARGUMENT_8       - Eighth argument from args array
#   $ARGUMENT_9       - Ninth argument from args array
#   $ARGUMENT_10      - Tenth argument from args array
#   $ARGUMENT_11      - Eleventh argument from args array
#   $ARGUMENT_12      - Twelfth argument from args array
#   $ARGUMENT_13      - Thirteenth argument from args array
#   $ARGUMENT_14      - Fourteenth argument from args array
#   $ARGUMENT_15      - Fifteenth argument from args array
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


# ADD CUSTOM LOGIC HERE:
# ----------------------------------------

# ------------------ BEGIN: Apache multi-server SSH deployment ------------------
log_message "Entering Apache multi-server SSH deployment logic"

# --- Source files issued by TLM ----------------------------------------------
if [ -z "${CERT_FOLDER}" ] || [ -z "${CRT_FILE}" ] || [ -z "${KEY_FILE}" ]; then
    log_message "ERROR: Missing one or more required inputs (CERT_FOLDER/CRT_FILE/KEY_FILE). Aborting."
    exit 1
fi
SRC_CERT="${CRT_FILE_PATH:-${CERT_FOLDER}/${CRT_FILE}}"
SRC_KEY="${KEY_FILE_PATH:-${CERT_FOLDER}/${KEY_FILE}}"
if [ ! -f "${SRC_CERT}" ]; then
    log_message "ERROR: Source certificate not found at ${SRC_CERT}"
    exit 1
fi
if [ ! -f "${SRC_KEY}" ]; then
    log_message "ERROR: Source private key not found at ${SRC_KEY}"
    exit 1
fi

# ssh needs HOME for ~/.ssh; the agent may run without it.
if [ -z "${HOME:-}" ]; then
    HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
    export HOME
    log_message "HOME was unset; using ${HOME:-<unknown>}"
fi

# --- Helpers ------------------------------------------------------------------
# Quote a string for a remote POSIX shell (single quotes, safe for any content).
shq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Mask secrets in anything that reaches the log.
mask_secrets() {
    local text="$1" s
    for s in "${S_SSH_PASS}" "${S_SUDO_PASS}"; do
        [ -n "${s}" ] && text="${text//"${s}"/********}"
    done
    printf '%s' "${text}"
}

log_lines() {
    # Log every line of stdin with a prefix, secrets masked.
    local prefix="$1" line
    while IFS= read -r line || [ -n "${line}" ]; do
        log_message "${prefix}$(mask_secrets "${line}")"
    done
}

read_secret_file() {
    # Print the first line of a password file; fail if unreadable.
    local f="$1"
    if [ ! -r "${f}" ]; then
        return 1
    fi
    head -n 1 "${f}" | tr -d '\r\n'
}

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "${v}"
}

# Parse one SERVERS entry into S_* variables, starting from the DEFAULT_* values.
parse_server_entry() {
    local entry="$1" pair key value
    S_HOST=""
    S_PORT="${DEFAULT_SSH_PORT}"
    S_USER="${DEFAULT_SSH_USER}"
    S_AUTH="${DEFAULT_AUTH}"
    S_KEYFILE="${DEFAULT_SSH_KEYFILE}"
    S_SSH_PASS="${DEFAULT_SSH_PASS}"
    S_SSH_PASS_FILE="${DEFAULT_SSH_PASS_FILE}"
    S_SUDO_PASS="${DEFAULT_SUDO_PASS}"
    S_SUDO_PASS_FILE="${DEFAULT_SUDO_PASS_FILE}"
    S_USE_SUDO="${DEFAULT_USE_SUDO}"
    S_CERT_DEST="${DEFAULT_CERT_DEST}"
    S_KEY_DEST="${DEFAULT_KEY_DEST}"
    S_BACKUP="${DEFAULT_BACKUP}"
    S_RELOAD="${DEFAULT_RELOAD}"
    S_CONFIGTEST_CMD="${DEFAULT_CONFIGTEST_CMD}"
    S_RELOAD_CMD="${DEFAULT_RELOAD_CMD}"

    local -a pairs=()
    local IFS="${SERVER_FIELD_SEP}"
    read -r -a pairs <<< "${entry}"
    unset IFS
    for pair in "${pairs[@]}"; do
        pair="$(trim "${pair}")"
        [ -z "${pair}" ] && continue
        key="$(trim "${pair%%=*}")"
        value="${pair#*=}"
        [ "${key}" = "${pair}" ] && value=""
        case "$(printf '%s' "${key}" | tr '[:upper:]' '[:lower:]')" in
            host)           S_HOST="$(trim "${value}")" ;;
            port)           S_PORT="$(trim "${value}")" ;;
            user)           S_USER="$(trim "${value}")" ;;
            auth)           S_AUTH="$(trim "${value}" | tr '[:upper:]' '[:lower:]')" ;;
            keyfile)        S_KEYFILE="$(trim "${value}")" ;;
            pass)           S_SSH_PASS="${value}" ;;
            pass_file)      S_SSH_PASS_FILE="$(trim "${value}")" ;;
            sudo_pass)      S_SUDO_PASS="${value}" ;;
            sudo_pass_file) S_SUDO_PASS_FILE="$(trim "${value}")" ;;
            use_sudo)       S_USE_SUDO="$(trim "${value}" | tr '[:upper:]' '[:lower:]')" ;;
            cert_dest)      S_CERT_DEST="$(trim "${value}")" ;;
            key_dest)       S_KEY_DEST="$(trim "${value}")" ;;
            backup)         S_BACKUP="$(trim "${value}" | tr '[:upper:]' '[:lower:]')" ;;
            reload)         S_RELOAD="$(trim "${value}" | tr '[:upper:]' '[:lower:]')" ;;
            configtest_cmd) S_CONFIGTEST_CMD="$(trim "${value}")" ;;
            reload_cmd)     S_RELOAD_CMD="$(trim "${value}")" ;;
            *) log_message "  WARNING: unknown field '${key}' ignored" ;;
        esac
    done
}

# Validate S_* and resolve secrets from files. Returns 1 with a logged reason.
validate_server_config() {
    if [ -z "${S_HOST}" ]; then
        log_message "  ERROR: entry has no host= field"
        return 1
    fi
    case "${S_PORT}" in
        ''|*[!0-9]*) log_message "  ERROR: port '${S_PORT}' is not numeric"; return 1 ;;
    esac
    if [ -z "${S_USER}" ]; then
        log_message "  ERROR: no SSH user (set user= or DEFAULT_SSH_USER)"
        return 1
    fi
    case "${S_AUTH}" in
        key)
            if [ -z "${S_KEYFILE}" ] || [ ! -r "${S_KEYFILE}" ]; then
                log_message "  ERROR: auth=key but keyfile '${S_KEYFILE}' is missing or unreadable"
                return 1
            fi
            ;;
        password)
            if ! command -v sshpass >/dev/null 2>&1; then
                log_message "  ERROR: auth=password requires 'sshpass' on this host (apt install sshpass / dnf install sshpass)"
                return 1
            fi
            if [ -n "${S_SSH_PASS_FILE}" ]; then
                if ! S_SSH_PASS="$(read_secret_file "${S_SSH_PASS_FILE}")"; then
                    log_message "  ERROR: cannot read pass_file '${S_SSH_PASS_FILE}'"
                    return 1
                fi
            fi
            if [ -z "${S_SSH_PASS}" ]; then
                log_message "  ERROR: auth=password but no password (pass=, pass_file= or DEFAULT_SSH_PASS)"
                return 1
            fi
            ;;
        *)
            log_message "  ERROR: auth must be 'key' or 'password' (got '${S_AUTH}')"
            return 1
            ;;
    esac
    if [ -n "${S_SUDO_PASS_FILE}" ]; then
        if ! S_SUDO_PASS="$(read_secret_file "${S_SUDO_PASS_FILE}")"; then
            log_message "  ERROR: cannot read sudo_pass_file '${S_SUDO_PASS_FILE}'"
            return 1
        fi
    fi
    if [ -z "${S_SUDO_PASS}" ] && [ "${S_AUTH}" = "password" ]; then
        S_SUDO_PASS="${S_SSH_PASS}"
    fi
    case "${S_USE_SUDO}" in true|false) ;; *) log_message "  ERROR: use_sudo must be true or false"; return 1 ;; esac
    case "${S_BACKUP}"   in true|false) ;; *) log_message "  ERROR: backup must be true or false";   return 1 ;; esac
    case "${S_RELOAD}"   in true|false) ;; *) log_message "  ERROR: reload must be true or false";   return 1 ;; esac
    case "${S_CERT_DEST}" in /*) ;; *) log_message "  ERROR: cert_dest must be an absolute path"; return 1 ;; esac
    case "${S_KEY_DEST}"  in /*) ;; *) log_message "  ERROR: key_dest must be an absolute path";  return 1 ;; esac
    if [ "${S_RELOAD}" = "true" ] && [ -z "${S_RELOAD_CMD}" ]; then
        log_message "  ERROR: reload=true but reload_cmd is empty"
        return 1
    fi
    return 0
}

# Build SSH_OPTS (array) for the current S_* server.
build_ssh_opts() {
    SSH_OPTS=(
        -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
        -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
        -o "LogLevel=ERROR"
        -o "ServerAliveInterval=15"
    )
    if [ -n "${KNOWN_HOSTS_FILE}" ]; then
        SSH_OPTS+=(-o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}")
    fi
    if [ "${S_AUTH}" = "key" ]; then
        SSH_OPTS+=(
            -o "BatchMode=yes"
            -o "IdentitiesOnly=yes"
            -o "PasswordAuthentication=no"
            -i "${S_KEYFILE}"
        )
    else
        SSH_OPTS+=(
            -o "PubkeyAuthentication=no"
            -o "PreferredAuthentications=password,keyboard-interactive"
            -o "NumberOfPasswordPrompts=1"
        )
    fi
}

# run_ssh <remote command>   (stdin is passed through to the remote command)
run_ssh() {
    if [ "${S_AUTH}" = "password" ]; then
        SSHPASS="${S_SSH_PASS}" sshpass -e ssh "${SSH_OPTS[@]}" -p "${S_PORT}" "${S_USER}@${S_HOST}" "$@"
    else
        ssh "${SSH_OPTS[@]}" -p "${S_PORT}" "${S_USER}@${S_HOST}" "$@"
    fi
}

# run_scp <local files...> <remote dir>
run_scp() {
    local dest="${*: -1}"
    local -a srcs=("${@:1:$#-1}")
    if [ "${S_AUTH}" = "password" ]; then
        SSHPASS="${S_SSH_PASS}" sshpass -e scp "${SSH_OPTS[@]}" -q -P "${S_PORT}" "${srcs[@]}" "${S_USER}@${S_HOST}:${dest}/"
    else
        scp "${SSH_OPTS[@]}" -q -P "${S_PORT}" "${srcs[@]}" "${S_USER}@${S_HOST}:${dest}/"
    fi
}

# --- Remote installer (uploaded next to the certificate and run on the target)
REMOTE_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/tlm-apache-install.XXXXXX")" || {
    log_message "ERROR: cannot create temporary file for the remote installer"
    exit 1
}
trap 'rm -f "${REMOTE_INSTALLER}"' EXIT
cat > "${REMOTE_INSTALLER}" <<'REMOTE_EOF'
#!/bin/bash
# Runs ON THE TARGET. Uploaded by apache-multi-server-ssh.sh, deleted afterwards.
# Usage: bash install.sh <stage_dir> <cert_dest> <key_dest> <backup> <use_sudo> <reload> <configtest_cmd> <reload_cmd>
# The sudo password (may be empty) is read from the first line of stdin.
# Exit codes: 0 ok, 2 bad input, 3 sudo unavailable, 4 install failed,
#             5 configtest failed (certificate installed, NOT reloaded), 6 reload failed.
set -u
STAGE_DIR="$1"; CERT_DEST="$2"; KEY_DEST="$3"; BACKUP="$4"; USE_SUDO="$5"
RELOAD="$6"; CONFIGTEST_CMD="$7"; RELOAD_CMD="$8"
IFS= read -r SUDO_PASS || SUDO_PASS=""

say()  { echo "$*"; }
fail() { local code="$1"; shift; say "ERROR: $*"; exit "${code}"; }
cleanup() { rm -rf "${STAGE_DIR}"; }
trap cleanup EXIT

priv() {
    if [ "${USE_SUDO}" != "true" ]; then
        "$@"
    elif [ -n "${SUDO_PASS}" ]; then
        printf '%s\n' "${SUDO_PASS}" | sudo -S -p '' -- "$@"
    else
        sudo -n -- "$@"
    fi
}

SRC_CERT="${STAGE_DIR}/cert.crt"
SRC_KEY="${STAGE_DIR}/key.key"
[ -s "${SRC_CERT}" ] || fail 2 "staged certificate missing: ${SRC_CERT}"
[ -s "${SRC_KEY}"  ] || fail 2 "staged private key missing: ${SRC_KEY}"

# Certificate / key pair sanity check (skipped when openssl is absent)
if command -v openssl >/dev/null 2>&1; then
    CERT_PUB="$(openssl x509 -in "${SRC_CERT}" -noout -pubkey 2>/dev/null)"
    KEY_PUB="$(openssl pkey -in "${SRC_KEY}" -pubout 2>/dev/null)"
    if [ -z "${CERT_PUB}" ] || [ -z "${KEY_PUB}" ]; then
        fail 2 "openssl could not parse the certificate or the private key"
    fi
    [ "${CERT_PUB}" = "${KEY_PUB}" ] || fail 2 "private key does not match the certificate"
    say "certificate/key pair verified: $(openssl x509 -in "${SRC_CERT}" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
else
    say "WARNING: openssl not found on target, skipping certificate/key match check"
fi

# Privilege check (non-interactive)
if ! priv true 2>/dev/null; then
    fail 3 "sudo is not usable non-interactively for $(id -un) (wrong sudo password, no NOPASSWD rule, or 'Defaults requiretty')"
fi

TS="$(date -u +%Y%m%d-%H%M%SZ)"
install_file() {
    local src="$1" dest="$2" mode="$3" dir tmp
    dir="$(dirname "${dest}")"
    priv mkdir -p "${dir}" || fail 4 "cannot create ${dir}"
    if [ "${BACKUP}" = "true" ] && priv test -f "${dest}"; then
        priv cp -p "${dest}" "${dest}.${TS}.backup" || fail 4 "backup of ${dest} failed"
        say "backup: ${dest} -> ${dest}.${TS}.backup"
    fi
    tmp="${dest}.tmp.$$"
    if [ "${USE_SUDO}" = "true" ]; then
        priv install -m "${mode}" -o root -g root "${src}" "${tmp}" || fail 4 "install of ${dest} failed"
    else
        install -m "${mode}" "${src}" "${tmp}" || fail 4 "install of ${dest} failed"
    fi
    priv mv -f "${tmp}" "${dest}" || { priv rm -f "${tmp}"; fail 4 "move into place failed for ${dest}"; }
    say "installed ${dest} (mode ${mode})"
}
install_file "${SRC_CERT}" "${CERT_DEST}" 0644
install_file "${SRC_KEY}"  "${KEY_DEST}"  0600

if [ "${RELOAD}" != "true" ]; then
    say "reload=false; Apache not reloaded"
    exit 0
fi
if [ -n "${CONFIGTEST_CMD}" ]; then
    say "running config test: ${CONFIGTEST_CMD}"
    if ! priv sh -c "${CONFIGTEST_CMD}" 2>&1; then
        fail 5 "config test failed; certificate installed but Apache NOT reloaded"
    fi
    say "config test passed"
fi
say "reloading Apache: ${RELOAD_CMD}"
if ! priv sh -c "${RELOAD_CMD}" 2>&1; then
    fail 6 "reload command failed"
fi
say "Apache reloaded"
exit 0
REMOTE_EOF

# --- Deploy to one server (S_* already parsed and validated) --------------------
deploy_to_server() {
    local stage out rc remote_cmd sudo_mode
    build_ssh_opts

    log_message "  [1/3] Creating staging directory on ${S_HOST}..."
    if ! stage="$(run_ssh 'mktemp -d /tmp/tlm-apache.XXXXXX' 2>&1 </dev/null)"; then
        log_message "  ERROR: SSH connection or mktemp failed: $(mask_secrets "${stage}")"
        return 1
    fi
    stage="$(printf '%s' "${stage}" | tr -d '\r\n')"
    case "${stage}" in
        /tmp/tlm-apache.*) ;;
        *) log_message "  ERROR: unexpected mktemp output: $(mask_secrets "${stage}")"; return 1 ;;
    esac
    log_message "  Staging directory: ${stage}"

    log_message "  [2/3] Uploading certificate, key and installer..."
    local up_dir
    up_dir="$(mktemp -d "${TMPDIR:-/tmp}/tlm-apache-upload.XXXXXX")" || { log_message "  ERROR: local mktemp failed"; return 1; }
    cp "${SRC_CERT}" "${up_dir}/cert.crt" && cp "${SRC_KEY}" "${up_dir}/key.key" && cp "${REMOTE_INSTALLER}" "${up_dir}/install.sh" || {
        log_message "  ERROR: could not prepare upload set"; rm -rf "${up_dir}"; return 1; }
    chmod 0600 "${up_dir}/key.key"
    if ! out="$(run_scp "${up_dir}/cert.crt" "${up_dir}/key.key" "${up_dir}/install.sh" "${stage}" 2>&1 </dev/null)"; then
        log_message "  ERROR: upload failed: $(mask_secrets "${out}")"
        rm -rf "${up_dir}"
        run_ssh "rm -rf $(shq "${stage}")" </dev/null >/dev/null 2>&1
        return 1
    fi
    rm -rf "${up_dir}"

    if [ "${S_USE_SUDO}" != "true" ]; then sudo_mode="none"
    elif [ -n "${S_SUDO_PASS}" ]; then sudo_mode="password"
    else sudo_mode="NOPASSWD (sudo -n)"; fi
    log_message "  [3/3] Installing (sudo: ${sudo_mode}, reload: ${S_RELOAD})..."
    remote_cmd="bash $(shq "${stage}/install.sh") $(shq "${stage}") $(shq "${S_CERT_DEST}") $(shq "${S_KEY_DEST}") \
$(shq "${S_BACKUP}") $(shq "${S_USE_SUDO}") $(shq "${S_RELOAD}") $(shq "${S_CONFIGTEST_CMD}") $(shq "${S_RELOAD_CMD}")"
    out="$(printf '%s\n' "${S_SUDO_PASS}" | run_ssh "${remote_cmd}" 2>&1)"
    rc=$?
    printf '%s\n' "${out}" | log_lines "    remote> "
    if [ "${rc}" -ne 0 ]; then
        log_message "  ERROR: remote installer exited with code ${rc}"
        return 1
    fi
    return 0
}

# --- Collect server list ----------------------------------------------------------
if [ -n "${SERVER_LIST_FILE}" ]; then
    if [ -r "${SERVER_LIST_FILE}" ]; then
        while IFS= read -r line || [ -n "${line}" ]; do
            line="$(trim "${line}")"
            case "${line}" in ''|'#'*) continue ;; esac
            SERVERS+=("${line}")
        done < "${SERVER_LIST_FILE}"
        log_message "Loaded entries from SERVER_LIST_FILE ${SERVER_LIST_FILE}"
    else
        log_message "ERROR: SERVER_LIST_FILE '${SERVER_LIST_FILE}' is not readable"
        exit 1
    fi
fi
if [ "${#SERVERS[@]}" -eq 0 ]; then
    log_message "ERROR: SERVERS is empty; nothing to deploy"
    exit 1
fi
log_message "Deploying ${SRC_CERT} and ${SRC_KEY} to ${#SERVERS[@]} server(s)"

# --- Main loop ----------------------------------------------------------------------
SUCCESS_LIST=()
FAILED_LIST=()
INDEX=0
for ENTRY in "${SERVERS[@]}"; do
    INDEX=$((INDEX + 1))
    S_SSH_PASS=""; S_SUDO_PASS=""
    parse_server_entry "${ENTRY}"
    LABEL="${S_HOST:-entry#${INDEX}}"
    log_message "------------------------------------------"
    log_message "Server ${INDEX}/${#SERVERS[@]}: ${LABEL}"
    log_message "  user=${S_USER} port=${S_PORT} auth=${S_AUTH} use_sudo=${S_USE_SUDO}"
    log_message "  cert_dest=${S_CERT_DEST}"
    log_message "  key_dest=${S_KEY_DEST}"
    log_message "  backup=${S_BACKUP} reload=${S_RELOAD} configtest_cmd='${S_CONFIGTEST_CMD}' reload_cmd='${S_RELOAD_CMD}'"
    if validate_server_config && deploy_to_server; then
        log_message "  RESULT: SUCCESS"
        SUCCESS_LIST+=("${LABEL}")
    else
        log_message "  RESULT: FAILED"
        FAILED_LIST+=("${LABEL}")
        if [ "${STOP_ON_FIRST_FAILURE}" = "true" ]; then
            log_message "STOP_ON_FIRST_FAILURE=true; remaining servers skipped"
            break
        fi
    fi
done
S_SSH_PASS=""; S_SUDO_PASS=""

log_message "------------------------------------------"
log_message "DEPLOYMENT SUMMARY: ${#SUCCESS_LIST[@]} succeeded, ${#FAILED_LIST[@]} failed, ${#SERVERS[@]} configured"
[ "${#SUCCESS_LIST[@]}" -gt 0 ] && log_message "  Succeeded: ${SUCCESS_LIST[*]}"
[ "${#FAILED_LIST[@]}"  -gt 0 ] && log_message "  Failed:    ${FAILED_LIST[*]}"
if [ "${#FAILED_LIST[@]}" -gt 0 ]; then
    log_message "Apache multi-server deployment finished with errors"
    log_message "=========================================="
    exit 1
fi
log_message "Apache multi-server deployment complete"
# ------------------ END: Apache multi-server SSH deployment ------------------

# ----------------------------------------
# END CUSTOM LOGIC

log_message "Custom script section completed"
log_message "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

log_message "=========================================="
log_message "Script execution completed"
log_message "=========================================="

exit 0