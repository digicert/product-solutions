# DigiCert TLM — Apache Tomcat TLS Certificate Automation

PowerShell scripts for automating TLS certificate lifecycle management on **Apache Tomcat (Windows)** using DigiCert Trust Lifecycle Manager (TLM). Two complementary automation paths are provided:

| Script | Trigger | Use Case |
|---|---|---|
| `tomcat-awr.ps1` | TLM Agent AWR post-enrollment | Automated renewal via TLM Agent |
| `tomcat-acm.ps1` | Standalone / scheduled task | Initial provisioning via ACME (Posh-ACME + DigiCert mPKI) |

---

## Overview

### `tomcat-awr.ps1` — TLM Agent AWR Post-Enrollment Script

Runs as a **post-enrollment hook** triggered by the DigiCert TLM Agent after a certificate is issued or renewed. It receives certificate artefacts via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON), updates Tomcat's `server.xml` with the new JKS keystore path and credentials, and restarts the Tomcat Windows service automatically.

**Key behaviours:**
- Decodes TLM Agent payload (`DC1_POST_SCRIPT_DATA`) containing cert folder, JKS filename, keystore password, and truststore password
- Locates Tomcat via `CATALINA_HOME` or falls back to common installation paths (`Tomcat 9.0`, `10.0`, `10.1`)
- Creates a timestamped backup of `server.xml` before any modification
- Replaces the `<Certificate>` element in `server.xml` using regex — supports both strict and flexible pattern matching
- Restarts the Tomcat Windows service (`Tomcat10` → `Tomcat9` fallback, 30 s timeout)
- Writes a structured log to `C:\CertificateImport.log`

---

### `tomcat-acm.ps1` — Standalone ACME Provisioning Script

An **end-to-end provisioning script** that handles everything from dependency installation through to Tomcat restart. It uses [Posh-ACME](https://github.com/rmbolger/Posh-ACME) to request a certificate from the DigiCert mPKI ACME endpoint, converts it to a Java Keystore (JKS) format, updates `server.xml`, and restarts Tomcat.

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

## Prerequisites

### Both scripts
- **Windows** with PowerShell 5.1 or later
- **Apache Tomcat** installed as a Windows service (`Tomcat9` or `Tomcat10`)
- Administrator privileges

### `tomcat-awr.ps1`
- DigiCert TLM Agent installed and enrolled
- TLM Agent configured with an AWR post-enrollment script pointing to this file
- JKS format selected in the TLM certificate profile

### `tomcat-acm.ps1`
- Internet access for dependency downloads and ACME challenge
- **Java JDK** with `keytool` (or `JAVA_HOME` set) — download from [Adoptium](https://adoptium.net/)
- **OpenSSL for Windows** — installed automatically via Chocolatey or direct download if not present
- **AWS credentials** with Route53 write access (for DNS-01 validation)
- A DigiCert mPKI account with ACME enabled and EAB credentials

---

## Configuration

### `tomcat-awr.ps1`

The script reads all runtime values from the TLM Agent payload. The only configuration required before deployment:

```powershell
# Accept the legal notice to enable execution
$LEGAL_NOTICE_ACCEPT = $true

# Log file path (adjust if needed)
$logFile = "C:\CertificateImport.log"
```

Tomcat home is resolved from `$env:CATALINA_HOME` automatically. If not set, the script probes these paths:

```
C:\Program Files\Apache Software Foundation\Tomcat 10.1
C:\Program Files\Apache Software Foundation\Tomcat 10.0
C:\Program Files\Apache Software Foundation\Tomcat 9.0
C:\tomcat
C:\apache-tomcat
```

### `tomcat-acm.ps1`

Edit the configuration block near the top of the script before running:

```powershell
$LEGAL_NOTICE_ACCEPT = $true          # Must be set to $true

$domain           = "your-domain.example.com"
$keystorePassword = "changeit"        # Use a strong password in production
$tomcatHome       = "C:\tomcat"       # Path to your Tomcat installation
```

EAB credentials and Route53 keys are also defined inline — see the [Security](#security) section below for guidance on externalising these.

---

## Tomcat `server.xml` Requirements

Both scripts expect a `<Certificate>` element to be present within an `<SSLHostConfig>` block in `server.xml`. A minimal compatible configuration looks like this:

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

Both scripts create a timestamped backup of `server.xml` before making changes (e.g. `server.xml.backup_20250101_120000`).

---

## Usage

### `tomcat-awr.ps1` — via TLM Agent AWR

1. Set `$LEGAL_NOTICE_ACCEPT = $true` in the script.
2. In TLM, configure the certificate seat with:
   - **Format:** JKS
   - **Post-enrollment script:** path to `tomcat-awr.ps1`
3. When the TLM Agent enrolls or renews a certificate, the script runs automatically and restarts Tomcat.

### `tomcat-acm.ps1` — standalone

1. Set `$LEGAL_NOTICE_ACCEPT = $true` and update the configuration variables.
2. Run PowerShell **as Administrator**.
3. Execute the script:

```powershell
.\tomcat-acm.ps1
```

For automated renewal, schedule this script using Windows Task Scheduler (recommended: run every 60 days for 90-day certificates).

---

## Security

> ⚠️ **Important:** The scripts in this repository contain **placeholder credentials** intended for demo/lab use only. Before deploying to any environment, review and address the following:

| Item | Risk | Recommendation |
|---|---|---|
| `$LEGAL_NOTICE_ACCEPT = $false` | Script will not run | Set to `$true` after reviewing the DigiCert legal notice |
| Keystore password hardcoded | Credential exposure | Read from a secrets manager or environment variable |
| EAB KID / HMAC in plaintext | Credential exposure | Use `$env:` variables, Windows Credential Manager, or a vault |
| AWS access key / secret key in plaintext | Credential exposure | Use IAM roles, instance profiles, or AWS Secrets Manager |
| Password logging in `tomcat-awr.ps1` | Log file exposure | Remove or redact the plaintext password log lines before production use |
| `CATALINA_HOME` or hardcoded paths | Path mismatch | Validate paths match your actual Tomcat installation |

---

## Logging

**`tomcat-awr.ps1`** writes timestamped entries to:
```
C:\CertificateImport.log
```

**`tomcat-acm.ps1`** outputs directly to the PowerShell console with colour-coded status messages. Redirect to a file if logging is required:
```powershell
.\tomcat-acm.ps1 *>> C:\tomcat-acme.log
```

---

## Troubleshooting

**Script exits immediately with "Legal notice not accepted"**
Set `$LEGAL_NOTICE_ACCEPT = $true` in the script.

**`CATALINA_HOME` not found / wrong path**
Set the environment variable: `[System.Environment]::SetEnvironmentVariable("CATALINA_HOME","C:\your\tomcat\path","Machine")`

**`keytool` not found**
Ensure a Java JDK is installed and either `JAVA_HOME` is set or `keytool.exe` is on the system `PATH`.

**Certificate element not found in `server.xml`**
Verify your `server.xml` contains a `<Certificate ... />` element inside `<SSLHostConfig>`. The scripts use regex matching and require at least one element to be present to perform an update.

**Tomcat service not restarting**
The scripts probe `Tomcat10` then `Tomcat9` (and additional names in `tomcat-acm.ps1`). Run `Get-Service | Where-Object {$_.Name -like "*tomcat*"}` to confirm the exact service name and update the script accordingly.

**ACME certificate request fails (DNS-01)**
Verify the Route53 credentials have `route53:ChangeResourceRecordSets` and `route53:GetChange` permissions for the hosted zone, and that the domain's NS records resolve to Route53.

---

## Related Resources

- [DigiCert Trust Lifecycle Manager Documentation](https://docs.digicert.com/en/trust-lifecycle-manager.html)
- [DigiCert mPKI ACME Documentation](https://docs.digicert.com/en/trust-lifecycle-manager/certificate-issuance/acme.html)
- [Posh-ACME on GitHub](https://github.com/rmbolger/Posh-ACME)
- [Apache Tomcat SSL/TLS How-To](https://tomcat.apache.org/tomcat-10.1-doc/ssl-howto.html)
- [OpenSSL for Windows (Shining Light)](https://slproweb.com/products/Win32OpenSSL.html)

---

## License

Copyright © 2024 DigiCert. All rights reserved. See the legal notice embedded in each script for full terms.