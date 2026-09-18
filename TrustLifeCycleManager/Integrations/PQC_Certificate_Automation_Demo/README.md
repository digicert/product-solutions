# PQC Certificate Automation Demo — Apache + DigiCert Trust Lifecycle Manager

A self-contained lab that shows DigiCert **Trust Lifecycle Manager (TLM)** issuing a
**post-quantum (ML-DSA-87)** TLS certificate and installing it, unattended, on a live Apache
web server. The whole story plays out on one URL in the browser:

1. Apache serves a **self-signed** placeholder certificate (RSA or ML-DSA, your choice).
2. TLM issues an **ML-DSA-87** certificate through an Admin Web Request (AWR).
3. The TLM agent runs the AWR post-enrollment script, which validates the new cert and key,
   deploys them to the vhost, and gracefully reloads Apache.
4. Refresh the browser and the page now shows a **CA-issued, ML-DSA-87** certificate.
5. Revoke the certificate in TLM and watch the alert land in Slack and Jira.

Two independent post-quantum layers are exercised, and the demo page makes the distinction
explicit because most "PQC readiness" checkers only look at the first one:

| Layer | Algorithm | Who provides it |
|-------|-----------|-----------------|
| Key exchange | Hybrid `X25519MLKEM768` (ML-KEM, FIPS 203) | Negotiated automatically by Apache + modern browsers. Invisible to the user. |
| Authentication | `ML-DSA-87` certificate (FIPS 204) | Issued by TLM's PQC CA, deployed by the AWR script. |

Everything is built from source against **OpenSSL 3.5** into isolated prefixes under `/opt`,
so the distro's system OpenSSL is never touched.

---

## Repository layout

| Folder | Contents |
|--------|----------|
| [`setup-demo-environment/`](setup-demo-environment/) | Builds the target host: OpenSSL 3.5 + Apache from source, self-signed baseline cert, hybrid key-exchange config, and the styled live-certificate test page. Has its own detailed [README](setup-demo-environment/README.md). |
| [`admin-webrequest-post-script/`](admin-webrequest-post-script/) | The TLM **AWR post-enrollment script** that deploys the issued ML-DSA certificate to Apache. Has its own detailed [README](admin-webrequest-post-script/README.md). |
| [`demo/`](demo/) | `PQCAlerting.mp4` — a one-minute screen recording of the full demo flow, including the Slack and Jira alerting at the end. |

### Files

| File | Purpose |
|------|---------|
| `setup-demo-environment/pqc-apache-setup.sh` | Primary tool. Builds OpenSSL + Apache, manages vhosts and certificates, runs the demo loop (`install`, `demo`, `reset`, `show`, `mldsa`, `mldsa-ca`, `verify`, `status`). |
| `setup-demo-environment/cgi-prereqs.sh` | One-time enablement of the CGI test page (loads the CGI module, installs the page, writes a self-contained Apache config block). |
| `setup-demo-environment/test-page.cgi` | The DigiCert-styled "Live certificate inspector" page. Renders the certificate the browser is *currently* connected with, using the PQC OpenSSL, so ML-DSA displays correctly. |
| `admin-webrequest-post-script/pqc-certificate-install-awr.sh` | TLM AWR post-enrollment script: validate → key/cert match guard → deploy → `configtest` → graceful reload → health probe. |
| `demo/PQCAlerting.mp4` | Recorded walkthrough. |

---

## How the pieces fit together

```
   DigiCert TLM ─── issues ML-DSA-87 cert via AWR ───►  TLM Agent on the Apache host
   (PQC CA)                                                  │ writes .crt/.key, then runs
                                                             ▼
                                              pqc-certificate-install-awr.sh
                                                validate → deploy → graceful reload
                                                             │
                                                             ▼
   Browser ──TLS 1.3 (X25519MLKEM768)──►  Apache demo vhost :443
   (Chrome 131+, Firefox, Safari)          serves /opt/httpd-pqc/conf/tlm-pqc.crt
                                                             │
                                                  test-page.cgi renders the live cert
```

The demo vhost, the `reset` command, and the AWR script all read and write the **same file**
(`/opt/httpd-pqc/conf/tlm-pqc.crt` and `.key`). Whatever last wrote that slot is what the
browser sees. That shared path is what makes the self-signed ↔ issued swap seamless.

Key install locations on the target host:

| Component | Path |
|-----------|------|
| OpenSSL 3.5 (from source) | `/opt/openssl-pqc` |
| Apache (from source) | `/opt/httpd-pqc` |
| Demo cert / key (shared slot) | `/opt/httpd-pqc/conf/tlm-pqc.crt` / `.key` |
| CGI test page | `/opt/httpd-pqc/htdocs/index.cgi` |
| Setup log | `/var/log/pqc-apache-setup.log` |
| AWR script log | `/home/ubuntu/pqc-demo-logfile.log` |

---

## Prerequisites

### Target host

- A fresh **Ubuntu 26.04** instance (EC2 is what the scripts were written for; other
  versions may work but only 26.04 is tested).
- Outbound internet for the initial source downloads (GitHub for OpenSSL, `dlcdn.apache.org`
  for Apache/APR).
- Inbound **TCP 443** open in the security group. The optional `mldsa` / `mldsa-ca` modes
  also use `8443`.
- Root / `sudo`. The scripts re-exec themselves under `sudo` if needed.
- Roughly 15–40 minutes for the first build, depending on instance size.

### Name resolution

The default certificate CN is `pqc-demo.digicert-demo.com`. For browser testing that name must
resolve to the instance: either real DNS or a `hosts` entry on the client pointing the name at
the instance's public IP. Change the hostname with the `CN` and `SAN` environment variables if
you use your own domain (see [Adapting to your environment](#adapting-to-your-environment)).

### DigiCert TLM

- A TLM account with a **PQC-capable private CA** (ML-DSA-87 issuing ICA) and a certificate
  profile that uses it.
- The **TLM agent** installed on the Apache host, running as a user that can write to
  `/opt/httpd-pqc/conf` and run `apachectl` (root is simplest).
- Optional, for the alerting part of the demo: TLM notification integrations to **Slack**
  and/or **Jira** (ServiceNow and email work the same way).

> **Always use the PQC OpenSSL** at `/opt/openssl-pqc/bin/openssl` for any manual checks.
> The distro OpenSSL (and LibreSSL on macOS) cannot parse ML-DSA and will mislead you.

---

## Setup

### 1. Build the host

Copy the `setup-demo-environment/` folder to the instance, then:

```bash
cd setup-demo-environment
chmod +x pqc-apache-setup.sh cgi-prereqs.sh test-page.cgi

# Build OpenSSL 3.5 + Apache from source (15–40 min). Pass --accept to skip the usage gate.
sudo ./pqc-apache-setup.sh install --accept
```

The `install` step verifies that `mod_ssl.so` links against the *new* OpenSSL (not the distro
one) and that ML-KEM is present. If either guard fails the script stops and tells you why.

### 2. Stand up the single-vhost demo

```bash
# Baseline cert on :443. Use DEMO_SELF_ALG=rsa so the ALGORITHM visibly changes (RSA -> ML-DSA-87)
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo
```

Without `DEMO_SELF_ALG=rsa` the baseline is a self-signed **ML-DSA-87** cert, and the demo shows
only the *issuer* changing (self-signed → TLM). Both are valid stories; RSA → ML-DSA is the more
striking one.

### 3. Enable the live-certificate test page

```bash
sudo ./cgi-prereqs.sh ./test-page.cgi
```

This loads the correct CGI module for the Apache MPM, installs the page as `index.cgi`, writes
a self-contained `# >>> PQC-LAB CGI` config block, does a full Apache restart, and probes the
page over TLS. The block lives outside the vhost, so later `demo` / `reset` runs do not remove it.

Browse to `https://pqc-demo.digicert-demo.com/`. You should see the "Live certificate inspector"
page with **Key exchange: Post-quantum** and **Authentication: Classical** (self-signed RSA).

### 4. Configure TLM

1. Create (or reuse) a certificate profile bound to your **ML-DSA-87 issuing CA**, with
   the TLM agent as the delivery method. Name it something recognisable, e.g. `PQC-MLDSA87`.
2. Attach `admin-webrequest-post-script/pqc-certificate-install-awr.sh` as the profile's
   **post-enrollment (AWR) script**. Before uploading, check the top of the file:
   - `LEGAL_NOTICE_ACCEPT="true"` — the script refuses to run otherwise.
   - `LOGFILE` — defaults to `/home/ubuntu/pqc-demo-logfile.log`. Change it if the agent runs
     as another user; the script cannot report its own failure if this path is not writable.
3. Optionally pass the deploy paths and port as profile **arguments** so the script stays
   generic across hosts: argument 1 = cert path, argument 2 = key path, argument 3 = port.
   Left empty, the defaults (`/opt/httpd-pqc/conf/tlm-pqc.crt`, `.key`, `443`) apply.
4. Make sure the certificate's **SAN matches the vhost hostname** (`pqc-demo.digicert-demo.com`
   by default).
5. For the alerting finale, enable TLM notifications for *certificate issued* and
   *certificate revoked* events to a Slack channel and/or Jira project.

---

## Running the demo

```bash
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh demo    # 1. self-signed RSA baseline on :443
```

1. **Show the baseline.** Open `https://pqc-demo.digicert-demo.com/`. The page shows
   `sha256WithRSAEncryption`, the amber **Self-signed** badge, and **Authentication: Classical**.
   Optionally run the domain through DigiCert's public PQC readiness checker: it will report
   **Pass** because the key exchange is already quantum-safe, which is exactly the point the
   page makes about the two layers being independent.
2. **Issue from TLM.** In TLM go to *Inventory → Admin web request*, pick the PQC profile, choose
   the agent on the Apache host as the delivery integration, and submit. Watch the enrollment
   status move through *CSR generating → Issuing → Certificate delivery → Post script execution*.
3. **Refresh the browser.** The page now shows **ML-DSA-87**, the green **CA-issued** badge,
   **Authentication: Post-quantum**, and the TLM ICA as issuer. The AWR log on the host ends with
   `SUCCESS: PQC vhost on :443 is serving the newly issued certificate (ML-DSA-87)`.
4. **Show the alerting.** Revoke the certificate in TLM. The Slack channel receives the
   "Your certificate has been revoked" message from the DigiCert ONE app and a Jira ticket is
   created, both within seconds.
5. **Reset for the next run.**

```bash
sudo DEMO_SELF_ALG=rsa ./pqc-apache-setup.sh reset   # fresh self-signed cert, new key + serial
sudo ./pqc-apache-setup.sh show                      # print what's being served right now
```

> `reset` re-reads `DEMO_SELF_ALG` every time. A bare `reset` falls back to the `mldsa87`
> default, so keep the `DEMO_SELF_ALG=rsa` prefix to stay on the RSA baseline.

The recording in [`demo/PQCAlerting.mp4`](demo/PQCAlerting.mp4) shows steps 1–4 end to end.

---

## What the AWR script does on the host

The script has two halves. The first is the generic DigiCert AWR template that decodes
`DC1_POST_SCRIPT_DATA` (base64 JSON) into the cert folder, filenames, and up to 15 profile
arguments. The second is the PQC-specific deploy logic:

| # | Step | On failure |
|---|------|-----------|
| 0 | Check the PQC OpenSSL exists and the issued cert/key are present | exit 1, nothing touched |
| 1 | Parse the certificate; log subject and signature algorithm | exit 1, nothing touched |
| 2 | Parse the private key (with an ML-DSA seed-vs-expanded encoding hint) | exit 1, nothing touched |
| 3 | **Guard:** confirm key matches cert by comparing derived public keys (algorithm-agnostic, works for ML-DSA which has no modulus) | exit 1, not deployed |
| 4 | Copy cert and key to the deploy paths, `chmod 644` / `600` | exit 1 |
| 5 | `apachectl configtest` | exit 1, **not reloaded**, live server unaffected |
| 6 | `apachectl -k graceful` (or `start` if not running) | exit 1 |
| 7 | Health probe: `s_client` to the port, compare served vs deployed fingerprint | warning only, exit 0 |

Validation happens before the reload, so a bad or mismatched certificate never reaches the live
service. Certificates are **overwritten in place with no backup**, by design for a lab flow.

---

## Adapting to your environment

Every setting is an environment-variable override on the setup scripts. A few values must stay
in sync across components or the pieces will not line up:

| Value | Must match in | Symptom if it drifts |
|-------|---------------|----------------------|
| **Hostname** (`CN` / `SAN`) | DNS or `hosts`, the setup scripts, and the SAN on the TLM-issued cert | Browser name-mismatch error |
| **Deploy path** (`DEMO_CRT` / `DEMO_KEY`) | The demo vhost and the AWR script's `DEPLOY_CRT` / `DEPLOY_KEY` (or arguments 1 and 2) | AWR log warns "served fingerprint ≠ deployed" |
| **Port** (`DEMO_PORT`) | Setup, `cgi-prereqs.sh`, the AWR probe port (argument 3), and the security group | Connection refused or health probe cannot confirm the swap |

Example with a custom hostname and port:

```bash
sudo DEMO_SELF_ALG=rsa DEMO_PORT=9443 CN=pqc.acme.internal SAN=DNS:pqc.acme.internal \
     ./pqc-apache-setup.sh demo
sudo DEMO_PORT=9443 CN=pqc.acme.internal ./cgi-prereqs.sh ./test-page.cgi
```

The full configuration reference, per-file specifics, non-Ubuntu notes, and troubleshooting
tables are in the two sub-folder READMEs:

- [setup-demo-environment/README.md](setup-demo-environment/README.md) — build, vhost modes,
  browser trust per OS, troubleshooting.
- [admin-webrequest-post-script/README.md](admin-webrequest-post-script/README.md) — payload
  extraction, deploy block, reading the log, troubleshooting.

---

## Browser trust

The key-exchange half needs no configuration: Chrome 131+, Firefox, and Safari all negotiate
`X25519MLKEM768` by default. The authentication half is newer. Chrome (BoringSSL) verifies
ML-DSA in the handshake, but OS trust stores lag: Windows 11 24H2+ / Server 2025 can import an
ML-DSA root, macOS's system keychain cannot yet, and Firefox uses its own store on every OS.

For the demo this does not matter. A "not trusted" warning is a *trust-anchor* gap, not an
algorithm problem, and you can click through and inspect the cert or read it off the test page.
For an actual green padlock, use a Windows client and import your TLM PQC root, or use Firefox.

---

## Not yet implemented

- **Dual-cert vhost.** One vhost holding both an RSA and an ML-DSA certificate, with OpenSSL 3.5
  selecting per connection from the client's `signature_algorithms`.
- **TLM-issued ML-DSA root** in place of the hand-rolled `mldsa-ca` root for a fully
  TLM-managed chain in the standalone (non-TLM) modes.

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. Provided as-is for lab and evaluation use.
