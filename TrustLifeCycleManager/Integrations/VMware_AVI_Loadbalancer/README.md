# DigiCert TLM — VMware Avi Load Balancer Integration

Automated certificate lifecycle management for VMware (Broadcom) Avi Load Balancer using DigiCert Trust Lifecycle Manager (TLM). This folder contains two independent integration options.

| Script | Purpose | Runs on |
|--------|---------|---------|
| [`Admin_Web_Request/Linux/vmware_avi_loadbalancer_awr.sh`](Admin_Web_Request/Linux/vmware_avi_loadbalancer_awr.sh) | AWR post-delivery script (Bash): uploads the delivered certificate to Avi and binds it to selected Virtual Services | TLM Agent on Linux |
| [`Admin_Web_Request/Windows/vmware_avi_loadbalancer_awr.ps1`](Admin_Web_Request/Windows/vmware_avi_loadbalancer_awr.ps1) | AWR post-delivery script (PowerShell): same workflow, arguments and logging as the Linux script | TLM Agent on Windows |
| [`Certificate_Management_Provider/vmware_avi_loadbalancer_control_script.py`](Certificate_Management_Provider/vmware_avi_loadbalancer_control_script.py) | Avi Certificate Management Profile: requests and renews certificates from DigiCert via ACME with EAB | Avi Controller |

---

## Architecture Overview

### Option A — TLM Agent AWR post-delivery script

The DigiCert TLM Agent manages the certificate lifecycle. After enrollment or renewal, the Agent runs the AWR (Admin Web Request) post-delivery script. The script logs in to the Avi Controller REST API, uploads the certificate and key as a new certificate object (or reuses an identical one), and binds it to the Virtual Services you list.

```
TLM Agent ──enroll/renew──▶ DigiCert
     │
     └──post-delivery──▶ AWR script ──REST API──▶ Avi Controller
                                                   ├─ sslkeyandcertificate (upload / reuse)
                                                   └─ virtualservice (bind certificate)
```

### Option B — Avi Certificate Management Profile (control script)

The Avi Controller manages the certificate lifecycle itself, using the Python control script as a **Certificate Management Profile**. When a certificate is created or nears expiry, Avi generates a CSR and calls the script, which runs the ACME flow against DigiCert (account registration with External Account Binding, order, finalisation and download) and returns the signed certificate chain to Avi.

```
Avi Controller ──CSR──▶ Control script ──ACME──▶ DigiCert
                ◀──cert chain──                  (CertCentral / TLM)
```

---

## Option A — AWR Post-Delivery Script

### Prerequisites

- DigiCert TLM Agent installed and configured, with network access to the Avi Controller over HTTPS.
- An Avi Controller account with the permissions listed in [Avi permissions](#avi-permissions).
- The Virtual Services to update must already exist and have a TLS-enabled service (listener). The script does not create Virtual Services, SSL profiles or SNI topology.

| Platform | Requirements |
|----------|--------------|
| Linux | Bash 4+, `curl`, `jq`, `openssl`, `base64`, `mktemp`, `date`, `awk`, `sed`, `cmp`, `tr`, `find`, GNU-compatible `sort -V`, `cat` |
| Windows | Windows PowerShell 5.1 or PowerShell 7, `curl.exe` 7.70 or newer (not the PowerShell `curl` alias), `openssl.exe` from an organisation-approved distribution. No Bash, jq or Python is needed. |

The Linux script checks for every required command at startup and stops with `Missing command: <name>` if one is absent. The Windows script stops with `Missing curl.exe` / `Missing openssl.exe` and accepts absolute paths through environment variables (see [Environment variables](#environment-variables)). Tools must be visible to the **Agent service account**, not only to an interactive user.

#### Installing `jq` (Linux)

`curl` and `openssl` ship with most distributions, but `jq` often does not.

| Distribution | Command |
|--------------|---------|
| Debian / Ubuntu | `sudo apt-get update && sudo apt-get install -y jq` |
| RHEL / CentOS / Rocky / Alma | `sudo yum install -y jq` (or `sudo dnf install -y jq`) |
| SUSE / SLES | `sudo zypper install -y jq` |
| Alpine | `sudo apk add jq` |

> Without internet access, download the standalone `jq` binary from the [official releases](https://github.com/jqlang/jq/releases), place it on the `PATH` (for example `/usr/local/bin/jq`) and mark it executable with `chmod +x`.

### 1. Accept the Legal Notice

Each script starts with the DigiCert Legal Notice and ships with the acceptance flag set to `"false"`. The script refuses to run, and logs `Legal notice not accepted`, until you set it to exactly `"true"`:

| Script | Line to change |
|--------|----------------|
| Linux | `LEGAL_NOTICE_ACCEPT="false"` → `LEGAL_NOTICE_ACCEPT="true"` |
| Windows | `$LEGAL_NOTICE_ACCEPT = "false"` → `$LEGAL_NOTICE_ACCEPT = "true"` |

No other settings need to be edited in the script. Everything else is passed as AWR arguments or environment variables.

When editing or transferring the files:

- **Linux:** keep UTF-8 without BOM and Unix LF line endings.
- **Windows:** keep UTF-8 **with** BOM so Windows PowerShell 5.1 reads the Legal Notice correctly. Follow your organisation's PowerShell execution and signing policy; the script does not change the execution policy.

### 2. Configure the AWR Arguments in TLM

Upload the script as a post-delivery script and select it in the AWR enrollment profile (Linux Agent) or the Windows Agent integration. Configure the arguments **in this order**; both scripts use the same order. Arguments 1 to 6 are required.

| # | Argument | Example | Description |
|---|----------|---------|-------------|
| 1 | Controller | `avi-controller.example.com` | Controller hostname or IPv4, optionally `:port`. No `https://` and no path. |
| 2 | Username | `svc-tlm-avi` | Avi API account. |
| 3 | Password | *(configured in TLM)* | Never hardcode it in the script. |
| 4 | Tenant | `admin` | All selected Virtual Services must belong to this tenant. Use separate AWR configurations for other tenants. |
| 5 | Virtual Services | `web-vs,api-vs` | Comma-separated Virtual Service names and/or UUIDs. A single entry is fine. Spaces around entries are trimmed; dots, hyphens and underscores are allowed. Semicolons, empty entries and control characters are rejected. For a name containing a comma, use its UUID. |
| 6 | Certificate name prefix | `tlm-web` | 1–40 letters, digits, `_` or `-`. Keep it stable across renewals. |
| 7 | Replacement selector | `AUTO_SINGLE` | Which existing binding to replace on **every** selected Virtual Service. See [Replacement selector](#replacement-selector). Default `AUTO_SINGLE`. |
| 8 | Mode | `dry-run` | `dry-run` (default) or `apply`. |
| 9 | API version | `30.2.2` | `X-Avi-Version` header. Default `30.2.2`. Set it to your Controller's version; other releases must be validated. |
| 10 | CA bundle | `/etc/pki/avi-ca.pem` or `C:\PKI\avi-ca.pem` | Optional PEM CA bundle on the Agent used to verify the Controller's HTTPS certificate. |

The TLM Agent passes the arguments and the delivered file names to the script in the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON).

#### Replacement selector

| Value | Behaviour |
|-------|-----------|
| `AUTO_SINGLE` | Each Virtual Service must have exactly one certificate bound; that one is replaced. |
| `slot:N` | Replace the certificate at zero-based position `N` on each Virtual Service, for example `slot:0`. |
| Old certificate name or UUID | Replace that certificate object. It must be bound exactly once on each Virtual Service being updated. |
| `NONE` | Only bind to a Virtual Service with an empty certificate list; never replaces an existing binding. |

Virtual Services already bound to the new certificate object are skipped and reported as `ALREADY_ASSOCIATED`.

#### SNI Virtual Services

- Normal Virtual Services, SNI children and explicitly listed SNI parents are supported. Enhanced Virtual Hosting (EVH) is not.
- To update only an SNI child, list only the child. The script reads its parent (GET only) to confirm the parent has a TLS listener; the parent is not changed.
- To update both child and parent, list both in argument 5.
- Other Virtual Services that share the old certificate object are never changed implicitly.

### 3. Certificate Delivery Format

> **Select as Cert Delivery Format: `CRT`**

| Requirement | Detail |
|-------------|--------|
| Cert Delivery Format | `CRT`: a PEM `.crt` plus exactly one matching, **unencrypted** PEM `.key`. |
| Intermediates | Optional PEM files ending in `_ica.cer` or `_ica.crt` are appended to the chain. Duplicate certificates are removed. |
| Key algorithm | RSA or ECDSA. |
| SANs | Must cover the DNS names served by every selected Virtual Service. |

PFX/P12, JKS, password-protected keys and Windows certificate-store imports are not supported. The script picks the `.crt` whose public key matches the delivered `.key` and rejects an expired certificate.

### 4. Run a Dry-Run, Then Apply

1. Set argument 8 to `dry-run` and trigger a delivery. The script logs in, resolves and validates every Virtual Service and logs the plan. It makes **no** API writes.
2. Review the log (see [Logging](#logging)).
3. Change argument 8 to `apply` and run again.
4. After apply, check the certificate presented over HTTPS with the correct hostname/SNI for each Virtual Service. The script reads the configuration back but does not test live traffic.

### Avi Authentication

The scripts use **session-based (cookie + CSRF token) authentication** with a local username and password (arguments 2 and 3). HTTP Basic Auth, API tokens and client certificates are not used.

1. `POST https://<controller>/login` with `{"username": "...", "password": "..."}`. The JSON body is written to a private temporary file, never passed on the command line.
2. The Controller returns `sessionid` and `csrftoken` cookies, kept in a temporary cookie jar.
3. Every API call sends the session cookie plus the `X-CSRFToken`, `X-Avi-Version`, `X-Avi-Tenant` and `Referer` headers.
4. The temporary directory, including the cookie jar, is deleted when the script exits.

**HTTPS certificate verification is always on.** If the Controller's certificate is not trusted by the Agent's default trust store, supply its CA chain with argument 10. The Agent may inherit proxy variables; set `NO_PROXY` for the Controller if it should be reached directly.

### Avi Permissions

The API account needs, in the selected tenant:

- **Read** on the selected Virtual Services, their SNI parents and SSL/TLS certificate objects (`sslkeyandcertificate`).
- **Create** on SSL/TLS certificate objects.
- **Write** on the selected Virtual Services (to change `ssl_key_and_certificate_refs`).

A dedicated service account with a custom role is recommended over `admin`. A dry-run does not check write permissions.

### Environment Variables

All are optional. Set them for the Agent service account if needed.

| Variable | Script | Default | Purpose |
|----------|--------|---------|---------|
| `AVI_LOGFILE` | Linux | `/AWR/logs/avi-upload.log` | Log file path. Its directory is created if missing. |
| `AVI_LOGFILE` | Windows | `%ProgramData%\DigiCert\TLM\AVI-AWR\avi-upload.log` | Log file path. Its directory is created if missing. |
| `AVI_CURL_PATH` | Windows | `curl.exe` on `PATH` | Absolute path to `curl.exe`, for example `C:\Windows\System32\curl.exe`. |
| `AVI_OPENSSL_PATH` | Windows | `openssl.exe` on `PATH` | Absolute path to `openssl.exe`, for example `C:\Program Files\OpenSSL-Win64\bin\openssl.exe`. |

### How It Works

1. **Input checks.** Checks the legal-notice flag, required tools and arguments. Validates argument 5 and logs an `INPUT_CHECK` report (type, length, comma count and any prohibited character positions, never the full value).
2. **Certificate selection.** Finds the one `.crt` that matches the delivered `.key`, checks it has not expired and builds the full chain from the `.crt` and any `_ica.cer` / `_ica.crt` files.
3. **Naming.** The certificate object name is `<prefix>-<SHA-256 fingerprint>`, for example `tlm-web-9306…ad53`. Each certificate gets its own immutable object, so a rerun with the same certificate reuses the existing object. Existing objects are **never** overwritten in place, and old objects are retained (not deleted).
4. **Login.** Session login as described in [Avi Authentication](#avi-authentication).
5. **Preflight.** Resolves every Virtual Service name/UUID (duplicates resolving to the same Virtual Service are skipped), validates its type and TLS listener, and works out which binding to replace. Nothing is uploaded or changed if any target fails preflight.
6. **Dry-run stops here.** Targets are reported as `PLANNED`.
7. **Pre-write recheck and snapshots.** Re-reads every target and stops if anything changed since preflight. Saves each target's current bindings to `avi-binding-<vs-uuid>-<run-id>.json` next to the log file. Snapshots contain references only, no private keys, and are not an automatic restore mechanism.
8. **Upload or reuse.** Uploads the certificate object (`POST /api/sslkeyandcertificate`), or reuses the existing identical one, then reads it back and checks the fingerprint.
9. **Binding.** For each target in turn: re-reads it, sends `PATCH /api/virtualservice/<uuid>` with the updated `ssl_key_and_certificate_refs`, and reads it back to verify. All other bindings are preserved exactly.

Bindings are sequential, **not transactional**. The first failure stops the run. Earlier successful bindings remain in place; there is no automatic retry or rollback. Inspect the Controller before retrying, especially after a timeout. Do not run two writers against the same Virtual Service at the same time.

### Logging

Each run appends to the log file (see `AVI_LOGFILE` above). The log file and snapshots are created with owner-only permissions (`600` on Linux, a protected ACL for the current account, SYSTEM and Administrators on Windows). If the log file cannot be created, the script stops with `cannot create or write log file` (Linux) and writes the error to the console.

Every line carries a UTC timestamp and a run id (`<UTC start time>-<process id>`), so lines from one run can be filtered with `grep 'run=<id>'`. Both scripts log the same events:

| Event | Content |
|-------|---------|
| `INIT`, `LEGAL_NOTICE` | Script revision, process id, account, log path, legal-notice acceptance |
| `INPUT_RUNTIME`, `INPUT_CHECK`, `START`, `TLS_TRUST` | Tool paths and versions, argument 5 check, mode, Controller, API version, tenant, selector, prefix, trust source |
| `CERT_SELECTED` | Certificate file, key file, subject, serial, expiry, SHA-256, chain length, object name |
| `LOGIN`, `API` | Login, and every API call's method, path (without query string) and HTTP status |
| `CERTIFICATE_LOOKUP` / `_UPLOADED` / `_REUSED` / `_VERIFIED` | Whether the object exists, was uploaded or reused, and its verified fingerprint |
| `Preflight`, `Plan`, `SNI_*`, `Already associated`, `Duplicate target skipped` | Per-target resolution and planned change |
| `Previous bindings saved to` | Snapshot path |
| `Binding`, `SUCCESS` | Per-target write and verification |
| `ERROR` | The failure reason, including curl's own reason line on transport errors (DNS, TLS trust, proxy, timeout) |
| `SUMMARY`, `RESULT` | Overall result and one line per requested Virtual Service |

The log never contains the password, private key, cookies, CSRF token or Controller response bodies. Error responses are classified into fixed labels (`AUTHORIZATION`, `CSRF_SESSION`, `TENANT_SCOPE`, `AUTHENTICATION`, `HTTP_METHOD`, `UNCLASSIFIED`) instead of being copied.

Example (apply, two Virtual Services; shortened):

```
[2026-11-17T13:17:31Z] [run=20261117T131731Z-12414] INIT: revision=2026-11-17-v5.3 pid=12414 user=tlmagent log=/AWR/logs/avi-upload.log
[2026-11-17T13:17:31Z] [run=20261117T131731Z-12414] LEGAL_NOTICE: accepted (LEGAL_NOTICE_ACCEPT="true").
[2026-11-17T13:17:31Z] [run=20261117T131731Z-12414] START: revision=2026-11-17-v5.3 mode=apply controller=avi-controller.example.com api_version=30.2.2 tenant=admin selector=AUTO_SINGLE prefix=tlm-web requested_targets=2
[2026-11-17T13:17:31Z] [run=20261117T131731Z-12414] CERT_SELECTED: file=www_example_com.crt key=www_example_com.key subject=CN=www.example.com serial=578E…9F14 not_after=Nov 19 13:17:25 2027 GMT SHA256=9306…ad53 chain_certs=2 object_name=tlm-web-9306…ad53
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] LOGIN: succeeded (HTTP 200)
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] CERTIFICATE_LOOKUP: object tlm-web-9306…ad53 not found; it will be uploaded in apply mode.
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] Plan: mode=apply tenant=admin VS=virtualservice-cfd8… selector=AUTO_SINGLE new_object=tlm-web-9306…ad53 …
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] PREFLIGHT completed: unique_targets=2 updates=2. No certificate upload or binding changes yet.
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] Previous bindings saved to /AWR/logs/avi-binding-virtualservice-cfd8…-20261117T131731Z-12414.json
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] API: POST /api/sslkeyandcertificate HTTP 201
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] CERTIFICATE_VERIFIED: uuid=sslkeyandcertificate-a3d4… SHA256=9306…ad53
[2026-11-17T13:17:32Z] [run=20261117T131731Z-12414] API: PATCH /api/virtualservice/virtualservice-cfd8… HTTP 200
[2026-11-17T13:17:33Z] [run=20261117T131731Z-12414] SUCCESS: certificate=sslkeyandcertificate-a3d4… bound to VS=virtualservice-cfd8…. Previous objects retained. Verify endpoint TLS/SNI separately.
[2026-11-17T13:17:33Z] [run=20261117T131731Z-12414] SUMMARY: result=SUCCESS mode=apply phase=DONE targets=2 exit=0
[2026-11-17T13:17:33Z] [run=20261117T131731Z-12414] RESULT: VS=web-vs uuid=virtualservice-cfd8… status=UPDATED
[2026-11-17T13:17:33Z] [run=20261117T131731Z-12414] RESULT: VS=api-vs uuid=virtualservice-04fc… status=UPDATED
```

The console output (captured by the TLM Agent) is a short summary that names the log file:

```
AVI AWR INPUT_CHECK: {"type":"string","characters":14,"commas":1,"invalid":[]}
AVI AWR SUCCESS: mode=apply, targets=2, phase=DONE (see /AWR/logs/avi-upload.log)
VS=web-vs: UPDATED
VS=api-vs: UPDATED
```

#### Per-target result status

| Status | Meaning |
|--------|---------|
| `PLANNED` | Dry-run: would be updated. |
| `UPDATED` | Bound and verified. |
| `ALREADY_ASSOCIATED` | Already bound to this certificate object; nothing changed. |
| `DUPLICATE_SKIPPED` | Another entry in argument 5 resolved to the same Virtual Service. |
| `FAILED` | Failed before any write to this target. |
| `FAILED_OR_UNCONFIRMED` | The PATCH was sent but could not be confirmed. Inspect the Controller and the snapshot. |
| `NOT_ATTEMPTED` | The run stopped before reaching this target. |

---

## Option B — Certificate Management Profile (Control Script)

### Prerequisites

- Python 3 in the Avi Controller's control-script environment (the script uses Python 3-only modules; Python 2 is not supported).
- OpenSSL CLI on the Avi Controller.
- DigiCert ACME credentials: ACME directory URL, EAB Key ID (`eab_kid`) and EAB HMAC key (`eab_hmac_key`).
- Domains pre-validated in DigiCert. The script does not implement HTTP-01 or DNS-01 challenges.

### 1. Import the Script

1. Log in to the Avi Controller UI.
2. Navigate to **Templates → Security → Certificate Management**.
3. Click **Create** and paste the contents of `vmware_avi_loadbalancer_control_script.py`.

### 2. Configure Script Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `acme_directory_url` | Yes | DigiCert ACME directory URL (must be HTTPS) |
| `eab_kid` | Yes | External Account Binding Key ID |
| `eab_hmac_key` | Yes | EAB HMAC key (mark as **Sensitive**) |
| `contact` | No | Email address, or comma-separated addresses, for the ACME account |
| `acme_account_key` | No | PEM RSA ACME account key (mark as **Sensitive**). Recommended for HA so every Controller node and restart uses the same ACME account. |
| `request_timeout_seconds` | No | HTTP request timeout, default 30, maximum 300 |
| `poll_timeout_seconds` | No | Order polling timeout, default 300, maximum 3600 |
| `debug` | No | `true` for verbose logging |

#### DigiCert ACME Directory URLs

| Product | URL |
|---------|-----|
| CertCentral | `https://acme.digicert.com/v2/acme/directory/` |
| Trust Lifecycle Manager | `https://one.digicert.com/mpki/api/v1/acme/v2/directory` |

### 3. Request a Certificate

1. Navigate to **Templates → Security → SSL/TLS Certificates**.
2. Click **Create → Application Certificate**.
3. Enter a name for the certificate.
4. Set **Type** to **CSR**.
5. Set **Common Name** to the target domain.
6. Select the Certificate Management profile created above.
7. Click **Save**. The script requests and imports the certificate automatically.

### How It Works

1. Uses the supplied `acme_account_key`, or generates (once) an RSA 4096-bit account key scoped to the directory URL and EAB credentials, stored as `/tmp/digicert_acme_<hash>.key` with mode `0600`.
2. Verifies the CSR from Avi and extracts the DNS names (CN and SANs).
3. Fetches the ACME directory from DigiCert, with TLS certificate verification.
4. Registers (or finds) the ACME account with External Account Binding.
5. Creates an order for the requested names.
6. Checks that every authorisation is already valid (pre-validated in DigiCert).
7. Finalises the order with the CSR in DER format and polls until the certificate is ready.
8. Downloads the certificate chain, checks that it matches the CSR's public key, and returns it to Avi.

Output goes to stdout/stderr and is captured in the Avi Controller's certificate management logs. Set `debug` to `true` for more detail.

---

## Troubleshooting

### AWR scripts

Messages appear in the log as `ERROR: …` and on the console as `AVI AWR ERROR: …`.

| Message | Cause | Resolution |
|---------|-------|------------|
| `Legal notice not accepted` | Flag not set to exactly `"true"` | See [Accept the Legal Notice](#1-accept-the-legal-notice). |
| `cannot create or write log file` (Linux) | Agent account cannot write the log directory | Fix permissions or set `AVI_LOGFILE`. |
| `Missing command: jq` / `Missing curl.exe` / `Missing openssl.exe` | Tool not on the Agent account's `PATH` | Install it, or on Windows set `AVI_CURL_PATH` / `AVI_OPENSSL_PATH`. |
| `Exactly one .key file must be delivered` / `Deliver PEM .crt with exactly one unencrypted .key` | Wrong Cert Delivery Format | Use `CRT`. |
| `Private key is unreadable or encrypted` | Key is password-protected | Use `CRT` delivery with an unencrypted key. |
| `Expected exactly one PEM .crt matching the delivered private key` | No (or several) matching `.crt` files | Check the delivered files. |
| `… transport failure (curl exit 60: … SSL certificate problem …)` | Controller certificate not trusted | Supply the Controller's CA chain as argument 10. |
| `… transport failure (curl exit 6 / 7 / 28: …)` | DNS, connection refused or timeout | Check the Controller address, port, firewall and proxy (`NO_PROXY`). |
| `Controller login failed (HTTP 401)` / `POST /login failed (HTTP 401)` | Wrong credentials or locked account | Check arguments 2 and 3. |
| `failed (HTTP 403). AUTHORIZATION: …` | Missing role permission or wrong tenant | See [Avi permissions](#avi-permissions); check argument 4. |
| `failed (HTTP 403). CSRF_SESSION: …` | Session or CSRF rejected | Check argument 9 matches the Controller and that no proxy strips cookies or the `Referer` header. |
| `Argument 5 contains prohibited characters` | Semicolon, tab, line break or other control character | Fix the list; positions are in the `INPUT_CHECK` line. |
| `No unique virtualservice match for the specified selector` | Name misspelt, in another tenant, or ambiguous | Check the name and tenant, or use the UUID. |
| `AUTO_SINGLE requires exactly one bound certificate on each target` | A Virtual Service has zero or several certificates | Use `slot:N`, the old certificate name/UUID, or `NONE` as argument 7. |
| `Selected Virtual Service has no TLS-enabled listener` | No service with SSL enabled | Configure the TLS listener in Avi first. |
| `Enhanced Virtual Hosting (EVH) is not supported` | EVH parent or child selected | Not supported by this version. |
| `Bindings changed after preflight` / `Bindings changed concurrently` | Someone changed the Virtual Service during the run | Check the Controller, then rerun. |
| `Versioned name exists with a different certificate` | An object with the expected name holds another certificate | Investigate the object in Avi before retrying. |

### Control script

| Message | Cause | Resolution |
|---------|-------|------------|
| `Missing required parameter: eab_kid` (or another name) | Profile parameter not configured | Add all required parameters. |
| `Domain … is not pre-validated in DigiCert` | Domain validation not complete | Complete domain validation in DigiCert. |
| `acme_directory_url must be an absolute HTTPS URL` | Wrong URL | Use a directory URL from the table above. |

---

## Security Considerations

- Store the Avi password only in the TLM AWR configuration. The Agent passes it in `DC1_POST_SCRIPT_DATA`; secure the Agent host accordingly.
- The AWR scripts verify the Controller's HTTPS certificate. Use argument 10 rather than disabling verification.
- The private key is sent only in the certificate upload request body and is never logged or written to snapshots. Temporary files are created with owner-only permissions and deleted at exit.
- Use a dedicated Avi service account with the minimum role described in [Avi permissions](#avi-permissions).
- Old certificate objects are retained in Avi after rotation. Remove them through your normal change process once they are no longer needed.
- For the control script, mark `eab_hmac_key` and `acme_account_key` as **Sensitive**. The generated ACME account key lives under `/tmp` on the Controller with mode `0600`; supply `acme_account_key` if the key must survive restarts or be shared across HA nodes.

---

## Legal Notice

Copyright © 2026 DigiCert. All rights reserved. The full Legal Notice is embedded at the top of each AWR script. Both AWR scripts ship with the acceptance flag set to `"false"` and will not run until it is set to `"true"` (see [Accept the Legal Notice](#1-accept-the-legal-notice)).

---

## Version History

| Version | Date | Description |
|---------|------|-------------|
| 1.1.0 | 2026-11 | AWR: Linux script v5.3 and new Windows PowerShell script win1.1 with multi-VS and SNI binding, immutable fingerprint-named certificate objects, dry-run/apply, verified HTTPS and consistent logging. README rewritten for both scripts; control script section updated (Python 3, TLS verification, account key handling, new parameters). |
| 1.0.1 | 2026-10 | README: AWR documented first; added Cert Delivery Format (`CRT`) and Avi authentication details |
| 1.0.0 | 2024 | Initial release — ACME control script and AWR post-enrollment script |
