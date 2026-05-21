# DigiCert TLM — Apache Tomcat TLS Certificate Automation

Scripts for automating TLS certificate lifecycle management on **Apache Tomcat** (Windows and Linux) using DigiCert Trust Lifecycle Manager (TLM). Three complementary automation paths are provided.

| # | Script | Folder | Platform | Trigger | Use Case |
|---|---|---|---|---|---|
| 1 | `tomcat-acm.ps1` | [ACME_DV_Route53](ACME_DV_Route53) | Windows | Standalone / scheduled task | Initial provisioning via ACME (Posh-ACME + DigiCert mPKI) with Route53 DNS-01 validation |
| 2 | `tomcat-awr.ps1` | [Admin_Web_Request](Admin_Web_Request) | Windows | TLM Agent AWR post-enrollment | Automated JKS-based renewal via TLM Agent |
| 3 | `tomcat-awr.sh`  | [Admin_Web_Request](Admin_Web_Request) | Linux   | TLM Agent AWR post-enrollment | Automated JKS-based renewal via TLM Agent |

> All three scripts assume a **JKS keystore** configuration in `server.xml`. They update the `<Certificate>` element under `<SSLHostConfig>` and restart Tomcat.

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

### 2. `tomcat-awr.ps1` — TLM Agent AWR Post-Enrollment (Windows)

Location: [Admin_Web_Request/tomcat-awr.ps1](Admin_Web_Request/tomcat-awr.ps1)

Runs as a **post-enrollment hook** triggered by the DigiCert TLM Agent after a certificate is issued or renewed. It receives certificate artefacts via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON), updates Tomcat's `server.xml` with the new JKS keystore path and credentials, and restarts the Tomcat Windows service automatically.

**Key behaviours:**
- Decodes TLM Agent payload (`DC1_POST_SCRIPT_DATA`) containing cert folder, JKS filename, keystore password, and truststore password
- Locates Tomcat via `CATALINA_HOME` or falls back to common Windows install paths (`Tomcat 9.0`, `10.0`, `10.1`)
- Creates a timestamped backup of `server.xml` before any modification
- Replaces the `<Certificate>` element in `server.xml` using regex (strict and flexible pattern matching)
- Restarts the Tomcat Windows service (`Tomcat10` → `Tomcat9` fallback, 30 s timeout)
- Writes a structured log to `C:\CertificateImport.log`

---

### 3. `tomcat-awr.sh` — TLM Agent AWR Post-Enrollment (Linux)

Location: [Admin_Web_Request/tomcat-awr.sh](Admin_Web_Request/tomcat-awr.sh)

The Linux bash counterpart of `tomcat-awr.ps1`. Runs as a **post-enrollment hook** when the TLM Agent issues or renews a certificate, decodes the `DC1_POST_SCRIPT_DATA` payload, updates `server.xml`, and restarts Tomcat.

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

## Prerequisites

### All scripts
- **Apache Tomcat** installed as a managed service
- A `<Certificate>` element under `<SSLHostConfig>` in `server.xml` (see [server.xml Requirements](#tomcat-serverxml-requirements))
- Administrative privileges (root on Linux, Administrator on Windows)

### Windows-specific (`tomcat-acm.ps1`, `tomcat-awr.ps1`)
- PowerShell 5.1 or later
- Tomcat installed as a Windows service (`Tomcat9` or `Tomcat10`)

### Linux-specific (`tomcat-awr.sh`)
- Bash, `jq`, `perl`, `base64`, `systemctl` (or `catalina.sh` as fallback)
- Install `jq` if missing: `sudo apt-get install jq` (Debian/Ubuntu) or `sudo yum install jq` (RHEL/CentOS)

### `tomcat-acm.ps1` only
- Internet access for dependency downloads and ACME challenge
- **Java JDK** with `keytool` (or `JAVA_HOME` set) — download from [Adoptium](https://adoptium.net/)
- **OpenSSL for Windows** — installed automatically via Chocolatey or direct download if not present
- **AWS credentials** with Route53 write access (for DNS-01 validation)
- A DigiCert mPKI account with ACME enabled and EAB credentials

### `tomcat-awr.ps1` and `tomcat-awr.sh`
- DigiCert TLM Agent installed and enrolled
- TLM Agent configured with an AWR post-enrollment script pointing to this file
- JKS format selected in the TLM certificate profile

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

EAB credentials and Route53 keys are also defined inline — see the [Security](#security) section below for guidance on externalising these.

### `tomcat-awr.ps1` (Windows)

Reads runtime values from the TLM Agent payload. Only minimal configuration is required:

```powershell
# Accept the legal notice to enable execution
$LEGAL_NOTICE_ACCEPT = $true

# Log file path (adjust if needed)
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

### `tomcat-awr.sh` (Linux)

Reads runtime values from the TLM Agent payload. Only minimal configuration is required:

```bash
# Accept the legal notice to enable execution
LEGAL_NOTICE_ACCEPT="true"

# Log file path (adjust if needed)
LOG_FILE="/opt/digicert/TomcatCertificateImport.log"
```

Tomcat home is resolved from `$CATALINA_HOME` automatically. If not set, the script probes:

```
/opt/tomcat        /usr/share/tomcat        /var/lib/tomcat        /etc/tomcat
/opt/tomcat10      /usr/share/tomcat10      /var/lib/tomcat10      /etc/tomcat10
/opt/tomcat9       /usr/share/tomcat9       /var/lib/tomcat9       /etc/tomcat9
```

If your Tomcat install or service name differs, edit the `possible_paths` and `service_names` arrays at the top of the script.

---

## Tomcat `server.xml` Requirements

All three scripts expect a `<Certificate>` element to be present within an `<SSLHostConfig>` block in `server.xml`. A minimal compatible configuration looks like this:

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

All three scripts create a timestamped backup of `server.xml` before making changes (e.g. `server.xml.backup_20260101_120000`).

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

### `tomcat-awr.ps1` — via TLM Agent AWR (Windows)

1. Set `$LEGAL_NOTICE_ACCEPT = $true` in the script.
2. In TLM, configure the certificate seat with:
   - **Format:** JKS
   - **Post-enrollment script:** path to `tomcat-awr.ps1`
3. When the TLM Agent enrolls or renews a certificate, the script runs automatically and restarts Tomcat.

### `tomcat-awr.sh` — via TLM Agent AWR (Linux)

1. Mark the script as executable: `chmod +x tomcat-awr.sh`
2. Edit the script and set `LEGAL_NOTICE_ACCEPT="true"`.
3. In TLM, configure the certificate seat with:
   - **Format:** JKS
   - **Post-enrollment script:** absolute path to `tomcat-awr.sh`
4. Ensure `jq` and `perl` are installed on the host.
5. When the TLM Agent enrolls or renews a certificate, the script runs automatically and restarts Tomcat.

---

## Security

> ⚠️ **Important:** The scripts in this repository contain **placeholder credentials** intended for demo/lab use only. Before deploying to any environment, review and address the following:

| Item | Risk | Recommendation |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT = false` | Script will not run | Set to `true` after reviewing the DigiCert legal notice |
| Keystore password hardcoded (ACM) | Credential exposure | Read from a secrets manager or environment variable |
| EAB KID / HMAC in plaintext (ACM) | Credential exposure | Use environment variables, Windows Credential Manager, or a vault |
| AWS access key / secret key in plaintext (ACM) | Credential exposure | Use IAM roles, instance profiles, or AWS Secrets Manager |
| Password logging | Log file exposure | `tomcat-awr.sh` masks passwords; review `tomcat-awr.ps1` and `tomcat-acm.ps1` and redact before production use |
| `CATALINA_HOME` or hard-coded paths | Path mismatch | Validate paths match your actual Tomcat installation |
| Log file permissions | Disclosure of cert metadata | Restrict log directory ACLs (`/opt/digicert/` on Linux, `C:\` on Windows) |

---

## Logging

| Script | Log destination |
|---|---|
| `tomcat-acm.ps1` | PowerShell console (colour-coded). Redirect with `.\tomcat-acm.ps1 *>> C:\tomcat-acme.log` |
| `tomcat-awr.ps1` | `C:\CertificateImport.log` |
| `tomcat-awr.sh`  | `/opt/digicert/TomcatCertificateImport.log` (passwords are masked) |

---

## Troubleshooting

**Script exits immediately with "Legal notice not accepted"**
Set `$LEGAL_NOTICE_ACCEPT = $true` (PowerShell) or `LEGAL_NOTICE_ACCEPT="true"` (bash) in the script.

**`CATALINA_HOME` not found / wrong path**
- Windows: `[System.Environment]::SetEnvironmentVariable("CATALINA_HOME","C:\your\tomcat\path","Machine")`
- Linux: `export CATALINA_HOME=/your/tomcat/path` (and persist in `/etc/environment` or the TLM Agent service environment)

**`keytool` not found (ACM script)**
Ensure a Java JDK is installed and either `JAVA_HOME` is set or `keytool.exe` is on the system `PATH`.

**`jq: command not found` (Linux AWR script)**
Install jq: `sudo apt-get install jq` or `sudo yum install jq`.

**Certificate element not found in `server.xml`**
Verify that `server.xml` contains a `<Certificate ... />` element inside `<SSLHostConfig>`. All scripts use regex/perl matching and require at least one element to be present to perform an update.

**Tomcat service not restarting**
- Windows: scripts probe `Tomcat10` then `Tomcat9`. Run `Get-Service | Where-Object {$_.Name -like "*tomcat*"}` to confirm the actual service name and update the script.
- Linux: scripts probe `tomcat`, `tomcat10`, `tomcat9` via `systemctl`. Run `systemctl list-unit-files | grep -i tomcat` to find your service name, then add it to the `service_names` array. If no systemd unit exists, the script falls back to `${CATALINA_HOME}/bin/shutdown.sh` and `startup.sh`.

**ACME certificate request fails (DNS-01)**
Verify the Route53 credentials have `route53:ChangeResourceRecordSets` and `route53:GetChange` permissions for the hosted zone, and that the domain's NS records resolve to Route53.

**`DC1_POST_SCRIPT_DATA environment variable is not set`**
The AWR scripts are designed to be triggered by the TLM Agent, which automatically populates this variable. If you are testing manually, you must set it to a Base64-encoded JSON payload matching the expected schema (`certfolder`, `files[0]`, `password`, `keystorepassword`, `truststorepassword`).

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
