#!/bin/bash
###############################################################################
# certinfo.cgi — live TLS certificate inspector for the PQC demo vhost.
#
# Renders the certificate the browser is CURRENTLY connected with, derived from
# mod_ssl's exported cert (SSL_SERVER_CERT) using the PQC-capable OpenSSL, so
# ML-DSA is displayed correctly and the page reflects a cert swap on reload.
#
# Enable in the demo vhost (see notes at end of file).
###############################################################################

OSSL="${PQC_OPENSSL:-/opt/openssl-pqc/bin/openssl}"
# Hybrid KEX group this lab configures. Used for the "Key exchange" layer badge
# when mod_ssl doesn't export the live negotiated group. Keep in sync with
# PQC_GROUPS in pqc-apache-setup.sh.
EXPECTED_GROUP="${EXPECTED_GROUP:-X25519MLKEM768}"

# HTML-escape helper
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

CERT_PEM="${SSL_SERVER_CERT:-}"

PROTO="$(esc "${SSL_PROTOCOL:-—}")"
CIPHER="$(esc "${SSL_CIPHER:-—}")"
GROUP_RAW="${SSL_GROUP:-${SSL_SERVER_GROUP:-}}"   # not exported by all builds

SUBJECT="—"; ISSUER="—"; SIGALG="—"; KEYALG="—"; SERIAL="—"
NOTBEFORE="—"; NOTAFTER="—"; SANS="—"; FP="—"
STATE_LABEL="No certificate"; STATE_CLASS="is-none"; STATE_NOTE=""

if [ -n "$CERT_PEM" ] && [ -x "$OSSL" ]; then
  TXT="$(printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -text 2>/dev/null)"
  s_subj="$(printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -subject 2>/dev/null | sed -E 's/^subject=? *//')"
  s_iss="$( printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -issuer  2>/dev/null | sed -E 's/^issuer=? *//')"
  s_ser="$( printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -serial  2>/dev/null | sed -E 's/^serial=//')"
  s_nb="$(  printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -startdate 2>/dev/null | sed -E 's/^notBefore=//')"
  s_na="$(  printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -enddate   2>/dev/null | sed -E 's/^notAfter=//')"
  s_fp="$(  printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  s_sig="$( printf '%s' "$TXT" | grep -m1 -i 'Signature Algorithm' | sed -E 's/.*: *//')"
  s_key="$( printf '%s' "$TXT" | grep -m1 -i 'Public Key Algorithm' | sed -E 's/.*: *//')"
  s_san="$( printf '%s' "$CERT_PEM" | "$OSSL" x509 -noout -ext subjectAltName 2>/dev/null \
            | grep -i 'DNS:' | sed -E 's/^ *//' )"

  [ -n "$s_subj" ] && SUBJECT="$(esc "$s_subj")"
  [ -n "$s_iss" ]  && ISSUER="$(esc "$s_iss")"
  [ -n "$s_ser" ]  && SERIAL="$(esc "$s_ser")"
  [ -n "$s_nb" ]   && NOTBEFORE="$(esc "$s_nb")"
  [ -n "$s_na" ]   && NOTAFTER="$(esc "$s_na")"
  [ -n "$s_fp" ]   && FP="$(esc "$s_fp")"
  [ -n "$s_sig" ]  && SIGALG="$(esc "$s_sig")"
  [ -n "$s_key" ]  && KEYALG="$(esc "$s_key")"
  [ -n "$s_san" ]  && SANS="$(esc "$s_san")"

  if [ -n "$s_subj" ] && [ "$s_subj" = "$s_iss" ]; then
    STATE_LABEL="Self-signed"; STATE_CLASS="is-selfsigned"
    STATE_NOTE="Subject equals issuer — no CA in the path."
  elif [ -n "$s_subj" ]; then
    STATE_LABEL="CA-issued"; STATE_CLASS="is-issued"
    STATE_NOTE="Signed by an issuing authority."
  fi
fi

HOSTPORT="$(esc "${HTTP_HOST:-${SERVER_NAME:-localhost}}")"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Authentication layer — classified from the certificate's own signing key.
AUTH_CLASS="classical"; AUTH_LABEL="Classical"
case "$(lc "${s_key:-}${s_sig:-}")" in
  *ml-dsa*|*mldsa*|*dilithium*|*slh-dsa*|*sphincs*|*falcon*) AUTH_CLASS="pq"; AUTH_LABEL="Post-quantum" ;;
esac
[ -z "${s_subj:-}" ] && { AUTH_CLASS="none"; AUTH_LABEL="—"; }

# Key-exchange layer — prefer the live negotiated group if exported, else the
# lab's configured hybrid group (labelled as server-offered).
if [ -n "$GROUP_RAW" ]; then
  KEX_GROUP="$GROUP_RAW"; KEX_NOTE="negotiated this session"
else
  KEX_GROUP="$EXPECTED_GROUP"; KEX_NOTE="server-offered · live group not exported by this build"
fi
case "$(lc "$KEX_GROUP")" in
  *mlkem*|*kyber*) KEX_CLASS="pq";        KEX_LABEL="Post-quantum" ;;
  *)               KEX_CLASS="classical"; KEX_LABEL="Classical" ;;
esac
KEX_GROUP_ESC="$(esc "$KEX_GROUP")"

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store\r\n\r\n'

cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PQC TLS Certificate — ${SUBJECT}</title>
<style>
  /* ---------------------------------------------------------------------
     DigiCert-styled palette. These hex values are a close approximation of
     the DigiCert look (deep navy + brand blue on a light ground). Replace
     them with the exact values from the DigiCert brand kit if you have it —
     everything else in this stylesheet is driven from these tokens.
     --------------------------------------------------------------------- */
  :root{
    color-scheme:light;
    --navy:#0B2C4D;          /* headings, top bar, primary text */
    --navy-deep:#06203A;     /* top bar gradient end */
    --blue:#0F70B7;          /* DigiCert brand blue - accents, rules */
    --blue-bright:#1E9CE8;   /* lighter blue for gradients */
    --green:#0E8F5F;         /* post-quantum / CA-issued */
    --green-tint:#E9F6F0;
    --amber:#B77400;         /* classical / self-signed */
    --amber-tint:#FDF5E6;
    --page:#F3F6FA;          /* page background */
    --card:#FFFFFF;          /* card surfaces */
    --line:#DCE5EF;          /* hairlines and card borders */
    --ink:#12283F;           /* body copy */
    --muted:#5A7189;         /* secondary copy */
    --dim:#7C8FA3;           /* field labels */
    --mono:ui-monospace,"SFMono-Regular",Menlo,Consolas,monospace;
    --sans:"Segoe UI",system-ui,-apple-system,Roboto,Helvetica,Arial,sans-serif;
    --shadow:0 1px 2px rgba(11,44,77,.06), 0 12px 28px -18px rgba(11,44,77,.35);
  }
  *{box-sizing:border-box}
  html,body{margin:0}
  body{
    background:var(--page); color:var(--ink); font-family:var(--sans);
    line-height:1.5; -webkit-font-smoothing:antialiased; min-height:100vh;
  }

  /* ---- top bar / brand lockup ---- */
  .topbar{
    background:linear-gradient(100deg,var(--navy-deep),var(--navy) 55%,#0E3963);
    border-bottom:3px solid var(--blue);
  }
  .topbar .inner{
    max-width:1000px; margin:0 auto; padding:14px clamp(16px,4vw,32px);
    display:flex; align-items:center; justify-content:space-between; gap:16px; flex-wrap:wrap;
  }
  .brand{display:flex; align-items:center; gap:10px; color:#fff}
  .brand svg{display:block; flex:none}
  .brand .name{font-size:1.18rem; font-weight:700; letter-spacing:-.02em}
  .brand .name span{font-weight:400; opacity:.72}
  .topbar .tag{
    font-family:var(--mono); font-size:.68rem; letter-spacing:.18em; text-transform:uppercase;
    color:#CFE4F6; background:rgba(255,255,255,.10); border:1px solid rgba(255,255,255,.20);
    padding:5px 11px; border-radius:999px; white-space:nowrap;
  }

  .wrap{max-width:1000px; margin:0 auto; padding:clamp(22px,4vw,40px) clamp(16px,4vw,32px) 44px}

  h1{font-size:clamp(1.35rem,2.8vw,1.85rem); font-weight:700; color:var(--navy);
     margin:0 0 6px; letter-spacing:-.02em}
  .sub{color:var(--muted); font-size:.95rem; margin:0 0 26px; max-width:64ch}

  /* ---- connection strip ---- */
  .conn{
    display:flex; flex-wrap:wrap; gap:1px; background:var(--line);
    border:1px solid var(--line); border-radius:10px; overflow:hidden;
    margin-bottom:20px; box-shadow:var(--shadow);
  }
  .conn .cell{background:var(--card); padding:13px 18px; flex:1 1 190px}
  .conn .k{font-family:var(--mono); font-size:.64rem; letter-spacing:.16em;
           text-transform:uppercase; color:var(--dim)}
  .conn .v{font-family:var(--mono); font-size:.92rem; color:var(--navy);
           margin-top:4px; word-break:break-word}

  /* ---- the two PQC layers: key exchange + authentication ---- */
  .layers{display:grid; grid-template-columns:1fr 1fr; gap:14px; margin-bottom:14px}
  .layer{
    background:var(--card); border:1px solid var(--line); border-left:4px solid var(--dim);
    border-radius:10px; padding:15px 18px; box-shadow:var(--shadow);
  }
  .layer.is-pq{border-left-color:var(--green)}
  .layer.is-classical{border-left-color:var(--amber)}
  .layer.is-none{border-left-color:var(--dim)}
  .layer-k{display:block; font-family:var(--mono); font-size:.64rem; letter-spacing:.18em;
           text-transform:uppercase; color:var(--dim)}
  .layer-badge{
    display:inline-block; margin:9px 0 7px; font-family:var(--mono); font-size:.66rem;
    font-weight:600; letter-spacing:.12em; text-transform:uppercase;
    padding:3px 11px; border-radius:999px; border:1px solid currentColor;
  }
  .layer.is-pq .layer-badge{color:var(--green); background:var(--green-tint)}
  .layer.is-classical .layer-badge{color:var(--amber); background:var(--amber-tint)}
  .layer.is-none .layer-badge{color:var(--dim); background:#EEF2F6}
  .layer-v{display:block; font-family:var(--mono); font-size:.9rem; color:var(--navy); word-break:break-word}
  .layer-note{display:block; color:var(--muted); font-size:.76rem; margin-top:5px}
  .layers-cap{color:var(--muted); font-size:.85rem; margin:0 0 22px; max-width:78ch}
  @media (max-width:560px){.layers{grid-template-columns:1fr}}

  /* ---- hero: current certificate state ---- */
  .hero{
    position:relative; background:var(--card);
    border:1px solid var(--line); border-left:5px solid var(--blue);
    border-radius:10px; padding:clamp(20px,3.6vw,32px);
    margin-bottom:20px; box-shadow:var(--shadow); overflow:hidden;
  }
  .hero::after{
    content:""; position:absolute; inset:0; pointer-events:none;
    background:radial-gradient(90% 120% at 100% 0%, rgba(30,156,232,.09), transparent 62%);
  }
  .hero > *{position:relative}
  .badge{
    display:inline-flex; align-items:center; gap:8px; font-family:var(--mono);
    font-size:.7rem; font-weight:600; letter-spacing:.14em; text-transform:uppercase;
    padding:6px 13px; border-radius:999px; border:1px solid currentColor;
  }
  .badge::before{content:""; width:8px; height:8px; border-radius:50%; background:currentColor}
  .badge.is-selfsigned{color:var(--amber); background:var(--amber-tint)}
  .badge.is-issued{color:var(--green); background:var(--green-tint)}
  .badge.is-none{color:var(--dim); background:#EEF2F6}
  .state-note{color:var(--muted); font-size:.88rem; margin:12px 0 0}

  .siglabel{font-family:var(--mono); font-size:.64rem; letter-spacing:.2em;
            text-transform:uppercase; color:var(--dim); margin:24px 0 8px}
  .sigalg{
    font-family:var(--mono); font-weight:700; letter-spacing:-.02em; color:var(--navy);
    font-size:clamp(1.7rem,5.4vw,3rem); line-height:1.06; word-break:break-word;
  }
  .keyalg{font-family:var(--mono); color:var(--muted); font-size:.92rem;
          margin:14px 0 0; padding-top:14px; border-top:1px solid var(--line)}
  .keyalg b{color:var(--navy); font-weight:600}

  /* ---- certificate detail grid ---- */
  .sectionlabel{
    font-family:var(--mono); font-size:.64rem; letter-spacing:.2em; text-transform:uppercase;
    color:var(--dim); margin:0 0 10px;
  }
  .grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:1px;
        background:var(--line); border:1px solid var(--line); border-radius:10px;
        overflow:hidden; box-shadow:var(--shadow)}
  .field{background:var(--card); padding:16px 18px}
  .field.full{grid-column:1/-1}
  .field .k{font-family:var(--mono); font-size:.64rem; letter-spacing:.16em;
            text-transform:uppercase; color:var(--dim); margin-bottom:6px}
  .field .v{font-family:var(--mono); font-size:.88rem; color:var(--ink);
            word-break:break-word; white-space:pre-wrap}

  footer{
    color:var(--muted); font-family:var(--mono); font-size:.7rem; margin-top:28px;
    padding-top:16px; border-top:1px solid var(--line);
    display:flex; flex-wrap:wrap; gap:6px 18px; justify-content:space-between;
  }
  footer .host{color:var(--navy)}

  @media (prefers-reduced-motion:no-preference){
    .hero,.conn,.layers,.grid{animation:rise .45s cubic-bezier(.2,.7,.2,1) both}
    .grid{animation-delay:.06s}
  }
  @keyframes rise{from{opacity:0; transform:translateY(8px)} to{opacity:1; transform:none}}
</style>
</head>
<body>
  <header class="topbar">
    <div class="inner">
      <div class="brand">
        <svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
          <defs>
            <linearGradient id="dcmark" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#1E9CE8"/>
              <stop offset="1" stop-color="#0F70B7"/>
            </linearGradient>
          </defs>
          <path d="M16 2.2 27.4 6v9.3c0 6.9-4.6 12.3-11.4 14.5C9.2 27.6 4.6 22.2 4.6 15.3V6z" fill="url(#dcmark)"/>
          <path d="M10.6 16.1l3.7 3.8 7.1-7.5" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        <div class="name">digi<span>cert</span></div>
      </div>
      <div class="tag">Post-Quantum TLS Demo</div>
    </div>
  </header>

  <div class="wrap">
    <h1>Live certificate inspector</h1>
    <p class="sub">Showing the certificate this browser session is connected with. Reload after issuing from Trust Lifecycle Manager to see it change.</p>

    <div class="conn">
      <div class="cell"><div class="k">TLS Protocol</div><div class="v">${PROTO}</div></div>
      <div class="cell"><div class="k">Cipher Suite</div><div class="v">${CIPHER}</div></div>
      <div class="cell"><div class="k">Key Exchange Group</div><div class="v">${KEX_GROUP_ESC}</div></div>
    </div>

    <section class="layers">
      <div class="layer is-${KEX_CLASS}">
        <span class="layer-k">Key exchange</span>
        <span class="layer-badge">${KEX_LABEL}</span>
        <span class="layer-v">${KEX_GROUP_ESC}</span>
        <span class="layer-note">${KEX_NOTE}</span>
      </div>
      <div class="layer is-${AUTH_CLASS}">
        <span class="layer-k">Authentication</span>
        <span class="layer-badge">${AUTH_LABEL}</span>
        <span class="layer-v">${KEYALG}</span>
        <span class="layer-note">certificate signing key</span>
      </div>
    </section>
    <p class="layers-cap">Key exchange and authentication are independent layers. A server can be quantum-safe for key exchange (ML-KEM) while still presenting a classical certificate — which is exactly what a PQC key-exchange checker reports "ready". Issuing an ML-DSA certificate makes authentication post-quantum too.</p>

    <section class="hero">
      <span class="badge ${STATE_CLASS}">${STATE_LABEL}</span>
      <p class="state-note">${STATE_NOTE}</p>
      <p class="siglabel">Certificate signature algorithm</p>
      <div class="sigalg">${SIGALG}</div>
      <p class="keyalg">Public key algorithm &middot; <b>${KEYALG}</b></p>
    </section>

    <p class="sectionlabel">Certificate details</p>
    <div class="grid">
      <div class="field"><div class="k">Subject</div><div class="v">${SUBJECT}</div></div>
      <div class="field"><div class="k">Issuer</div><div class="v">${ISSUER}</div></div>
      <div class="field"><div class="k">Valid from</div><div class="v">${NOTBEFORE}</div></div>
      <div class="field"><div class="k">Valid to</div><div class="v">${NOTAFTER}</div></div>
      <div class="field"><div class="k">Serial</div><div class="v">${SERIAL}</div></div>
      <div class="field"><div class="k">Subject alternative names</div><div class="v">${SANS}</div></div>
      <div class="field full"><div class="k">SHA-256 fingerprint</div><div class="v">${FP}</div></div>
    </div>

    <footer>
      <span class="host">${HOSTPORT}</span>
      <span>Rendered ${NOW}</span>
    </footer>
  </div>
</body>
</html>
EOF

###############################################################################
# ENABLE IN THE DEMO VHOST
#
#   1) Place this file at:  /opt/httpd-pqc/htdocs/index.cgi   (chmod 755)
#   2) In the demo <VirtualHost> add:
#        SSLOptions +StdEnvVars +ExportCertData
#        <Directory "/opt/httpd-pqc/htdocs">
#            Options +ExecCGI
#            AddHandler cgi-script .cgi
#            DirectoryIndex index.cgi
#        </Directory>
#   3) Ensure the CGI module is loaded (event MPM uses cgid):
#        LoadModule cgid_module modules/mod_cgid.so
#   4) apachectl -k graceful
#
# +ExportCertData is what populates SSL_SERVER_CERT (used to derive every field
# with the PQC OpenSSL). Without it the page shows a "no certificate" state.
###############################################################################
