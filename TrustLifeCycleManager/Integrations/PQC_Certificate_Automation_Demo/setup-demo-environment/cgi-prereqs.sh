#!/usr/bin/env bash
###############################################################################
# cgi-prereqs.sh — prepare the PQC demo Apache to serve the certinfo.cgi page.
#
# It:
#   1. detects the Apache MPM and loads the correct CGI module (cgid/cgi),
#   2. installs the CGI page as <docroot>/index.cgi (chmod 755),
#   3. writes a SELF-CONTAINED managed config block enabling CGI + exporting
#      the TLS cert env (SSLOptions +StdEnvVars +ExportCertData) for the docroot,
#   4. configtests, reloads, and probes the page over TLS with the PQC OpenSSL.
#
# The CGI directives live in their own "# >>> PQC-LAB CGI" block, independent of
# the demo vhost, so re-running 'demo'/'reset' in pqc-apache-setup.sh will NOT
# remove them.
#
# Usage:
#   sudo ./cgi-prereqs.sh [path-to-certinfo.cgi]      (default: ./certinfo.cgi)
###############################################################################

set -Eeuo pipefail

# ------------------------------ configuration -------------------------------
HTTPD_PREFIX="${HTTPD_PREFIX:-/opt/httpd-pqc}"
OPENSSL_PREFIX="${OPENSSL_PREFIX:-/opt/openssl-pqc}"
OSSL="${OPENSSL_PREFIX}/bin/openssl"
APACHECTL="${HTTPD_PREFIX}/bin/apachectl"
HTTPD_BIN="${HTTPD_PREFIX}/bin/httpd"
CONF="${HTTPD_PREFIX}/conf/httpd.conf"
DOCROOT="${DOCROOT:-${HTTPD_PREFIX}/htdocs}"

DEMO_PORT="${DEMO_PORT:-443}"
CN="${CN:-pqc-demo.digicert-demo.com}"

CGI_SRC="${1:-./certinfo.cgi}"          # source page to install
CGI_DEST="${DOCROOT}/index.cgi"         # where the vhost expects it

LOGFILE="${LOGFILE:-/var/log/cgi-prereqs.log}"

# -------------------------------- logging -----------------------------------
_ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()  { printf '%s [INFO ] %s\n' "$(_ts)" "$*" | tee -a "$LOGFILE"; }
warn() { printf '%s [WARN ] %s\n' "$(_ts)" "$*" | tee -a "$LOGFILE" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(_ts)" "$*" | tee -a "$LOGFILE" >&2; }
die()  { err "$*"; exit 1; }
trap 'rc=$?; [ $rc -ne 0 ] && err "Aborted at line $LINENO (exit $rc). Log: $LOGFILE"; exit $rc' ERR

ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log "Re-executing under sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

# ------------------------------- preflight ----------------------------------
preflight() {
  mkdir -p "$(dirname "$LOGFILE")"; : > "$LOGFILE" 2>/dev/null || true
  [ -x "$HTTPD_BIN" ]  || die "Apache not found at $HTTPD_BIN. Run pqc-apache-setup.sh install first."
  [ -x "$OSSL" ]       || die "PQC OpenSSL not found at $OSSL."
  [ -f "$CONF" ]       || die "httpd.conf not found at $CONF."
  [ -d "$DOCROOT" ]    || die "DocumentRoot $DOCROOT does not exist."
  log "Apache : $("$HTTPD_BIN" -v | head -1)"
}

# ---------------------- pick + load the CGI module --------------------------
detect_and_load_cgi_module() {
  local mpm
  mpm=$("$HTTPD_BIN" -V 2>/dev/null | sed -n 's/.*Server MPM: *//p' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  log "Detected MPM: ${mpm:-unknown}"
  case "$mpm" in
    prefork) CGI_MOD="cgi_module";  CGI_SO="mod_cgi.so" ;;
    *)       CGI_MOD="cgid_module"; CGI_SO="mod_cgid.so" ;;   # event / worker
  esac
  [ -f "${HTTPD_PREFIX}/modules/${CGI_SO}" ] \
    || die "Required module ${CGI_SO} not built. Rebuild httpd (it ships by default)."

  # Uncomment if present-but-commented; add once if entirely absent.
  sed -i "s|^#[[:space:]]*LoadModule ${CGI_MOD} |LoadModule ${CGI_MOD} |" "$CONF"
  if ! grep -q "^LoadModule ${CGI_MOD} " "$CONF"; then
    printf 'LoadModule %s modules/%s\n' "$CGI_MOD" "$CGI_SO" >> "$CONF"
  fi
  log "CGI module ensured: ${CGI_MOD} (${CGI_SO})"
}

# --------------------------- install the page -------------------------------
install_cgi_page() {
  if [ -f "$CGI_SRC" ]; then
    cp -f "$CGI_SRC" "$CGI_DEST"
    chmod 755 "$CGI_DEST"
    log "Installed CGI page: $CGI_SRC -> $CGI_DEST (755)"
  elif [ -f "$CGI_DEST" ]; then
    chmod 755 "$CGI_DEST"
    warn "Source '$CGI_SRC' not found; using existing $CGI_DEST."
  else
    die "CGI source '$CGI_SRC' not found and no page at $CGI_DEST. Pass the path: sudo ./cgi-prereqs.sh /path/to/certinfo.cgi"
  fi
}

# --------------- self-contained managed CGI config block --------------------
write_cgi_conf() {
  # Idempotent: drop our previous block, then re-append.
  sed -i '/# >>> PQC-LAB CGI BEGIN/,/# <<< PQC-LAB CGI END/d' "$CONF"
  cat >> "$CONF" <<EOF

# >>> PQC-LAB CGI BEGIN  (managed by cgi-prereqs.sh)
<Directory "${DOCROOT}">
    Options +ExecCGI
    AddHandler cgi-script .cgi
    DirectoryIndex index.cgi
    SSLOptions +StdEnvVars +ExportCertData
</Directory>
# <<< PQC-LAB CGI END
EOF
  log "CGI directives written for ${DOCROOT} (ExecCGI, index.cgi, StdEnvVars+ExportCertData)."
}

# ------------------------------ apply + probe -------------------------------
apply() {
  if ! "$APACHECTL" configtest >>"$LOGFILE" 2>&1; then
    err "configtest failed. Last error_log lines:"
    tail -n 20 "${HTTPD_PREFIX}/logs/error_log" 2>/dev/null | tee -a "$LOGFILE" >&2 || true
    die "See $LOGFILE"
  fi
  log "configtest: Syntax OK"
  # A newly-added LoadModule (cgid/cgi) is NOT picked up by a graceful reload,
  # and mod_cgid needs its daemon (re)started cleanly -> do a FULL restart.
  "$HTTPD_BIN" -k stop >/dev/null 2>&1 && sleep 2
  "$APACHECTL" -k start >>"$LOGFILE" 2>&1 || die "apache start failed (see error_log)"
  sleep 1
  if "$HTTPD_BIN" -M 2>/dev/null | grep -qi "${CGI_MOD%%_module}"; then
    log "GUARD: ${CGI_MOD} is loaded."
  else
    warn "${CGI_MOD} does not appear in 'httpd -M'. CGI will 503 until it loads."
  fi
}

probe() {
  log "Probing the CGI page over TLS on :${DEMO_PORT}..."
  local resp
  resp=$(printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$CN" \
         | "$OSSL" s_client -connect "127.0.0.1:${DEMO_PORT}" -quiet 2>/dev/null || true)
  if printf '%s' "$resp" | grep -qi "Live certificate inspector"; then
    log "PASS: certinfo.cgi is rendering on https://${CN}:${DEMO_PORT}/"
  else
    warn "Could not confirm the CGI page on :${DEMO_PORT}."
    warn "Check that the demo vhost is up (pqc-apache-setup.sh demo) and DocumentRoot is ${DOCROOT}."
  fi
}

# ----------------------------------- main -----------------------------------
main() {
  ensure_root "$@"
  preflight
  detect_and_load_cgi_module
  install_cgi_page
  write_cgi_conf
  apply
  probe
  cat <<EOF

============================== CGI PREP COMPLETE =============================
 Page   : ${CGI_DEST}
 Serves : https://${CN}:${DEMO_PORT}/   (via DirectoryIndex index.cgi)
 Config : self-contained "# >>> PQC-LAB CGI" block (survives demo/reset)
 Log    : ${LOGFILE}

 If the page shows a "No certificate" state, the demo vhost isn't running yet:
   sudo ./pqc-apache-setup.sh demo
=============================================================================
EOF
}

main "$@"