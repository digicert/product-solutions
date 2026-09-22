#!/usr/bin/env bash
###############################################################################
# pqc-apache-setup.sh
#
# Provision a FRESH Ubuntu 26.04 EC2 instance to Apache httpd with post-quantum
# hybrid key exchange (X25519MLKEM768), built from source against OpenSSL 3.5+
# in an isolated prefix, serving a self-signed RSA certificate.
#
# Later, swap in an ML-DSA-87 certificate on a separate port with:
#     sudo ./pqc-apache-setup.sh mldsa
#
# Commands:
#     install   (default)  Build OpenSSL + Apache, self-signed RSA cert, start.
#     mldsa                 Issue a self-signed ML-DSA-<level> cert on MLDSA_PORT.
#     mldsa-ca              Build a private ML-DSA root + leaf chain on MLDSA_PORT
#                           (trustable: import the printed root into the browser).
#     demo                  Single-vhost demo on DEMO_PORT: self-signed cert that
#                           TLM later overwrites (self-signed <-> issued swap).
#     reset                 Re-mint a fresh self-signed cert on the demo vhost
#                           (back to the self-signed state). Rebuilds nothing.
#     show                  Print subject/issuer/algorithm/fingerprint currently
#                           served on DEMO_PORT.
#     verify                Re-run the PQC handshake health probes only.
#     status                Show what is installed / running.
#
# ---------------------------------------------------------------------------
# ENVIRONMENT OVERRIDES
#   Every setting in the "configuration" block below is an environment
#   override -- prefix them to the command. Defaults in brackets.
#
#     DEMO_SELF_ALG   [mldsa87]  Self-signed baseline for demo/reset:
#                                rsa | mldsa44 | mldsa65 | mldsa87.
#                                Use rsa to make the ALGORITHM itself change
#                                (RSA self-signed -> ML-DSA TLM-issued) rather
#                                than only the issuer:
#
#                                    sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo
#
#                                Set it on the FIRST demo run -- it is applied
#                                when the baseline cert is minted, so changing
#                                it later means re-running demo (or reset).
#     CN / SAN        [pqc-demo.digicert-demo.com]  Cert subject / SAN. Must
#                                match DNS (or the client hosts file) and the
#                                SAN on the certificate TLM issues.
#     DEMO_PORT       [443]      Demo vhost listen port. Must match the AWR
#                                script's probe port and the security group.
#     DEMO_CRT/_KEY   [<HTTPD_PREFIX>/conf/tlm-pqc.crt|.key]  The shared cert
#                                slot. The AWR script must deploy to this exact
#                                path or the swap will not be visible.
#     MLDSA_LEVEL     [87]       ML-DSA parameter set for mldsa / mldsa-ca.
#     PQC_GROUPS      [X25519MLKEM768:X25519:secp256r1:secp384r1]
#                                TLS 1.3 group preference (hybrid first).
#     OPENSSL_PREFIX / HTTPD_PREFIX   [/opt/openssl-pqc | /opt/httpd-pqc]
#     OPENSSL_VERSION / HTTPD_VERSION / APR_VERSION / APRUTIL_VERSION
#     ACCEPT=1 / FORCE=1         Same as --accept / --force.
#
#   Example combining several:
#     sudo DEMO_SELF_ALG=rsa DEMO_PORT=9443 CN=pqc.acme.internal \
#          SAN=DNS:pqc.acme.internal ./pqc-apache-setup.sh demo
# ---------------------------------------------------------------------------
#
# ---------------------------------------------------------------------------
# USAGE / LEGAL NOTICE
#   This script is provided as-is for lab and evaluation use. It builds and
#   installs software from upstream source into /opt and starts a listening
#   web service. Run it only on infrastructure you are authorised to modify.
#   Review before running. Set ACCEPT=1 (or pass --accept) to bypass the gate
#   for unattended runs.
# ---------------------------------------------------------------------------
#
# NOTE ON VERSIONS: upstream mirrors only keep current releases; if a pinned
# version 404s the script falls back to archive.apache.org and reports the
# failure clearly. Override any version via environment variables (see below).
###############################################################################

set -Eeuo pipefail

# ----------------------------- configuration --------------------------------
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.0}"     # must be >= 3.5.0 for native PQC
HTTPD_VERSION="${HTTPD_VERSION:-2.4.65}"        # confirm current at dlcdn.apache.org/httpd
APR_VERSION="${APR_VERSION:-1.7.6}"
APRUTIL_VERSION="${APRUTIL_VERSION:-1.6.3}"

OPENSSL_PREFIX="${OPENSSL_PREFIX:-/opt/openssl-pqc}"
HTTPD_PREFIX="${HTTPD_PREFIX:-/opt/httpd-pqc}"
OPENSSL_LIBDIR="$OPENSSL_PREFIX/lib"            # forced deterministic via --libdir=lib

WORKDIR="${WORKDIR:-/usr/local/src/pqc-build}"
LOGFILE="${LOGFILE:-/var/log/pqc-apache-setup.log}"

CN="${CN:-pqc-demo.digicert-demo.com}"
SAN="${SAN:-DNS:pqc-demo.digicert-demo.com}"
HTTPS_PORT="${HTTPS_PORT:-443}"                 # RSA + ML-KEM vhost (browser-facing)
MLDSA_PORT="${MLDSA_PORT:-8443}"                # ML-DSA vhost (controlled clients only)
MLDSA_LEVEL="${MLDSA_LEVEL:-87}"                # 44 | 65 | 87
MLDSA_CA_CN="${MLDSA_CA_CN:-PQC Lab Root ML-DSA-$MLDSA_LEVEL}"

# --- single-vhost demo (self-signed <-> TLM-issued swap on ONE port/path) ---
DEMO_PORT="${DEMO_PORT:-443}"                           # demo vhost listen port
DEMO_CRT="${DEMO_CRT:-$HTTPD_PREFIX/conf/tlm-pqc.crt}"  # AWR script overwrites this exact file
DEMO_KEY="${DEMO_KEY:-$HTTPD_PREFIX/conf/tlm-pqc.key}"
DEMO_SELF_ALG="${DEMO_SELF_ALG:-mldsa87}"               # self-signed baseline: rsa|mldsa44|mldsa65|mldsa87

# Hybrid group first, classical fallbacks after (keeps every client compatible).
# NB: do NOT name this GROUPS — that is a bash special/read-only array (user GIDs)
# and assignments to it are silently ignored, yielding "Groups 0" in the config.
PQC_GROUPS="${PQC_GROUPS:-X25519MLKEM768:X25519:secp256r1:secp384r1}"

# Optional integrity pinning. If left empty the script warns instead of failing.
OPENSSL_SHA256="${OPENSSL_SHA256:-}"

ACCEPT="${ACCEPT:-0}"
FORCE="${FORCE:-0}"                              # FORCE=1 rebuilds even if present

# ------------------------------- logging ------------------------------------
_ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log()  { printf '%s [INFO ] %s\n'  "$(_ts)" "$*" | tee -a "$LOGFILE"; }
warn() { printf '%s [WARN ] %s\n'  "$(_ts)" "$*" | tee -a "$LOGFILE" >&2; }
err()  { printf '%s [ERROR] %s\n'  "$(_ts)" "$*" | tee -a "$LOGFILE" >&2; }
die()  { err "$*"; exit 1; }

trap 'rc=$?; [ $rc -ne 0 ] && err "Aborted at line $LINENO (exit $rc). Log: $LOGFILE"; exit $rc' ERR

# --------------------------- privilege / gate -------------------------------
ensure_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log "Re-executing under sudo..."
    exec sudo -E bash "$0" "$@"
  fi
}

legal_gate() {
  [ "$ACCEPT" = "1" ] && return 0
  cat <<'GATE'
-------------------------------------------------------------------------------
 This will build OpenSSL and Apache from source, install them under /opt, and
 start a TLS web server. Run only on hosts you are authorised to modify.
-------------------------------------------------------------------------------
GATE
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) : ;; *) die "Declined by operator." ;; esac
}

# ------------------------------- preflight ----------------------------------
preflight() {
  mkdir -p "$WORKDIR" "$(dirname "$LOGFILE")"
  : > "$LOGFILE" 2>/dev/null || true
  log "Log file: $LOGFILE"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    log "OS: ${PRETTY_NAME:-unknown}"
    case "${VERSION_ID:-}" in
      26.04) : ;;
      *) warn "Tested on Ubuntu 26.04; detected '${VERSION_ID:-?}'. Continuing." ;;
    esac
  else
    warn "/etc/os-release not found; cannot confirm distribution."
  fi
  log "Architecture: $(uname -m)"
}

# ----------------------------- fetch helper ---------------------------------
# fetch <outfile> <url> [<fallback_url> ...]
fetch() {
  local out="$1"; shift
  if [ -s "$out" ]; then log "Cached: $(basename "$out")"; return 0; fi
  local url
  for url in "$@"; do
    log "Downloading $url"
    if curl -fsSL --retry 3 -o "$out.part" "$url"; then
      mv "$out.part" "$out"; return 0
    fi
    warn "Fetch failed: $url"
  done
  rm -f "$out.part"
  die "All download URLs failed for $(basename "$out"). Check the version pin."
}

verify_sha256() {  # verify_sha256 <file> <expected-or-empty>
  local file="$1" expect="$2"
  [ -z "$expect" ] && { warn "No SHA256 pin for $(basename "$file"); skipping integrity check."; return 0; }
  local got; got="$(sha256sum "$file" | awk '{print $1}')"
  [ "$got" = "$expect" ] || die "SHA256 mismatch for $(basename "$file"): got $got"
  log "SHA256 verified: $(basename "$file")"
}

# ----------------------------- prerequisites --------------------------------
install_prereqs() {
  log "Installing build prerequisites..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOGFILE" 2>&1
  apt-get install -y \
    build-essential wget curl perl ca-certificates \
    zlib1g-dev libpcre2-dev libexpat1-dev \
    >>"$LOGFILE" 2>&1
  log "Prerequisites installed."
}

# ------------------------------ build OpenSSL -------------------------------
build_openssl() {
  if [ "$FORCE" != "1" ] && [ -x "$OPENSSL_PREFIX/bin/openssl" ] \
     && "$OPENSSL_PREFIX/bin/openssl" version | grep -q "$OPENSSL_VERSION"; then
    log "OpenSSL $OPENSSL_VERSION already present at $OPENSSL_PREFIX; skipping."
    return 0
  fi

  local tar="$WORKDIR/openssl-$OPENSSL_VERSION.tar.gz"
  fetch "$tar" \
    "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz"
  verify_sha256 "$tar" "$OPENSSL_SHA256"

  log "Building OpenSSL $OPENSSL_VERSION into $OPENSSL_PREFIX (libdir=lib)..."
  rm -rf "$WORKDIR/openssl-$OPENSSL_VERSION"
  tar -xzf "$tar" -C "$WORKDIR"
  (
    cd "$WORKDIR/openssl-$OPENSSL_VERSION"
    ./Configure \
      --prefix="$OPENSSL_PREFIX" \
      --openssldir="$OPENSSL_PREFIX/ssl" \
      --libdir=lib \
      shared \
      "-Wl,-rpath,$OPENSSL_LIBDIR"
    make -j"$(nproc)"
    make install_sw       # libs, binaries, headers
    make install_ssldirs  # default openssl.cnf + ssl/ dir tree (needed by req/ca)
  ) >>"$LOGFILE" 2>&1

  log "OpenSSL version: $("$OPENSSL_PREFIX/bin/openssl" version)"
  if "$OPENSSL_PREFIX/bin/openssl" list -kem-algorithms 2>/dev/null | grep -qi mlkem; then
    log "GUARD: ML-KEM present in OpenSSL build."
  else
    die "GUARD FAILED: ML-KEM not found in $OPENSSL_PREFIX. Need OpenSSL >= 3.5."
  fi
}

# ------------------------------- build httpd --------------------------------
build_httpd() {
  if [ "$FORCE" != "1" ] && [ -x "$HTTPD_PREFIX/bin/httpd" ]; then
    log "Apache already present at $HTTPD_PREFIX; skipping build."
    return 0
  fi

  local h="$WORKDIR/httpd-$HTTPD_VERSION.tar.gz"
  local a="$WORKDIR/apr-$APR_VERSION.tar.gz"
  local u="$WORKDIR/apr-util-$APRUTIL_VERSION.tar.gz"

  fetch "$h" \
    "https://dlcdn.apache.org/httpd/httpd-$HTTPD_VERSION.tar.gz" \
    "https://archive.apache.org/dist/httpd/httpd-$HTTPD_VERSION.tar.gz"
  fetch "$a" \
    "https://dlcdn.apache.org/apr/apr-$APR_VERSION.tar.gz" \
    "https://archive.apache.org/dist/apr/apr-$APR_VERSION.tar.gz"
  fetch "$u" \
    "https://dlcdn.apache.org/apr/apr-util-$APRUTIL_VERSION.tar.gz" \
    "https://archive.apache.org/dist/apr/apr-util-$APRUTIL_VERSION.tar.gz"

  log "Building Apache $HTTPD_VERSION against $OPENSSL_PREFIX ..."
  rm -rf "$WORKDIR/httpd-$HTTPD_VERSION"
  tar -xzf "$h" -C "$WORKDIR"
  tar -xzf "$a" -C "$WORKDIR"
  tar -xzf "$u" -C "$WORKDIR"
  rm -rf "$WORKDIR/httpd-$HTTPD_VERSION/srclib/apr" "$WORKDIR/httpd-$HTTPD_VERSION/srclib/apr-util"
  mv "$WORKDIR/apr-$APR_VERSION"       "$WORKDIR/httpd-$HTTPD_VERSION/srclib/apr"
  mv "$WORKDIR/apr-util-$APRUTIL_VERSION" "$WORKDIR/httpd-$HTTPD_VERSION/srclib/apr-util"

  (
    cd "$WORKDIR/httpd-$HTTPD_VERSION"
    ./configure \
      --prefix="$HTTPD_PREFIX" \
      --enable-ssl --with-ssl="$OPENSSL_PREFIX" \
      --enable-so --enable-mpm=event \
      --with-included-apr \
      CPPFLAGS="-I$OPENSSL_PREFIX/include" \
      LDFLAGS="-Wl,-rpath,$OPENSSL_LIBDIR"
    make -j"$(nproc)"
    make install
  ) >>"$LOGFILE" 2>&1

  verify_linkage
}

# The single most important guard rail: mod_ssl must resolve to OUR libssl,
# not the distro's older one, or you silently get no PQC.
verify_linkage() {
  local so="$HTTPD_PREFIX/modules/mod_ssl.so"
  [ -f "$so" ] || die "GUARD FAILED: mod_ssl.so not built."
  if ldd "$so" | grep -q "$OPENSSL_LIBDIR"; then
    log "GUARD: mod_ssl.so linked to $OPENSSL_LIBDIR"
  else
    err "mod_ssl.so linkage:"; ldd "$so" | grep -i ssl | tee -a "$LOGFILE" >&2
    die "GUARD FAILED: mod_ssl.so is NOT linked to $OPENSSL_LIBDIR (rpath issue)."
  fi
}

# ------------------------------ certificates --------------------------------
gen_selfsigned_rsa() {
  local crt="$HTTPD_PREFIX/conf/server.crt"
  local key="$HTTPD_PREFIX/conf/server.key"
  if [ "$FORCE" != "1" ] && [ -f "$crt" ] && [ -f "$key" ]; then
    log "RSA self-signed cert already present; skipping."
    return 0
  fi
  log "Generating self-signed RSA cert (CN=$CN)..."
  "$OPENSSL_PREFIX/bin/openssl" req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout "$key" -out "$crt" \
    -subj "/CN=$CN" \
    -addext "subjectAltName=$SAN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" >>"$LOGFILE" 2>&1
  log "RSA cert written: $crt"
}

gen_mldsa_cert() {
  local lvl="$MLDSA_LEVEL"
  case "$lvl" in 44|65|87) : ;; *) die "MLDSA_LEVEL must be 44, 65, or 87 (got '$lvl')." ;; esac
  local crt="$HTTPD_PREFIX/conf/server-mldsa$lvl.crt"
  local key="$HTTPD_PREFIX/conf/server-mldsa$lvl.key"
  log "Generating self-signed ML-DSA-$lvl cert (CN=$CN)..."
  "$OPENSSL_PREFIX/bin/openssl" req -x509 -newkey "mldsa$lvl" -nodes -days 30 \
    -keyout "$key" -out "$crt" \
    -subj "/CN=$CN" \
    -addext "subjectAltName=$SAN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" >>"$LOGFILE" 2>&1
  log "ML-DSA-$lvl cert written: $crt"
  MLDSA_CRT="$crt"; MLDSA_KEY="$key"
}

# Build a private two-tier ML-DSA chain: self-signed root (CA:TRUE) that signs
# an end-entity leaf (CA:FALSE, serverAuth). Import the root into a browser
# trust store and the leaf validates -> fully trusted PQC auth, no public CA.
gen_mldsa_ca_chain() {
  local lvl="$MLDSA_LEVEL"
  case "$lvl" in 44|65|87) : ;; *) die "MLDSA_LEVEL must be 44, 65, or 87 (got '$lvl')." ;; esac
  local dir="$HTTPD_PREFIX/conf"
  local rootkey="$dir/root-mldsa$lvl.key" rootcrt="$dir/root-mldsa$lvl.crt"
  local leafkey="$dir/leaf-mldsa$lvl.key" leafcrt="$dir/leaf-mldsa$lvl.crt"
  local csr="$dir/leaf-mldsa$lvl.csr"      ext="$dir/leaf-mldsa$lvl.ext"
  local ossl="$OPENSSL_PREFIX/bin/openssl"

  log "Generating ML-DSA-$lvl ROOT CA (CN=$MLDSA_CA_CN)..."
  "$ossl" req -x509 -newkey "mldsa$lvl" -nodes -days 3650 \
    -keyout "$rootkey" -out "$rootcrt" \
    -subj "/CN=$MLDSA_CA_CN" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >>"$LOGFILE" 2>&1

  log "Generating ML-DSA-$lvl leaf key + CSR (CN=$CN)..."
  "$ossl" req -new -newkey "mldsa$lvl" -nodes \
    -keyout "$leafkey" -out "$csr" -subj "/CN=$CN" >>"$LOGFILE" 2>&1

  cat > "$ext" <<EXT
subjectAltName=$SAN
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
EXT

  log "Signing leaf with the ML-DSA-$lvl root..."
  "$ossl" x509 -req -in "$csr" \
    -CA "$rootcrt" -CAkey "$rootkey" -CAcreateserial \
    -days 30 -extfile "$ext" -out "$leafcrt" >>"$LOGFILE" 2>&1

  log "Verifying chain locally..."
  if "$ossl" verify -CAfile "$rootcrt" "$leafcrt" >>"$LOGFILE" 2>&1; then
    log "GUARD: leaf verifies against root (ML-DSA chain OK)."
  else
    die "GUARD FAILED: leaf did not verify against root. See $LOGFILE"
  fi

  MLDSA_CRT="$leafcrt"; MLDSA_KEY="$leafkey"; MLDSA_ROOT="$rootcrt"
}

print_trust_import() {
  cat <<EOF

 To make a browser TRUST this chain, copy the ROOT to your CLIENT machine and
 import it (only the root is a trust anchor; the leaf is served automatically):

   Root CA on this host: ${MLDSA_ROOT}
   Copy it down, e.g.:   scp <user>@<this-host>:${MLDSA_ROOT} .

 NOTE (2026): browser TLS engines (Chrome/BoringSSL) verify ML-DSA in the
 handshake, but OS trust-store support lags and is per-platform:
   - Windows 11 24H2+/Server 2025 (July 2026 PQC updates): CNG parses ML-DSA.
   - Linux NSS / Firefox: build-dependent; improving release-by-release.
   - macOS keychain: Security.framework does NOT yet ingest ML-DSA certs
     ("Unknown format in import"). Use Firefox (own NSS store) on macOS instead.

   Windows (PowerShell, admin)  <-- most reliable for a Chrome/Edge padlock:
     Import-Certificate -FilePath root-mldsa${MLDSA_LEVEL}.crt -CertStoreLocation Cert:\\LocalMachine\\Root
   Linux (Chrome/NSS):
     sudo apt-get install -y libnss3-tools
     certutil -d sql:\$HOME/.pki/nssdb -A -t "C,," -n "${MLDSA_CA_CN}" -i root-mldsa${MLDSA_LEVEL}.crt
   Firefox (any OS, bypasses the OS keychain):
     Settings -> Privacy & Security -> Certificates -> View Certificates
       -> Authorities -> Import -> root-mldsa${MLDSA_LEVEL}.crt (trust for websites)
   macOS system keychain (EXPECTED TO FAIL until Apple adds ML-DSA to SecTrust):
     sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root-mldsa${MLDSA_LEVEL}.crt

 Then FULLY restart the browser and reload https://${CN}:${MLDSA_PORT}/
 A green padlock = fully validated ML-DSA-${MLDSA_LEVEL} auth with no public CA.
EOF
}

# --------------------------- single-vhost demo ------------------------------
# Remove every managed vhost block and neutralise stray SSL LoadModule lines,
# so the DEMO block below is the single source of the SSL module + vhost.
strip_managed_blocks() {
  local conf="$HTTPD_PREFIX/conf/httpd.conf"
  [ -f "$conf" ] || die "httpd.conf not found; run 'install' first."
  sed -i '/# >>> PQC-LAB RSA BEGIN/,/# <<< PQC-LAB RSA END/d'     "$conf"
  sed -i '/# >>> PQC-LAB MLDSA BEGIN/,/# <<< PQC-LAB MLDSA END/d' "$conf"
  sed -i '/# >>> PQC-LAB DEMO BEGIN/,/# <<< PQC-LAB DEMO END/d'   "$conf"
  sed -i 's/^LoadModule ssl_module/#LoadModule ssl_module/'                     "$conf"
  sed -i 's/^LoadModule socache_shmcb_module/#LoadModule socache_shmcb_module/' "$conf"
}

# Mint a fresh self-signed cert into the demo path (new key + serial each time).
gen_selfsigned_demo() {
  local alg="$DEMO_SELF_ALG" newkey
  case "$alg" in
    rsa|RSA)                 newkey="rsa:2048" ;;
    mldsa44|mldsa65|mldsa87) newkey="$alg" ;;
    *) die "DEMO_SELF_ALG must be rsa|mldsa44|mldsa65|mldsa87 (got '$alg')." ;;
  esac
  log "Minting self-signed demo cert ($alg, CN=$CN) -> $DEMO_CRT"
  "$OPENSSL_PREFIX/bin/openssl" req -x509 -newkey "$newkey" -nodes -days 30 \
    -keyout "$DEMO_KEY" -out "$DEMO_CRT" \
    -subj "/O=PQC Demo (SELF-SIGNED)/CN=$CN" \
    -addext "subjectAltName=$SAN" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" >>"$LOGFILE" 2>&1
  chmod 600 "$DEMO_KEY" 2>/dev/null; chmod 644 "$DEMO_CRT" 2>/dev/null
}

write_demo_conf() {
  local conf="$HTTPD_PREFIX/conf/httpd.conf"
  sed -i '/# >>> PQC-LAB DEMO BEGIN/,/# <<< PQC-LAB DEMO END/d' "$conf"
  cat >> "$conf" <<EOF

# >>> PQC-LAB DEMO BEGIN  (managed by pqc-apache-setup.sh)
ServerName ${CN}
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
Listen ${DEMO_PORT}
<VirtualHost *:${DEMO_PORT}>
    ServerName ${CN}
    SSLEngine on
    SSLProtocol -all +TLSv1.3
    SSLOpenSSLConfCmd Groups ${PQC_GROUPS}
    SSLCertificateFile    "${DEMO_CRT}"
    SSLCertificateKeyFile "${DEMO_KEY}"
    DocumentRoot "${HTTPD_PREFIX}/htdocs"
</VirtualHost>
# <<< PQC-LAB DEMO END
EOF
  log "Demo vhost on :${DEMO_PORT} -> ${DEMO_CRT}"
}

# Print what is actually being served right now (self-signed vs TLM-issued).
show_served() {
  local port="${1:-$DEMO_PORT}" ossl="$OPENSSL_PREFIX/bin/openssl" pem
  pem=$(printf '' | "$ossl" s_client -connect "127.0.0.1:${port}" -servername "$CN" 2>/dev/null \
        | "$ossl" x509 2>/dev/null)
  if [ -z "$pem" ]; then warn "No certificate retrieved from :${port}"; return 1; fi
  local subj iss alg fp kind
  subj=$(printf '%s' "$pem" | "$ossl" x509 -noout -subject 2>/dev/null | sed -E 's/^subject=? *//')
  iss=$( printf '%s' "$pem" | "$ossl" x509 -noout -issuer  2>/dev/null | sed -E 's/^issuer=? *//')
  alg=$( printf '%s' "$pem" | "$ossl" x509 -noout -text    2>/dev/null | grep -m1 -i "Signature Algorithm" | sed 's/.*: *//')
  fp=$(  printf '%s' "$pem" | "$ossl" x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  kind="TLM-ISSUED"; [ "$subj" = "$iss" ] && kind="SELF-SIGNED"
  cat <<EOF

 Served on :${port}  [${kind}]
   Subject   : ${subj}
   Issuer    : ${iss}
   Signature : ${alg}
   SHA256 FP : ${fp}
EOF
}

# ---------------------------- apache configuration --------------------------
write_base_conf() {
  local conf="$HTTPD_PREFIX/conf/httpd.conf"
  # Prevent double-loading: comment any active ssl/socache LoadModule lines.
  sed -i 's/^LoadModule ssl_module/#LoadModule ssl_module/'                       "$conf"
  sed -i 's/^LoadModule socache_shmcb_module/#LoadModule socache_shmcb_module/'   "$conf"
  # Idempotent: drop our previous managed block, then re-append.
  sed -i '/# >>> PQC-LAB RSA BEGIN/,/# <<< PQC-LAB RSA END/d' "$conf"

  cat >> "$conf" <<EOF

# >>> PQC-LAB RSA BEGIN  (managed by pqc-apache-setup.sh)
ServerName ${CN}
LoadModule ssl_module modules/mod_ssl.so
LoadModule socache_shmcb_module modules/mod_socache_shmcb.so
Listen ${HTTPS_PORT}
<VirtualHost *:${HTTPS_PORT}>
    ServerName ${CN}
    SSLEngine on
    SSLProtocol -all +TLSv1.3
    SSLOpenSSLConfCmd Groups ${PQC_GROUPS}
    SSLCertificateFile    "${HTTPD_PREFIX}/conf/server.crt"
    SSLCertificateKeyFile "${HTTPD_PREFIX}/conf/server.key"
    DocumentRoot "${HTTPD_PREFIX}/htdocs"
</VirtualHost>
# <<< PQC-LAB RSA END
EOF
  log "Base HTTPS vhost written on port ${HTTPS_PORT}."
}

write_mldsa_conf() {
  local conf="$HTTPD_PREFIX/conf/httpd.conf"
  sed -i '/# >>> PQC-LAB MLDSA BEGIN/,/# <<< PQC-LAB MLDSA END/d' "$conf"
  cat >> "$conf" <<EOF

# >>> PQC-LAB MLDSA BEGIN  (managed by pqc-apache-setup.sh)
Listen ${MLDSA_PORT}
<VirtualHost *:${MLDSA_PORT}>
    ServerName ${CN}
    SSLEngine on
    SSLProtocol -all +TLSv1.3
    SSLOpenSSLConfCmd Groups ${PQC_GROUPS}
    SSLCertificateFile    "${MLDSA_CRT}"
    SSLCertificateKeyFile "${MLDSA_KEY}"
    DocumentRoot "${HTTPD_PREFIX}/htdocs"
</VirtualHost>
# <<< PQC-LAB MLDSA END
EOF
  log "ML-DSA-${MLDSA_LEVEL} vhost written on port ${MLDSA_PORT}."
}

# ------------------------------ service control -----------------------------
apache_apply() {
  local ctl="$HTTPD_PREFIX/bin/apachectl"
  log "Running configtest..."
  "$ctl" configtest 2>&1 | tee -a "$LOGFILE"
  if "$HTTPD_PREFIX/bin/httpd" -k stop >/dev/null 2>&1; then sleep 1; fi
  if ! "$ctl" -k start >>"$LOGFILE" 2>&1; then
    err "Apache failed to start. Last error_log lines:"
    tail -n 20 "$HTTPD_PREFIX/logs/error_log" 2>/dev/null | tee -a "$LOGFILE" >&2 || true
    die "Startup failed. See $HTTPD_PREFIX/logs/error_log and $LOGFILE"
  fi
  sleep 1
  log "Apache started."
}

# ------------------------------- health probes ------------------------------
probe_kex() {  # probe_kex <port>
  local port="$1"
  log "Probing hybrid key exchange on port ${port}..."
  local out
  out="$("$OPENSSL_PREFIX/bin/openssl" s_client -connect "127.0.0.1:${port}" \
        -groups X25519MLKEM768 -tls1_3 </dev/null 2>/dev/null || true)"
  local grp; grp="$(printf '%s\n' "$out" | grep -i 'Negotiated .*group' || true)"
  if printf '%s' "$grp" | grep -qi 'X25519MLKEM768'; then
    log "PASS: ${grp#*: } negotiated on ${port}."
    return 0
  fi
  warn "Hybrid group not negotiated on ${port}. Raw: ${grp:-<none>}"
  return 1
}

probe_sig() {  # probe_sig <port> <expected e.g. mldsa87|RSA>
  local port="$1" expect="$2"
  log "Probing certificate signature type on port ${port} (expect ${expect})..."
  local out
  out="$("$OPENSSL_PREFIX/bin/openssl" s_client -connect "127.0.0.1:${port}" \
        -brief </dev/null 2>&1 || true)"
  local sig; sig="$(printf '%s\n' "$out" | grep -i 'Signature type' || true)"
  log "Observed: ${sig:-<none>}"
}

# --------------------------------- summary ----------------------------------
summary_install() {
  local ip; ip="$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<instance-ip>')"
  cat <<EOF

================================ SETUP COMPLETE ===============================
 OpenSSL : $OPENSSL_PREFIX  ($("$OPENSSL_PREFIX/bin/openssl" version | awk '{print $1,$2}'))
 Apache  : $HTTPD_PREFIX
 HTTPS   : port ${HTTPS_PORT}  (self-signed RSA cert + ${PQC_GROUPS%%:*} hybrid KEX)
 Log     : $LOGFILE

 Test from this host:
   $OPENSSL_PREFIX/bin/openssl s_client -connect 127.0.0.1:${HTTPS_PORT} \\
       -groups X25519MLKEM768 -tls1_3 </dev/null 2>/dev/null | grep -i group

 From a browser:  https://${ip}:${HTTPS_PORT}/
   - EC2 security group must allow inbound ${HTTPS_PORT} (and ${MLDSA_PORT} for ML-DSA).
   - Expect the usual "not trusted" warning: the cert is SELF-SIGNED. That is a
     trust-chain warning, NOT a PQC warning. The ML-KEM key exchange is invisible
     to the user and negotiates silently on modern Chrome/Firefox.

 Next: issue and serve an ML-DSA-${MLDSA_LEVEL} certificate (controlled clients only,
 browsers do NOT yet validate ML-DSA chains):
   sudo MLDSA_LEVEL=87 $0 mldsa
===============================================================================
EOF
}

# ----------------------------------- flows ----------------------------------
cmd_install() {
  legal_gate
  preflight
  install_prereqs
  build_openssl
  build_httpd
  gen_selfsigned_rsa
  write_base_conf
  apache_apply
  probe_kex "$HTTPS_PORT" || warn "KEX probe did not pass; review $LOGFILE."
  probe_sig "$HTTPS_PORT" "RSA"
  summary_install
}

cmd_mldsa() {
  preflight
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built. Run 'install' first."
  [ -x "$HTTPD_PREFIX/bin/httpd" ]     || die "Apache not built. Run 'install' first."
  gen_mldsa_cert
  write_mldsa_conf
  apache_apply
  probe_kex "$MLDSA_PORT" || warn "KEX probe did not pass on ${MLDSA_PORT}."
  probe_sig "$MLDSA_PORT" "mldsa$MLDSA_LEVEL"
  cat <<EOF

=========================== ML-DSA-${MLDSA_LEVEL} VHOST READY ==========================
 Serving self-signed ML-DSA-${MLDSA_LEVEL} cert on port ${MLDSA_PORT}.
 Verify signature type (browsers will NOT work here):
   $OPENSSL_PREFIX/bin/openssl s_client -connect 127.0.0.1:${MLDSA_PORT} -brief \\
       </dev/null 2>&1 | grep -i "Signature type"   # expect: mldsa${MLDSA_LEVEL}

 To REPLACE the browser-facing cert instead of running in parallel, re-run with
 HTTPS_PORT and MLDSA_PORT set to the same value (understanding browsers break).
 When your private CA (e.g. DigiCert TLM) can issue ML-DSA, drop the issued
 cert/key in place of server-mldsa${MLDSA_LEVEL}.crt/.key and re-run 'mldsa'.
===============================================================================
EOF
}

cmd_mldsa_ca() {
  preflight
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built. Run 'install' first."
  [ -x "$HTTPD_PREFIX/bin/httpd" ]     || die "Apache not built. Run 'install' first."
  gen_mldsa_ca_chain
  write_mldsa_conf
  apache_apply
  probe_kex "$MLDSA_PORT" || warn "KEX probe did not pass on ${MLDSA_PORT}."
  log "Verifying served chain over TLS (expect Verification: OK)..."
  "$OPENSSL_PREFIX/bin/openssl" s_client -connect "127.0.0.1:${MLDSA_PORT}" \
    -CAfile "$MLDSA_ROOT" -brief </dev/null 2>&1 \
    | grep -iE "Signature type|Verification" | tee -a "$LOGFILE" || true
  cat <<EOF

======================= ML-DSA-${MLDSA_LEVEL} CA CHAIN READY =======================
 Root : ${MLDSA_ROOT}
 Leaf : ${MLDSA_CRT}
        (served on port ${MLDSA_PORT}; browsers will trust it once the root
         is imported, per the instructions below)
===============================================================================
EOF
  print_trust_import
}

cmd_verify() {
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built."
  probe_kex "$HTTPS_PORT" || true
  probe_sig "$HTTPS_PORT" "RSA"
  if "$OPENSSL_PREFIX/bin/openssl" s_client -connect "127.0.0.1:${MLDSA_PORT}" \
       -brief </dev/null >/dev/null 2>&1; then
    probe_kex "$MLDSA_PORT" || true
    probe_sig "$MLDSA_PORT" "mldsa$MLDSA_LEVEL"
  fi
}

cmd_status() {
  echo "OpenSSL : $([ -x "$OPENSSL_PREFIX/bin/openssl" ] && "$OPENSSL_PREFIX/bin/openssl" version || echo 'not installed')"
  echo "Apache  : $([ -x "$HTTPD_PREFIX/bin/httpd" ] && "$HTTPD_PREFIX/bin/httpd" -v | head -1 || echo 'not installed')"
  if [ -x "$HTTPD_PREFIX/bin/httpd" ]; then
    echo "mod_ssl : $(ldd "$HTTPD_PREFIX/modules/mod_ssl.so" 2>/dev/null | grep -i ssl | tr -s ' ' || echo '?')"
  fi
  echo "Running : $(pgrep -af "$HTTPD_PREFIX/bin/httpd" >/dev/null && echo yes || echo no)"
}

# Clear generated cert material and managed vhosts, back to base config.
# Leaves the OpenSSL and Apache builds untouched.
reset_state() {
  log "Resetting demo state (builds are preserved)..."
  if "$HTTPD_PREFIX/bin/httpd" -k stop >/dev/null 2>&1; then sleep 1; log "Apache stopped."; fi
  local conf="$HTTPD_PREFIX/conf/httpd.conf" dir="$HTTPD_PREFIX/conf"
  rm -f "$dir"/server.crt "$dir"/server.key \
        "$dir"/server-mldsa*.crt "$dir"/server-mldsa*.key \
        "$dir"/root-mldsa*.crt "$dir"/root-mldsa*.key \
        "$dir"/leaf-mldsa*.crt "$dir"/leaf-mldsa*.key \
        "$dir"/leaf-mldsa*.csr "$dir"/leaf-mldsa*.ext \
        "$dir"/*.srl 2>/dev/null || true
  log "Generated cert material removed."
  if [ -f "$conf" ]; then
    sed -i '/# >>> PQC-LAB RSA BEGIN/,/# <<< PQC-LAB RSA END/d'     "$conf"
    sed -i '/# >>> PQC-LAB MLDSA BEGIN/,/# <<< PQC-LAB MLDSA END/d' "$conf"
    log "Managed vhost blocks removed."
  fi
}

cmd_demo() {
  preflight
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built. Run 'install' first."
  [ -x "$HTTPD_PREFIX/bin/httpd" ]     || die "Apache not built. Run 'install' first."

  # Surface the Option A choice BEFORE the baseline cert is minted. Afterwards
  # the algorithm is fixed for this run and switching means re-running demo.
  if [ "$(printf '%s' "$DEMO_SELF_ALG" | tr '[:upper:]' '[:lower:]')" != "rsa" ]; then
    cat <<EOF

 NOTE: self-signed baseline will be ${DEMO_SELF_ALG} — the demo will show the
       ISSUER changing (self-signed -> TLM) but the algorithm staying ML-DSA.
       To make the ALGORITHM itself change, stop now and run instead:

           sudo DEMO_SELF_ALG=rsa ./$(basename "$0") demo
EOF
    # Give an interactive operator a moment to act; never stall unattended runs.
    if [ "$ACCEPT" != "1" ]; then
      printf '\n       Continuing with %s in 5s (Ctrl-C to abort)...\n' "$DEMO_SELF_ALG"
      sleep 5
    fi
  fi

  strip_managed_blocks
  gen_selfsigned_demo
  write_demo_conf
  apache_apply
  probe_kex "$DEMO_PORT" || warn "KEX probe did not pass on :$DEMO_PORT"

  local alg_hint
  if [ "$(printf '%s' "$DEMO_SELF_ALG" | tr '[:upper:]' '[:lower:]')" = "rsa" ]; then
    alg_hint=" Baseline is RSA, so the TLM-issued cert will change the ALGORITHM itself
 (RSA -> ML-DSA) and not only the issuer."
  else
    alg_hint=" Baseline is ${DEMO_SELF_ALG}, so only the ISSUER will change. Re-run with
 DEMO_SELF_ALG=rsa to make the algorithm itself change instead."
  fi

  cat <<EOF

=============================== DEMO READY ===================================
 One PQC vhost on :${DEMO_PORT}, currently serving a SELF-SIGNED cert.
 Served file (TLM overwrites this exact path): ${DEMO_CRT}
 Browse: https://${CN}:${DEMO_PORT}/   (needs ${CN} -> this host in DNS/hosts)

 Demo loop:
   1) Show the self-signed cert in the browser.
   2) Issue via TLM -> the AWR script overwrites ${DEMO_CRT} and reloads Apache.
   3) Refresh the browser -> the new TLM-issued cert is shown.
   4) sudo DEMO_SELF_ALG=${DEMO_SELF_ALG} ./$(basename "$0") reset
                                      -> fresh self-signed cert, and repeat.

${alg_hint}
 NB: reset re-reads DEMO_SELF_ALG every time -- a bare 'reset' falls back to the
 mldsa87 default, so keep the prefix above to stay on this baseline.
===============================================================================
EOF
  show_served "$DEMO_PORT"
}

cmd_reset() {
  preflight
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built. Run 'install' first."
  [ -x "$HTTPD_PREFIX/bin/httpd" ]     || die "Apache not built. Run 'install' first."
  strip_managed_blocks          # guarantee a single clean demo vhost
  gen_selfsigned_demo           # fresh self-signed (new key + serial)
  write_demo_conf
  apache_apply
  probe_kex "$DEMO_PORT" || warn "KEX probe did not pass on :$DEMO_PORT"
  log "Reset: :$DEMO_PORT reverted to a fresh self-signed cert."
  show_served "$DEMO_PORT"
}

cmd_show() {
  [ -x "$OPENSSL_PREFIX/bin/openssl" ] || die "OpenSSL not built."
  show_served "$DEMO_PORT"
}

# ----------------------------------- main -----------------------------------
main() {
  # strip a leading --accept flag if present
  local args=()
  for x in "$@"; do
    case "$x" in --accept) ACCEPT=1 ;; --force) FORCE=1 ;; *) args+=("$x") ;; esac
  done
  set -- "${args[@]:-}"

  local cmd="${1:-install}"
  ensure_root "$@"
  case "$cmd" in
    install) cmd_install ;;
    demo)    cmd_demo ;;
    reset)   cmd_reset ;;
    show)    cmd_show ;;
    mldsa)   cmd_mldsa ;;
    mldsa-ca) cmd_mldsa_ca ;;
    verify)  cmd_verify ;;
    status)  cmd_status ;;
    *) die "Unknown command '$cmd'. Use: install | demo | reset | show | mldsa | mldsa-ca | verify | status" ;;
  esac
}

main "$@"