#!/usr/bin/env bash

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
#
# File encoding: UTF-8 without BOM. The shebang above must be the first
# bytes in the file so the script can be executed directly on Linux.
# Generic DigiCert ONE AWR post-delivery script for a shared combined PEM.
#
# This is an independently reworked derivative of DigiCert's Generic AWR
# PostScript pattern. Review and accept the applicable DigiCert licence and
# legal terms before use.
#
# AWR parameters:
#   1. Destination directory
#   2. Symbolic link filename
#   3. Comma-separated post-completion commands
#
# The DigiCert Agent delivery must contain one .crt or .cer file and one .key
# file. The certificate file may contain the end-entity certificate plus one
# or more chain certificates.
#
# The script creates a versioned combined PEM and atomically points the stable
# filename at it using a symbolic link. Neither the stable filename nor an
# earlier versioned PEM has to exist before the first deployment.
#
# IMPORTANT: Set LEGAL_NOTICE_ACCEPT="true" only after reviewing the script and
# the applicable DigiCert legal terms.
#
######################################################################################################################

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/var/log/digicert-awr-combined-pem.log"
LOCKFILE="/var/lock/digicert-awr-combined-pem.lock"
CREATE_DESTINATION_DIRECTORY="true"
DEFAULT_DIRECTORY_MODE="750"
DEFAULT_PEM_MODE="600"
DEFAULT_PEM_OWNER="root"
DEFAULT_PEM_GROUP="root"
ROLLBACK_ON_COMMAND_FAILURE="true"
RUN_COMMANDS_AFTER_ROLLBACK="true"

# -----------------------------------------------------------------------------
# Runtime state
# -----------------------------------------------------------------------------
TEMP_DIR=""
TARGET_DIR=""
STABLE_NAME=""
STABLE_PATH=""
NEW_ACTUAL_PATH=""
NEW_ACTUAL_NAME=""
STABLE_PATH_UPDATED="false"
DEPLOYMENT_COMPLETE="false"
PREVIOUS_TYPE="absent"
PREVIOUS_LINK_TARGET=""
PREVIOUS_BACKUP_PATH=""
PREVIOUS_MODE=""
PREVIOUS_UID=""
PREVIOUS_GID=""
HAVE_PREVIOUS_METADATA="false"
LOCK_DIR_FALLBACK=""
COMMANDS=()

log_message() {
    local message="$*"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $message"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOGFILE" 2>/dev/null || true
}

cleanup() {
    local rc=$?
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
    if [[ -n "$LOCK_DIR_FALLBACK" && -d "$LOCK_DIR_FALLBACK" ]]; then
        rmdir -- "$LOCK_DIR_FALLBACK" 2>/dev/null || true
    fi
    return "$rc"
}

make_temp_link_path() {
    local candidate
    local counter=0
    while :; do
        candidate="${TARGET_DIR}/.${STABLE_NAME}.linktmp.$$.$counter"
        if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
        counter=$((counter + 1))
    done
}

restore_previous_state() {
    local reason="${1:-rollback requested}"
    local temp_restore

    if [[ "$STABLE_PATH_UPDATED" != "true" || -z "$STABLE_PATH" ]]; then
        return 0
    fi

    log_message "ROLLBACK: Restoring the previous stable path because: $reason"

    case "$PREVIOUS_TYPE" in
        symlink)
            temp_restore=$(make_temp_link_path)
            if ln -s -- "$PREVIOUS_LINK_TARGET" "$temp_restore" && mv -Tf -- "$temp_restore" "$STABLE_PATH"; then
                log_message "ROLLBACK: Restored symlink [$STABLE_PATH] -> [$PREVIOUS_LINK_TARGET]"
            else
                rm -f -- "$temp_restore" 2>/dev/null || true
                log_message "ERROR: ROLLBACK failed while restoring symlink [$STABLE_PATH]"
                return 1
            fi
            ;;
        file)
            if [[ -z "$PREVIOUS_BACKUP_PATH" || ! -f "$PREVIOUS_BACKUP_PATH" ]]; then
                log_message "ERROR: ROLLBACK backup is unavailable for previous regular file [$STABLE_PATH]"
                return 1
            fi
            temp_restore=$(mktemp "${TARGET_DIR}/.${STABLE_NAME}.restore.XXXXXX")
            if cp -p -- "$PREVIOUS_BACKUP_PATH" "$temp_restore" && mv -Tf -- "$temp_restore" "$STABLE_PATH"; then
                log_message "ROLLBACK: Restored previous regular file [$STABLE_PATH] from [$PREVIOUS_BACKUP_PATH]"
            else
                rm -f -- "$temp_restore" 2>/dev/null || true
                log_message "ERROR: ROLLBACK failed while restoring regular file [$STABLE_PATH]"
                return 1
            fi
            ;;
        absent)
            if rm -f -- "$STABLE_PATH"; then
                log_message "ROLLBACK: Removed the newly created stable symlink [$STABLE_PATH]"
            else
                log_message "ERROR: ROLLBACK failed while removing [$STABLE_PATH]"
                return 1
            fi
            ;;
        *)
            log_message "ERROR: ROLLBACK encountered unknown previous type [$PREVIOUS_TYPE]"
            return 1
            ;;
    esac

    STABLE_PATH_UPDATED="false"

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "$STABLE_PATH" >> "$LOGFILE" 2>&1 || true
    fi

    return 0
}

on_unexpected_error() {
    local rc="$1"
    local line="$2"
    trap - ERR
    log_message "ERROR: Unexpected failure at script line [$line], exit code [$rc]"
    if [[ "$STABLE_PATH_UPDATED" == "true" && "$DEPLOYMENT_COMPLETE" != "true" ]]; then
        restore_previous_state "unexpected script error at line $line" || true
    fi
    exit "$rc"
}

fatal() {
    local rc="$1"
    shift
    trap - ERR
    log_message "ERROR: $*"
    if [[ "$STABLE_PATH_UPDATED" == "true" && "$DEPLOYMENT_COMPLETE" != "true" ]]; then
        restore_previous_state "$*" || true
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'on_unexpected_error "$?" "$LINENO"' ERR
trap 'fatal 130 "Script interrupted by signal"' INT TERM HUP

init_logging() {
    local log_dir
    log_dir=$(dirname -- "$LOGFILE")
    mkdir -p -- "$log_dir"
    touch -- "$LOGFILE"
    chmod 600 -- "$LOGFILE" 2>/dev/null || true
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fatal 127 "Required command not found: $command_name"
}

acquire_lock() {
    mkdir -p -- "$(dirname -- "$LOCKFILE")"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCKFILE"
        if ! flock -n 9; then
            fatal 75 "Another combined-PEM deployment is already running"
        fi
        log_message "Acquired deployment lock using flock: $LOCKFILE"
    else
        LOCK_DIR_FALLBACK="${LOCKFILE}.d"
        if ! mkdir -- "$LOCK_DIR_FALLBACK" 2>/dev/null; then
            fatal 75 "Another combined-PEM deployment may already be running: $LOCK_DIR_FALLBACK"
        fi
        log_message "Acquired deployment lock using directory fallback: $LOCK_DIR_FALLBACK"
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

sha256_file() {
    openssl dgst -sha256 -- "$1" | awk '{print $NF}'
}

copy_and_verify() {
    local source="$1"
    local destination="$2"
    local preserve="${3:-false}"
    local source_hash destination_hash

    if [[ "$preserve" == "true" ]]; then
        cp -p -- "$source" "$destination"
    else
        cp -- "$source" "$destination"
    fi

    source_hash=$(sha256_file "$source")
    destination_hash=$(sha256_file "$destination")
    if [[ "$source_hash" != "$destination_hash" ]]; then
        fatal 2 "SHA-256 verification failed copying [$source] to [$destination]"
    fi
    log_message "Verified copy [$source] -> [$destination], SHA-256 [$destination_hash]"
}

unique_backup_path() {
    local base="$1"
    local candidate="$base"
    local counter=0
    while [[ -e "$candidate" || -L "$candidate" ]]; do
        counter=$((counter + 1))
        candidate="${base}.${counter}"
    done
    printf '%s\n' "$candidate"
}

validate_destination_arguments() {
    TARGET_DIR=$(trim "$1")
    STABLE_NAME=$(trim "$2")

    [[ -n "$TARGET_DIR" ]] || fatal 64 "AWR parameter 1 (destination directory) is empty"
    [[ "$TARGET_DIR" == /* ]] || fatal 64 "Destination directory must be an absolute path: [$TARGET_DIR]"
    [[ "$TARGET_DIR" != *$'\n'* && "$TARGET_DIR" != *$'\r'* ]] || fatal 64 "Destination directory contains a newline"

    if [[ ! -e "$TARGET_DIR" ]]; then
        local ancestor="$TARGET_DIR"
        local created_directory
        local index
        local -a created_directories=()

        if [[ "$CREATE_DESTINATION_DIRECTORY" != "true" ]]; then
            fatal 66 "Destination directory does not exist and automatic creation is disabled: [$TARGET_DIR]"
        fi

        while [[ ! -e "$ancestor" ]]; do
            created_directories+=("$ancestor")
            ancestor=$(dirname -- "$ancestor")
        done

        [[ -d "$ancestor" ]] || fatal 73 "Nearest existing parent is not a directory: [$ancestor]"

        if ! mkdir -p -- "$TARGET_DIR"; then
            fatal 73 "Unable to create destination directory: [$TARGET_DIR]"
        fi

        for ((index = ${#created_directories[@]} - 1; index >= 0; index--)); do
            created_directory="${created_directories[index]}"
            chmod -- "$DEFAULT_DIRECTORY_MODE" "$created_directory"
            log_message "Created destination directory [$created_directory] with mode [$DEFAULT_DIRECTORY_MODE]"
        done
    fi

    [[ -d "$TARGET_DIR" ]] || fatal 73 "Destination path is not a directory: [$TARGET_DIR]"
    [[ -w "$TARGET_DIR" ]] || fatal 73 "Destination directory is not writable: [$TARGET_DIR]"

    [[ -n "$STABLE_NAME" ]] || fatal 64 "AWR parameter 2 (stable PEM filename) is empty"
    [[ "$STABLE_NAME" != "." && "$STABLE_NAME" != ".." ]] || fatal 64 "Invalid stable PEM filename: [$STABLE_NAME]"
    [[ "$STABLE_NAME" != */* ]] || fatal 64 "AWR parameter 2 must be a filename only, not a path: [$STABLE_NAME]"
    [[ "$STABLE_NAME" != *$'\n'* && "$STABLE_NAME" != *$'\r'* ]] || fatal 64 "Stable PEM filename contains a newline"

    STABLE_PATH="${TARGET_DIR%/}/${STABLE_NAME}"
    log_message "Destination directory: [$TARGET_DIR]"
    log_message "Stable PEM path: [$STABLE_PATH]"
}

parse_payload_with_awk() {
    local json_file="$1"
    local fields_file="$2"

    awk '
        function fail(message) {
            print "JSON parse error: " message > "/dev/stderr"
            exit 65
        }

        function skip_ws(    c) {
            while (pos <= json_len) {
                c = substr(json_text, pos, 1)
                if (c == " " || c == "\t" || c == "\r" || c == "\n") {
                    pos++
                } else {
                    break
                }
            }
        }

        function parse_string(    c, esc, value) {
            skip_ws()
            if (substr(json_text, pos, 1) != "\"") {
                fail("expected string at character " pos)
            }
            pos++
            value = ""

            while (pos <= json_len) {
                c = substr(json_text, pos, 1)
                pos++

                if (c == "\"") {
                    return value
                }

                if (c == "\\") {
                    if (pos > json_len) {
                        fail("unterminated escape sequence")
                    }
                    esc = substr(json_text, pos, 1)
                    pos++

                    if (esc == "\"" || esc == "\\" || esc == "/") {
                        value = value esc
                    } else if (esc == "b") {
                        value = value sprintf("%c", 8)
                    } else if (esc == "f") {
                        value = value sprintf("%c", 12)
                    } else if (esc == "n") {
                        value = value "\n"
                    } else if (esc == "r") {
                        value = value "\r"
                    } else if (esc == "t") {
                        value = value "\t"
                    } else if (esc == "u") {
                        fail("Unicode \\u escapes are not supported in AWR paths or arguments")
                    } else {
                        fail("invalid escape sequence at character " pos)
                    }
                } else {
                    value = value c
                }
            }

            fail("unterminated string")
        }

        function skip_primitive(    c, start) {
            skip_ws()
            start = pos
            while (pos <= json_len) {
                c = substr(json_text, pos, 1)
                if (c == "," || c == "]" || c == "}" || c == " " || c == "\t" || c == "\r" || c == "\n") {
                    break
                }
                pos++
            }
            if (pos == start) {
                fail("expected value at character " pos)
            }
        }

        function skip_value(    c, key) {
            skip_ws()
            c = substr(json_text, pos, 1)

            if (c == "\"") {
                parse_string()
                return
            }

            if (c == "[") {
                pos++
                skip_ws()
                if (substr(json_text, pos, 1) == "]") {
                    pos++
                    return
                }
                while (1) {
                    skip_value()
                    skip_ws()
                    c = substr(json_text, pos, 1)
                    if (c == ",") {
                        pos++
                        continue
                    }
                    if (c == "]") {
                        pos++
                        return
                    }
                    fail("expected comma or closing bracket at character " pos)
                }
            }

            if (c == "{") {
                pos++
                skip_ws()
                if (substr(json_text, pos, 1) == "}") {
                    pos++
                    return
                }
                while (1) {
                    key = parse_string()
                    skip_ws()
                    if (substr(json_text, pos, 1) != ":") {
                        fail("expected colon at character " pos)
                    }
                    pos++
                    skip_value()
                    skip_ws()
                    c = substr(json_text, pos, 1)
                    if (c == ",") {
                        pos++
                        continue
                    }
                    if (c == "}") {
                        pos++
                        return
                    }
                    fail("expected comma or closing brace at character " pos)
                }
            }

            skip_primitive()
        }

        function parse_string_array(destination,    c, value) {
            skip_ws()
            if (substr(json_text, pos, 1) != "[") {
                fail("expected array at character " pos)
            }
            pos++
            skip_ws()

            if (substr(json_text, pos, 1) == "]") {
                pos++
                return
            }

            while (1) {
                value = parse_string()
                if (destination == "files") {
                    files[++file_count] = value
                } else if (destination == "args") {
                    args[++arg_count] = value
                }

                skip_ws()
                c = substr(json_text, pos, 1)
                if (c == ",") {
                    pos++
                    continue
                }
                if (c == "]") {
                    pos++
                    return
                }
                fail("expected comma or closing bracket at character " pos)
            }
        }

        function reject_controls(value, label) {
            if (value ~ /[[:cntrl:]]/) {
                fail(label " contains a control character")
            }
        }

        BEGIN {
            json_text = ""
            while ((getline line < ARGV[1]) > 0) {
                json_text = json_text line "\n"
            }
            close(ARGV[1])
            ARGC = 1

            json_len = length(json_text)
            pos = 1
            skip_ws()
            if (substr(json_text, pos, 1) != "{") {
                fail("top-level JSON value must be an object")
            }
            pos++

            skip_ws()
            if (substr(json_text, pos, 1) != "}") {
                while (1) {
                    key = parse_string()
                    skip_ws()
                    if (substr(json_text, pos, 1) != ":") {
                        fail("expected colon after object key")
                    }
                    pos++

                    if (key == "certfolder") {
                        certfolder_count++
                        certfolder = parse_string()
                    } else if (key == "files") {
                        files_count++
                        parse_string_array("files")
                    } else if (key == "args") {
                        args_count++
                        parse_string_array("args")
                    } else {
                        skip_value()
                    }

                    skip_ws()
                    c = substr(json_text, pos, 1)
                    if (c == ",") {
                        pos++
                        continue
                    }
                    if (c == "}") {
                        pos++
                        break
                    }
                    fail("expected comma or closing brace at character " pos)
                }
            } else {
                pos++
            }

            skip_ws()
            if (pos <= json_len) {
                remaining = substr(json_text, pos)
                if (remaining !~ /^[[:space:]]*$/) {
                    fail("unexpected data after top-level object")
                }
            }

            if (certfolder_count != 1 || certfolder == "") {
                fail("payload field certfolder is missing, duplicated, or empty")
            }
            if (files_count != 1) {
                fail("payload field files is missing or duplicated")
            }
            if (args_count != 1 || arg_count < 3) {
                fail("payload field args must contain at least three string values")
            }

            for (i = 1; i <= file_count; i++) {
                lower = tolower(files[i])
                if (lower ~ /\.(crt|cer)$/) {
                    crt_count++
                    crt_file = files[i]
                } else if (lower ~ /\.key$/) {
                    key_count++
                    key_file = files[i]
                }
            }

            if (crt_count != 1) {
                fail("expected exactly one .crt or .cer file; found " crt_count)
            }
            if (key_count != 1) {
                fail("expected exactly one .key file; found " key_count)
            }

            reject_controls(certfolder, "certfolder")
            reject_controls(crt_file, "certificate filename")
            reject_controls(key_file, "private-key filename")
            reject_controls(args[1], "AWR parameter 1")
            reject_controls(args[2], "AWR parameter 2")
            reject_controls(args[3], "AWR parameter 3")

            print certfolder
            print crt_file
            print key_file
            print args[1]
            print args[2]
            print args[3]
        }
    ' "$json_file" > "$fields_file"
}

decode_payload() {
    local json_file="$TEMP_DIR/dc1-post-script-data.json"
    local fields_file="$TEMP_DIR/fields.txt"
    local certificate_entry key_entry
    local -a fields

    [[ -n "${DC1_POST_SCRIPT_DATA:-}" ]] || fatal 1 "DC1_POST_SCRIPT_DATA environment variable is not set"

    if ! printf '%s' "$DC1_POST_SCRIPT_DATA" | base64 --decode > "$json_file" 2>> "$LOGFILE"; then
        fatal 65 "Unable to base64-decode DC1_POST_SCRIPT_DATA"
    fi

    if ! parse_payload_with_awk "$json_file" "$fields_file" 2>> "$LOGFILE"; then
        fatal 65 "Unable to parse DC1_POST_SCRIPT_DATA JSON payload using awk"
    fi

    mapfile -t fields < "$fields_file"
    [[ "${#fields[@]}" -eq 6 ]] || fatal 65 "Parsed AWR payload returned an unexpected number of fields"

    CERT_FOLDER="${fields[0]}"
    certificate_entry="${fields[1]}"
    key_entry="${fields[2]}"
    ARGUMENT_1="${fields[3]}"
    ARGUMENT_2="${fields[4]}"
    ARGUMENT_3="${fields[5]}"

    if [[ "$certificate_entry" == /* ]]; then
        CRT_FILE_PATH="$certificate_entry"
    else
        CRT_FILE_PATH="${CERT_FOLDER%/}/$certificate_entry"
    fi

    if [[ "$key_entry" == /* ]]; then
        KEY_FILE_PATH="$key_entry"
    else
        KEY_FILE_PATH="${CERT_FOLDER%/}/$key_entry"
    fi

    log_message "DigiCert delivery directory: [$CERT_FOLDER]"
    log_message "Delivered certificate bundle: [$CRT_FILE_PATH]"
    log_message "Delivered private key: [$KEY_FILE_PATH]"
    log_message "AWR parameter 3 command list: [${ARGUMENT_3:-<empty>}]"
}

parse_command_list() {
    local command_list="$1"
    local buffer=""
    local character
    local command_text
    local index
    local in_single_quote="false"
    local in_double_quote="false"
    local escaped="false"

    COMMANDS=()
    [[ -n "$(trim "$command_list")" ]] || return 0

    for ((index = 0; index < ${#command_list}; index++)); do
        character="${command_list:index:1}"

        if [[ "$in_single_quote" == "true" ]]; then
            buffer+="$character"
            if [[ "$character" == "'" ]]; then
                in_single_quote="false"
            fi
            continue
        fi

        if [[ "$escaped" == "true" ]]; then
            buffer+="$character"
            escaped="false"
            continue
        fi

        if [[ "$character" == "\\" ]]; then
            buffer+="$character"
            escaped="true"
            continue
        fi

        if [[ "$character" == "'" && "$in_double_quote" == "false" ]]; then
            buffer+="$character"
            in_single_quote="true"
            continue
        fi

        if [[ "$character" == '"' ]]; then
            buffer+="$character"
            if [[ "$in_double_quote" == "true" ]]; then
                in_double_quote="false"
            else
                in_double_quote="true"
            fi
            continue
        fi

        if [[ "$character" == "," && "$in_double_quote" == "false" ]]; then
            command_text=$(trim "$buffer")
            [[ -n "$command_text" ]] || fatal 64 "AWR parameter 3 contains an empty command entry"
            COMMANDS+=("$command_text")
            buffer=""
            continue
        fi

        buffer+="$character"
    done

    [[ "$in_single_quote" == "false" ]] || fatal 64 "AWR parameter 3 contains an unmatched single quote"
    [[ "$in_double_quote" == "false" ]] || fatal 64 "AWR parameter 3 contains an unmatched double quote"
    [[ "$escaped" == "false" ]] || fatal 64 "AWR parameter 3 ends with an incomplete escape"

    command_text=$(trim "$buffer")
    [[ -n "$command_text" ]] || fatal 64 "AWR parameter 3 contains an empty trailing command entry"
    COMMANDS+=("$command_text")

    for command_text in "${COMMANDS[@]}"; do
        [[ "$command_text" != *$'\n'* && "$command_text" != *$'\r'* ]] || fatal 64 "Post-completion commands may not contain newline characters"
        log_message "Registered post-completion command: [$command_text]"
    done
}

split_and_validate_certificates() {
    local cert_dir="$TEMP_DIR/certificates"
    local count_file="$cert_dir/count"
    local cert_count
    local cert_file
    local key_pub_hash cert_pub_hash
    local matching_cert=""
    local match_count=0
    local candidate="$TEMP_DIR/combined-candidate.pem"

    mkdir -p -- "$cert_dir"

    [[ -f "$CRT_FILE_PATH" ]] || fatal 66 "Delivered certificate bundle not found: [$CRT_FILE_PATH]"
    [[ -s "$CRT_FILE_PATH" ]] || fatal 65 "Delivered certificate bundle is empty: [$CRT_FILE_PATH]"
    [[ -f "$KEY_FILE_PATH" ]] || fatal 66 "Delivered private key not found: [$KEY_FILE_PATH]"
    [[ -s "$KEY_FILE_PATH" ]] || fatal 65 "Delivered private key is empty: [$KEY_FILE_PATH]"

    if ! openssl pkey -in "$KEY_FILE_PATH" -noout </dev/null >> "$LOGFILE" 2>&1; then
        fatal 65 "Delivered private key is invalid or encrypted; an unencrypted PEM private key is required"
    fi

    if ! awk -v outdir="$cert_dir" '
        /-----BEGIN CERTIFICATE-----/ {
            if (inside) exit 20
            count++
            file=sprintf("%s/cert-%04d.pem", outdir, count)
            inside=1
        }
        inside { print > file }
        /-----END CERTIFICATE-----/ {
            if (!inside) exit 21
            close(file)
            inside=0
        }
        END {
            if (inside) exit 22
            if (count == 0) exit 23
            print count > (outdir "/count")
        }
    ' "$CRT_FILE_PATH"; then
        fatal 65 "Delivered certificate bundle does not contain well-formed PEM certificate blocks"
    fi

    cert_count=$(cat -- "$count_file")
    log_message "Delivered certificate bundle contains [$cert_count] certificate(s)"

    if ! key_pub_hash=$(openssl pkey -in "$KEY_FILE_PATH" -pubout -outform DER 2>> "$LOGFILE" | openssl dgst -sha256 2>> "$LOGFILE" | awk '{print $NF}'); then
        fatal 65 "Unable to calculate the delivered private key public-key hash"
    fi

    for cert_file in "$cert_dir"/cert-*.pem; do
        if ! openssl x509 -in "$cert_file" -noout >> "$LOGFILE" 2>&1; then
            fatal 65 "Invalid X.509 certificate block detected: [$cert_file]"
        fi
        if ! cert_pub_hash=$(openssl x509 -in "$cert_file" -pubkey -noout 2>> "$LOGFILE" | openssl pkey -pubin -outform DER 2>> "$LOGFILE" | openssl dgst -sha256 2>> "$LOGFILE" | awk '{print $NF}'); then
            fatal 65 "Unable to calculate public-key hash for certificate block [$cert_file]"
        fi
        if [[ "$cert_pub_hash" == "$key_pub_hash" ]]; then
            matching_cert="$cert_file"
            match_count=$((match_count + 1))
        fi
    done

    [[ "$match_count" -eq 1 ]] || fatal 65 "Expected exactly one certificate matching the private key; found [$match_count]"

    : > "$candidate"
    cat -- "$matching_cert" >> "$candidate"
    printf '\n' >> "$candidate"
    for cert_file in "$cert_dir"/cert-*.pem; do
        if [[ "$cert_file" != "$matching_cert" ]]; then
            cat -- "$cert_file" >> "$candidate"
            printf '\n' >> "$candidate"
        fi
    done
    cat -- "$KEY_FILE_PATH" >> "$candidate"
    printf '\n' >> "$candidate"

    CANDIDATE_PEM="$candidate"
    LEAF_CERT_FILE="$matching_cert"
    CERTIFICATE_COUNT="$cert_count"

    local pem_cert_count pem_key_count
    pem_cert_count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$CANDIDATE_PEM" || true)
    pem_key_count=$(grep -Ec -- '-----BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY-----' "$CANDIDATE_PEM" || true)
    [[ "$pem_cert_count" -eq "$CERTIFICATE_COUNT" ]] || fatal 65 "Combined PEM certificate count verification failed"
    [[ "$pem_key_count" -eq 1 ]] || fatal 65 "Combined PEM must contain exactly one private key; found [$pem_key_count]"

    local subject serial not_before not_after fingerprint
    subject=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -subject -nameopt RFC2253 2>> "$LOGFILE")
    serial=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -serial 2>> "$LOGFILE")
    not_before=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -startdate 2>> "$LOGFILE")
    not_after=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -enddate 2>> "$LOGFILE")
    fingerprint=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -fingerprint -sha256 2>> "$LOGFILE")

    log_message "Matched end-entity certificate: [$subject]"
    log_message "Matched end-entity certificate: [$serial]"
    log_message "Matched end-entity certificate: [$not_before]"
    log_message "Matched end-entity certificate: [$not_after]"
    log_message "Matched end-entity certificate: [$fingerprint]"
    log_message "Combined PEM order validated as: matching end-entity certificate, remaining chain, private key"
}

capture_previous_state() {
    local timestamp="$1"
    local metadata_source=""
    local backup_base

    if [[ -L "$STABLE_PATH" ]]; then
        PREVIOUS_TYPE="symlink"
        PREVIOUS_LINK_TARGET=$(readlink -- "$STABLE_PATH")
        backup_base="${STABLE_PATH}-${timestamp}.link.bak"
        PREVIOUS_BACKUP_PATH=$(unique_backup_path "$backup_base")
        ln -s -- "$PREVIOUS_LINK_TARGET" "$PREVIOUS_BACKUP_PATH"
        log_message "Backed up existing symlink as [$PREVIOUS_BACKUP_PATH] -> [$PREVIOUS_LINK_TARGET]"
        metadata_source=$(readlink -f -- "$STABLE_PATH" 2>/dev/null || true)
        if [[ -z "$metadata_source" || ! -f "$metadata_source" ]]; then
            log_message "WARNING: Existing symlink is broken or does not resolve to a regular file; default PEM metadata will be used"
            metadata_source=""
        fi
    elif [[ -e "$STABLE_PATH" ]]; then
        [[ -f "$STABLE_PATH" ]] || fatal 73 "Existing stable path is not a regular file or symlink: [$STABLE_PATH]"
        PREVIOUS_TYPE="file"
        backup_base="${STABLE_PATH}-${timestamp}.bak"
        PREVIOUS_BACKUP_PATH=$(unique_backup_path "$backup_base")
        copy_and_verify "$STABLE_PATH" "$PREVIOUS_BACKUP_PATH" "true"
        log_message "Backed up existing regular PEM file to [$PREVIOUS_BACKUP_PATH]"
        metadata_source="$STABLE_PATH"
    else
        PREVIOUS_TYPE="absent"
        log_message "No existing stable file or symlink found at [$STABLE_PATH]; proceeding with first deployment"
    fi

    if [[ -n "$metadata_source" ]]; then
        PREVIOUS_MODE=$(stat -c '%a' -- "$metadata_source")
        PREVIOUS_UID=$(stat -c '%u' -- "$metadata_source")
        PREVIOUS_GID=$(stat -c '%g' -- "$metadata_source")
        HAVE_PREVIOUS_METADATA="true"
        log_message "Captured existing PEM metadata: mode=[$PREVIOUS_MODE], uid=[$PREVIOUS_UID], gid=[$PREVIOUS_GID]"
    else
        HAVE_PREVIOUS_METADATA="false"
        log_message "Using default PEM metadata: mode=[$DEFAULT_PEM_MODE], owner=[$DEFAULT_PEM_OWNER:$DEFAULT_PEM_GROUP]"
    fi
}

build_versioned_filename() {
    local timestamp="$1"
    local fingerprint stem extension

    fingerprint=$(openssl x509 -in "$LEAF_CERT_FILE" -noout -fingerprint -sha256 | awk -F= '{print $2}')
    fingerprint="${fingerprint//:/}"
    fingerprint="${fingerprint,,}"
    fingerprint="${fingerprint:0:12}"

    if [[ "$STABLE_NAME" == *.* && "$STABLE_NAME" != .* ]]; then
        stem="${STABLE_NAME%.*}"
        extension=".${STABLE_NAME##*.}"
    else
        stem="$STABLE_NAME"
        extension=""
    fi

    NEW_ACTUAL_NAME="${stem}-${timestamp}-${fingerprint}${extension}"
    NEW_ACTUAL_PATH="${TARGET_DIR%/}/${NEW_ACTUAL_NAME}"

    if [[ -e "$NEW_ACTUAL_PATH" || -L "$NEW_ACTUAL_PATH" ]]; then
        fatal 73 "Versioned PEM destination already exists: [$NEW_ACTUAL_PATH]"
    fi
}

apply_pem_metadata() {
    local file="$1"
    if [[ "$HAVE_PREVIOUS_METADATA" == "true" ]]; then
        chmod -- "$PREVIOUS_MODE" "$file"
        chown -- "$PREVIOUS_UID:$PREVIOUS_GID" "$file"
    else
        chmod -- "$DEFAULT_PEM_MODE" "$file"
        chown -- "$DEFAULT_PEM_OWNER:$DEFAULT_PEM_GROUP" "$file"
    fi

    log_message "Applied PEM metadata to [$file]: mode=[$(stat -c '%a' -- "$file")], owner=[$(stat -c '%U:%G' -- "$file")]"
}

deploy_versioned_pem() {
    local temp_actual
    local temp_link
    local source_hash destination_hash

    temp_actual=$(mktemp "${TARGET_DIR}/.${STABLE_NAME}.pemtmp.XXXXXX")
    copy_and_verify "$CANDIDATE_PEM" "$temp_actual" "false"
    apply_pem_metadata "$temp_actual"

    mv -- "$temp_actual" "$NEW_ACTUAL_PATH"
    source_hash=$(sha256_file "$CANDIDATE_PEM")
    destination_hash=$(sha256_file "$NEW_ACTUAL_PATH")
    [[ "$source_hash" == "$destination_hash" ]] || fatal 2 "Versioned PEM verification failed after final move"
    log_message "Created versioned combined PEM [$NEW_ACTUAL_PATH], SHA-256 [$destination_hash]"

    if command -v restorecon >/dev/null 2>&1; then
        if restorecon -v "$NEW_ACTUAL_PATH" >> "$LOGFILE" 2>&1; then
            log_message "Restored SELinux context on [$NEW_ACTUAL_PATH]"
        else
            log_message "WARNING: restorecon returned non-zero for [$NEW_ACTUAL_PATH]"
        fi
    fi

    temp_link=$(make_temp_link_path)
    ln -s -- "$NEW_ACTUAL_NAME" "$temp_link"
    mv -Tf -- "$temp_link" "$STABLE_PATH"
    STABLE_PATH_UPDATED="true"

    [[ -L "$STABLE_PATH" ]] || fatal 2 "Stable PEM path is not a symlink after deployment: [$STABLE_PATH]"
    [[ "$(readlink -- "$STABLE_PATH")" == "$NEW_ACTUAL_NAME" ]] || fatal 2 "Stable symlink target verification failed"
    [[ "$(readlink -f -- "$STABLE_PATH")" == "$(readlink -f -- "$NEW_ACTUAL_PATH")" ]] || fatal 2 "Stable symlink does not resolve to the new versioned PEM"

    log_message "Atomically updated symlink [$STABLE_PATH] -> [$NEW_ACTUAL_NAME]"

    if command -v restorecon >/dev/null 2>&1; then
        restorecon -v "$STABLE_PATH" >> "$LOGFILE" 2>&1 || log_message "WARNING: restorecon returned non-zero for [$STABLE_PATH]"
    fi
}

run_one_command() {
    local phase="$1"
    local command_text="$2"
    local output_file="$TEMP_DIR/command-output.log"
    local rc
    local line

    : > "$output_file"
    log_message "$phase command starting: [$command_text]"
    if bash -c -- "$command_text" > "$output_file" 2>&1; then
        rc=0
    else
        rc=$?
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        log_message "$phase command output: $line"
    done < "$output_file"

    if [[ "$rc" -eq 0 ]]; then
        log_message "$phase command completed successfully: [$command_text]"
    else
        log_message "ERROR: $phase command failed with exit code [$rc]: [$command_text]"
    fi
    return "$rc"
}

run_post_completion_commands() {
    local command_text
    local rc

    if [[ "${#COMMANDS[@]}" -eq 0 ]]; then
        log_message "No post-completion commands were supplied"
        return 0
    fi

    for command_text in "${COMMANDS[@]}"; do
        if run_one_command "Post-completion" "$command_text"; then
            continue
        else
            rc=$?
        fi

        if [[ "$ROLLBACK_ON_COMMAND_FAILURE" == "true" ]]; then
            restore_previous_state "post-completion command failed with exit code $rc" || true

            if [[ "$RUN_COMMANDS_AFTER_ROLLBACK" == "true" && "$PREVIOUS_TYPE" != "absent" ]]; then
                log_message "Attempting configured commands again after rollback so consumers can reload the previous PEM"
                for command_text in "${COMMANDS[@]}"; do
                    run_one_command "Rollback recovery" "$command_text" || true
                done
            elif [[ "$PREVIOUS_TYPE" == "absent" ]]; then
                log_message "No earlier stable PEM existed, so commands will not be repeated after rollback"
            fi
        fi

        return "$rc"
    done

    return 0
}

main() {
    local timestamp
    local command_status

    init_logging
    log_message "============================================================"
    log_message "Starting DigiCert AWR combined-PEM symlink deployment"
    log_message "============================================================"

    [[ "$LEGAL_NOTICE_ACCEPT" == "true" ]] || fatal 1 "Legal notice not accepted. Review the script, then set LEGAL_NOTICE_ACCEPT=\"true\""

    require_command base64
    require_command openssl
    require_command awk
    require_command stat
    require_command mktemp
    require_command ln
    require_command mv
    require_command readlink
    require_command grep
    require_command cp
    require_command chmod
    require_command chown
    require_command mkdir
    require_command rm
    require_command rmdir
    require_command cat
    require_command dirname
    require_command touch
    require_command date

    acquire_lock
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/digicert-awr-combined-pem.XXXXXX")

    decode_payload
    validate_destination_arguments "$ARGUMENT_1" "$ARGUMENT_2"
    parse_command_list "$ARGUMENT_3"
    split_and_validate_certificates

    timestamp=$(date '+%Y%m%d_%H%M%S')
    capture_previous_state "$timestamp"
    build_versioned_filename "$timestamp"
    deploy_versioned_pem

    if run_post_completion_commands; then
        command_status=0
    else
        command_status=$?
    fi

    if [[ "$command_status" -ne 0 ]]; then
        fatal "$command_status" "Deployment was rolled back because a post-completion command failed"
    fi

    DEPLOYMENT_COMPLETE="true"
    log_message "Deployment completed successfully"
    log_message "Active stable symlink: [$STABLE_PATH] -> [$NEW_ACTUAL_NAME]"
    log_message "Versioned combined PEM: [$NEW_ACTUAL_PATH]"
    log_message "============================================================"
}

main "$@"
exit 0
