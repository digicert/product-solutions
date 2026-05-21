# DigiCert TLM — Apache Tomcat TLS Certificate Automation

Scripts for automating TLS certificate lifecycle management on **Apache Tomcat** (Windows and Linux) using DigiCert Trust Lifecycle Manager (TLM). Four complementary scripts are provided across two folders.

| # | Script | Folder | Platform | Cert format | Trigger | Use case |
|---|---|---|---|---|---|---|
| 1 | `tomcat-acm.ps1`     | [ACME_DV_Route53](ACME_DV_Route53)   | Windows | JKS | Standalone / scheduled task    | Initial provisioning via ACME (Posh-ACME + DigiCert mPKI) with Route53 DNS-01 validation |
| 2 | `tomcat-awr-jks.ps1` | [Admin_Web_Request](Admin_Web_Request) | Windows | JKS | TLM Agent AWR post-enrollment  | Automated **JKS-keystore** renewal via TLM Agent |
| 3 | `tomcat-awr-jks.sh`  | [Admin_Web_Request](Admin_Web_Request) | Linux   | JKS | TLM Agent AWR post-enrollment  | Automated **JKS-keystore** renewal via TLM Agent |
| 4 | `tomcat-awr-pem.sh`  | [Admin_Web_Request](Admin_Web_Request) | Linux   | PEM | TLM Agent AWR post-enrollment  | Automated **PEM file-based** (key + cert + chain) renewal via TLM Agent |

> **Picking the right AWR script:** if your `server.xml` uses `certificateKeystoreFile` (a JKS) → use `tomcat-awr-jks.*`. If your `server.xml` uses `certificateKeyFile` + `certificateFile` (raw PEM) → use `tomcat-awr-pem.sh`. The PEM script explicitly refuses JKS/PFX/PKCS12 configurations.

---

## Overview

### 1. `tomcat-acm.ps1` — Standalone ACME Provisioning (Windows)

Location: [ACME_DV_Route53/tomcat-acm.ps1](ACME_DV_Route53/tomcat-acm.ps1)

An **end-to-end provisioning script** that handles everything from dependency installation through to Tomcat restart. It uses [Posh-ACME](https://github.com/rmbolger/Posh-ACME) to request a certificate from the DigiCert mPKI ACME endpoint with **DNS-01 validation via AWS Route53**, converts the result to a Java Keystore (JKS), updates `server.xml`, and restarts the Tomcat Windows service.

**Workflow (9 steps):**

| Step | Action |
|---|---|
| 1 | Detect and install prerequisites (OpenSSL, Java `keytool`, Posh-ACME) |
| 2 | Clean up any existing Posh-ACME account |
| 3 | Set PA Server to the DigiCert mPKI ACME directory |
| 4 | Create a new PA Account with EAB credentials |
| 5 | Configure the Route53 DNS plugin for DNS-01 validation |
| 6 | Request a certificate via `New-PACertificate` |
| 7 | Convert PEM → PKCS12 (OpenSSL) → JKS (`keytool`) |
| 8 | Update `server.xml` with the new keystore configuration and back up the original |
| 9 | Restart the Tomcat Windows service (`Tomcat10`, with fallback to `Tomcat9/8`) |

---

### 2. `tomcat-awr-jks.ps1` — TLM Agent AWR Post-Enrollment, JKS (Windows)

Location: [Admin_Web_Request/tomcat-awr-jks.ps1](Admin_Web_Request/tomcat-awr-jks.ps1)

Runs as a **post-enrollment hook** triggered by the DigiCert TLM Agent after a JKS certificate is issued or renewed. It receives certificate artefacts via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON), updates Tomcat's `server.xml` with the new JKS keystore path and credentials, and restarts the Tomcat Windows service automatically.

**Key behaviours:**
- Decodes TLM Agent payload (`DC1_POST_SCRIPT_DATA`) containing cert folder, JKS filename, keystore password, and truststore password
- Locates Tomcat via `CATALINA_HOME` or falls back to common Windows install paths (`Tomcat 9.0`, `10.0`, `10.1`)
- Creates a timestamped backup of `server.xml` before any modification
- Replaces the `<Certificate>` element in `server.xml` using regex (strict and flexible pattern matching)
- Restarts the Tomcat Windows service (`Tomcat10` → `Tomcat9` fallback, 30 s timeout)
- Writes a structured log to `C:\CertificateImport.log`

---

### 3. `tomcat-awr-jks.sh` — TLM Agent AWR Post-Enrollment, JKS (Linux)

Location: [Admin_Web_Request/tomcat-awr-jks.sh](Admin_Web_Request/tomcat-awr-jks.sh)

The Linux bash counterpart of `tomcat-awr-jks.ps1`. Runs as a **post-enrollment hook** when the TLM Agent issues or renews a JKS certificate, decodes the `DC1_POST_SCRIPT_DATA` payload, updates `server.xml`, and restarts Tomcat.

**Key behaviours:**
- Reads `DC1_POST_SCRIPT_DATA` and decodes the Base64 JSON payload using `jq`
- Resolves Tomcat home from `$CATALINA_HOME`, or auto-probes common Linux paths (`/opt/tomcat`, `/opt/tomcat10`, `/opt/tomcat9`, `/usr/share/tomcat*`, `/var/lib/tomcat*`, `/etc/tomcat*`)
- Derives the key alias automatically from the JKS filename (e.g. `mydomain.com.jks` → alias `mydomain.com`)
- Creates a timestamped backup of `server.xml`; restores it on any failure
- Replaces the `<Certificate />` element in `server.xml` using `perl -i` for reliable multi-line XML rewriting
- Restarts Tomcat via `systemctl` (tries `tomcat`, `tomcat10`, `tomcat9` in order), with fallback to `catalina.sh shutdown` / `startup.sh`
- Masks passwords in logs (shows only first/last 2 chars); writes to `/opt/digicert/TomcatCertificateImport.log`

**Required commands on the host:** `jq`, `perl`, `base64`, `systemctl` (or `catalina.sh`).

---

### 4. `tomcat-awr-pem.sh` — TLM Agent AWR Post-Enrollment, PEM (Linux)

Location: [Admin_Web_Request/tomcat-awr-pem.sh](Admin_Web_Request/tomcat-awr-pem.sh)

A **PEM file-based** AWR post-enrollment script for Tomcat on Linux. Unlike the JKS variants, this script targets a `server.xml` that uses `certificateKeyFile` + `certificateFile` (+ optional `certificateChainFile`) — i.e. raw PEM files rather than a Java keystore. It is significantly more defensive than the JKS scripts, with checksum verification, permission preservation, and structured exit codes.

**Key behaviours:**
- Reads `DC1_POST_SCRIPT_DATA` and parses the JSON payload using built-in `sed`/`awk` (no `jq` dependency)
- Takes the **Tomcat base directory** as `ARGUMENT_1` and the **restart command** as `ARGUMENT_2` from the AWR args array — no autoprobing
- Uses a defensive `awk`-based `server.xml` parser that:
  - Handles XML comments, single/double-quoted attributes, and multi-line `<Connector>` blocks
  - Detects multiple active SSL connectors and fails if more than one is found
  - **Refuses JKS/PFX/PKCS12 configurations** (`certificateKeystoreFile`, `keystoreFile`, `.jks`, `.p12`, `.pfx`, etc.) with exit code 12
- Deploys delivered files:
  - If `certificateChainFile` is configured → leaf cert goes to `certificateFile`, remaining chain certs go to `certificateChainFile`
  - If `certificateChainFile` is not configured → the full PEM bundle goes to `certificateFile`
- **SHA-256 checksum verification** after every backup and copy
- **Preserves existing file ownership and permissions**; falls back to `600` (key) / `644` (cert, chain) for new files
- Calls **SELinux `restorecon`** on deployed files when available
- Backs up every file it touches with a `.bak` timestamp (e.g. `server.key-20260101_120000.bak`)
- Provides a clearly demarcated **"ADD CUSTOM LOGIC HERE"** hook section that runs after deployment, before restart
- Runs the user-supplied restart command via `bash -c` and reports a structured exit code
- Writes logs to `/var/log/digicert-awr-tomcat-serverxml-script.log` (falls back to `/tmp/` if `/var/log` is not writable)

**Required commands on the host:** `awk`, `sed`, `grep`, `base64`, `stat`, `sha256sum`, `cp`, `chmod`, `chown`, `dirname`, `mktemp`, `bash`, `tr`, `head`, `date`. Optional: `restorecon` (SELinux hosts).

**Structured exit codes:** `0` success · `1` general error · `2` script-defined failure · `10` no PEM connector found · `11` multiple PEM connectors found · `12` unsupported JKS/PFX/PKCS12 configuration · `127` required command missing.

---

## Prerequisites

### All scripts
- **Apache Tomcat** installed as a managed service (8.5.x or newer for the PEM script)
- A `<Certificate>` element under `<SSLHostConfig>` in `server.xml` (see [server.xml Requirements](#tomcat-serverxml-requirements))
- Administrative privileges (root on Linux, Administrator on Windows)

### Windows-specific (`tomcat-acm.ps1`, `tomcat-awr-jks.ps1`)
- PowerShell 5.1 or later
- Tomcat installed as a Windows service (`Tomcat9` or `Tomcat10`)

### Linux-specific (`tomcat-awr-jks.sh`)
- Bash, `jq`, `perl`, `base64`, `systemctl` (or `catalina.sh` as fallback)
- Install `jq` if missing: `sudo apt-get install jq` (Debian/Ubuntu) or `sudo yum install jq` (RHEL/CentOS)

### Linux-specific (`tomcat-awr-pem.sh`)
- Bash, `awk`, `sed`, `grep`, `base64`, `stat`, `sha256sum`, `cp`, `chmod`, `chown`, `dirname`, `mktemp`, `tr`, `head`, `date` (all standard on most distributions)
- `restorecon` if running on SELinux-enforcing hosts (optional but recommended)

### `tomcat-acm.ps1` only
- Internet access for dependency downloads and the ACME challenge
- **Java JDK** with `keytool` (or `JAVA_HOME` set) — download from [Adoptium](https://adoptium.net/)
- **OpenSSL for Windows** — installed automatically via Chocolatey or direct download if not present
- **AWS credentials** with Route53 write access (for DNS-01 validation)
- A DigiCert mPKI account with ACME enabled and EAB credentials

### `tomcat-awr-*` scripts (all three)
- DigiCert TLM Agent installed and enrolled
- TLM Agent configured with an AWR post-enrollment script pointing to this file
- TLM certificate profile aligned with the script: **JKS** for `*-jks.*`, **PEM** for `*-pem.sh`

---

## Configuration

### `tomcat-acm.ps1`

Edit the configuration block near the top of the script before running:

```powershell
$LEGAL_NOTICE_ACCEPT = $true          # Must be set to $true

$domain           = "your-domain.example.com"
$keystorePassword = "changeit"        # Use a strong password in production
$tomcatHome       = "C:\tomcat"       # Path to your Tomcat installation
```

EAB credentials and Route53 keys are also defined inline — see the [Security](#security) section for guidance on externalising these.

### `tomcat-awr-jks.ps1` (Windows JKS)

Reads runtime values from the TLM Agent payload. Only minimal configuration is required:

```powershell
$LEGAL_NOTICE_ACCEPT = $true
$logFile = "C:\CertificateImport.log"
```

Tomcat home is resolved from `$env:CATALINA_HOME` automatically. If not set, the script probes:

```
C:\Program Files\Apache Software Foundation\Tomcat 10.1
C:\Program Files\Apache Software Foundation\Tomcat 10.0
C:\Program Files\Apache Software Foundation\Tomcat 9.0
C:\tomcat
C:\apache-tomcat
```

### `tomcat-awr-jks.sh` (Linux JKS)

Reads runtime values from the TLM Agent payload. Only minimal configuration is required:

```bash
LEGAL_NOTICE_ACCEPT="true"
LOG_FILE="/opt/digicert/TomcatCertificateImport.log"
```

Tomcat home is resolved from `$CATALINA_HOME` automatically. If not set, the script probes:

```
/opt/tomcat        /usr/share/tomcat        /var/lib/tomcat        /etc/tomcat
/opt/tomcat10      /usr/share/tomcat10      /var/lib/tomcat10      /etc/tomcat10
/opt/tomcat9       /usr/share/tomcat9       /var/lib/tomcat9       /etc/tomcat9
```

If your Tomcat install or service name differs, edit the `possible_paths` and `service_names` arrays at the top of the script.

### `tomcat-awr-pem.sh` (Linux PEM)

Only the legal-notice flag is configured inside the script:

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/var/log/digicert-awr-tomcat-serverxml-script.log"
```

**Tomcat path and restart command are passed as AWR arguments**, not detected:

| AWR argument | Purpose | Example |
|---|---|---|
| `ARGUMENT_1` | Tomcat base directory (script reads `${ARGUMENT_1}/conf/server.xml`) | `/opt/tomcat` |
| `ARGUMENT_2` | Restart command executed via `bash -c` after deployment | `systemctl restart tomcat.service` |

This makes the script portable across distros, custom install paths, and non-systemd setups — at the cost of requiring explicit AWR configuration.

---

## Tomcat `server.xml` Requirements

### JKS scripts (`tomcat-acm.ps1`, `tomcat-awr-jks.ps1`, `tomcat-awr-jks.sh`)

These scripts expect a `<Certificate>` element using `certificateKeystoreFile` under `<SSLHostConfig>`:

```xml
<Connector port="8443" protocol="org.apache.coyote.http11.Http11NioProtocol"
           maxThreads="150" SSLEnabled="true">
    <SSLHostConfig>
        <Certificate certificateKeystoreFile="conf/placeholder.keystore"
                     certificateKeystorePassword="changeit"
                     certificateKeyAlias="placeholder"
                     type="RSA" />
    </SSLHostConfig>
</Connector>
```

### PEM script (`tomcat-awr-pem.sh`)

This script expects a `<Certificate>` element using `certificateKeyFile` + `certificateFile` (+ optional `certificateChainFile`):

```xml
<Connector protocol="org.apache.coyote.http11.Http11NioProtocol"
           port="8443" SSLEnabled="true">
    <SSLHostConfig>
        <Certificate certificateKeyFile="conf/ssl/server.key"
                     certificateFile="conf/ssl/server.crt"
                     certificateChainFile="conf/ssl/chain.pem"
                     type="RSA" />
    </SSLHostConfig>
</Connector>
```

`certificateChainFile` is optional. If omitted, the full delivered PEM bundle is written to `certificateFile`.

All four scripts create timestamped backups of files they modify (e.g. `server.xml.backup_20260101_120000`, or `server.key-20260101_120000.bak` for the PEM script).

---

## Usage

### `tomcat-acm.ps1` — Standalone

1. Set `$LEGAL_NOTICE_ACCEPT = $true` and update the configuration variables.
2. Run PowerShell **as Administrator**.
3. Execute:

```powershell
.\tomcat-acm.ps1
```

For automated renewal, schedule via Windows Task Scheduler (recommended: every 60 days for 90-day certs).

### `tomcat-awr-jks.ps1` — via TLM Agent AWR (Windows JKS)

1. Set `$LEGAL_NOTICE_ACCEPT = $true` in the script.
2. In TLM, configure the certificate seat with:
   - **Format:** JKS
   - **Post-enrollment script:** path to `tomcat-awr-jks.ps1`
3. When the TLM Agent enrolls or renews a certificate, the script runs automatically and restarts Tomcat.

### `tomcat-awr-jks.sh` — via TLM Agent AWR (Linux JKS)

1. Mark the script as executable: `chmod +x tomcat-awr-jks.sh`
2. Edit the script and set `LEGAL_NOTICE_ACCEPT="true"`.
3. Ensure `jq` and `perl` are installed on the host.
4. In TLM, configure the certificate seat with:
   - **Format:** JKS
   - **Post-enrollment script:** absolute path to `tomcat-awr-jks.sh`
5. When the TLM Agent enrolls or renews a certificate, the script runs automatically and restarts Tomcat.

### `tomcat-awr-pem.sh` — via TLM Agent AWR (Linux PEM)

1. Mark the script as executable: `chmod +x tomcat-awr-pem.sh`
2. Edit the script and set `LEGAL_NOTICE_ACCEPT="true"`.
3. In TLM, configure the certificate seat with:
   - **Format:** PEM (separate key and cert files delivered)
   - **Post-enrollment script:** absolute path to `tomcat-awr-pem.sh`
   - **AWR argument 1:** Tomcat base directory (e.g. `/opt/tomcat`)
   - **AWR argument 2:** restart command (e.g. `systemctl restart tomcat.service`)
4. When the TLM Agent enrolls or renews a certificate, the script:
   - Discovers the active PEM SSL connector in `${ARGUMENT_1}/conf/server.xml`
   - Backs up, copies, and checksum-verifies the new key/cert/chain files
   - Restores prior file ownership and permissions
   - Runs `ARGUMENT_2` to restart Tomcat

---

## Security

> ⚠️ **Important:** The scripts in this repository contain **placeholder credentials** intended for demo/lab use only. Before deploying to any environment, review and address the following:

| Item | Risk | Recommendation |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT = false` | Script will not run | Set to `true` after reviewing the DigiCert legal notice |
| Keystore password hardcoded (ACM) | Credential exposure | Read from a secrets manager or environment variable |
| EAB KID / HMAC in plaintext (ACM) | Credential exposure | Use environment variables, Windows Credential Manager, or a vault |
| AWS access key / secret key in plaintext (ACM) | Credential exposure | Use IAM roles, instance profiles, or AWS Secrets Manager |
| Password logging | Log file exposure | `tomcat-awr-jks.sh` masks passwords; review `tomcat-awr-jks.ps1` and `tomcat-acm.ps1` and redact before production use |
| `CATALINA_HOME` or hard-coded paths | Path mismatch | Validate paths match your actual Tomcat installation |
| Log file permissions | Disclosure of cert metadata | Restrict log directory ACLs (`/opt/digicert/`, `/var/log/` on Linux; `C:\` on Windows) |
| Untrusted AWR argument string (PEM) | Command injection via `ARGUMENT_2` | The PEM script runs `ARGUMENT_2` via `bash -c`. Only configure this value through TLM admin UI; never let it be set from user-supplied data |

---

## Logging

| Script | Log destination |
|---|---|
| `tomcat-acm.ps1`     | PowerShell console (colour-coded). Redirect with `.\tomcat-acm.ps1 *>> C:\tomcat-acme.log` |
| `tomcat-awr-jks.ps1` | `C:\CertificateImport.log` |
| `tomcat-awr-jks.sh`  | `/opt/digicert/TomcatCertificateImport.log` (passwords are masked) |
| `tomcat-awr-pem.sh`  | `/var/log/digicert-awr-tomcat-serverxml-script.log` (falls back to `/tmp/digicert-awr-tomcat-serverxml-script.log` if `/var/log` is not writable) |

---

## Troubleshooting

**Script exits immediately with "Legal notice not accepted"**
Set `$LEGAL_NOTICE_ACCEPT = $true` (PowerShell) or `LEGAL_NOTICE_ACCEPT="true"` (bash) in the script.

**`CATALINA_HOME` not found / wrong path (JKS scripts)**
- Windows: `[System.Environment]::SetEnvironmentVariable("CATALINA_HOME","C:\your\tomcat\path","Machine")`
- Linux:   `export CATALINA_HOME=/your/tomcat/path` (persist in `/etc/environment` or the TLM Agent service environment)

**`keytool` not found (ACM script)**
Ensure a Java JDK is installed and either `JAVA_HOME` is set or `keytool.exe` is on the system `PATH`.

**`jq: command not found` (Linux JKS script)**
Install jq: `sudo apt-get install jq` or `sudo yum install jq`. (Not required for the PEM script.)

**Certificate element not found in `server.xml`**
Verify that `server.xml` contains a `<Certificate ... />` element inside `<SSLHostConfig>`. The JKS scripts use regex/perl matching; the PEM script does a structured `awk` parse.

**PEM script exits with code 10 ("No PEM certificate-file-based SSL Connector")**
Your `server.xml` is using a JKS/PFX/PKCS12 keystore. Either switch to `tomcat-awr-jks.*`, or reconfigure `server.xml` to use `certificateKeyFile` + `certificateFile`.

**PEM script exits with code 11 ("Multiple active PEM SSL Connectors")**
The PEM script only supports exactly one active PEM SSL connector. Disable additional connectors or comment them out.

**PEM script exits with code 12 ("Unsupported JKS/PFX/PKCS12 configuration")**
Same as code 10 — your `server.xml` uses a keystore. Use a JKS-flavoured script instead.

**Tomcat service not restarting**
- Windows: scripts probe `Tomcat10` then `Tomcat9`. Run `Get-Service | Where-Object {$_.Name -like "*tomcat*"}` to confirm the actual service name and update the script.
- Linux JKS: scripts probe `tomcat`, `tomcat10`, `tomcat9` via `systemctl`. Run `systemctl list-unit-files | grep -i tomcat` to find your service name, then add it to the `service_names` array. Falls back to `${CATALINA_HOME}/bin/shutdown.sh` and `startup.sh`.
- Linux PEM: the restart command is exactly whatever you supplied as `ARGUMENT_2`. Re-check it against `systemctl status <service>`.

**ACME certificate request fails (DNS-01)**
Verify the Route53 credentials have `route53:ChangeResourceRecordSets` and `route53:GetChange` permissions for the hosted zone, and that the domain's NS records resolve to Route53.

**`DC1_POST_SCRIPT_DATA environment variable is not set`**
The AWR scripts are designed to be triggered by the TLM Agent, which automatically populates this variable. If you are testing manually, you must set it to a Base64-encoded JSON payload matching the expected schema (`certfolder`, `files[]`, `password`, `keystorepassword`, `truststorepassword`, plus `args` for the PEM script).

---

## Script Selection Quick Reference

```
                         │ Windows           │ Linux
─────────────────────────┼───────────────────┼─────────────────────
 Initial provisioning    │ tomcat-acm.ps1    │ (n/a — use AWR
 (ACME + Route53 DNS)    │                   │  flow instead)
─────────────────────────┼───────────────────┼─────────────────────
 TLM Agent renewal       │ tomcat-awr-jks    │ tomcat-awr-jks.sh
 (JKS keystore)          │ .ps1              │
─────────────────────────┼───────────────────┼─────────────────────
 TLM Agent renewal       │ (n/a)             │ tomcat-awr-pem.sh
 (PEM key + cert files)  │                   │
─────────────────────────┴───────────────────┴─────────────────────
```

---

## Related Resources

- [DigiCert Trust Lifecycle Manager Documentation](https://docs.digicert.com/en/trust-lifecycle-manager.html)
- [DigiCert mPKI ACME Documentation](https://docs.digicert.com/en/trust-lifecycle-manager/certificate-issuance/acme.html)
- [Posh-ACME on GitHub](https://github.com/rmbolger/Posh-ACME)
- [Apache Tomcat SSL/TLS How-To](https://tomcat.apache.org/tomcat-10.1-doc/ssl-howto.html)
- [OpenSSL for Windows (Shining Light)](https://slproweb.com/products/Win32OpenSSL.html)

---

## License

Copyright © 2026 DigiCert. All rights reserved. See the legal notice embedded in each script for full terms.
