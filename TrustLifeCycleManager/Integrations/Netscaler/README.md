# DigiCert TLM AWR Post-Enrollment Script — Citrix NetScaler ADC

Automates TLS certificate deployment to Citrix NetScaler (ADC) appliances via the Nitro REST API, triggered by DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment hooks (AWR).

## Overview

This PowerShell script is designed to run as an **Admin Web Request (AWR) post-enrollment script** within the DigiCert TLM Agent. After the agent enrolls or renews a certificate, this script automatically uploads and installs it on a target NetScaler ADC — handling both first-time creation and in-place renewal of SSL cert-key pairs.

### What It Does

1. **Uploads** the certificate and private key to `/nsconfig/ssl/` on the ADC via the Nitro `systemfile` endpoint, using timestamped filenames for auditability.
2. **Detects** whether the named SSL cert-key pair already exists on the appliance.
3. **Updates** an existing cert-key pair in place (preserving all vserver bindings) or **creates** a new one.
4. **Saves** the running configuration so changes persist across reboots.

### Key Features

- **Zero-downtime renewals** — updating an existing cert-key pair preserves all vserver bindings; no manual rebinding required.
- **Multi-method update fallback** — tries POST `?action=update` with full path, PUT with full path, then repeats with filename-only payloads, accommodating differences across NetScaler firmware versions.
- **PowerShell 5.1 & 7+ compatible** — uses `Invoke-RestMethod -SkipCertificateCheck` on PS 7+ and a `TrustAllCertsPolicy` type on PS 5.1 for self-signed management certificates.
- **TLS 1.2/1.3 enforced** — sets the security protocol before any API call.
- **Comprehensive logging** — every step, API response, and error is written to a timestamped log file with sensitive values obfuscated.

## Prerequisites

| Requirement | Details |
|---|---|
| **DigiCert TLM Agent** | Installed and configured on a Windows host with AWR post-enrollment enabled |
| **PowerShell** | 5.1 or 7+ |
| **NetScaler ADC** | Any supported Citrix ADC / NetScaler version with the Nitro REST API enabled |
| **API credentials** | A Nitro API user with permissions to upload files, manage SSL cert-key pairs, and save the configuration |
| **Network access** | HTTPS connectivity from the TLM Agent host to the NetScaler management IP |

## AWR Configuration

Configure the script in the TLM Agent AWR settings with **four arguments**:

| Argument | Description | Example |
|---|---|---|
| **Argument 1** | NetScaler hostname or IP (no `https://` prefix) | `netscaler.example.com` |
| **Argument 2** | Nitro API username | `nsroot` |
| **Argument 3** | Nitro API password | `••••••••` |
| **Argument 4** | SSL cert-key pair name on the ADC | `www.example.com-certkey` |

The script receives certificate data from the TLM Agent via the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON containing the certificate folder path, file list, and arguments).

## Legal Notice Acceptance

Before the script will execute, you must explicitly accept the legal notice by editing the configuration variable at the top of the script:

```powershell
$LEGAL_NOTICE_ACCEPT = "true"
```

The script will exit immediately if this value is not set to `"true"`.

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

## Logging

All output is written to:

```
C:\Program Files\DigiCert\TLM Agent\logs\awr-netscaler-adc.log
```

The log path is configurable via the `$LOGFILE` variable at the top of the script. Passwords are automatically obfuscated in log entries.

## Troubleshooting

| Symptom | Likely Cause |
|---|---|
| `ERROR: Legal notice not accepted` | Set `$LEGAL_NOTICE_ACCEPT = "true"` in the script |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | The script is not being invoked by the TLM Agent AWR framework |
| `Authentication failed (HTTP 401)` | Check the Nitro API username and password (Arguments 2 & 3) |
| `Connectivity test failed` | Verify HTTPS access from the agent host to the NetScaler management IP |
| `All update methods failed` | Check the cert-key pair name matches exactly; review NetScaler firmware compatibility |
| `Failed to create cert-key pair` | The cert-key pair name may conflict with an existing resource; check the ADC |

## File Structure

```
netscaler-awr.ps1          # Main AWR post-enrollment script
```

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. Use of this software is subject to the terms and conditions of your agreement with DigiCert. See the legal notice embedded in the script header for full details.