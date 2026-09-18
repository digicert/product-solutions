# Post-Quantum TLS Demo — Apache + DigiCert Trust Lifecycle Manager (ML-DSA)

A self-contained lab that stands up an Apache web server with **post-quantum TLS**, then demonstrates a certificate moving from a **self-signed** placeholder to one **issued by DigiCert Trust Lifecycle Manager (TLM)** — live, in the browser, on a single URL. Certificate installation is automated by a TLM **Admin Web Request (AWR)** post-enrollment script.

## What the demo proves

Two independent post-quantum pieces are exercised, and the demo page shows them as separate layers:

| Layer | Mechanism | Status today |
|---|---|---|
| **Key exchange** | Hybrid `X25519MLKEM768` (ML-KEM) | Negotiated automatically by Chrome 131+, Firefox and Safari. Invisible to the user, no warning. |
| **Authentication** | **ML-DSA-87** certificate (FIPS 204), issued by TLM | Newer. TLS engines verify it; OS trust stores lag (see *Browser trust*). |

This distinction is the point of the demo: **a server can be quantum-safe for key exchange while still presenting a classical RSA certificate** — which is exactly what a PQC readiness checker reports as "ready". Issuing an ML-DSA certificate makes authentication post-quantum too.

Everything is built from source against **OpenSSL 3.5** (the first release with native ML-KEM + ML-DSA) into isolated prefixes under `/opt`, so nothing touches the distro's system OpenSSL.

---

## Architecture

```
   DigiCert TLM                        Target host (Ubuntu 26.04)
   ─────────────                       ──────────────────────────────────────────
   1. Issues ML-DSA-87 cert
   2. Agent writes .crt/.key   ──────►  <certfolder>/<name>.crt + <name>.key
   3. Runs AWR post-script     ──────►  pqc-certificate-install-awr.sh
      (DC1_POST_SCRIPT_DATA)              │ validate → deploy → configtest
                                          │ → graceful reload → health probe
                                          ▼
                                     /opt/httpd-pqc/conf/tlm-pqc.crt
                                          │
   Browser ──TLS 1.3 (X25519MLKEM768)──►  Apache demo vhost :443
   (Chrome)                                └─ index.cgi renders the live cert
```

The demo vhost, the `reset` command, and the AWR script all read and write the **same file** (`/opt/httpd-pqc/conf/tlm-pqc.crt`). Whatever last wrote to that slot is what the browser sees — that shared path is what makes the self-signed ↔ issued swap seamless.

### Install locations

| Item | Path |
|---|---|
| OpenSSL 3.5 (from source) | `/opt/openssl-pqc` |
| Apache httpd (from source) | `/opt/httpd-pqc` |
| Shared cert slot | `/opt/httpd-pqc/conf/tlm-pqc.crt` / `.key` |
| Test page | `/opt/httpd-pqc/htdocs/index.cgi` |
| Setup log | `/var/log/pqc-apache-setup.log` |
| CGI prep log | `/var/log/cgi-prereqs.log` |
| AWR script log | `/home/ubuntu/pqc-demo-logfile.log` |

### Repository contents

| File | Purpose |
|---|---|
| `setup-demo-environment/pqc-apache-setup.sh` | Builds OpenSSL + Apache, manages vhosts and certificates, runs the demo loop. Primary tool. |
| `setup-demo-environment/cgi-prereqs.sh` | One-time enablement of the CGI test page (module + config + install). |
| `setup-demo-environment/test-page.cgi` | The test page — shows the **live** served certificate and the two PQC layers. |
| `admin-webrequest-post-script/pqc-certificate-install-awr.sh` | TLM **AWR post-enrollment** script — validates the issued cert/key and deploys it to the vhost. |

---

## Prerequisites

### Infrastructure

* A **fresh Ubuntu 26.04** EC2 instance (other versions may work; only 26.04 is tested).
* **Root / sudo** on the host. The scripts re-exec themselves under sudo if needed.
* **Outbound internet** for the initial source downloads (OpenSSL, httpd, APR).
* Build toolchain — installed by the script via `apt` (`gcc`, `make`, `pcre2-dev`, `zlib1g-dev`, `libexpat1-dev`, `perl`).
* Roughly **15–40 minutes** for the first build, depending on instance size.

### Network and naming

* **Security group**: inbound TCP on the demo port (**443** by default).
* **Name resolution**: the demo certificate CN is `pqc-demo.digicert-demo.com`. For browser testing that name must resolve to the instance — real DNS, or a `hosts` entry on the client pointing the name at the instance's public IP.

### DigiCert TLM side

* A certificate profile capable of issuing **ML-DSA-87** certificates from the PQC CA.
* The profile's **SAN must match the vhost hostname** used above.
* `pqc-certificate-install-awr.sh` attached as the profile's **post-enrollment (AWR) script**.
* The **TLM agent installed on the target host**, with its execution user able to:
  * write to `/opt/httpd-pqc/conf`, and
  * run `/opt/httpd-pqc/bin/apachectl` (root is simplest; otherwise grant ownership plus sudo on `apachectl`).

### Host tooling assumed by the AWR script

Linux with **GNU grep** (`grep -oP`), `base64`, `awk`, `stat -c`, `pgrep`, and the PQC OpenSSL present at `/opt/openssl-pqc/bin/openssl`.

> ⚠️ **Always use the PQC OpenSSL** at `/opt/openssl-pqc/bin/openssl` for any manual checks. The distro/system OpenSSL (and LibreSSL on macOS) cannot parse ML-DSA and will mislead you.

---

## Setup

### Step 1 — Build OpenSSL 3.5 + Apache

```bash
sudo ./pqc-apache-setup.sh install
```

Builds both from source into `/opt`, creates a self-signed RSA vhost on `443` plus the hybrid key-exchange configuration.

### Step 2 — Stand up the single-vhost demo

```bash
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo
```

Mints a self-signed certificate at the shared `tlm-pqc.*` path that TLM later overwrites, and strips other managed vhosts so there is exactly one clean demo vhost.

> 💡 **Use `DEMO_SELF_ALG=rsa`.** With the default (`mldsa87`) the demo shows only the **issuer** changing. Starting from RSA makes the **algorithm itself** visibly change (RSA → ML-DSA-87) when TLM issues, which is the more compelling story. The variable is applied when the certificate is minted, so it must be set on the run that creates the baseline.

### Step 3 — Enable the test page (one-time)

```bash
sudo ./cgi-prereqs.sh ./test-page.cgi
```

Detects the Apache MPM, loads the correct CGI module (`mod_cgid` for the event MPM), installs the page as `index.cgi`, and writes a self-contained `# >>> PQC-LAB CGI` config block with `+ExecCGI`, the `.cgi` handler, `DirectoryIndex index.cgi`, and `SSLOptions +StdEnvVars +ExportCertData`.

> ⚠️ **Pass the page path explicitly.** The script's default argument is `./certinfo.cgi`, but the page in this repo is named `test-page.cgi`. Without the argument it will not find the source.

Because the CGI directives live in their own block (not inside the vhost), running `demo` or `reset` afterwards will **not** disable the page. `+ExportCertData` is what populates the certificate data the page renders; without it the page shows a "No certificate" state.

### Step 4 — Confirm

Browse to `https://pqc-demo.digicert-demo.com/`. You should see the self-signed certificate, the TLS protocol and cipher, and the two PQC layer cards.

---

## Command reference — `pqc-apache-setup.sh`

First positional argument is the command (default `install`).

| Command | What it does |
|---|---|
| `install` | Builds OpenSSL 3.5 + Apache from source; self-signed RSA vhost on 443 plus hybrid KEX config. Multi-vhost mode. |
| `demo` | Single-vhost demo on `DEMO_PORT`: mints the self-signed baseline at the shared path TLM later overwrites. |
| `reset` | Re-mints a **fresh** self-signed cert (new key + serial) and reloads. Use between demo runs. |
| `show` | Prints subject / issuer / signature algorithm / SHA-256 fingerprint currently served, tagged `[SELF-SIGNED]` or `[TLM-ISSUED]`. |
| `mldsa` | Serves a self-signed ML-DSA-`<level>` cert on `MLDSA_PORT`. |
| `mldsa-ca` | Builds a private ML-DSA root + leaf chain and prints per-OS root-import instructions. |
| `verify` | Re-runs the PQC handshake health probes. |
| `status` | Shows what is installed, mod_ssl linkage, and whether Apache is running. |

Flags: `--accept` (skip the legal/usage gate for unattended runs), `--force` (rebuild even if present).

### Environment overrides

Prefix any of these to the command.

| Variable | Default | Meaning |
|---|---|---|
| `DEMO_SELF_ALG` | `mldsa87` | Self-signed baseline: `rsa` \| `mldsa44` \| `mldsa65` \| `mldsa87`. |
| `CN` / `SAN` | `pqc-demo.digicert-demo.com` | Certificate subject / SAN. |
| `DEMO_PORT` | `443` | Demo vhost listen port. |
| `DEMO_CRT` / `DEMO_KEY` | `/opt/httpd-pqc/conf/tlm-pqc.crt` / `.key` | The shared cert slot. |
| `PQC_GROUPS` | `X25519MLKEM768:X25519:secp256r1:secp384r1` | TLS 1.3 group preference (hybrid first). |
| `MLDSA_LEVEL` | `87` | ML-DSA parameter set for `mldsa` / `mldsa-ca`. |
| `OPENSSL_PREFIX` / `HTTPD_PREFIX` | `/opt/openssl-pqc` / `/opt/httpd-pqc` | Install prefixes. |
| `OPENSSL_VERSION` | `3.5.0` | Must be ≥ 3.5 for native PQC. |
| `HTTPD_VERSION` / `APR_VERSION` / `APRUTIL_VERSION` | `2.4.65` / `1.7.6` / `1.6.3` | Apache + APR source versions. |
| `ACCEPT=1` / `FORCE=1` | — | Same as `--accept` / `--force`. |

> ⚠️ **`reset` does not remember the baseline.** `DEMO_SELF_ALG` is read fresh on every invocation, so a bare `sudo ./pqc-apache-setup.sh reset` returns to the `mldsa87` default — not to RSA. To stay on the RSA baseline, pass it every time: `sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh reset`.

---

## Admin Web Request (AWR) post-enrollment script

`pqc-certificate-install-awr.sh` runs **on the target host**, triggered by TLM immediately after a certificate is issued and the agent has written the files to disk. It produces **no stdout** — everything goes to a timestamped log file and it returns only an exit code.

### How TLM passes data to it

TLM sets a single environment variable, `DC1_POST_SCRIPT_DATA`, containing **base64-encoded JSON**. The script decodes it and extracts:

| Variable | From JSON | Meaning |
|---|---|---|
| `CERT_FOLDER` | `"certfolder"` | Directory the agent wrote the certificate into. |
| `CRT_FILE` / `KEY_FILE` | `"files":[…]` | The `.crt` and `.key` filenames. |
| `CRT_FILE_PATH` / `KEY_FILE_PATH` | derived | Full paths to each. |
| `ARGUMENT_1` … `ARGUMENT_15` | `"args":[…]` | Free-form arguments configured on the TLM profile. |

The decoded JSON is logged verbatim, so a profile misconfiguration is easy to diagnose — look for the `Raw JSON content:` block in the log.

### What it does, step by step

| # | Step | On failure |
|---|---|---|
| 0 | Check the PQC OpenSSL is executable and the issued cert/key both exist | `exit 1`, nothing touched |
| 1 | Parse the certificate; log its **subject** and **signature algorithm** | `exit 1`, nothing touched |
| 2 | Parse the private key (logs an ML-DSA seed-vs-expanded encoding hint if this fails) | `exit 1`, nothing touched |
| 3 | **Guard:** confirm the key matches the certificate by comparing SHA-256 of the derived public keys | `exit 1` — cert not deployed |
| 4 | Copy cert and key to the deploy paths, `chmod 644` / `600` | `exit 1` on copy failure (permissions) |
| 5 | `apachectl configtest` | `exit 1` — **not** reloaded, live server unaffected |
| 6 | `apachectl -k graceful` (or `-k start` if Apache is not running) | `exit 1`, points at Apache's `error_log` |
| 7 | **Health probe:** TLS connect to `127.0.0.1:<port>` and compare served vs deployed fingerprint | Logs a `WARNING` only — exit stays `0` |

Two design points worth understanding:

* **The key/cert match uses public keys, not the modulus.** ML-DSA has no modulus, so the usual `-modulus | md5` comparison does not work. Comparing `x509 -pubkey` against `pkey -pubout` is algorithm-agnostic and works for RSA, ECC and ML-DSA alike.
* **All validation happens before the reload.** Apache keeps its currently loaded certificate in memory until a successful reload, so any failure in steps 0–5 leaves the live service serving the old, working certificate.

> ⚠️ **Certificates are overwritten in place. No backup is taken.** This is deliberate for the demo flow. If you need rollback, add a copy of the existing files before step 4.

### Configuration

| Setting | Default | Notes |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT` | `"true"` | Must be `"true"` or the script exits `1` immediately. |
| `LOGFILE` | `/home/ubuntu/pqc-demo-logfile.log` | Change it if the TLM agent runs as a different user or on a non-Ubuntu host — the script cannot log its own failure if this path is not writable. |
| `APACHE_PREFIX` | `/opt/httpd-pqc` | Edit in script. |
| `PQC_OPENSSL` | `/opt/openssl-pqc/bin/openssl` | Must be OpenSSL 3.5+. Edit in script. |
| `DEPLOY_CRT` | `/opt/httpd-pqc/conf/tlm-pqc.crt` | Override with **`ARGUMENT_1`**. |
| `DEPLOY_KEY` | `/opt/httpd-pqc/conf/tlm-pqc.key` | Override with **`ARGUMENT_2`**. |
| `PQC_VHOST_PORT` | `443` | Override with **`ARGUMENT_3`**. |

Passing the deploy path and port from the TLM profile's **argument list** keeps one copy of the script generic across hosts rather than forking it per environment. Leave the arguments empty and the defaults apply.

### Attaching it in TLM — checklist

1. Attach the script as the certificate profile's **post-enrollment (AWR) script**.
2. Confirm `LEGAL_NOTICE_ACCEPT="true"`.
3. Set `LOGFILE` to a path the agent's user can write.
4. Optionally set profile arguments 1, 2, 3 to the cert path, key path and port.
5. Grant the agent's execution user write access to the Apache `conf` directory and the ability to run `apachectl`.
6. **Confirm the vhost's `SSLCertificateFile` / `SSLCertificateKeyFile` point at exactly the same paths as `DEPLOY_CRT` / `DEPLOY_KEY`** — this is the single most common misconfiguration.

### A successful run looks like this

```
[…] GUARD: key matches certificate (public keys identical).
[…] Deployed cert -> /opt/httpd-pqc/conf/tlm-pqc.crt (certs in file: 1), key -> …
[…] apachectl configtest: Syntax OK
[…] Apache gracefully reloaded.
[…] Health probe: SNI=pqc-demo.digicert-demo.com  deployed_fp=AB:CD:…  served_fp=AB:CD:…
[…] SUCCESS: PQC vhost on :443 is serving the newly issued certificate (ML-DSA-87).
[…] Script execution completed
```

Exit code is `0` on success and on a served-fingerprint mismatch (step 7 warns but does not fail); `1` for any earlier failure.

---

## Demo runbook

```bash
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo    # RSA self-signed baseline
# → browse https://pqc-demo.digicert-demo.com/       (page shows RSA, self-signed)

# → issue the certificate from TLM
# → the AWR script validates, overwrites tlm-pqc.crt and gracefully reloads
# → refresh the browser                              (page shows ML-DSA-87, CA-issued)

sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh reset   # back to the RSA baseline
sudo ./pqc-apache-setup.sh show                      # print what's served right now
```

The test page leads with the signature algorithm, shows a state badge that flips amber "Self-signed" → green "CA-issued", and separates the key-exchange and authentication layers so the audience can see that the two move independently.

---

## Verifying a certificate manually

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

If the key fails to parse, suspect the FIPS 204 private-key encoding (seed-only vs expanded) — tools sometimes disagree on the format.

---

## Browser trust and platform support

The **key exchange** half is settled: Chrome 131+, Firefox and Safari all negotiate `X25519MLKEM768` by default, with no configuration and no warning.

The **authentication** half splits into two questions — *does the TLS engine verify ML-DSA?* and *can the OS trust store hold an ML-DSA root?*

| Client / platform | ML-DSA handshake | Import ML-DSA root into trust store |
|---|---|---|
| Chrome 151 (BoringSSL) | Yes — verifies in the handshake | Uses the platform trust store (below) |
| Windows 11 24H2+ / Server 2025 (July 2026 PQC updates) | — | **Yes** (CNG parses ML-DSA) → most reliable for a trusted padlock |
| Firefox (own NSS store) | Build-dependent | Build-dependent; bypasses the OS keychain |
| Linux NSS (`certutil`) | — | Build-dependent, improving |
| macOS keychain (Security.framework) | — | **No** — cannot import an ML-DSA root yet (`Unknown format in import`) |

**Practical upshot:** a self-signed or private-CA ML-DSA certificate will show a "not trusted" warning in the browser. That is a **trust-anchor** gap, not an algorithm problem. You can still click through and inspect the certificate, which is all the demo needs. For an actual green padlock, use a Windows client and import the private root produced by `pqc-apache-setup.sh mldsa-ca`. On macOS, use Firefox rather than the system keychain.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script was not invoked as an AWR post-enrollment hook, or was run manually. |
| `ERROR: Legal notice not accepted` | Set `LEGAL_NOTICE_ACCEPT="true"` in the script. |
| `ERROR: PQC-capable OpenSSL not found/executable` | Fix `PQC_OPENSSL`, or OpenSSL 3.5 is not installed on this host. |
| `ERROR: certificate failed to parse` | Almost always the wrong OpenSSL — use `/opt/openssl-pqc/bin/openssl`. |
| `ERROR: private key failed to parse` (ML-DSA seed vs expanded) | FIPS 204 private-key encoding mismatch between what TLM emitted and what this OpenSSL build accepts. |
| `ERROR: private key does NOT match certificate` | Agent wrote a key from a different enrollment, or the `"files"` extraction picked the wrong `.key`. Check the `Files array content:` log line. |
| `ERROR: failed to write …` | The agent's user cannot write to `/opt/httpd-pqc/conf`. |
| `WARNING: served cert fingerprint does not match deployed cert` | The vhost `SSLCertificateFile` points somewhere other than `DEPLOY_CRT`, or the vhost is not on `PQC_VHOST_PORT`. The certificate was deployed — it just is not the one being served. |
| Nothing in the AWR log at all | `LOGFILE` is not writable by the agent's user. |
| **503 Service Unavailable** after enabling CGI | A graceful reload does not load a new `LoadModule`; `mod_cgid` needs a full restart. `cgi-prereqs.sh` handles this, but to repair manually: `sudo /opt/httpd-pqc/bin/apachectl -k stop; sleep 2; sudo /opt/httpd-pqc/bin/apachectl -k start`. |
| Test page shows "No certificate" | `+ExportCertData` is not reaching the handshake — usually the demo vhost is not running. |
| Demo page shows self-signed after a TLM issuance | The AWR deploy path and the vhost's `SSLCertificateFile` differ. Both must be `/opt/httpd-pqc/conf/tlm-pqc.crt`. |
| Cert generation fails: `Can't open .../ssl/openssl.cnf` | OpenSSL installed without its config dir. Repair with: `cd <openssl-src> && sudo make install_ssldirs`. |
| Download 404 during build | Upstream mirror rotated the pinned version. The script falls back to `archive.apache.org`; otherwise bump `HTTPD_VERSION` / `APR_VERSION`. |
| Manual `openssl` errors on ML-DSA | You are using the system or LibreSSL OpenSSL. Use `/opt/openssl-pqc/bin/openssl`. |

---

## Known limitations

* **No rollback in the AWR script** — deployment overwrites the certificate without a backup, by design.
* **Chain handling** — if TLM emits the issuing chain as a *separate* file, Apache serves the leaf only. Concatenate it (leaf first) into the deploy path.
* **Single vhost** — one cert/key pair on one port. Deploying to several vhosts means looping over additional arguments.
* **Dual-cert vhost not implemented** — one vhost holding both an RSA and an ML-DSA certificate simultaneously, with OpenSSL 3.5 selecting per connection from the client's `signature_algorithms`, so PQC clients get ML-DSA and legacy clients get RSA on the same URL.
* **TLM-issued ML-DSA root** — the `mldsa-ca` command currently builds a hand-rolled root rather than a fully TLM-managed chain.
