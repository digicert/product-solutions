# Kemp LoadMaster — DigiCert TLM Agent AWR Post-Enrollment Scripts

Automated certificate deployment to [Kemp LoadMaster](https://kemptechnologies.com/loadmaster) load balancers using [DigiCert Trust Lifecycle Manager (TLM)](https://www.digicert.com/trust-lifecycle-manager) Agent post-enrollment hooks (AWR).

Available in **Bash** (Linux) and **PowerShell** (Windows) — both scripts are functionally equivalent.

---

## Overview

These scripts run automatically after the DigiCert TLM Agent enrolls or renews a certificate. They perform four steps:

1. **Combine** the issued certificate and private key into a single PEM bundle.
2. **Check** whether a certificate with the configured name already exists on the LoadMaster (`listcert`).
3. **Upload** the PEM to the LoadMaster via `addcert`, replacing the existing certificate if present.
4. **Assign** the certificate to a target Virtual Service via `modvs`.

The result is fully automated, zero-touch certificate lifecycle management for TLS-terminated Virtual Services on Kemp LoadMaster appliances.

## Prerequisites

| Requirement | Details |
|---|---|
| **DigiCert TLM Agent** | Installed and configured with certificate enrollment. The agent provides the `DC1_POST_SCRIPT_DATA` environment variable consumed by these scripts. |
| **Kemp LoadMaster** | REST API enabled. Navigate to *System Configuration → Certificates & Security → API Access* in the LoadMaster UI. |
| **API Credentials** | A user account with API access on the LoadMaster. Credentials are passed inline in the base URL (see [Arguments](#arguments)). |
| **Network Access** | The host running the TLM Agent must be able to reach the LoadMaster API port (commonly `8444/tcp`). |

### Bash-specific

- `curl` (with TLS support)
- `base64`, `grep`, `sed`, `awk` (standard on most Linux distributions)
- Optional: `xmllint` for robust XML parsing of `listcert` responses (falls back to `grep` if unavailable)

### PowerShell-specific

- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (cross-platform)
- No external modules required — uses `System.Net.HttpWebRequest` directly for maximum compatibility

## Files

| File | Platform | Description |
|---|---|---|
| `kemp_loadmaster_awr.sh` | Linux / macOS | Bash implementation using `curl` for API calls |
| `kemp_loadmaster_awr.ps1` | Windows | PowerShell implementation using `HttpWebRequest` |

## Arguments

Both scripts receive their configuration via the TLM Agent `DC1_POST_SCRIPT_DATA` environment variable, which contains a Base64-encoded JSON payload. The `args` array within this payload maps to the following arguments:

| Argument | Name | Required | Description | Example |
|---|---|---|---|---|
| `args[0]` | Base URL | Yes | LoadMaster API endpoint including scheme, credentials, host, and port | `https://user:pass@loadmaster.example.com:8444` |
| `args[1]` | VS IP | Yes | Virtual Service IP address to update | `172.31.7.5` |
| `args[2]` | VS Port | Yes | Virtual Service port to update | `443` |
| `args[3]` | Cert Name | Yes | Certificate identifier on the LoadMaster (how it appears in the LM UI) | `my-certificate` |
| `args[4]` | *(Reserved)* | No | Reserved for future use | — |

> **Note:** Credentials in the base URL are automatically obfuscated in all log output.

## Configuration

Before using, edit the following variables at the top of each script:

### Bash

```bash
LEGAL_NOTICE_ACCEPT="true"   # Must be set to "true" to run
LOGFILE="/path/to/kemp.log"  # Log file location
```

### PowerShell

```powershell
$LEGAL_NOTICE_ACCEPT = "true"                                        # Must be set to "true" to run
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\kemp_data.log"   # Log file location
```

## TLM Agent AWR Setup

1. In DigiCert ONE, navigate to **Trust Lifecycle Manager → Automation → Admin Web Request (AWR)**.
2. Create or edit a post-enrollment script entry.
3. Upload the appropriate script (`kemp_loadmaster_awr.sh` for Linux agents, `kemp_loadmaster_awr.ps1` for Windows agents).
4. Configure the arguments array with your LoadMaster details:

```
Argument 1: https://<api_user>:<api_password>@<loadmaster_host>:<api_port>
Argument 2: <virtual_service_ip>
Argument 3: <virtual_service_port>
Argument 4: <certificate_name>
```

5. Save and trigger a certificate enrollment or renewal to test.

## API Flow

The scripts interact with the Kemp LoadMaster REST API as follows:

```
┌─────────────────┐         ┌──────────────────┐
│  TLM Agent      │         │  Kemp LoadMaster  │
│  (AWR Script)   │         │  REST API         │
└────────┬────────┘         └────────┬─────────┘
         │                           │
         │  GET /access/listcert     │
         │──────────────────────────►│  Check if cert exists
         │◄──────────────────────────│  XML response
         │                           │
         │  POST /access/addcert     │
         │   ?cert=<name>            │
         │   [&replace=1]            │
         │   Body: PEM bundle        │
         │──────────────────────────►│  Upload certificate
         │◄──────────────────────────│  Success/Error
         │                           │
         │  GET /access/modvs        │
         │   ?vs=<ip>&port=<port>    │
         │   &prot=tcp               │
         │   &CertFile=<name>        │
         │──────────────────────────►│  Assign cert to VS
         │◄──────────────────────────│  Success/Error
         │                           │
```

## Logging

Both scripts produce timestamped logs with detailed status information:

- Environment variable validation
- JSON payload extraction and argument parsing
- Certificate and key file metadata (size, type, chain length)
- API request URLs (with obfuscated credentials)
- HTTP status codes and response summaries
- Success/failure status for each deployment step

Sensitive information (passwords, private keys) is never written to the log.

## Error Handling

The scripts validate and exit with a non-zero code on:

- Legal notice not accepted
- Missing `DC1_POST_SCRIPT_DATA` environment variable
- JSON decode/parse failure
- Missing required arguments (base URL, VS IP, VS port, cert name)
- Certificate or key files not found
- PEM creation failure
- API upload failure (non-2xx response)

The PowerShell version includes additional handling for HTTP 422 responses (invalid certificate format) with troubleshooting guidance.

## Security Considerations

- **Credential obfuscation** — All log entries mask usernames and passwords embedded in URLs, showing only the first three characters.
- **PEM cleanup** — The combined PEM file (cert + key) is created as a temporary artifact with restricted permissions (`chmod 600` on Linux, ACL-restricted on Windows) and is cleaned up after upload.
- **TLS verification** — The LoadMaster API is accessed with TLS certificate verification disabled (`curl -k` / `SkipCertValidation`) to support self-signed management certificates. Adjust if your LoadMaster has a trusted certificate.
- **No secrets in logs** — Raw JSON payloads and private key content are never logged.

## Troubleshooting

| Symptom | Possible Cause | Resolution |
|---|---|---|
| `ERROR: Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` not set to `"true"` | Edit the variable at the top of the script |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script not running as an AWR post-enrollment hook | Ensure the script is configured in TLM as a post-enrollment script |
| HTTP 422 on `addcert` | Certificate format issue | Verify the cert and key are valid PEM, the key matches the cert, and the chain is complete |
| `modvs returned non-success status` | VS IP/port mismatch or cert name not found | Confirm the Virtual Service exists and the cert name matches what was uploaded |
| Connection timeout | Network or firewall blocking access | Verify the agent host can reach the LoadMaster API port |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice header in each script file for full terms.