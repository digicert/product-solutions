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
Export Regulation: The software and related technical data and services (collectively “Controlled Technology”)
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
US Government Restricted Rights: The software is provided with “Restricted Rights,” Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

# Legal notice acceptance variable (user must set to "true" to accept and allow script execution)
LEGAL_NOTICE_ACCEPT="false"  # Change this to "true" to accept the legal notice and run the script

if [[ "${LEGAL_NOTICE_ACCEPT,,}" != "true" ]]; then
    echo "ERROR: You must accept the legal notice by setting LEGAL_NOTICE_ACCEPT=\"true\" in this script to proceed."
    exit 1
fi

LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/mailcow.log"

# Redirect stdout and stderr to the logfile, preserving original output if needed
exec > >(tee -a "$LOGFILE") 2>&1

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

log "===== Script started ====="

# Step 1: Read the Base64-encoded JSON string from the environment variable
if [[ -z "$DC1_POST_SCRIPT_DATA" ]]; then
    log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set."
    exit 1
fi

CERT_INFO="$DC1_POST_SCRIPT_DATA"
log "Decoding base64 JSON string from DC1_POST_SCRIPT_DATA..."
JSON_STRING=$(echo "$CERT_INFO" | base64 -d 2>>"$LOGFILE")
if [[ $? -ne 0 ]]; then
    log "ERROR: Failed to decode base64 string."
    exit 1
fi
log "Decoded JSON: $JSON_STRING"

CERT_FOLDER=$(echo "$JSON_STRING" | grep -oP '"certfolder":"\K[^"]+')
if [[ -z "$CERT_FOLDER" ]]; then
    log "ERROR: Could not extract certfolder from JSON."
    exit 1
fi
log "Certificate folder: $CERT_FOLDER"

# Step 2: Extract the .crt file name
CRT_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.crt')
if [[ -z "$CRT_FILE" ]]; then
    log "ERROR: Could not extract .crt filename from JSON."
    exit 1
fi
log "CRT file: $CRT_FILE"

# Step 3: Extract the .key file name
KEY_FILE=$(echo "$JSON_STRING" | grep -oP '"files":\[\K[^]]*' | grep -oP '[^,"]+\.key')
if [[ -z "$KEY_FILE" ]]; then
    log "ERROR: Could not extract .key filename from JSON."
    exit 1
fi
log "KEY file: $KEY_FILE"

# Step 4: Construct file paths
CRT_FILE_PATH="${CERT_FOLDER}/${CRT_FILE}"
KEY_FILE_PATH="${CERT_FOLDER}/${KEY_FILE}"

log "CRT file path: $CRT_FILE_PATH"
log "KEY file path: $KEY_FILE_PATH"

# Step 5: Backup current certificates
log "Backing up current certificates..."
if ! mv ~/mailcow-dockerized/data/assets/ssl/*.pem /home/ubuntu/ 2>>"$LOGFILE"; then
    log "WARNING: Failed to backup some or all existing certificate files."
else
    log "Backup completed."
fi

# Step 6: Install new certificates
log "Installing new certificates..."
if ! cp "$CRT_FILE_PATH" ~/mailcow-dockerized/data/assets/ssl/cert.pem 2>>"$LOGFILE"; then
    log "ERROR: Failed to copy $CRT_FILE_PATH to cert.pem"
    exit 1
fi

if ! cp "$KEY_FILE_PATH" ~/mailcow-dockerized/data/assets/ssl/key.pem 2>>"$LOGFILE"; then
    log "ERROR: Failed to copy $KEY_FILE_PATH to key.pem"
    exit 1
fi
log "Certificates installed."

# Step 7: Restart Mailcow Webinterface
log "Changing directory to /root/mailcow-dockerized..."
if ! cd /root/mailcow-dockerized 2>>"$LOGFILE"; then
    log "ERROR: Failed to change directory to /root/mailcow-dockerized."
    exit 1
fi

log "Restarting Mailcow nginx-mailcow container..."
if ! docker-compose restart nginx-mailcow 2>>"$LOGFILE"; then
    log "ERROR: Failed to restart nginx-mailcow container."
    exit 1
fi
log "Mailcow nginx-mailcow container restarted successfully."

log "===== Script finished ====="