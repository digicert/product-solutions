# DigiCert TLM Agent — Imperva Cloud WAF AWR Post-Enrollment Scripts

Automated custom certificate deployment to Imperva Cloud WAF using DigiCert Trust Lifecycle Manager (TLM) Agent Admin Web Request (AWR) post-enrollment scripts.

Two scripts are provided — a **bash** version for Linux TLM Agents and a **PowerShell** version for Windows TLM Agents. Both upload a certificate chain and private key to an Imperva Cloud WAF site via the Imperva Provisioning API, enabling fully automated certificate lifecycle management for WAF-protected websites.

---

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [Template Arguments](#template-arguments)
- [Script Configuration](#script-configuration)
  - [Linux (Bash)](#linux-bash)
  - [Windows (PowerShell)](#windows-powershell)
- [Imperva API Details](#imperva-api-details)
- [Key Type Detection](#key-type-detection)
- [Logging](#logging)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

| Script | Platform | Language | TLM Agent Path | API Client |
|---|---|---|---|---|
| `imperva-awr.sh` | Linux | Bash | `/home/ubuntu/terraform/tlmagent/cdn/tlm_agent_3.1.4_linux64/` | `curl` |
| `imperva-awr.ps1` | Windows | PowerShell 5.1+ | `C:\Program Files\DigiCert\TLM Agent\` | `Invoke-RestMethod` |

Both scripts perform the same operation:

1. Decode the `DC1_POST_SCRIPT_DATA` environment variable (base64-encoded JSON) provided by the TLM Agent
2. Extract the certificate chain (`.crt`) and private key (`.key`) files
3. Base64-encode both the full PEM certificate chain and private key
4. Auto-detect the key type (`RSA` or `ECC`) for the Imperva `auth_type` parameter
5. Upload to the Imperva site via a `PUT` request to the custom certificate API endpoint

---

## Prerequisites

**Both platforms:**

- **DigiCert TLM Agent** installed and configured with an AWR certificate template
- An **Imperva Cloud WAF** account with API access enabled
- The **Site ID**, **API ID**, and **API Key** for the target Imperva site

**Linux (bash):**

- **bash**, **curl**, **base64**, **grep** with PCRE (`-P`) support
- **openssl** (used for PKCS#8 key type detection)

**Windows (PowerShell):**

- **PowerShell 5.1** or later
- **OpenSSL** (optional — used for PKCS#8 key type detection; the script falls back to text matching if unavailable)

---

## How It Works

The Imperva Cloud WAF custom certificate API accepts a JSON payload containing the certificate chain and private key as base64-encoded strings, along with an `auth_type` field indicating whether the key is RSA or ECC. The scripts automate this entire flow:

1. The TLM Agent enrolls or renews a certificate and sets the `DC1_POST_SCRIPT_DATA` environment variable
2. The script decodes the JSON payload to locate the `.crt` and `.key` files on disk
3. The full PEM content of both files (including `BEGIN`/`END` headers) is base64-encoded
4. The key type is auto-detected from the PEM header and, for PKCS#8 keys, by inspecting the certificate with `openssl`
5. A `PUT` request is sent to `https://my.imperva.com/api/prov/v2/sites/{siteId}/customCertificate` with the JSON payload
6. The API response is logged and checked for success (HTTP 200/201)

---

## Quick Start

1. Copy the appropriate script to the TLM Agent's user-scripts directory
2. Edit the configuration section:

   **Linux:**
   ```bash
   LEGAL_NOTICE_ACCEPT="true"
   ```

   **Windows:**
   ```powershell
   $LEGAL_NOTICE_ACCEPT = "true"
   ```

3. Configure the TLM certificate template with the script as the AWR post-enrollment script and set the three required arguments (see below)
4. Enroll or renew a certificate — the script runs automatically and uploads to Imperva

---

## Template Arguments

Configure these in the TLM certificate template AWR arguments. Both scripts use the same argument positions:

| Argument | Description | Example |
|---|---|---|
| Argument 1 | Imperva Site ID | `123456789` |
| Argument 2 | API ID (from Imperva account settings) | `12345` |
| Argument 3 | API Key (from Imperva account settings) | `abcdef01-2345-6789-...` |

### Obtaining Imperva API Credentials

1. Log in to the Imperva Cloud Security Console at `https://my.imperva.com`
2. Navigate to **Account → Account Settings → API Keys**
3. Create a new API key or use an existing one — note the **API ID** and **API Key**
4. Find the **Site ID** under **Websites → your site → Settings → General**, or from the URL in the management console

---

## Script Configuration

### Linux (Bash)

Edit the variables at the top of `imperva-awr.sh`:

```bash
LEGAL_NOTICE_ACCEPT="true"    # Required — must be "true" to run
LOGFILE="/home/ubuntu/terraform/tlmagent/cdn/tlm_agent_3.1.4_linux64/log/imperva.log"
API_CALL_LOGFILE="/home/ubuntu/terraform/tlmagent/cdn/tlm_agent_3.1.4_linux64/log/imperva-api-call.log"
```

The bash script uses `curl` for the API call and `base64 -w 0` for encoding (with a fallback for macOS where the `-w` flag is not supported).

### Windows (PowerShell)

Edit the variables at the top of `imperva-awr.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT = "true"    # Required — must be "true" to run
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva.log"
$API_CALL_LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva-api-call.log"
```

The PowerShell script uses `Invoke-RestMethod` for the API call and `[System.Convert]::ToBase64String()` for encoding. It includes PowerShell 5.1 compatibility handling for HTTP error response extraction.

---

## Imperva API Details

| Field | Value |
|---|---|
| Endpoint | `https://my.imperva.com/api/prov/v2/sites/{siteId}/customCertificate` |
| Method | `PUT` |
| Authentication | `x-API-Id` and `x-API-Key` headers |
| Content-Type | `application/json` |

### Request Payload

```json
{
  "certificate": "<base64-encoded full PEM certificate chain>",
  "private_key": "<base64-encoded full PEM private key>",
  "auth_type": "RSA"
}
```

The `certificate` field should contain the entire PEM file including all certificates in the chain (leaf, intermediate, and optionally root), base64-encoded as a single string. The `private_key` field is the full PEM private key file, also base64-encoded. The `auth_type` field is either `"RSA"` or `"ECC"`.

---

## Key Type Detection

Both scripts auto-detect the key type to set the `auth_type` parameter correctly:

| PEM Header | Detected Type |
|---|---|
| `BEGIN RSA PRIVATE KEY` | `RSA` |
| `BEGIN EC PRIVATE KEY` | `ECC` |
| `BEGIN PRIVATE KEY` (PKCS#8) | Inspects the certificate with `openssl` to determine RSA or ECC |

If the key type cannot be determined, both scripts default to `RSA`.

**PKCS#8 detection differences:**

The bash script uses `openssl x509 -noout -text` to check for `rsaEncryption` or `id-ecPublicKey` in the certificate output. The PowerShell script does the same, but first searches for `openssl.exe` in several common Windows locations (`C:\Program Files\OpenSSL-Win64\bin\`, `C:\Program Files\OpenSSL\bin\`, `C:\OpenSSL\bin\`, and the system `PATH`). If OpenSSL is not found on Windows, it falls back to basic text pattern matching within the PEM certificate content.

---

## Logging

Both scripts write to two separate log files:

| Log File | Purpose |
|---|---|
| Main log (`imperva.log`) | Full script execution trace — argument extraction, file validation, encoding, API response |
| API call log (`imperva-api-call.log`) | Detailed API request information — endpoint, headers, and a truncated payload preview |

Sensitive values (API keys, private key content) are truncated in logs — only the first few characters are shown.

### Viewing Logs

**Linux:**
```bash
tail -f /home/ubuntu/terraform/tlmagent/cdn/tlm_agent_3.1.4_linux64/log/imperva.log
tail -f /home/ubuntu/terraform/tlmagent/cdn/tlm_agent_3.1.4_linux64/log/imperva-api-call.log
```

**Windows:**
```powershell
Get-Content "C:\Program Files\DigiCert\TLM Agent\log\imperva.log" -Tail 50 -Wait
Get-Content "C:\Program Files\DigiCert\TLM Agent\log\imperva-api-call.log" -Tail 50 -Wait
```

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set the acceptance flag to `"true"` in the script |
| `DC1_POST_SCRIPT_DATA` not set | Script not being executed by the TLM Agent | Verify the script is configured as an AWR post-enrollment script in the certificate template |
| HTTP 401 | Invalid API ID or API Key | Regenerate credentials in the Imperva console under Account → API Keys |
| HTTP 403 | API key lacks permissions for the target site | Verify the API key has access to the site identified by the Site ID |
| HTTP 404 | Invalid Site ID | Check the Site ID in the Imperva console |
| Certificate-related error in response | Chain order incorrect or incomplete | Ensure the `.crt` file contains the full chain in order: leaf → intermediate → root |
| Private key error in response | Key doesn't match the certificate | Verify the private key corresponds to the certificate's public key |
| `auth_type` error in response | Key type detection produced the wrong value | Manually inspect the key type and, if needed, adjust the detection logic or hard-code `AUTH_TYPE` |
| Base64 verification warning | PEM file may have unexpected encoding or BOM | Ensure certificate and key files are plain UTF-8 PEM without byte-order marks |
| OpenSSL not found (PowerShell only) | PKCS#8 key but no OpenSSL on Windows | Install OpenSSL for Windows, or the script will fall back to text matching (usually sufficient) |

---

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. These scripts are provided under the terms of the DigiCert software license. See the legal notice within each script for full details.