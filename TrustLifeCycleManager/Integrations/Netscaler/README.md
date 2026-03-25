# DigiCert TLM AWR Post-Enrollment Script — Citrix NetScaler ADC

Automates TLS certificate deployment to Citrix NetScaler (ADC) appliances via the Nitro REST API, triggered by DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment hooks (AWR).

## Overview

This PowerShell/Bash script is designed to run as an **Admin Web Request (AWR) post-enrollment script** within the DigiCert TLM Agent. After the agent enrolls or renews a certificate, this script automatically uploads and installs it on a target NetScaler ADC — handling both first-time creation and in-place renewal of SSL cert-key pairs.

The script is available in two variants to suit your deployment environment:

| Variant | Platform | Filename |
|---|---|---|
| **PowerShell** | Windows (TLM Agent on Windows) | `netscaler-awr.ps1` |
| **Bash** | Linux (TLM Agent on Linux/Ubuntu) | `netscaler-awr.sh` |

Both variants implement identical logic and produce the same outcome — choose the appropriate script for the OS hosting your TLM Agent.

---

## AWR Script vs. Native TLM Connector — Key Differences

DigiCert TLM also offers a **native Citrix NetScaler connector**. The two integration methods serve different purposes and operate in fundamentally different ways.

| | AWR Post-Enrollment Script | Native TLM Connector |
|---|---|---|
| **How it works** | Triggered by the TLM Agent after certificate enrollment or renewal; pushes the new cert/key directly to the ADC via the Nitro API | TLM discovers and inventories existing certificates already bound on the ADC, then manages their lifecycle from the platform |
| **Certificate discovery** | ❌ No — does not discover or inventory existing certs on the ADC | ✅ Yes — TLM scans the appliance and adds all discovered certificates to your centralised inventory |
| **Binding awareness** | ❌ No — targets a single named cert-key pair; not aware of IP/port bindings | ✅ Yes — maps which certificate is bound to which IP address and port (e.g. `10.160.53.251:51444`) |
| **Renewal targeting** | Updates the named cert-key pair; all existing vserver bindings to that pair are automatically preserved | Replaces the certificate on the specific IP:port binding identified during discovery |
| **Use case** | Best for environments where the TLM Agent manages the full certificate lifecycle end-to-end | Best for environments where certificates already exist on the ADC and you want to bring them under centralised TLM management without re-provisioning |
| **Agent required** | ✅ Yes — requires TLM Agent on a Windows or Linux host with network access to the ADC | Depends on connector configuration |

### When to Use Each

- **Use the AWR script** when the TLM Agent is already issuing and managing the certificate, and you need the resulting cert/key deployed to NetScaler automatically on each issuance or renewal.
- **Use the native connector** when you have existing certificates bound across multiple NetScaler IP:port combinations and want TLM to discover, inventory, and automate renewals against those specific bindings — without requiring a separately managed TLM Agent.

> **Note:** The two approaches are not mutually exclusive in all environments, but care should be taken to avoid dual management of the same certificate.

---

## What the Script Does

1. **Uploads** the certificate and private key to `/nsconfig/ssl/` on the ADC via the Nitro `systemfile` endpoint, using timestamped filenames for auditability.
2. **Detects** whether the named SSL cert-key pair already exists on the appliance.
3. **Updates** an existing cert-key pair in place (preserving all vserver bindings) or **creates** a new one.
4. **Saves** the running configuration so changes persist across reboots.

## Key Features

- **Zero-downtime renewals** — updating an existing cert-key pair preserves all vserver bindings; no manual rebinding required.
- **Multi-method update fallback** — tries POST `?action=update` with full path, PUT with full path, then repeats with filename-only payloads, accommodating differences across NetScaler firmware versions.
- **Windows & Linux support** — available as both a PowerShell script (`.ps1`) for Windows-hosted TLM Agents and a Bash script (`.sh`) for Linux-hosted TLM Agents.
- **PowerShell 5.1 & 7+ compatible** — uses `Invoke-RestMethod -SkipCertificateCheck` on PS 7+ and a `TrustAllCertsPolicy` type on PS 5.1 for self-signed management certificates.
- **TLS 1.2/1.3 enforced** — sets the security protocol before any API call.
- **Comprehensive logging** — every step, API response, and error is written to a timestamped log file with sensitive values obfuscated.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **DigiCert TLM Agent** | Installed and configured on a Windows or Linux host with AWR post-enrollment enabled |
| **PowerShell** | 5.1 or 7+ (Windows variant) |
| **Bash** | bash 4+ (Linux variant) |
| **NetScaler ADC** | Any supported Citrix ADC / NetScaler version with the Nitro REST API enabled |
| **API credentials** | A Nitro API user with permissions to upload files, manage SSL cert-key pairs, and save the configuration |
| **Network access** | HTTPS connectivity from the TLM Agent host to the NetScaler management IP |

---

## AWR Configuration

Configure the script in the TLM Agent AWR settings with **four arguments**:

| Argument | Description | Example |
|---|---|---|
| **Argument 1** | NetScaler hostname or IP (no `https://` prefix) | `netscaler.example.com` |
| **Argument 2** | Nitro API username | `nsroot` |
| **Argument 3** | Nitro API password | `••••••••` |
| **Argument 4** | SSL cert-key pair name on the ADC | `www.example.com-certkey` |

The script receives certificate data from the TLM Agent via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON containing the certificate folder path, file list, and arguments).

---

## Legal Notice Acceptance

Before the script will execute, you must explicitly accept the legal notice by editing the configuration variable at the top of the script.

**PowerShell (`netscaler-awr.ps1`):**
```powershell
$LEGAL_NOTICE_ACCEPT = "true"
```

**Bash (`netscaler-awr.sh`):**
```bash
LEGAL_NOTICE_ACCEPT="true"
```

The script will exit immediately if this value is not set to `"true"`.

---

## How It Works
```
TLM Agent enrolls/renews cert
        │
        ▼
AWR triggers this script
        │
        ▼
Decode DC1_POST_SCRIPT_DATA (Base64 → JSON)
        │
        ▼
Extract cert/key files + arguments
        │
        ▼
Validate arguments & test Nitro API connectivity
        │
        ▼
Upload cert & key to /nsconfig/ssl/ (timestamped filenames)
        │
        ▼
Cert-key pair exists? ─── YES ──▶ Update in place (bindings preserved)
        │
        NO
        │
        ▼
Create new cert-key pair
        │
        ▼
Save running configuration
```

---

## Logging

All output is written to a timestamped log file. Default paths:

| Platform | Default Log Path |
|---|---|
| **Windows** | `C:\Program Files\DigiCert\TLM Agent\logs\awr-netscaler-adc.log` |
| **Linux** | `/home/ubuntu/netscaler/netscaler-adc.log` |

The log path is configurable via the `$LOGFILE` (PowerShell) or `LOGFILE` (Bash) variable at the top of the script. Passwords are automatically obfuscated in all log entries.

---

## Troubleshooting

| Symptom | Likely Cause |
|---|---|
| `ERROR: Legal notice not accepted` | Set `LEGAL_NOTICE_ACCEPT = "true"` in the script |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | The script is not being invoked by the TLM Agent AWR framework |
| `Authentication failed (HTTP 401)` | Check the Nitro API username and password (Arguments 2 & 3) |
| `Connectivity test failed` | Verify HTTPS access from the agent host to the NetScaler management IP |
| `All update methods failed` | Check the cert-key pair name matches exactly; review NetScaler firmware compatibility |
| `Failed to create cert-key pair` | The cert-key pair name may conflict with an existing resource; check the ADC |

---

## File Structure
```
netscaler-awr.ps1          # AWR post-enrollment script (Windows / PowerShell)
netscaler-awr.sh           # AWR post-enrollment script (Linux / Bash)
```

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. Use of this software is subject to the terms and conditions of your agreement with DigiCert. See the legal notice embedded in the script header for full details.