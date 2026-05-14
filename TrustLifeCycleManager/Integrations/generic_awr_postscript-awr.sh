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

######################################################################################################################
# Usage:
#	This script is driven as part of the DigiCert ONE Trust Lifecycle Manager Admin Web Request (AWR) workflow for
#	a Linux endpoint running the DigiCert Agent.
#
#	The script will check if the existing files exist, capture their permissions/ownership, back them up,
#	verify the backup, copy the new files into the folder with the same filename, restore the original
#	permissions/ownership on the new files, and then run the command or script to force the application/
#	service to use the new certificates.
#
#	To initiate the automation, you will need to access AWR workflow wizard within your "inventory" view.
#
#	Step 1:
#		Complete the usual items - profile selection, common-name, SAN, and renewal period.
#
#	Step 2:
#		Add the Agents (and any other integrations needing certificates with the same CN and SANs)
#
#		Select ".crt" as certificate format.
#
#		Set "Target path" to be a SUBFOLDER of the application/service cert folder
#		(e.g. "/etc/nginx/ssl/digicert" - the script promotes the issued files up one level
#		to "/etc/nginx/ssl/" under the filenames given in Parameters #1 and #2).
#
#		Select tickbox for "Run post-delivery scripts".
#
#		Select this script and set parameters as follows:
#			Paramter #1: Name of CRT file the application/service is expecting (e.g. "jenkins.crt")
#			Paramter #2: Name of KEY file the application/service is expecting (e.g. "jenkins.key")
#			Paramter #3: The command or script to run to allow the application/service to use the certificate (e.g. "systemctl restart nginx.service")
#
#		Click "Next" once done.
#
#	Step 3:
#		Review configuration, accept terms-and-conditions, and click on "Submit request"
#
######################################################################################################################

# Configuration
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/var/log/digicert-awr-generic-script.log"
DEFAULT_CRT_MODE="644"   # Fallback mode for new .crt when no existing file to inherit from
DEFAULT_KEY_MODE="600"   # Fallback mode for new .key when no existing file to inherit from

# Function to log messages with timestamp
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# ----------------------------------------------------------------------------
# Capture mode/owner/group from an existing file into prefixed variables.
# Usage: capture_metadata <filepath> <prefix>
# Sets:  <prefix>_EXISTED, <prefix>_MODE, <prefix>_OWNER, <prefix>_GROUP
# ----------------------------------------------------------------------------
capture_metadata() {
    local filepath="$1"
    local prefix="$2"

    if [ -f "$filepath" ]; then
        local mode owner group
        mode=$(stat -c '%a' "$filepath")
        owner=$(stat -c '%U' "$filepath")
        group=$(stat -c '%G' "$filepath")

        # Use printf -v for safe indirect assignment (avoids eval pitfalls)
        printf -v "${prefix}_EXISTED" '%s' "true"
        printf -v "${prefix}_MODE"    '%s' "$mode"
        printf -v "${prefix}_OWNER"   '%s' "$owner"
        printf -v "${prefix}_GROUP"   '%s' "$group"

        log_message "Captured metadata for [$filepath]: mode=$mode, owner=$owner, group=$group"
    else
        printf -v "${prefix}_EXISTED" '%s' "false"
        log_message "No existing file at [$filepath] - default permissions will be applied to the new file"
    fi
}

# ----------------------------------------------------------------------------
# Apply captured metadata to a file, or fall back to a safe default mode if
# there was no pre-existing file to inherit from.
# Usage: apply_metadata <filepath> <prefix> <default_mode>
# Returns 0 on success, 1 on failure.
# ----------------------------------------------------------------------------
apply_metadata() {
    local filepath="$1"
    local prefix="$2"
    local default_mode="$3"

    local existed_var="${prefix}_EXISTED"
    local mode_var="${prefix}_MODE"
    local owner_var="${prefix}_OWNER"
    local group_var="${prefix}_GROUP"

    local existed="${!existed_var}"

    if [ "$existed" = "true" ]; then
        local mode="${!mode_var}"
        local owner="${!owner_var}"
        local group="${!group_var}"

        if ! chmod "$mode" "$filepath"; then
            log_message "ERROR: chmod $mode failed on [$filepath]"
            return 1
        fi
        if ! chown "$owner:$group" "$filepath"; then
            log_message "ERROR: chown $owner:$group failed on [$filepath]"
            return 1
        fi
        log_message "Restored metadata on [$filepath]: mode=$mode, owner=$owner:$group"
    else
        if ! chmod "$default_mode" "$filepath"; then
            log_message "ERROR: chmod $default_mode failed on [$filepath]"
            return 1
        fi
        log_message "Applied default mode [$default_mode] to new file [$filepath] (no prior file to inherit from)"
    fi

    # Verify what we set actually stuck and log it for the audit trail
    local actual_mode actual_owner
    actual_mode=$(stat -c '%a' "$filepath")
    actual_owner=$(stat -c '%U:%G' "$filepath")
    log_message "Verified [$filepath]: mode=$actual_mode, owner=$actual_owner"

    return 0
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
log_message "  DEFAULT_CRT_MODE: $DEFAULT_CRT_MODE"
log_message "  DEFAULT_KEY_MODE: $DEFAULT_KEY_MODE"

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
ARGUMENT_1=$(echo "$ARGS_ARRAY" | awk -F',' '{print $1}' | sed 's/^"//;s/"$//' | tr -d '\r\n')
log_message "ARGUMENT_1 extracted: '$ARGUMENT_1'"
log_message "ARGUMENT_1 length: ${#ARGUMENT_1}"

# Extract Argument_2 - second argument
ARGUMENT_2=$(echo "$ARGS_ARRAY" | awk -F',' '{print $2}' | sed 's/^"//;s/"$//' | tr -d '\r\n')
log_message "ARGUMENT_2 extracted: '$ARGUMENT_2'"
log_message "ARGUMENT_2 length: ${#ARGUMENT_2}"

# Extract Argument_3 - third argument
ARGUMENT_3=$(echo "$ARGS_ARRAY" | awk -F',' '{print $3}' | sed 's/^"//;s/"$//' | tr -d '\r\n')
log_message "ARGUMENT_3 extracted: '$ARGUMENT_3'"
log_message "ARGUMENT_3 length: ${#ARGUMENT_3}"

# Extract Argument_4 - fourth argument
ARGUMENT_4=$(echo "$ARGS_ARRAY" | awk -F',' '{print $4}' | sed 's/^"//;s/"$//' | tr -d '\r\n')
log_message "ARGUMENT_4 extracted: '$ARGUMENT_4'"
log_message "ARGUMENT_4 length: ${#ARGUMENT_4}"

# Extract Argument_5 - fifth argument
ARGUMENT_5=$(echo "$ARGS_ARRAY" | awk -F',' '{print $5}' | sed 's/^"//;s/"$//' | tr -d '\r\n')
log_message "ARGUMENT_5 extracted: '$ARGUMENT_5'"
log_message "ARGUMENT_5 length: ${#ARGUMENT_5}"

# Clean arguments (remove whitespace, newlines, carriage returns)
ARGUMENT_1=$(printf '%s' "$ARGUMENT_1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
ARGUMENT_2=$(printf '%s' "$ARGUMENT_2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
ARGUMENT_3=$(printf '%s' "$ARGUMENT_3" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
ARGUMENT_4=$(printf '%s' "$ARGUMENT_4" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
ARGUMENT_5=$(printf '%s' "$ARGUMENT_5" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')

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
log_message "  Argument 1 (Application Certificate Filename): $ARGUMENT_1"
log_message "  Argument 2 (Application Private Key Filename): $ARGUMENT_2"
log_message "  Argument 3 (Application Restart Command): $ARGUMENT_3"
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
# Utility functions:
#   log_message "text"                          - Write timestamped messages to log file
#   capture_metadata <filepath> <prefix>        - Capture mode/owner/group of a file
#   apply_metadata <filepath> <prefix> <mode>   - Restore captured metadata (or apply default)
#
# Example custom logic:
# ============================================================================

log_message "=========================================="
log_message "Starting custom script section..."
log_message "=========================================="

# Example 1: Copy certificates to web server directory
# if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
#     WEB_CERT_DIR="/etc/nginx/ssl"
#     mkdir -p "$WEB_CERT_DIR"
#     cp "$CRT_FILE_PATH" "$WEB_CERT_DIR/server.crt"
#     cp "$KEY_FILE_PATH" "$WEB_CERT_DIR/server.key"
#     chmod 644 "$WEB_CERT_DIR/server.crt"
#     chmod 600 "$WEB_CERT_DIR/server.key"
#     log_message "Certificates deployed to web server directory: $WEB_CERT_DIR"
# fi

# Example 2: Create PFX/PKCS12 from CRT and KEY
# if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ] && command -v openssl &> /dev/null; then
#     PFX_PASSWORD="changeit"
#     PFX_OUTPUT="${CERT_FOLDER}/certificate.pfx"
#
#     openssl pkcs12 -export \
#         -out "$PFX_OUTPUT" \
#         -inkey "$KEY_FILE_PATH" \
#         -in "$CRT_FILE_PATH" \
#         -passout pass:"$PFX_PASSWORD"
#
#     if [ $? -eq 0 ]; then
#         log_message "PFX file created: $PFX_OUTPUT"
#     else
#         log_message "ERROR: Failed to create PFX file"
#     fi
# fi

# Example 3: Update Apache SSL configuration
# if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
#     APACHE_SSL_CONF="/etc/apache2/sites-available/default-ssl.conf"
#
#     if [ -f "$APACHE_SSL_CONF" ]; then
#         # Backup current configuration
#         cp "$APACHE_SSL_CONF" "${APACHE_SSL_CONF}.backup.$(date +%Y%m%d%H%M%S)"
#
#         # Update certificate paths (requires sed or proper configuration management)
#         # sed -i "s|SSLCertificateFile.*|SSLCertificateFile $CRT_FILE_PATH|" "$APACHE_SSL_CONF"
#         # sed -i "s|SSLCertificateKeyFile.*|SSLCertificateKeyFile $KEY_FILE_PATH|" "$APACHE_SSL_CONF"
#
#         log_message "Apache SSL configuration updated"
#
#         # Test and reload Apache
#         apachectl configtest
#         if [ $? -eq 0 ]; then
#             systemctl reload apache2
#             log_message "Apache reloaded successfully"
#         else
#             log_message "ERROR: Apache configuration test failed"
#         fi
#     fi
# fi

# Example 4: Import to Java keystore
# if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ]; then
#     KEYSTORE_PATH="/path/to/keystore.jks"
#     KEYSTORE_PASS="changeit"
#     ALIAS_NAME="${ARGUMENT_1:-myservice}"  # Use argument 1 as alias or default
#
#     # First create a PKCS12 file
#     TEMP_P12="/tmp/temp_cert.p12"
#     openssl pkcs12 -export \
#         -in "$CRT_FILE_PATH" \
#         -inkey "$KEY_FILE_PATH" \
#         -out "$TEMP_P12" \
#         -passout pass:temppass
#
#     # Import into Java keystore
#     keytool -importkeystore \
#         -srckeystore "$TEMP_P12" \
#         -srcstoretype PKCS12 \
#         -srcstorepass temppass \
#         -destkeystore "$KEYSTORE_PATH" \
#         -deststoretype JKS \
#         -deststorepass "$KEYSTORE_PASS" \
#         -alias "$ALIAS_NAME"
#
#     rm -f "$TEMP_P12"
#     log_message "Certificate imported to Java keystore with alias: $ALIAS_NAME"
# fi

# Example 5: Verify certificate and key match
# if [ -f "$CRT_FILE_PATH" ] && [ -f "$KEY_FILE_PATH" ] && command -v openssl &> /dev/null; then
#     CRT_MODULUS=$(openssl x509 -noout -modulus -in "$CRT_FILE_PATH" | openssl md5)
#     KEY_MODULUS=$(openssl rsa -noout -modulus -in "$KEY_FILE_PATH" | openssl md5)
#
#     if [ "$CRT_MODULUS" == "$KEY_MODULUS" ]; then
#         log_message "SUCCESS: Certificate and private key match"
#     else
#         log_message "ERROR: Certificate and private key DO NOT match!"
#         log_message "Certificate modulus: $CRT_MODULUS"
#         log_message "Key modulus: $KEY_MODULUS"
#     fi
# fi

# Example 6: Send notification based on arguments
# if [ "$ARGUMENT_2" == "notify" ]; then
#     NOTIFICATION_EMAIL="$ARGUMENT_3"  # Email in argument 3
#     HOSTNAME=$(hostname)
#
#     if [ ! -z "$NOTIFICATION_EMAIL" ]; then
#         MESSAGE="Certificate deployed on $HOSTNAME\n"
#         MESSAGE+="Certificate: $CRT_FILE_PATH\n"
#         MESSAGE+="Key: $KEY_FILE_PATH\n"
#         MESSAGE+="Time: $(date)\n"
#
#         echo -e "$MESSAGE" | mail -s "Certificate Deployment - $HOSTNAME" "$NOTIFICATION_EMAIL"
#         log_message "Notification sent to: $NOTIFICATION_EMAIL"
#     fi
# fi

# ADD YOUR CUSTOM LOGIC HERE:
# ----------------------------------------

APP_CERT_FOLDER=$(dirname "$CERT_FOLDER")
APP_CRT_FILE_PATH="${APP_CERT_FOLDER}/${ARGUMENT_1}"
APP_KEY_FILE_PATH="${APP_CERT_FOLDER}/${ARGUMENT_2}"
APP_SERVICE_COMMAND="${ARGUMENT_3}"

# ----------------------------------------------------------------------------
# Capture original permissions/ownership BEFORE any backup or overwrite.
# Must happen before the cp -f operations below so we still have a reference
# to read from.
# ----------------------------------------------------------------------------
log_message "Capturing existing file metadata for permission/ownership preservation..."
capture_metadata "$APP_CRT_FILE_PATH" "CRT"
capture_metadata "$APP_KEY_FILE_PATH" "KEY"

# Backup existing CRT file
if [ -f "$APP_CRT_FILE_PATH" ]; then
	#Create backup with timestamp - use cp -p so the .bak inherits mode/owner/timestamps
     	BACKUP_CRT_FILE=$APP_CRT_FILE_PATH-$(date '+%Y%m%d_%H%M%S').bak
	cp -pf "$APP_CRT_FILE_PATH" "$BACKUP_CRT_FILE"
	log_message "[$APP_CRT_FILE_PATH] CRT file exists. Creating backup: $BACKUP_CRT_FILE"

	# Calculate checksum of files copied
	SRC_HASH=$(sha256sum "$APP_CRT_FILE_PATH" | awk '{print $1}')
	DEST_HASH=$(sha256sum "$BACKUP_CRT_FILE" | awk '{print $1}')

	log_message "Checksum [$APP_CRT_FILE_PATH] = [$SRC_HASH]"
	log_message "Checksum [$BACKUP_CRT_FILE] = [$DEST_HASH]"

	# Verify the copy using checksum
	if [ ! "$SRC_HASH" == "$DEST_HASH" ]; then
	    log_message "Error: Verification check of backup failed. Aborting"
	    exit 2
	fi
	log_message "File copied successfully and verified."
else
	log_message "[$APP_CRT_FILE_PATH] CRT file does NOT exist"
fi

# Backup existing KEY file
if [ -f "$APP_KEY_FILE_PATH" ]; then
	#Create backup with timestamp - use cp -p so the .bak inherits mode/owner/timestamps
     	BACKUP_KEY_FILE=$APP_KEY_FILE_PATH-$(date '+%Y%m%d_%H%M%S').bak
	cp -pf "$APP_KEY_FILE_PATH" "$BACKUP_KEY_FILE"
	log_message "[$APP_KEY_FILE_PATH] Key file exists. Creating backup: $BACKUP_KEY_FILE"

	# Calculate checksum of files copied
	SRC_HASH=$(sha256sum "$APP_KEY_FILE_PATH" | awk '{print $1}')
	DEST_HASH=$(sha256sum "$BACKUP_KEY_FILE" | awk '{print $1}')

	log_message "Checksum [$APP_KEY_FILE_PATH] = [$SRC_HASH]"
	log_message "Checksum [$BACKUP_KEY_FILE] = [$DEST_HASH]"

	# Verify the copy using checksum
	if [ ! "$SRC_HASH" == "$DEST_HASH" ]; then
	    log_message "Error: Verification check of backup failed. Aborting"
	    exit 2
	fi
	log_message "File copied successfully and verified."
else
	log_message "[$APP_KEY_FILE_PATH] Key file does NOT exist"
fi

# Replace CRT with new DigiCert generated one
if [ ! -f "$CRT_FILE_PATH" ]; then
	log_message "DigiCert generated CRT file not found [$CRT_FILE_PATH]"
	log_message "Unable to complete automation - exiting!"
	exit 2
    else
	#Copying DigiCert generated CRT to Application CRT filename and path
	cp -f "$CRT_FILE_PATH" "$APP_CRT_FILE_PATH"
	log_message "DigiCert generated [$CRT_FILE_PATH] copied to [$APP_CRT_FILE_PATH]"
fi

# Calculate checksum of files copied
SRC_HASH=$(sha256sum "$CRT_FILE_PATH" | awk '{print $1}')
DEST_HASH=$(sha256sum "$APP_CRT_FILE_PATH" | awk '{print $1}')

log_message "Checksum [$CRT_FILE_PATH] = [$SRC_HASH]"
log_message "Checksum [$APP_CRT_FILE_PATH] = [$DEST_HASH]"

# Verify the copy using checksum
if [ ! "$SRC_HASH" == "$DEST_HASH" ]; then
    log_message "Error: File copy verification failed."
    exit 2
fi
log_message "CRT file copied successfully and verified."

# Replace KEY with new DigiCert generated one
if [ ! -f "$KEY_FILE_PATH" ]; then
	log_message "DigiCert generated KEY file not found [$KEY_FILE_PATH]"
	log_message "Unable to complete automation - exiting!"
	exit 2
    else
	#Copying DigiCert generated KEY to Application KEY filename and path
	cp -f "$KEY_FILE_PATH" "$APP_KEY_FILE_PATH"
	log_message "DigiCert generated [$KEY_FILE_PATH] copied to [$APP_KEY_FILE_PATH]"
fi

# Calculate checksum of files copied
SRC_HASH=$(sha256sum "$KEY_FILE_PATH" | awk '{print $1}')
DEST_HASH=$(sha256sum "$APP_KEY_FILE_PATH" | awk '{print $1}')

log_message "Checksum [$KEY_FILE_PATH] = [$SRC_HASH]"
log_message "Checksum [$APP_KEY_FILE_PATH] = [$DEST_HASH]"

# Verify the copy using checksum
if [ ! "$SRC_HASH" == "$DEST_HASH" ]; then
    log_message "Error: File copy verification failed."
    exit 2
fi
log_message "File copied successfully and verified."

# ----------------------------------------------------------------------------
# Restore captured permissions/ownership on the newly written files.
# If there was no pre-existing file, fall back to the default modes defined
# at the top of the script (644 for cert, 600 for key).
# ----------------------------------------------------------------------------
log_message "Applying permissions/ownership to newly deployed files..."
if ! apply_metadata "$APP_CRT_FILE_PATH" "CRT" "$DEFAULT_CRT_MODE"; then
    log_message "ERROR: Failed to apply metadata to CRT file. Aborting."
    exit 2
fi
if ! apply_metadata "$APP_KEY_FILE_PATH" "KEY" "$DEFAULT_KEY_MODE"; then
    log_message "ERROR: Failed to apply metadata to KEY file. Aborting."
    exit 2
fi

# ----------------------------------------------------------------------------
# If SELinux is in use, reapply the policy-defined context to the new files.
# restorecon reads from the active policy, which is the correct source of
# truth on RHEL/CentOS/Rocky/Fedora hosts. Silently skipped on systems
# without restorecon.
# ----------------------------------------------------------------------------
if command -v restorecon >/dev/null 2>&1; then
    if restorecon -v "$APP_CRT_FILE_PATH" "$APP_KEY_FILE_PATH" >> "$LOGFILE" 2>&1; then
        log_message "SELinux contexts restored on cert and key files."
    else
        log_message "WARNING: restorecon returned non-zero. Check log for context errors."
    fi
else
    log_message "restorecon not available - skipping SELinux context restoration."
fi

# Function to provide more meaningful error code
describe_exit_code() {
    case "$1" in
        0)   echo "success" ;;
        1)   echo "general error" ;;
        2)   echo "misuse of shell builtins or script-defined failure" ;;
        126) echo "command found but not executable or permission denied" ;;
        127) echo "command not found" ;;
        128) echo "invalid exit argument" ;;
        130) echo "terminated by Ctrl+C / SIGINT" ;;
        137) echo "killed by SIGKILL, often out-of-memory or forced kill" ;;
        143) echo "terminated by SIGTERM" ;;
        *)   echo "application-specific failure" ;;
    esac
}

#Run post update command
if [ -n "$APP_SERVICE_COMMAND" ]; then
    log_message "Running post-update command: $APP_SERVICE_COMMAND"

	command_name=$(printf '%s' "$APP_SERVICE_COMMAND" | awk '{print $1}')

	if ! command -v "$command_name" >/dev/null 2>&1; then
		log_message "ERROR: Command not found: $command_name"
		log_message "Full post-update command was: $APP_SERVICE_COMMAND"
		exit 127
	fi

    command_output=$(bash -c "$APP_SERVICE_COMMAND" 2>&1)
    command_status=$?

    if [ -n "$command_output" ]; then
        log_message "Post-update command output:"
        while IFS= read -r line; do
            log_message "$line"
        done <<< "$command_output"
    fi

    exit_description=$(describe_exit_code "$command_status")

    if [ "$command_status" -eq 0 ]; then
        log_message "Post-update command completed successfully. Exit code: 0 ($exit_description)."
    else
        log_message "ERROR: Post-update command failed. Exit code: $command_status ($exit_description)."
        exit "$command_status"
    fi
fi

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