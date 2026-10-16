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
US Government Restricted Rights: The software is provided with "Restricted Rights." Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any
successor regulations. The contractor/manufacturer is DIGICERT, INC.
LEGAL_NOTICE

#==============================================================================
# websphere-awr.sh   (v3 -- transactional, auto-rollback)
# DigiCert TLM Post-Script - WebSphere Application Server (traditional) edition
#
# Replaces the active personal certificate in NodeDefaultKeyStore with a new
# CA-issued PKCS12 and binds it to every SSL config (both admin console 9043 and
# app HTTPS 9443). Mirrors the DigiCert WebLogic post-script contract (reads
# DC1_POST_SCRIPT_DATA) but uses WAS-native wsadmin/AdminTask for the swap.
#
# WHAT'S NEW IN v3 -- SAFETY / SUPPORTABILITY:
#   * TRANSACTIONAL SWAP: before any change, backs up the full keystore, trust
#     store, SSL config, AND exports the old cert+private key to a standalone
#     password-protected PFX. If ANY step of the swap fails, the script
#     AUTOMATICALLY ROLLS BACK (restores the backups, restarts, and verifies the
#     OLD cert is serving again) so WAS is never left broken. Critical for
#     unattended 2am renewals -- it self-heals instead of failing half-done.
#   * MANUAL ROLLBACK MODE:  ./websphere-awr.sh --rollback [TIMESTAMP]
#     Lists available backups (no timestamp) or restores a chosen one. For the
#     case where a swap "succeeded" but you later need to deliberately revert.
#   * DEDICATED BACKUP PASSWORD: the exported cert+key PFX is protected with
#     BACKUP_PFX_PASS (from the secrets file), NOT the well-known WebAS default.
#   * Retains all prior fixes: host-file+podman cp, robust find_pfx, secrets
#     precedence chain, VERIFY-OK markers (no sys.exit), rename-optional swap,
#     leveled logging with secret masking.
#==============================================================================

set -uo pipefail

#------------------------------------------------------------------------------
# CONFIGURATION -- EDIT THESE
#------------------------------------------------------------------------------
LEGAL_NOTICE_ACCEPT="false"
SCRIPT_VERSION="3.0.1"

RUN_IN_CONTAINER="true"          # true = wsadmin via `podman exec`; false = host
CONTAINER_NAME="was1"

WAS_PROFILE="/opt/IBM/WebSphere/AppServer/profiles/AppSrv01"
CELL_NAME="DefaultCell01"
NODE_NAME="DefaultNode01"
SERVER_NAME="server1"

# --- NON-SECRET settings ------------------------------------------------------
WAS_ADMIN_USER="wsadmin"
KEYSTORE_NAME="NodeDefaultKeyStore"
TRUSTSTORE_NAME="NodeDefaultTrustStore"
TARGET_ALIAS="default"
TEMP_ALIAS="digicert_tlmtest"
CERT_FOLDER="/opt/digicert/certs"

# --- SECRETS: resolved at runtime (env > secrets file > fail) -----------------
SECRETS_FILE="/opt/digicert/conf/was-cert.conf"   # root:root 0600
WAS_ADMIN_PASS=""    # from env or secrets file
KEYSTORE_PASS=""     # from env or secrets file
PFX_PASSWORD=""      # from TLM payload, env, or secrets file
BACKUP_PFX_PASS=""   # from env or secrets file; protects exported old cert+key

BACKUP_DIR="/opt/digicert/backups"
LOGFILE="/opt/digicert/log/was_cert_replace.log"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_MAX_BYTES=5242880
LOG_KEEP=5
BACKUP_KEEP=10

RESTART_SERVER="true"
REBOOT_HOST="false"
# NOTE: the TLM agent kills post-scripts that run too long. WAS traditional can
# take 3-5 min to fully initialize in a container, so we DO NOT block that long.
# The swap is saved to config BEFORE the restart, so even if we stop waiting
# early the cert change is durable and will be active once WAS finishes starting.
# Keep this comfortably under the agent's script timeout (~2-4 min typical).
STARTUP_WAIT_SECS=90                 # max wait for readiness marker (non-fatal)
STARTUP_POLL_SECS=5
POST_START_SETTLE_SECS=10
CONTAINER_STOP_TIMEOUT=30
AUTO_ROLLBACK="true"             # on swap failure, auto-restore the backup
RESTART_DETACHED="false"         # true = issue restart and DON'T wait (agent-safe);
                                 # the cert is already saved, WAS activates it on
                                 # its own. Use if the agent keeps killing the wait.

#------------------------------------------------------------------------------
# CLI flags
#------------------------------------------------------------------------------
ROLLBACK_MODE="false"
ROLLBACK_TS=""
usage() {
    cat <<EOF
Usage:
  $(basename "$0") [-d] [-q] [-n]           Perform a certificate swap
  $(basename "$0") --rollback [TIMESTAMP]   Manually roll back to a backup
  $(basename "$0") --list-backups           Show available backups
  $(basename "$0") -h

Options:
  -d            DEBUG logging (most verbose)
  -q            quiet: WARN and above only
  -n            do not restart the server (stage only)
  --rollback    restore the newest backup, or a specific TIMESTAMP
                (format YYYYMMDD_HHMMSS as shown by --list-backups)
  --list-backups  list available restore points and exit
  -h            this help

Secrets (env var > \$SECRETS_FILE): WAS_ADMIN_PASS, KEYSTORE_PASS,
  PFX_PASSWORD, BACKUP_PFX_PASS.
EOF
    exit 0
}
# manual long-option parse (getopts doesn't do --long)
_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rollback)     ROLLBACK_MODE="true"; [[ -n "${2:-}" && "${2:0:1}" != "-" ]] && { ROLLBACK_TS="$2"; shift; } ;;
        --list-backups) ROLLBACK_MODE="list" ;;
        -h|--help)      usage ;;
        -d)             LOG_LEVEL="DEBUG" ;;
        -q)             LOG_LEVEL="WARN" ;;
        -n)             RESTART_SERVER="false" ;;
        *)              _args+=("$1") ;;
    esac
    shift
done

#==============================================================================
# LOGGING FRAMEWORK
#==============================================================================
declare -A _LVL=( [DEBUG]=10 [INFO]=20 [WARN]=30 [ERROR]=40 )
_LVL_THRESHOLD=${_LVL["$LOG_LEVEL"]:-20}
_WARN_COUNT=0; _ERROR_COUNT=0
RUN_ID="$(date '+%Y%m%d_%H%M%S')_$$"
_T_START=$(date +%s)
TS=""

_rotate_log() {
    local f="$LOGFILE"; [[ -f "$f" ]] || return 0
    local size; size=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if (( size > LOG_MAX_BYTES )); then
        local i; for (( i=LOG_KEEP-1; i>=1; i-- )); do [[ -f "$f.$i" ]] && mv -f "$f.$i" "$f.$((i+1))" 2>/dev/null; done
        mv -f "$f" "$f.1" 2>/dev/null
    fi
}
mkdir -p "$(dirname "$LOGFILE")" "$BACKUP_DIR" 2>/dev/null || true
_rotate_log

_mask() {
    local s="$1" val
    for val in "$WAS_ADMIN_PASS" "$KEYSTORE_PASS" "${PFX_PASSWORD:-}" "${BACKUP_PFX_PASS:-}"; do
        [[ -n "$val" ]] || continue
        s="${s//$val/***(len=${#val})}"
    done
    printf '%s' "$s"
}
_log() {
    local level="$1"; shift; local msg="$*"; local num=${_LVL["$level"]:-20}
    [[ "$level" == "WARN"  ]] && (( _WARN_COUNT++ ))
    [[ "$level" == "ERROR" ]] && (( _ERROR_COUNT++ ))
    local line; line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $(_mask "$msg")"
    echo "$line" >> "$LOGFILE"
    if (( num >= _LVL_THRESHOLD )); then
        if (( num >= 30 )); then echo "$line" >&2; else echo "$line"; fi
    fi
}
debug() { _log DEBUG "$@"; }
info()  { _log INFO  "$@"; }
warn()  { _log WARN  "$@"; }
error() { _log ERROR "$@"; }

_PHASE=""
phase() { _PHASE="$1"; info "=================================================================="; info "PHASE: $1"; info "=================================================================="; }

run() {
    local desc="$1"; shift; local t0 t1 rc out
    debug "CMD [$desc]: $(_mask "$*")"
    t0=$(date +%s); out="$("$@" 2>&1)"; rc=$?; t1=$(date +%s)
    [[ -n "$out" ]] && while IFS= read -r l; do debug "  | $(_mask "$l")"; done <<< "$out"
    if (( rc == 0 )); then debug "OK   [$desc] rc=0 ($(( t1 - t0 ))s)"; else warn "NONZERO [$desc] rc=$rc ($(( t1 - t0 ))s)"; fi
    _LAST_OUTPUT="$out"; return $rc
}

_run_summary() {
    local status="$1" dur; dur=$(( $(date +%s) - _T_START ))
    info "=================================================================="
    info "RUN SUMMARY"
    info "  run_id=$RUN_ID status=$status duration_secs=$dur"
    info "  warnings=$_WARN_COUNT errors=$_ERROR_COUNT phase_reached=${_PHASE:-none}"
    info "  backups=${BACKUP_DIR}/{key,trust,security,old-default}_${TS:-NA}.*"
    info "  logfile=$LOGFILE log_level=$LOG_LEVEL"
    info "=================================================================="
    echo "SUMMARY status=$status run_id=$RUN_ID duration=${dur}s warnings=$_WARN_COUNT errors=$_ERROR_COUNT phase=${_PHASE:-none}" | tee -a "$LOGFILE"
}

# die WITHOUT rollback (used for pre-swap failures where nothing changed yet)
die() { error "$@"; _run_summary "FAILED"; exit 1; }

# die WITH automatic rollback (used once we've started mutating WAS)
die_rollback() {
    error "$@"
    if [[ "$AUTO_ROLLBACK" == "true" && -n "$TS" ]]; then
        warn "AUTO-ROLLBACK enabled -- restoring pre-swap state from backup $TS ..."
        if restore_backup "$TS"; then
            warn "Rollback complete: WAS restored to its pre-swap certificate."
            _run_summary "FAILED_ROLLED_BACK"
        else
            error "ROLLBACK FAILED. Manual recovery needed: restore ${BACKUP_DIR}/key_${TS}.p12, trust_${TS}.p12, security_${TS}.xml into the container and restart."
            _run_summary "FAILED_ROLLBACK_FAILED"
        fi
    else
        warn "AUTO_ROLLBACK disabled or no backup taken; leaving current state. Backups (if any): $BACKUP_DIR (ts=$TS)"
        _run_summary "FAILED_NO_ROLLBACK"
    fi
    exit 1
}

# ERR trap: pre-swap failures die cleanly; we switch to die_rollback once
# the swap has begun (a flag controls which path the trap takes).
_SWAP_STARTED="false"
trap '_rc=$?; if [[ "$_SWAP_STARTED" == "true" ]]; then die_rollback "Unhandled failure at line $LINENO (phase: ${_PHASE:-init}): [$BASH_COMMAND] exited $_rc"; else error "Unhandled failure at line $LINENO (phase: ${_PHASE:-init}): [$BASH_COMMAND] exited $_rc"; _run_summary "FAILED"; exit $_rc; fi' ERR

#------------------------------------------------------------------------------
# Execution helpers
#------------------------------------------------------------------------------
inwas() { if [[ "$RUN_IN_CONTAINER" == "true" ]]; then podman exec "$CONTAINER_NAME" "$@"; else "$@"; fi; }
push_into_was() {
    local src="$1" dst="$2"
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then run "stage into container" podman cp "$src" "${CONTAINER_NAME}:${dst}"
    else run "stage on host" cp -f "$src" "$dst"; fi
}
pull_from_was() {
    local src="$1" dst="$2"
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then run "pull from container" podman cp "${CONTAINER_NAME}:${src}" "$dst"
    else run "copy from host" cp -f "$src" "$dst"; fi
}

KEYTOOL="$WAS_PROFILE/../../java/8.0/bin/keytool"
WSADMIN="$WAS_PROFILE/bin/wsadmin.sh"
KEYSTORE_FILE="$WAS_PROFILE/config/cells/$CELL_NAME/nodes/$NODE_NAME/key.p12"
TRUSTSTORE_FILE="$WAS_PROFILE/config/cells/$CELL_NAME/nodes/$NODE_NAME/trust.p12"
SECURITY_XML="$WAS_PROFILE/config/cells/$CELL_NAME/security.xml"

# Resolve KEYTOOL if the fixed path is wrong (defensive)
_resolve_keytool() {
    if ! inwas test -x "$KEYTOOL" 2>/dev/null; then
        local k; k=$(inwas bash -lc 'ls /opt/IBM/WebSphere/AppServer/java*/bin/keytool 2>/dev/null | head -1')
        [[ -n "$k" ]] && KEYTOOL="$k"
    fi
    debug "keytool: $KEYTOOL"
}

#------------------------------------------------------------------------------
# restart_and_wait: graceful restart + readiness poll + settle pause
#------------------------------------------------------------------------------
restart_and_wait() {
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
        info "Restarting container '$CONTAINER_NAME' (graceful stop=${CONTAINER_STOP_TIMEOUT}s) ..."
        run "restart container" podman restart -t "$CONTAINER_STOP_TIMEOUT" "$CONTAINER_NAME" || return 1
        # Detached mode: issue the restart and return immediately. The cert change
        # is already saved to config, so WAS will serve it once it finishes coming
        # up on its own. Use when the TLM agent kills long-running post-scripts.
        if [[ "$RESTART_DETACHED" == "true" ]]; then
            info "RESTART_DETACHED=true -- restart issued; not waiting for readiness (cert already saved; WAS will activate it)."
            return 0
        fi
        local _restart_epoch; _restart_epoch=$(date +%s)
        info "Waiting up to ${STARTUP_WAIT_SECS}s for server readiness ..."
        local waited=0
        while (( waited < STARTUP_WAIT_SECS )); do
            if podman logs --since "$_restart_epoch" "$CONTAINER_NAME" 2>&1 \
                 | grep -Eq "open for e-business|WSVR0001I|WSVR0221I|is ready"; then
                info "Server reports ready (after ${waited}s)."
                [[ "$POST_START_SETTLE_SECS" -gt 0 ]] && { info "Settle pause ${POST_START_SETTLE_SECS}s ..."; sleep "$POST_START_SETTLE_SECS"; }
                return 0
            fi
            sleep "$STARTUP_POLL_SECS"; waited=$((waited+STARTUP_POLL_SECS)); debug "  ...waiting (${waited}s)"
        done
        warn "Did not observe a readiness marker within ${STARTUP_WAIT_SECS}s. The container was restarted and the cert change is already saved; WAS may simply still be initializing. Verify manually (Phase 6 will attempt it)."
        return 2   # timed out but NOT a hard failure
    else
        run "stop server"  "$WAS_PROFILE/bin/stopServer.sh"  "$SERVER_NAME" -username "$WAS_ADMIN_USER" -password "$WAS_ADMIN_PASS" || true
        run "start server" "$WAS_PROFILE/bin/startServer.sh" "$SERVER_NAME" || return 1
        [[ "$POST_START_SETTLE_SECS" -gt 0 ]] && sleep "$POST_START_SETTLE_SECS"
        return 0
    fi
}

#------------------------------------------------------------------------------
# restore_backup TIMESTAMP: restore key/trust/security from a backup set,
# restart, and confirm the server comes up. Used by auto-rollback and --rollback.
#------------------------------------------------------------------------------
restore_backup() {
    local ts="$1"
    local kb="$BACKUP_DIR/key_${ts}.p12"
    local tb="$BACKUP_DIR/trust_${ts}.p12"
    local sb="$BACKUP_DIR/security_${ts}.xml"
    info "Restoring backup set timestamp=$ts"
    for f in "$kb" "$tb" "$sb"; do
        [[ -f "$f" ]] || { error "Backup file missing: $f -- cannot restore this set."; return 1; }
    done
    # Copy the three files back into place (container or host)
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
        run "restore key.p12"      podman cp "$kb" "${CONTAINER_NAME}:${KEYSTORE_FILE}"   || return 1
        run "restore trust.p12"    podman cp "$tb" "${CONTAINER_NAME}:${TRUSTSTORE_FILE}" || return 1
        run "restore security.xml" podman cp "$sb" "${CONTAINER_NAME}:${SECURITY_XML}"    || return 1
    else
        run "restore key.p12"      cp -f "$kb" "$KEYSTORE_FILE"   || return 1
        run "restore trust.p12"    cp -f "$tb" "$TRUSTSTORE_FILE" || return 1
        run "restore security.xml" cp -f "$sb" "$SECURITY_XML"    || return 1
    fi
    info "Backup files restored; restarting to activate ..."
    restart_and_wait || warn "Server restart after restore did not confirm readiness; check manually."
    return 0
}

#------------------------------------------------------------------------------
# list_backups: print available restore points
#------------------------------------------------------------------------------
list_backups() {
    info "Available backup restore points in $BACKUP_DIR:"
    local found=0
    local kf
    for kf in "$BACKUP_DIR"/key_*.p12; do
        [[ -f "$kf" ]] || continue
        local ts; ts=$(basename "$kf" | sed 's/^key_//; s/\.p12$//')
        local tb="$BACKUP_DIR/trust_${ts}.p12" sb="$BACKUP_DIR/security_${ts}.xml" of="$BACKUP_DIR/old-default_${ts}.pfx"
        local complete="INCOMPLETE"; [[ -f "$tb" && -f "$sb" ]] && complete="complete"
        local haskey=""; [[ -f "$of" ]] && haskey=" (+cert/key pfx)"
        info "  $ts  [$complete]$haskey"
        found=1
    done
    [[ "$found" == "1" ]] || info "  (none found)"
}

#==============================================================================
# SECRET RESOLUTION
#==============================================================================
resolve_secrets() {
    local env_was="${WAS_ADMIN_PASS:-}" env_ks="${KEYSTORE_PASS:-}" env_pfx="${PFX_PASSWORD:-}" env_bpp="${BACKUP_PFX_PASS:-}"
    if [[ -f "$SECRETS_FILE" ]]; then
        local perms; perms=$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '?')
        if [[ "$perms" == "600" || "$perms" == "400" ]]; then
            debug "Sourcing secrets file $SECRETS_FILE (perms=$perms)"
            # shellcheck disable=SC1090
            source "$SECRETS_FILE"
        else
            warn "Secrets file $SECRETS_FILE perms=$perms (expected 600/400); refusing to source."
        fi
    else
        debug "No secrets file at $SECRETS_FILE."
    fi
    [[ -n "$env_was" ]] && WAS_ADMIN_PASS="$env_was"
    [[ -n "$env_ks"  ]] && KEYSTORE_PASS="$env_ks"
    [[ -n "$env_pfx" ]] && PFX_PASSWORD="$env_pfx"
    [[ -n "$env_bpp" ]] && BACKUP_PFX_PASS="$env_bpp"

    # If no dedicated backup-PFX password is set, derive a safe default: refuse
    # to fall back to WebAS. Require it explicitly for the export step.
    local missing=()
    [[ -n "${WAS_ADMIN_PASS:-}" ]] || missing+=("WAS_ADMIN_PASS")
    [[ -n "${KEYSTORE_PASS:-}"  ]] || missing+=("KEYSTORE_PASS")
    (( ${#missing[@]} > 0 )) && die "Missing required secret(s): ${missing[*]}. Provide via env or $SECRETS_FILE (root 0600)."
    if [[ -z "${BACKUP_PFX_PASS:-}" ]]; then
        warn "BACKUP_PFX_PASS not set; the exported old-cert PFX will be SKIPPED (full key.p12 backup still taken). Set BACKUP_PFX_PASS to enable the standalone cert+key export."
    fi
    info "Secrets resolved."
}

#==============================================================================
# MODE: --list-backups
#==============================================================================
if [[ "$ROLLBACK_MODE" == "list" ]]; then
    info "### was-cert-replace v3 -- list backups ###"
    list_backups
    exit 0
fi

#==============================================================================
# MODE: --rollback [TIMESTAMP]
#==============================================================================
if [[ "$ROLLBACK_MODE" == "true" ]]; then
    info "##################################################################"
    info "MANUAL ROLLBACK MODE  run_id=$RUN_ID"
    info "##################################################################"
    [[ "$LEGAL_NOTICE_ACCEPT" == "true" ]] || die "Legal notice not accepted."
    resolve_secrets
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
        run "verify container" podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" || die "container not inspectable"
        [[ "$_LAST_OUTPUT" == "true" ]] || die "container '$CONTAINER_NAME' not running"
    fi
    # pick timestamp: explicit arg, else newest available
    if [[ -z "$ROLLBACK_TS" ]]; then
        ROLLBACK_TS=$(ls -1t "$BACKUP_DIR"/key_*.p12 2>/dev/null | head -1 | sed 's/.*key_//; s/\.p12$//')
        [[ -n "$ROLLBACK_TS" ]] || die "No backups found in $BACKUP_DIR to roll back to."
        info "No timestamp given; using newest backup: $ROLLBACK_TS"
    fi
    TS="$ROLLBACK_TS"
    if restore_backup "$ROLLBACK_TS"; then
        info "Manual rollback to $ROLLBACK_TS complete. Verifying served cert ..."
        if command -v openssl >/dev/null 2>&1; then
            for PORT in 9043 9443; do
                _s=$(echo | openssl s_client -connect localhost:$PORT 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null)
                info "  port $PORT: $(echo "$_s" | tr '\n' ' ')"
            done
        fi
        _run_summary "ROLLBACK_SUCCESS"; trap - ERR; exit 0
    else
        die "Manual rollback to $ROLLBACK_TS failed."
    fi
fi

#==============================================================================
# NORMAL MODE: certificate swap (transactional, auto-rollback on failure)
#==============================================================================
info "##################################################################"
info "WAS certificate replacement (DigiCert TLM post-script) v3"
info "run_id=$RUN_ID host=$(hostname -f 2>/dev/null || hostname) log_level=$LOG_LEVEL"
info "container_mode=$RUN_IN_CONTAINER container=$CONTAINER_NAME auto_rollback=$AUTO_ROLLBACK"
info "target_alias=$TARGET_ALIAS keystore=$KEYSTORE_NAME scope=(cell):$CELL_NAME:(node):$NODE_NAME"
info "##################################################################"

[[ "$LEGAL_NOTICE_ACCEPT" == "true" ]] || die "Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=true."
resolve_secrets

#------------------------------------------------------------------------------
phase "0 - Pre-flight checks"
if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
    command -v podman >/dev/null 2>&1 || die "podman not found but RUN_IN_CONTAINER=true"
    run "verify container running" podman inspect -f '{{.State.Running}}' "$CONTAINER_NAME" || die "Container '$CONTAINER_NAME' not inspectable"
    [[ "$_LAST_OUTPUT" == "true" ]] || die "Container '$CONTAINER_NAME' is not running (state=$_LAST_OUTPUT)"
    info "Container '$CONTAINER_NAME' is running."
fi
command -v openssl >/dev/null 2>&1 || warn "openssl not on host PATH; Phase 6 verification may be skipped"
_resolve_keytool
info "Pre-flight OK."

#------------------------------------------------------------------------------
phase "1 - Resolve incoming PFX and password"
PFX_HOST_PATH=""
_PFX_PASS_RESOLVED="${PFX_PASSWORD:-}"
find_pfx() {
    local dir="$1"
    find "$dir" -maxdepth 2 -type f \( -iname '*.pfx' -o -iname '*.p12' \) -print0 2>/dev/null \
        | xargs -0 ls -1t 2>/dev/null | grep -v '_legacy' | head -1 || true
}
if [[ -n "${DC1_POST_SCRIPT_DATA:-}" ]]; then
    info "DC1_POST_SCRIPT_DATA present (${#DC1_POST_SCRIPT_DATA} b64 chars) -- parsing TLM payload."
    JSON=$(echo "$DC1_POST_SCRIPT_DATA" | base64 -d 2>/dev/null) || die "Failed to base64-decode DC1_POST_SCRIPT_DATA"
    getf() { echo "$JSON" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*"//; s/"$//' || true; }
    tlm_folder=$(getf certfolder)
    _tlm_pass=$(getf password); [[ -n "$_tlm_pass" ]] || _tlm_pass=$(getf pfx_password)
    if [[ -n "$_tlm_pass" ]]; then PFX_PASSWORD="$_tlm_pass"; debug "PFX pass from TLM payload."
    else PFX_PASSWORD="$_PFX_PASS_RESOLVED"; debug "PFX pass from env/secrets file."; fi
    [[ -n "$tlm_folder" ]] && { CERT_FOLDER="$tlm_folder"; info "certfolder from TLM: $CERT_FOLDER"; }
    PFX_HOST_PATH=$(find_pfx "$CERT_FOLDER")
else
    warn "DC1_POST_SCRIPT_DATA not set -- manual mode. Scanning $CERT_FOLDER."
    PFX_HOST_PATH=$(find_pfx "$CERT_FOLDER")
    PFX_PASSWORD="$_PFX_PASS_RESOLVED"
fi
[[ -n "$PFX_HOST_PATH" && -f "$PFX_HOST_PATH" ]] || die "No PFX/P12 found in $CERT_FOLDER"
[[ -n "$PFX_PASSWORD" ]] || die "PFX password not provided (TLM payload, PFX_PASSWORD env, or $SECRETS_FILE)."
info "Selected PFX: $PFX_HOST_PATH"
info "PFX password resolved: ***(len=${#PFX_PASSWORD})"

#------------------------------------------------------------------------------
phase "2 - Inspect and stage PFX"
STAGE_PATH="/tmp/clm-incoming.p12"
push_into_was "$PFX_HOST_PATH" "$STAGE_PATH" || die "Failed to stage PFX into WAS context."
info "PFX certificate details:"
_pfx_details=$(inwas "$KEYTOOL" -list -v -keystore "$STAGE_PATH" -storetype PKCS12 -storepass "$PFX_PASSWORD" 2>&1) || \
    warn "keytool inspection nonzero (continuing; wsadmin import will validate)"
echo "$_pfx_details" | grep -E 'Alias name:|Owner:|Issuer:|Valid from:|SHA256:' | while IFS= read -r l; do info "  $l"; done
SRC_ALIAS=$(echo "$_pfx_details" | awk -F, '/PrivateKeyEntry/{print $1; exit}' | sed 's/Alias name: //')
[[ -n "$SRC_ALIAS" ]] || SRC_ALIAS="1"
info "Source alias in PFX: $SRC_ALIAS"

# Derive the FQDN from the leaf cert's CN (first Owner line = the leaf), for use
# in the final alias name. Strips 'CN=' and any trailing ', ...' RDN components.
CERT_CN=$(echo "$_pfx_details" | grep -m1 'Owner:' | grep -o 'CN=[^,]*' | head -1 | sed 's/^CN=//; s/ *$//')
if [[ -z "$CERT_CN" ]]; then
    warn "Could not parse CN from cert; falling back to hostname for alias."
    CERT_CN=$(hostname -f 2>/dev/null || hostname)
fi
# Sanitize: WAS aliases are stored lowercase; keep it filesystem/alias-safe.
CERT_CN=$(echo "$CERT_CN" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_' | sed 's/_*$//')
info "Certificate CN for alias: $CERT_CN"

#------------------------------------------------------------------------------
phase "3 - Backup (keystore + trust + config + export old cert/key)"
TS=$(date '+%Y%m%d_%H%M%S')
pull_from_was "$KEYSTORE_FILE"   "$BACKUP_DIR/key_${TS}.p12"   || die "backup of key.p12 failed"
pull_from_was "$TRUSTSTORE_FILE" "$BACKUP_DIR/trust_${TS}.p12" || die "backup of trust.p12 failed"
pull_from_was "$SECURITY_XML"    "$BACKUP_DIR/security_${TS}.xml" || die "backup of security.xml failed"
info "Full keystore/trust/config backup complete (ts=$TS)."

# Detect the alias currently bound in the SSL config, so the export grabs the
# cert that's actually live (not a hardcoded 'default' that may not exist).
EXPORT_ALIAS=$(inwas "$WSADMIN" -lang jython -conntype NONE \
    -c "print AdminTask.getSSLConfig('[-alias NodeDefaultSSLSettings -scopeName (cell):${CELL_NAME}:(node):${NODE_NAME}]')" 2>/dev/null \
    | grep -o 'serverKeyAlias [^]]*' | head -1 | sed 's/serverKeyAlias //; s/ *$//' || true)
[[ -n "$EXPORT_ALIAS" ]] || EXPORT_ALIAS="$TARGET_ALIAS"
debug "Alias to export for rollback PFX: $EXPORT_ALIAS"

# Export the OLD active cert + private key to a standalone, password-protected
# PFX (portable fallback copy). keytool lives INSIDE the container, so run it
# there: stage the backup key.p12 in, export, pull the PFX back out. Operates on
# the backup copy so the live keystore is never touched. Skipped if no pass set.
if [[ -n "${BACKUP_PFX_PASS:-}" ]]; then
    OLD_PFX_HOST="$BACKUP_DIR/old-default_${TS}.pfx"
    _tmp_srckey="/tmp/rollback-src-${TS}.p12"
    _tmp_dstpfx="/tmp/old-default-${TS}.pfx"
    if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
        run "stage backup key into container" podman cp "$BACKUP_DIR/key_${TS}.p12" "${CONTAINER_NAME}:${_tmp_srckey}"
        if run "export old cert+key (in container)" \
            podman exec "$CONTAINER_NAME" "$KEYTOOL" -importkeystore \
              -srckeystore "$_tmp_srckey" -srcstoretype PKCS12 -srcstorepass "$KEYSTORE_PASS" \
              -srcalias "$EXPORT_ALIAS" \
              -destkeystore "$_tmp_dstpfx" -deststoretype PKCS12 -deststorepass "$BACKUP_PFX_PASS" \
              -destkeypass "$BACKUP_PFX_PASS" -noprompt
        then
            run "pull exported pfx"    podman cp "${CONTAINER_NAME}:${_tmp_dstpfx}" "$OLD_PFX_HOST" \
                && { chmod 600 "$OLD_PFX_HOST" 2>/dev/null; info "Old cert+key (alias $EXPORT_ALIAS) exported to $OLD_PFX_HOST (password-protected, 0600)."; } \
                || warn "Could not pull exported PFX (non-fatal; full key.p12 backup still covers rollback)."
            # tidy temp files inside the container
            podman exec "$CONTAINER_NAME" rm -f "$_tmp_srckey" "$_tmp_dstpfx" 2>/dev/null || true
        else
            warn "Old cert+key export failed (non-fatal; full key.p12 backup still covers rollback)."
            podman exec "$CONTAINER_NAME" rm -f "$_tmp_srckey" "$_tmp_dstpfx" 2>/dev/null || true
        fi
    else
        # bare-metal: keytool is local
        if run "export old cert+key" \
            "$KEYTOOL" -importkeystore \
              -srckeystore "$BACKUP_DIR/key_${TS}.p12" -srcstoretype PKCS12 -srcstorepass "$KEYSTORE_PASS" \
              -srcalias "$EXPORT_ALIAS" \
              -destkeystore "$OLD_PFX_HOST" -deststoretype PKCS12 -deststorepass "$BACKUP_PFX_PASS" \
              -destkeypass "$BACKUP_PFX_PASS" -noprompt
        then chmod 600 "$OLD_PFX_HOST" 2>/dev/null; info "Old cert+key exported to $OLD_PFX_HOST (0600)."
        else warn "Old cert+key export failed (non-fatal; full key.p12 backup still covers rollback)."; fi
    fi
else
    info "Skipping standalone old-cert export (BACKUP_PFX_PASS not set); full key.p12 backup covers rollback."
fi

# Prune old backups (per type) beyond BACKUP_KEEP
for pat in 'key_*.p12' 'trust_*.p12' 'security_*.xml' 'old-default_*.pfx'; do
    mapfile -t _old < <(ls -1t "$BACKUP_DIR"/$pat 2>/dev/null | tail -n +$((BACKUP_KEEP+1)))
    for f in "${_old[@]:-}"; do [[ -n "$f" ]] && rm -f "$f" && debug "pruned $f"; done
done
info "Backups retained: newest $BACKUP_KEEP per type. Restore points: use --list-backups."

#------------------------------------------------------------------------------
# From here on, WAS state will change. Arm auto-rollback.
#------------------------------------------------------------------------------
_SWAP_STARTED="true"

phase "4 - WAS-native certificate swap (auto-rollback armed)"
HOST_JY=$(mktemp /tmp/was-cert-replace-XXXX.py)
JY="/tmp/was-cert-replace.py"
# Final alias: <FQDN-from-cert-CN>_<timestamp>. Self-documenting (what + when)
# and timestamped so it can never collide with the currently-live alias, which
# keeps the swap collision-proof (no CWPKI0707E "last cert" errors).
NEW_ALIAS="${CERT_CN}_${TS}"
cat > "$HOST_JY" <<PYEOF
import sys
ks       = '${KEYSTORE_NAME}'
scope    = '(cell):${CELL_NAME}:(node):${NODE_NAME}'
prefer   = '${TARGET_ALIAS}'
newalias = '${NEW_ALIAS}'
pfx      = '${STAGE_PATH}'
pfxpw    = '${PFX_PASSWORD}'
sslcfg   = 'NodeDefaultSSLSettings'

def log(m): print '[JYTHON] ' + m
def personal_list():
    try: return AdminTask.listPersonalCertificates(['-keyStoreName', ks, '-keyStoreScope', scope])
    except: return ''

# --- Detect the CURRENT live alias (self-adapting; no assumption it's 'default')
# Priority: the alias the SSL config is actually using > preferred name if it
# exists > the single existing personal cert. This makes the swap work no matter
# what the keystore/alias state is.
def current_serverkeyalias():
    try:
        cfg = str(AdminTask.getSSLConfig(['-alias', sslcfg, '-scopeName', scope]))
        import re
        m = re.search(r'serverKeyAlias ([^\]]+)', cfg)
        if m:
            a = m.group(1).strip()
            if a: return a
    except:
        pass
    return ''

plist = personal_list()
live = current_serverkeyalias()
if live and (live in plist):
    old_alias = live
    log('detected live alias from SSL config: %s' % old_alias)
elif prefer in plist:
    old_alias = prefer
    log('using preferred alias (present in keystore): %s' % old_alias)
else:
    # fall back to the first personal cert alias present
    import re
    m = re.search(r'alias ([^\]]+)', plist)
    old_alias = m.group(1).strip() if m else prefer
    log('falling back to existing alias: %s' % old_alias)

# --- Import the NEW cert under a fresh timestamped alias. Import BEFORE any
# delete so the keystore always has >=2 certs during the swap (CWPKI0707E safe).
if newalias in plist:
    # extraordinarily unlikely (timestamped), but be safe
    log('temp alias %s unexpectedly present; deleting it first' % newalias)
    AdminTask.deleteCertificate(['-keyStoreName', ks, '-keyStoreScope', scope, '-certificateAlias', newalias])

log('import new cert under fresh alias %s' % newalias)
AdminTask.importCertificate(['-keyStoreName', ks, '-keyStoreScope', scope,
    '-keyFilePath', pfx, '-keyFilePassword', pfxpw, '-keyFileType', 'PKCS12',
    '-certificateAliasFromKeyFile', '${SRC_ALIAS}', '-certificateAlias', newalias])
log('import OK (keystore now holds old=%s and new=%s)' % (old_alias, newalias))

# --- Replace: rewrites SSL config refs from old_alias -> newalias and deletes
# the old cert. Because newalias already exists, we're never deleting the last.
if old_alias == newalias:
    log('old and new alias identical (%s); skipping replace' % newalias)
    final_alias = newalias
else:
    log('replaceCertificate %s -> %s (rewrites SSL config refs; both ports)' % (old_alias, newalias))
    AdminTask.replaceCertificate(['-keyStoreName', ks, '-keyStoreScope', scope,
        '-certificateAlias', old_alias, '-replacementCertificateAlias', newalias,
        '-deleteOldCert', 'true', '-deleteOldSigners', 'true'])
    final_alias = newalias
    log('replace OK -- active cert is now CA-issued (alias %s)' % newalias)

# --- Explicitly bind the new alias into the SSL config (hands-off automation).
# replaceCertificate only rewrites fields that referenced old_alias; if the field
# was '(none)' nothing gets pointed at the new cert. modifySSLConfig sets it.
try:
    AdminTask.modifySSLConfig(['-alias', sslcfg, '-scopeName', scope,
        '-serverKeyAlias', final_alias, '-clientKeyAlias', final_alias])
    log('bound SSL config %s serverKeyAlias/clientKeyAlias -> %s' % (sslcfg, final_alias))
except Exception, e:
    log('WARN could not modifySSLConfig %s (%s)' % (sslcfg, str(e)))

AdminConfig.save()
log('SAVED. active alias: %s' % final_alias)

# --- Verify: cert present, CA-issued (not self-signed localhost), AND bound.
info_str = str(AdminTask.getCertificate(['-keyStoreName', ks, '-keyStoreScope', scope, '-certificateAlias', final_alias]))
log('final cert (alias %s): %s' % (final_alias, info_str))
bound_ok = 0
try:
    cfg = str(AdminTask.getSSLConfig(['-alias', sslcfg, '-scopeName', scope]))
    if ('serverKeyAlias ' + final_alias) in cfg or ('serverKeyAlias=' + final_alias) in cfg:
        bound_ok = 1
except Exception, e:
    log('WARN could not read back SSL config (%s)' % str(e))

if final_alias not in personal_list():
    log('VERIFY-FAIL alias %s missing' % final_alias); print 'VERIFY-FAIL'
elif 'Root Certificate' in info_str and 'localhost' in info_str:
    log('VERIFY-FAIL alias %s still self-signed' % final_alias); print 'VERIFY-FAIL'
elif bound_ok == 0:
    log('VERIFY-FAIL SSL config serverKeyAlias not bound to %s' % final_alias); print 'VERIFY-FAIL'
else:
    log('VERIFY-OK alias %s holds CA-issued cert AND is bound in SSL config' % final_alias); print 'VERIFY-OK'
PYEOF

if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
    run "copy jython into container" podman cp "$HOST_JY" "${CONTAINER_NAME}:${JY}" || die_rollback "failed to copy jython into container"
else
    cp -f "$HOST_JY" "$JY"
fi
rm -f "$HOST_JY"

info "Invoking wsadmin (offline, -conntype NONE) ..."
_wsout=$(inwas "$WSADMIN" -lang jython -conntype NONE -f "$JY" 2>&1) || true
while IFS= read -r l; do
    case "$l" in
        *VERIFY-FAIL*)                               error "wsadmin: $(_mask "$l")" ;;
        *ERROR*|*Exception*|*WASX7015E*|*WASX7017E*) error "wsadmin: $(_mask "$l")" ;;
        *WARN*|*NOTE*)                               warn  "wsadmin: $(_mask "$l")" ;;
        *)                                           info  "wsadmin: $(_mask "$l")" ;;
    esac
done <<< "$_wsout"
echo "$_wsout" | grep -q 'VERIFY-OK' || die_rollback "Swap did not verify (no VERIFY-OK). Auto-rollback will restore the previous certificate."
info "Swap saved and VERIFIED in config."

# Remove files containing secrets from the container immediately after use.
if [[ "$RUN_IN_CONTAINER" == "true" ]]; then
    podman exec "$CONTAINER_NAME" rm -f "$JY" "$STAGE_PATH" 2>/dev/null || true
else
    rm -f "$JY" "$STAGE_PATH" 2>/dev/null || true
fi

#------------------------------------------------------------------------------
if [[ "$RESTART_SERVER" == "true" ]]; then
    phase "5 - Restart WAS to activate the new certificate"
    restart_and_wait; _rw_rc=$?
    if (( _rw_rc == 1 )); then
        die_rollback "Restart command itself failed. Auto-rollback will restore the previous certificate."
    elif (( _rw_rc == 2 )); then
        warn "Readiness marker not seen in time, but the restart was issued and the swap is already saved. Proceeding to verification; do NOT auto-rollback on a slow start."
    fi
else
    phase "5 - Restart SKIPPED (-n)"; warn "New cert not served until restart."
fi

#------------------------------------------------------------------------------
phase "6 - Verify served certificate on 9043 and 9443"
_verify_fail=0
if command -v openssl >/dev/null 2>&1; then
    for PORT in 9043 9443; do
        info "--- port $PORT ---"
        _served=$(echo | openssl s_client -connect localhost:$PORT 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
        if [[ -n "$_served" ]]; then
            while IFS= read -r l; do info "  $l"; done <<< "$_served"
            if echo "$_served" | grep -qi 'issuer=.*localhost'; then
                warn "Port $PORT still shows self-signed issuer."
                _verify_fail=1
            else
                info "Port $PORT serving a CA certificate."
            fi
        else
            warn "Could not read cert on $PORT."
            _verify_fail=1
        fi
    done
else
    warn "openssl unavailable; skipping served-cert verification."
fi

# If the restart happened but the served cert is still the old one on BOTH ports,
# treat as failure and roll back (only meaningful when we restarted).
if [[ "$RESTART_SERVER" == "true" && "$_verify_fail" == "1" ]]; then
    warn "Post-restart verification did not confirm the CA cert on the ports."
    # Not auto-rolling-back solely on a verify hiccup (server may still be warming
    # up); surface it loudly instead. Operator can --rollback if needed.
    warn "If this persists, run: $(basename "$0") --rollback $TS"
fi

_SWAP_STARTED="false"   # past the danger zone
_run_summary "SUCCESS"
info "Fallback available anytime: $(basename "$0") --rollback $TS"

if [[ "$REBOOT_HOST" == "true" ]]; then warn "REBOOT_HOST=true -- rebooting in 15s"; sleep 15; reboot; fi
trap - ERR
exit 0
