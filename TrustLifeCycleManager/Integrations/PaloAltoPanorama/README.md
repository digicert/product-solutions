<div align="center">
  <img src="https://upload.wikimedia.org/wikipedia/commons/4/48/DigiCert_logo.svg" alt="DigiCert Logo" width="300">

  <h3>DigiCert Trust Lifecycle Manager — AWR Post-Enrollment Script</h3>
  <h2>Palo Alto Panorama Certificate Upload</h2>

  [![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)
  [![Bash](https://img.shields.io/badge/bash-%3E%3D4.0-4EAA25?style=flat&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
  [![PowerShell](https://img.shields.io/badge/powershell-%3E%3D5.1-5391FE?style=flat&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
  [![PAN-OS](https://img.shields.io/badge/PAN--OS-XML%20API-FA582D?style=flat&logo=paloaltonetworks&logoColor=white)](https://docs.paloaltonetworks.com/pan-os/11-1/pan-os-panorama-api)
  [![TLM](https://img.shields.io/badge/DigiCert-TLM-FF6D00?style=flat)](https://www.digicert.com/tls-ssl/trust-lifecycle-manager)
</div>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [How It Works](#-how-it-works)
- [Supported Modes](#-supported-modes)
- [Prerequisites](#-prerequisites)
  - [Linux (Bash)](#linux-bash)
  - [Windows (PowerShell)](#windows-powershell)
- [TLM AWR Configuration](#-tlm-awr-configuration)
- [Script Configuration Variables](#-script-configuration-variables)
- [Certificate Name Resolution](#-certificate-name-resolution)
- [Logging](#-logging)
- [Troubleshooting](#-troubleshooting)
- [Legal Notice](#-legal-notice)
- [Support](#-support)

---

## 🎯 Overview

These production-ready reference scripts automate the upload of TLS certificates and private keys to **Palo Alto Panorama** via the PAN-OS XML API. They are designed to run non-interactively as **DigiCert Trust Lifecycle Manager (TLM) AWR (Automated Web Request) post-enrollment scripts**, triggering automatically each time a certificate is issued or renewed.

Three script variants are provided for maximum platform flexibility:

| Script | Platform | Shell / Runtime |
|---|---|---|
| `paloalto-panorama-awr.sh` | Linux / macOS | Bash ≥ 4.0 |
| `paloalto-panorama-awr_ps5.ps1` | Windows (built-in) | Windows PowerShell ≥ 5.1 |
| `paloalto-panorama-awr_ps7.ps1` | Windows / Linux | PowerShell ≥ 7.0 |

All three scripts implement the same six-step workflow. The two PowerShell variants differ only in how they handle multipart file uploads and TLS certificate validation — the PS5 variant implements both manually so it runs under the default `powershell.exe` shipped with Windows, while the PS7 variant uses the native `-Form` and `-SkipCertificateCheck` parameters available in PowerShell 7.

---

## 🔄 How It Works

The scripts receive certificate metadata from TLM via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON containing file paths and AWR arguments). On execution, the following steps are performed:

```
Step 1 │ Authenticate to Panorama → obtain API key
Step 2 │ Resolve certificate name (CN discovery or explicit override)
Step 3 │ Upload PEM certificate via multipart import API
Step 4 │ Upload PEM private key via multipart import API
Step 5 │ Commit changes to Panorama
Step 6 │ Push template stack to managed firewalls  ← template mode only
```

All steps are logged with timestamps. Credentials are masked in the log output.

---

## ⚙️ Supported Modes

The `MODE` / `$Mode` configuration variable controls the upload target and post-upload actions.

### `system` mode *(default)*

Uploads the certificate directly to **Panorama's own certificate store**. Use this when the certificate is for Panorama itself — for example the management UI, syslog TLS, or SNMP.

- Commits to Panorama after upload.
- Does **not** push to managed firewalls.
- After the script completes, manually create an SSL/TLS Service Profile referencing the new certificate and assign it under **Panorama › Setup › Management › General Settings**.

### `template` mode

Uploads the certificate into a **Panorama device template**, commits to Panorama, then pushes the template stack to all managed firewalls. Use this when the certificate is consumed by firewalls — for example GlobalProtect portals/gateways, SSL Forward Decryption, LDAP, Captive Portal, or IPSec.

- Requires **Argument 4** (Template Name) and **Argument 5** (Template Stack Name).
- The push targets all devices assigned to the specified template stack.

---

## 🛠 Prerequisites

### Linux (Bash)

The following tools must be present on the system where TLM executes the AWR script.

#### Required packages

| Tool | Purpose | Typical package name |
|---|---|---|
| `bash` ≥ 4.0 | Script interpreter | `bash` |
| `curl` | PAN-OS XML API calls (auth, config GET, commit, push) and multipart file uploads | `curl` |
| `openssl` | Extracts the Common Name from the leaf certificate PEM | `openssl` |
| `grep` with PCRE (`-P`) | JSON and XML parsing via regex | `grep` (GNU grep ≥ 2.5) |
| `awk` | AWR argument extraction from JSON | `gawk` or `mawk` |
| `base64` | Decodes the `DC1_POST_SCRIPT_DATA` payload | `coreutils` |

> **Note:** All of the above are standard on Ubuntu 20.04+, RHEL 8+, and Debian 11+. They are unlikely to require manual installation on a typical TLM agent host.

#### Installation — Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y curl openssl grep gawk coreutils
```

#### Installation — RHEL / CentOS / AlmaLinux

```bash
sudo dnf install -y curl openssl grep gawk coreutils
```

#### Verify installed versions

```bash
bash --version        # Should report 4.x or higher
curl --version        # Any recent version
openssl version       # Any recent version
grep --version        # Confirm GNU grep (PCRE -P support)
```

---

### Windows (PowerShell)

Two PowerShell variants are provided. Choose the one that matches your environment.

#### Option A — `paloalto-panorama-awr_ps5.ps1` (Windows PowerShell 5.1)

This variant runs under the **Windows PowerShell 5.1** that ships built-in with Windows 10 and Windows Server 2016+. No additional installation is required. It implements multipart file uploads manually via `System.IO.MemoryStream` and disables server certificate validation process-wide via `[Net.ServicePointManager]::ServerCertificateValidationCallback`. It also explicitly enables TLS 1.2 since Windows PowerShell 5.1 defaults to TLS 1.0/1.1 on older builds.

| Requirement | Minimum version | Notes |
|---|---|---|
| **Windows PowerShell** | **5.1** | Built into Windows 10 / Server 2016+. No installation needed. |
| **.NET Framework** | 4.5+ (bundled with Windows) | Used for `System.IO.MemoryStream`, `System.Convert`, `[uri]::EscapeDataString` |

**No additional installation steps are required.** Invoke with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\paloalto-panorama-awr_ps5.ps1
```

---

#### Option B — `paloalto-panorama-awr_ps7.ps1` (PowerShell 7)

This variant requires **PowerShell 7.0 or later** and uses the native `-Form` parameter on `Invoke-WebRequest` for multipart uploads and `-SkipCertificateCheck` for certificate validation bypass.

| Requirement | Minimum version | Notes |
|---|---|---|
| **PowerShell** | **7.0** | Required for `-Form` (multipart upload) and `-SkipCertificateCheck` on `Invoke-WebRequest`. The built-in Windows PowerShell 5.1 is **not** compatible with this script variant. |
| **.NET** | 6.0 (bundled with PS 7) | Used for `X509Certificate2`, `Convert::FromBase64String`, `HttpUtility::UrlEncode` |

##### Installing PowerShell 7

**Option 1 — winget (Windows 10/11)**

```powershell
winget install --id Microsoft.PowerShell --source winget
```

**Option 2 — MSI installer**

Download the latest stable MSI from the [PowerShell GitHub releases page](https://github.com/PowerShell/PowerShell/releases) and run the installer. Select "Add PowerShell to PATH" during setup.

**Option 3 — Direct download via PowerShell (existing PS 5.1)**

```powershell
Invoke-Expression "& { $(Invoke-RestMethod https://aka.ms/install-powershell.ps1) } -UseMSI"
```

##### Verify the installation

```powershell
pwsh --version
# Expected: PowerShell 7.x.x
```

Invoke with:

```powershell
pwsh -ExecutionPolicy Bypass -File .\paloalto-panorama-awr_ps7.ps1
```

---

#### Execution policy

TLM typically executes scripts in a process-scoped execution context. If you need to set the policy manually on the agent host:

```powershell
# Allow locally-created scripts to run (recommended minimum)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine

# Or for a single process session only (PS 5.1)
powershell.exe -ExecutionPolicy Bypass -File .\paloalto-panorama-awr_ps5.ps1

# Or for a single process session only (PS 7)
pwsh -ExecutionPolicy Bypass -File .\paloalto-panorama-awr_ps7.ps1
```

#### No additional modules required

Both PowerShell variants use only .NET built-in types and `Invoke-WebRequest` — no third-party PowerShell modules need to be installed.

---

## 🔧 TLM AWR Configuration

In the TLM Admin console, configure the AWR profile for the enrollment profile associated with this Panorama integration. Set the following **DC1_POST_SCRIPT_DATA** arguments:

| Argument | Required | Description |
|---|---|---|
| **Argument 1** | ✅ Yes | Panorama IP address or FQDN (e.g. `panorama.example.com` or `10.0.0.1`) |
| **Argument 2** | ✅ Yes | Panorama credentials in `username:password` format. Passwords containing colons are handled correctly — only the first colon is used as the delimiter. |
| **Argument 3** | ⬜ Optional | Certificate name override. If set, the script uses this exact name for the Panorama certificate entry and skips CN-based discovery entirely. If left blank, CN discovery is used (see [Certificate Name Resolution](#-certificate-name-resolution)). |
| **Argument 4** | ✅ `template` mode | Panorama **Template Name** — the name of the device template the certificate should be imported into. |
| **Argument 5** | ✅ `template` mode | Panorama **Template Stack Name** — the stack pushed to managed firewalls after the commit. |

> **Panorama account permissions:** The credentials supplied in Argument 2 must have sufficient privileges to import certificates, perform a full commit, and (in `template` mode) push a template stack. A role with `Commit`, `Import`, and `Panorama Push` permissions on the relevant templates is sufficient. Device admin or superuser roles also work.

---

## 🔩 Script Configuration Variables

The following variables are set at the top of each script and should be reviewed before deployment.

| Variable | Default | Description |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT` / `$LegalNoticeAccept` | `"false"` / `$false` | Must be changed to `"true"` / `$true` to accept the DigiCert legal notice. The script exits immediately if this is not set to the accepted value. |
| `MODE` / `$Mode` | `"system"` | Upload mode. Set to `"template"` or `"system"` — see [Supported Modes](#-supported-modes). |
| `KEY_PASSPHRASE` / `$KeyPassphrase` | `"ChangeMe123!"` | Storage passphrase passed to the PAN-OS private key import API. The PAN-OS XML API requires a non-empty passphrase parameter even for unencrypted PEM keys; this value is used purely as a placeholder on the PAN-OS side. **Change this to a site-specific value.** |
| `WAIT_SECONDS` / `$WaitSeconds` | `10` | Polling interval in seconds when monitoring commit and push job status. |
| `LOGFILE` / `$Logfile` | `/home/ubuntu/panorama.log` (Bash) `C:\DigiCert\panorama.log` (PS) | Full path to the log file. Parent directories are created automatically. |

---

## 🔍 Certificate Name Resolution

When **Argument 3 is not set**, the scripts automatically resolve the Panorama certificate entry name from the certificate's Common Name (CN) using the following logic:

```
┌─────────────────────────────────────────────────┐
│       CN extracted from leaf certificate        │
└────────────────────┬────────────────────────────┘
                     │  Query Panorama config for
                     │  all certs with matching CN
                     ▼
      ┌──────────────┴──────────────┐
      │   How many matches found?   │
      └──┬──────────────────────────┘
         │
    0 matches ──► Create new entry
    (CN → name: dots replaced with hyphens)
         │
    1 match   ──► Update in place
    (bindings such as SSL/TLS profiles
     and GP portals are preserved)
         │
    2+ matches ──► ❌ ERROR — ambiguous
    Script exits and lists all conflicting
    entry names. Set Argument 3 to resolve.
```

If your environment has multiple certificates sharing the same CN (for example, a wildcard renewed multiple times under different names), always set **Argument 3** to the exact Panorama certificate entry name you want to update.

---

## 📄 Logging

Both scripts write a structured timestamped log to the path configured in `LOGFILE` / `$Logfile`.

**Sensitive values masked in the log:**
- Panorama password (Argument 2)
- Key passphrase (`KEY_PASSPHRASE` / `$KeyPassphrase`)
- API key obtained from Panorama

**Sample log output (successful `template` mode run):**

```
[2026-01-15 09:12:04] ==========================================
[2026-01-15 09:12:04] Panorama Certificate Upload — AWR Post-Enrollment Script
[2026-01-15 09:12:04] ==========================================
[2026-01-15 09:12:04] Legal notice accepted, proceeding.
[2026-01-15 09:12:04] Mode validated: template
[2026-01-15 09:12:04] Common Name: vpn.example.com
[2026-01-15 09:12:04] [1] Authenticating to Panorama (panorama.example.com)...
[2026-01-15 09:12:04]   Authenticated successfully.
[2026-01-15 09:12:04] [2] Resolving target certificate name...
[2026-01-15 09:12:05]   Found exactly one certificate with CN='vpn.example.com': 'vpn-example-com'
[2026-01-15 09:12:05]   Will update in place (bindings will be preserved).
[2026-01-15 09:12:05] [3] Uploading certificate 'vpn-example-com'...
[2026-01-15 09:12:05]   Certificate uploaded successfully.
[2026-01-15 09:12:05] [4] Uploading private key for 'vpn-example-com'...
[2026-01-15 09:12:06]   Private key uploaded successfully.
[2026-01-15 09:12:06] [5] Committing to Panorama...
[2026-01-15 09:12:06]   Commit job ID: 142
[2026-01-15 09:12:16]   Commit... 45%
[2026-01-15 09:12:26]   Commit completed successfully.
[2026-01-15 09:12:26] [6] Pushing template stack 'GP-Stack' to all devices...
[2026-01-15 09:12:26]   Push job ID: 143
[2026-01-15 09:12:36]   Push to devices... 60%
[2026-01-15 09:12:46]   Push to devices completed successfully.
[2026-01-15 09:12:46] ==========================================
[2026-01-15 09:12:46] COMPLETED SUCCESSFULLY
[2026-01-15 09:12:46] ==========================================
```

---

## 🔎 Troubleshooting

### Authentication failure (Step 1)

**Symptom:** `ERROR: Failed to get API key.`

- Verify the credentials in Argument 2 are correct and in `username:password` format.
- Confirm the Panorama management interface is reachable from the TLM agent host on HTTPS (port 443).
- Check that the account has not been locked out (Panorama admin lockout policies).

---

### Certificate upload failure (Step 3 or 4)

**Symptom:** `ERROR: Certificate upload failed:` or `ERROR: Private key upload failed:`

- Confirm the `.crt` file contains **only the leaf certificate** (a single `BEGIN CERTIFICATE` block). If it is a full chain file, the API may reject it.
- Verify the certificate and key files exist at the paths reported in the log.
- Check that the Panorama user has import permissions for the target template (template mode) or shared store (system mode).

---

### CN discovery finds multiple matches (Step 2)

**Symptom:** `ERROR: CN-based discovery found N certificates sharing CN='...'`

- The log lists all conflicting certificate entry names.
- Set **Argument 3** to the exact Panorama entry name you want to update, then re-trigger the AWR.

---

### Commit creates no job (Step 5)

**Symptom:** `No commit job created (may be nothing to commit or already committed).`

- This is a warning, not an error. It typically means there were no pending changes in the candidate configuration at commit time.
- If the push in Step 6 also fails or produces no job, verify the template and stack names in Arguments 4 and 5 exactly match the names in Panorama (case-sensitive).

---

### PowerShell: `Invoke-WebRequest` form upload fails

**Symptom:** `A parameter cannot be found that matches parameter name 'Form'.`

- You are running `paloalto-panorama-awr_ps7.ps1` under Windows PowerShell 5.1. The PS7 script variant requires **PowerShell 7.0 or later**.
- **Recommended fix:** Switch to `paloalto-panorama-awr_ps5.ps1`, which is designed specifically for Windows PowerShell 5.1 and implements multipart uploads manually — no additional installation needed.
- Alternatively, install PowerShell 7 as described in [Prerequisites → Windows](#windows-powershell) and invoke the PS7 script with `pwsh` rather than `powershell`.

---

### PowerShell: Certificate validation error

**Symptom:** `The SSL connection could not be established` or `Could not establish trust relationship`

- Panorama uses a self-signed certificate by default.
- **`paloalto-panorama-awr_ps7.ps1`** uses `-SkipCertificateCheck` on all `Invoke-WebRequest` calls. If the error persists, confirm you are running PowerShell 7 and not 5.1.
- **`paloalto-panorama-awr_ps5.ps1`** disables certificate validation process-wide via `[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }` and forces TLS 1.2 via `[Net.ServicePointManager]::SecurityProtocol`. If the error persists, confirm you are running PowerShell 5.1 or later (not an older PS version) and that your Windows build supports TLS 1.2.

---

### Bash: `grep: invalid option -- 'P'`

**Symptom:** Script fails at argument extraction with a grep error.

- The system's `grep` does not support Perl-compatible regex (`-P`). This can occur on macOS which ships BSD grep by default.
- Install GNU grep: `brew install grep` (macOS with Homebrew) and ensure it appears first in `PATH`, or run the script on a Linux host.

---

## ⚖️ Legal Notice

Copyright © 2026 DigiCert, Inc. All rights reserved.

This software is provided under license and subject to the DigiCert legal notice embedded at the top of each script. Use is subject to the terms and conditions of your agreement with DigiCert. See the script header for the full notice text.

---
<div align="center">
  <br>
  <a href="https://www.digicert.com">Website</a> •
  <a href="https://www.linkedin.com/company/digicert">LinkedIn</a> •
  <a href="https://twitter.com/digicert">Twitter</a> •
  <a href="https://www.youtube.com/digicert">YouTube</a>
  <br><br>
  <sub>© 2026 DigiCert, Inc. All rights reserved.</sub>
</div>