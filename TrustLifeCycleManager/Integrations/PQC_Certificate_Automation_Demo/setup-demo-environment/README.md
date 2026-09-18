# PQC TLS Demo — Apache + DigiCert TLM (ML-DSA)

A self-contained lab that stands up an Apache web server with **post-quantum TLS**
on a fresh Ubuntu 26.04 EC2 instance, then demonstrates a certificate going from a
**self-signed** placeholder to one **issued by DigiCert TLM's PQC CA** — live, in the
browser, on a single URL.

Two independent post-quantum pieces are exercised:

- **Key exchange** — hybrid `X25519MLKEM768` (ML-KEM), negotiated automatically by
  modern browsers. Invisible to the user; no warning either way.
- **Authentication** — an **ML-DSA-87** certificate (FIPS 204), issued by TLM and
  deployed to the vhost by an AWR post-enrollment script.

Everything is built from source against **OpenSSL 3.5** (the first release with native
ML-KEM + ML-DSA) into isolated prefixes, so nothing touches the distro's system OpenSSL.

---

## Repository contents

| File | Purpose |
|------|---------|
| `pqc-apache-setup.sh` | Builds OpenSSL + Apache, manages vhosts and certificates, runs the demo loop. Primary tool. |
| `cgi-prereqs.sh` | One-time enablement of the CGI test page (module + config + install). |
| `certinfo.cgi` | Styled test page that shows the **live** served certificate (subject, issuer, signature algorithm, fingerprint). |
| `awr-pqc-vhost-deploy.sh` | DigiCert TLM **AWR post-enrollment** script — validates the issued cert/key and deploys it to the vhost. |
| `README.md` | This document. |

---

## Prerequisites

- A fresh **Ubuntu 26.04** EC2 instance (other versions may work; only 26.04 is tested).
- Outbound internet from the instance for the initial source downloads.
- **Security group**: inbound TCP for the demo port (`443` by default). The `mldsa`/`mldsa-ca`
  modes use `8443`; open that too if you use them.
- **Name resolution**: the demo certificate CN is `pqc-demo.digicert-demo.com`. For browser
  testing that name must resolve to the instance — real DNS, or a `hosts` entry on the client
  pointing the name at the instance's public IP.
- Run the scripts with `sudo` (they re-exec themselves under sudo if needed).

> **Always use the PQC OpenSSL** at `/opt/openssl-pqc/bin/openssl` for any manual checks.
> The distro/system OpenSSL (and LibreSSL on macOS) cannot parse ML-DSA and will mislead you.

---

## How it fits together

```
                         issues ML-DSA-87 cert
   DigiCert TLM  ───────────────────────────────►  AWR script (awr-pqc-vhost-deploy.sh)
   (PQC CA)                                              │ validates + deploys
                                                         ▼
   Browser  ──TLS 1.3 (X25519MLKEM768)──►  Apache demo vhost  :443
   (Chrome 151)                              serves /opt/httpd-pqc/conf/tlm-pqc.crt
                                                         │
                                              certinfo.cgi renders the live cert
```

The demo vhost, the `reset` command, and the AWR script all read/write the **same file**
(`/opt/httpd-pqc/conf/tlm-pqc.crt` on port `443`). Whatever last wrote to that slot is what
the browser sees — that shared path is what makes the self-signed ↔ issued swap seamless.

Key install locations:

| Thing | Path |
|-------|------|
| OpenSSL (from source) | `/opt/openssl-pqc` |
| Apache (from source) | `/opt/httpd-pqc` |
| Demo cert / key (shared slot) | `/opt/httpd-pqc/conf/tlm-pqc.crt` / `.key` |
| CGI test page | `/opt/httpd-pqc/htdocs/index.cgi` |
| Setup log | `/var/log/pqc-apache-setup.log` |

---

## Quick start (end to end)

```bash
# 1. Build OpenSSL 3.5 + Apache (~15–40 min depending on instance size)
sudo ./pqc-apache-setup.sh install

# 2. Stand up the single-vhost demo (self-signed cert on :8443)
sudo ./pqc-apache-setup.sh demo

# 3. Enable the styled test page (one-time)
sudo ./cgi-prereqs.sh ./certinfo.cgi
```

Browse to `https://pqc-demo.digicert-demo.com/`. You'll see the self-signed certificate.
Issue from TLM (the AWR script deploys it), reload, and the page shows the ML-DSA-87 cert.
Run `sudo ./pqc-apache-setup.sh reset` to return to a fresh self-signed cert and repeat.

---

## Scripts and commands

### `pqc-apache-setup.sh`

The main tool. First positional argument is the command (default `install`).

| Command | What it does |
|---------|--------------|
| `install` | Builds OpenSSL 3.5 + Apache from source; creates a self-signed RSA vhost on `443` plus the hybrid KEX config. Multi-vhost mode. |
| `demo` | Single-vhost demo on `DEMO_PORT` (443): mints a self-signed cert at the shared `tlm-pqc.*` path that TLM later overwrites. Strips other managed vhosts for a clean single vhost. |
| `reset` | Re-mints a **fresh** self-signed cert on the demo vhost (new key + serial) and reloads. Use between demo runs to return to the self-signed state. |
| `show` | Prints the subject / issuer / signature algorithm / SHA-256 fingerprint currently served on `DEMO_PORT`, tagged `[SELF-SIGNED]` or `[TLM-ISSUED]`. |
| `mldsa` | Serves a self-signed ML-DSA-`<level>` cert on `MLDSA_PORT` (parallel to install's RSA vhost). |
| `mldsa-ca` | Builds a private ML-DSA **root + leaf chain**, serves the leaf, and prints per-OS root-import instructions (for a trusted padlock). |
| `verify` | Re-runs the PQC handshake health probes. |
| `status` | Shows what is installed, mod_ssl linkage, and whether Apache is running. |

Flags: `--accept` (skip the legal/usage gate for unattended runs), `--force` (rebuild even if present).

**Build vs demo modes.** `install` produces a multi-vhost layout (RSA on 443, optional ML-DSA on 8443).
`demo`/`reset` are a **standalone single-vhost** mode — they strip the install/mldsa vhost blocks so there is
exactly one clean demo vhost (and no duplicate `LoadModule`). To go back to the multi-vhost layout, re-run `install`.

### `cgi-prereqs.sh`

One-time enablement of `certinfo.cgi`. Detects the Apache MPM and loads the correct CGI module
(`mod_cgid` for the event MPM), installs the page as `index.cgi`, and writes a **self-contained**
`# >>> PQC-LAB CGI` config block (scoped to the DocumentRoot) with `+ExecCGI`, the `.cgi` handler,
`DirectoryIndex index.cgi`, and `SSLOptions +StdEnvVars +ExportCertData`.

```bash
sudo ./cgi-prereqs.sh [path-to-certinfo.cgi]   # default: ./certinfo.cgi
```

Because the CGI directives live in their own block (not inside the vhost), running `demo`/`reset`
afterwards will **not** disable the page. `+ExportCertData` is what populates the cert data the page
renders; without it the page shows a "No certificate" state.

### `awr-pqc-vhost-deploy.sh` (DigiCert TLM AWR post-enrollment)

Runs on the target host, triggered by TLM after issuance. It decodes `DC1_POST_SCRIPT_DATA`, then in its
custom section:

1. Validates the issued cert parses and logs its signature algorithm.
2. Validates the private key parses (with an ML-DSA seed-vs-expanded encoding hint if it fails).
3. Confirms the key matches the certificate (public-key comparison — algorithm-agnostic).
4. Deploys to the vhost path (**overwrite in place, no backup**), sets permissions.
5. `configtest`, then **graceful** reload (safe: cert-only change, no dropped connections).
6. Health-probes the port and compares served vs deployed fingerprints.

The validate-before-reload ordering means a bad or mismatched cert never reaches the live service —
Apache keeps its loaded cert until a successful reload.

Deploy target defaults (overridable via the AWR `args` array — `ARGUMENT_1/2/3`):

| Setting | Default |
|---------|---------|
| Cert path | `/opt/httpd-pqc/conf/tlm-pqc.crt` |
| Key path | `/opt/httpd-pqc/conf/tlm-pqc.key` |
| Probe port | `443` |

Set `LEGAL_NOTICE_ACCEPT="true"` (in the template or via the TLM profile) for the script to run.
Ensure the TLM agent's execution user can write to `/opt/httpd-pqc/conf` and reload Apache.

### `certinfo.cgi`

A styled page rendered server-side from the **live** TLS certificate (via mod_ssl's exported cert,
parsed with the PQC OpenSSL). Leads with the signature algorithm, shows a state badge that flips
amber "Self-signed" ↔ green "CA-issued" (by comparing subject to issuer), plus subject, issuer,
validity, serial, SANs, and the SHA-256 fingerprint. No external assets — works offline.

---

## Demo runbook (the loop)

```bash
sudo ./pqc-apache-setup.sh demo    # self-signed cert on :443
# → browse https://pqc-demo.digicert-demo.com/  (shows self-signed)

# → issue via TLM; the AWR script overwrites tlm-pqc.crt and reloads
# → refresh the browser  (shows the ML-DSA-87 issued cert)

sudo ./pqc-apache-setup.sh reset   # back to a fresh self-signed cert
sudo ./pqc-apache-setup.sh show    # print what's served right now, anytime
```

### Option A — start on RSA, replace with ML-DSA (works great)

To make the **algorithm itself** visibly change (RSA → ML-DSA-87) rather than just the issuer,
set the self-signed baseline to RSA when standing up the demo:

```bash
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo
```

The page then shows an **RSA** self-signed cert; after TLM issues the ML-DSA-87 cert and the AWR
script swaps it in, a reload shows the signature algorithm change to **ML-DSA-87**. The certificate's
algorithm is independent of the hybrid KEX config, so Apache and OpenSSL 3.5 serve either without any
other change.

> **`reset` does not remember the baseline.** `DEMO_SELF_ALG` is read fresh on every invocation and
> applied when the cert is minted, so a bare `sudo ./pqc-apache-setup.sh reset` returns to the
> **`mldsa87`** default — not to RSA. To stay on Option A, pass it every time:
>
> ```bash
> sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh reset
> ```
>
> Or bake it in by changing the default on the `DEMO_SELF_ALG` line in the script's configuration block.

---

## Verifying a TLM-issued certificate manually

Always with the PQC OpenSSL:

```bash
OSSL=/opt/openssl-pqc/bin/openssl

# 1. Algorithm (expect ML-DSA on both lines)
$OSSL x509 -in cert.crt -noout -text | grep -iA1 "Signature Algorithm\|Public Key Algorithm"

# 2. Key parses
$OSSL pkey -in cert.key -noout -text | head -3

# 3. Key matches the cert (no output = match)
diff <($OSSL x509 -in cert.crt -noout -pubkey) <($OSSL pkey -in cert.key -pubout)

# 4. Chain / CA signature verifies
$OSSL verify -CAfile chain.pem cert.crt

# 5. On the wire (expect: Signature type: mldsa87 / Verification: OK)
$OSSL s_client -connect 127.0.0.1:443 -CAfile chain.pem -brief </dev/null 2>&1 \
  | grep -iE "Signature type|Verification"
```

If the key fails to parse, suspect the FIPS 204 private-key encoding (seed-only vs expanded) — tools
sometimes disagree on the format.

---

## Browser trust & per-OS support

The **key exchange** half is done: Chrome 131+, Firefox, and Safari all negotiate `X25519MLKEM768`
by default. No configuration, no warning.

The **authentication** half (ML-DSA certificates) is newer and splits into two questions — *does the
TLS engine verify ML-DSA?* and *can the OS trust store hold an ML-DSA root?*

| Client / platform | ML-DSA handshake | Import ML-DSA root into trust store |
|-------------------|------------------|-------------------------------------|
| Chrome 151 (BoringSSL) | Yes — verifies the cert in the handshake | Uses the platform trust store (below) |
| Windows 11 24H2+ / Server 2025 (July 2026 PQC updates) | — | **Yes** (CNG parses ML-DSA) → most reliable for a trusted padlock |
| Firefox (own NSS store) | Build-dependent | Build-dependent; bypasses the OS keychain |
| Linux NSS (`certutil`) | — | Build-dependent, improving |
| macOS keychain (Security.framework) | — | **No** — cannot import an ML-DSA root yet (`Unknown format in import`) |

Practical upshot for the demo: a self-signed **or** private-CA ML-DSA cert will show a
"not trusted" warning in the browser — that is a **trust-anchor** gap, not an algorithm problem.
You can still click through and inspect the cert (or use `certinfo.cgi`), which is all the demo
needs. For an actual green padlock, use a **Windows** client and import the private root produced by
`pqc-apache-setup.sh mldsa-ca`. On macOS, use Firefox (its own store) rather than the system keychain.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Cert generation fails: `Can't open .../ssl/openssl.cnf` | OpenSSL installed without its config dir. Fixed in-script (`install_ssldirs`); to repair an existing build: `cd <openssl-src> && sudo make install_ssldirs`. |
| `SSLOpenSSLConfCmd Groups 0 failed` at startup | The group value became `0` (an unquoted `GROUPS` shell array). Fixed in-script (renamed to `PQC_GROUPS`); use the current script version. |
| `server certificate is a CA certificate` warning | Self-signed cert had `CA:TRUE`. Fixed in-script (leaf now `CA:FALSE`, `serverAuth`). |
| **503 Service Unavailable** after enabling CGI | A graceful reload does **not** load a new `LoadModule`, and `mod_cgid` needs a full restart. Fix: `sudo /opt/httpd-pqc/bin/apachectl -k stop; sleep 2; sudo .../apachectl -k start`. (Fixed in `cgi-prereqs.sh` — it now full-restarts and verifies `httpd -M`.) |
| AWR log: served fingerprint ≠ deployed | The vhost `SSLCertificateFile` points at a different file than the AWR deploy path. Ensure both use `/opt/httpd-pqc/conf/tlm-pqc.crt`. The `demo` vhost already does. |
| Manual `openssl` errors on ML-DSA | You're using the system/LibreSSL OpenSSL. Use `/opt/openssl-pqc/bin/openssl`. |
| Download 404 during build | Upstream mirror rotated the pinned version. Script falls back to `archive.apache.org`; otherwise bump `HTTPD_VERSION`/`APR_VERSION` env vars. |
| CGI page shows "No certificate" | `+ExportCertData` not reaching the handshake — usually the demo vhost isn't running (`pqc-apache-setup.sh demo`). |

---

## Configuration reference

Override any of these as environment variables (e.g. `sudo DEMO_SELF_ALG=rsa DEMO_PORT=9443 ./pqc-apache-setup.sh demo`).

| Variable | Default | Meaning |
|----------|---------|---------|
| `OPENSSL_VERSION` | `3.5.0` | OpenSSL source version (must be ≥ 3.5). |
| `HTTPD_VERSION` / `APR_VERSION` / `APRUTIL_VERSION` | `2.4.65` / `1.7.6` / `1.6.3` | Apache + APR source versions. |
| `OPENSSL_PREFIX` / `HTTPD_PREFIX` | `/opt/openssl-pqc` / `/opt/httpd-pqc` | Install prefixes. |
| `CN` / `SAN` | `pqc-demo.digicert-demo.com` | Certificate subject / SAN. |
| `PQC_GROUPS` | `X25519MLKEM768:X25519:secp256r1:secp384r1` | TLS 1.3 group preference (hybrid first). |
| `DEMO_PORT` | `443` | Demo vhost port. |
| `DEMO_CRT` / `DEMO_KEY` | `.../conf/tlm-pqc.crt` / `.key` | Shared cert slot (demo, reset, and AWR all use this). |
| `DEMO_SELF_ALG` | `mldsa87` | Self-signed baseline algorithm (`rsa` \| `mldsa44` \| `mldsa65` \| `mldsa87`). **`rsa` = Option A.** |
| `MLDSA_LEVEL` | `87` | ML-DSA parameter set for `mldsa` / `mldsa-ca` (`44` \| `65` \| `87`). |
| `HTTPS_PORT` / `MLDSA_PORT` | `443` / `8443` | Ports for the multi-vhost `install` mode. |

---

## Adapting to your environment

Most settings are environment-variable overrides (see the reference above); a handful **must be
changed together** or the pieces won't line up. Start with the three that have to stay in sync.

### Values that must match across components

| Value | Must be identical in | Symptom if it drifts |
|-------|----------------------|----------------------|
| **Hostname** (`CN` / `SAN`) | the DNS/`hosts` entry, the scripts' `CN`/`SAN`, **and** the SAN on the cert TLM issues | Browser name-mismatch error; cert doesn't match the URL |
| **Deploy path** (`DEMO_CRT` / `DEMO_KEY`) | the setup vhost (`demo`/`reset`) **and** the AWR script's `DEPLOY_CRT`/`DEPLOY_KEY` | AWR log warns "served fingerprint ≠ deployed" (cert lands where nothing serves it) |
| **Port** | `DEMO_PORT` (setup), the AWR probe port / `ARGUMENT_3`, `cgi-prereqs.sh`'s `DEMO_PORT`, and the EC2 security group | Connection refused, or health probe can't confirm the swap |

### Common changes

| To change… | Do this |
|------------|---------|
| The demo hostname | Set `CN` and `SAN` on the setup commands, e.g. `sudo CN=pqc.acme.internal SAN=DNS:pqc.acme.internal ./pqc-apache-setup.sh demo`. Update DNS/`hosts` and the TLM profile's SAN to match. |
| The demo port | Set `DEMO_PORT` on the setup commands, `DEMO_PORT` on `cgi-prereqs.sh`, and the AWR port (edit the script or pass `ARGUMENT_3`). Open the port in the security group. Default is `443`. |
| Install location | Set `OPENSSL_PREFIX` / `HTTPD_PREFIX`. If you do, update the same prefixes in `awr-pqc-vhost-deploy.sh` and `certinfo.cgi` (both hard-reference `/opt/...`). |
| The cert slot path | Set `DEMO_CRT` / `DEMO_KEY` on the setup, and the matching `DEPLOY_CRT` / `DEPLOY_KEY` in the AWR script (or pass `ARGUMENT_1` / `ARGUMENT_2` from TLM). |
| Self-signed baseline algorithm | Set `DEMO_SELF_ALG` (`rsa` \| `mldsa44` \| `mldsa65` \| `mldsa87`). |
| Pinned source versions | Set `OPENSSL_VERSION` / `HTTPD_VERSION` / `APR_VERSION` / `APRUTIL_VERSION` on `install`. |

### Per-file specifics

- **`pqc-apache-setup.sh`** — everything is env-overridable; the defaults live in the `configuration`
  block at the top of the file if you prefer to bake them in for a fixed environment.
- **`awr-pqc-vhost-deploy.sh`** — three things typically need attention:
  - Set `LEGAL_NOTICE_ACCEPT="true"` (in the template or the TLM profile) or the script exits.
  - `LOGFILE` defaults to `/home/ubuntu/awr-template-logfile.log` — change it if the TLM agent runs
    as a different user or on a non-Ubuntu host.
  - The deploy block (`APACHE_PREFIX`, `PQC_OPENSSL`, `DEPLOY_CRT`/`DEPLOY_KEY`, `PQC_VHOST_PORT`)
    hard-references `/opt/...` and port `8443`; edit these, or drive them from TLM via `ARGUMENT_1/2/3`.
- **`certinfo.cgi`** — the OpenSSL path is `PQC_OPENSSL` (defaults to `/opt/openssl-pqc/bin/openssl`);
  change it if your prefix differs. The eyebrow title text (`DigiCert · Post-Quantum TLS Demo`) is
  cosmetic — edit it to rebrand the page for a specific customer or event.
- **`cgi-prereqs.sh`** — respects `HTTPD_PREFIX`, `OPENSSL_PREFIX`, `DOCROOT`, `DEMO_PORT`, and `CN`;
  set the same values you used for the setup so its post-install probe targets the right vhost.

### On the DigiCert TLM side

- Attach `awr-pqc-vhost-deploy.sh` as the profile's **post-enrollment (AWR) script**.
- Issue certificates whose **SAN matches the vhost hostname** used above.
- To keep the AWR script generic across environments, pass the deploy path and port through the
  profile's **argument list** (they arrive as `ARGUMENT_1` = cert path, `ARGUMENT_2` = key path,
  `ARGUMENT_3` = port) rather than editing the script per host.
- Ensure the **TLM agent's execution user** can write to the Apache `conf` directory and reload Apache
  (root is simplest; otherwise grant ownership/`sudo` on `apachectl`).

### Non-Ubuntu / non-root notes

- The scripts use `apt` and assume Ubuntu 26.04. On RHEL-family hosts, replace the build-dependency
  install with the `dnf` equivalents (`gcc`, `make`, `pcre2-devel`, `zlib-devel`, `expat-devel`, `perl`).
- This Apache build runs workers as the `daemon` user. If your TLM agent writes certs as another user,
  align file ownership/permissions so both the agent (write) and Apache master (read) are satisfied.
- Everything installs under `/opt`, so no distro packages are touched; removing the lab is just
  deleting the two prefixes and any managed blocks in `httpd.conf`. Note that `443` is a privileged
  port — the Apache master starts as root (workers drop to `daemon`), which the scripts already handle.

---

## Not yet implemented

- **Option B — dual-cert vhost.** One vhost holding both an RSA and an ML-DSA cert simultaneously,
  with OpenSSL 3.5 selecting per connection from the client's `signature_algorithms` (PQC clients get
  ML-DSA, legacy clients get RSA, same URL). Enabled by listing `SSLCertificateFile`/`SSLCertificateKeyFile`
  twice in the vhost. The CGI page reflects whichever cert *your* browser negotiated.
- **TLM-issued ML-DSA root** in place of the hand-rolled `mldsa-ca` root, for a fully TLM-managed chain.