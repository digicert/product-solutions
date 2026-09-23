# Kemp LoadMaster — DigiCert TLM Agent AWR Post-Enrollment Scripts

Automated certificate deployment to [Kemp LoadMaster](https://kemptechnologies.com/loadmaster) load balancers using [DigiCert Trust Lifecycle Manager (TLM)](https://www.digicert.com/trust-lifecycle-manager) Agent post-enrollment hooks (AWR).

Available in **Bash** (Linux) and **PowerShell** (Windows). Both scripts follow the same four-step flow, but they are not byte-for-byte equivalent — the differences that matter are called out in [Behavioural Differences](#behavioural-differences-between-the-two-scripts).

---

## Overview

These scripts run automatically after the DigiCert TLM Agent enrolls or renews a certificate. They perform four steps:

1. **Combine** the issued certificate (`.crt`) and private key (`.key`) into a single PEM bundle named `<CertName>.pem` in the agent's certificate folder.
2. **Check** whether a certificate with the configured name already exists on the LoadMaster (`GET /access/listcert`).
3. **Upload** the PEM to the LoadMaster via `POST /access/addcert`, adding `&replace=1` if the certificate already exists.
4. **Assign** the certificate to a target Virtual Service via `GET /access/modvs`.

The result is automated certificate lifecycle management for TLS-terminated Virtual Services on Kemp LoadMaster appliances.

## Prerequisites

| Requirement | Details |
|---|---|
| **DigiCert TLM Agent** | Installed and configured with certificate enrollment. The agent provides the `DC1_POST_SCRIPT_DATA` environment variable consumed by these scripts. |
| **Kemp LoadMaster** | REST API enabled. Navigate to *System Configuration → Certificates & Security → API Access* in the LoadMaster UI. |
| **API Credentials** | A user account with API access on the LoadMaster. Credentials are supplied inside the base URL argument (see [Arguments](#arguments)). Both scripts strip them from the URL and send them as HTTP Basic authentication. |
| **Network Access** | The host running the TLM Agent must be able to reach the LoadMaster API port (commonly `8444/tcp`). |

### Bash-specific

- `bash`, `curl` (with TLS support)
- GNU userland: `grep` with PCRE support (`grep -P`), GNU `stat` (`stat -c%s`), `sed`, `awk`, `cut`, `tr`, `base64`, `date`
- Optional: `xmllint` for XPath-based parsing of the `listcert` response (falls back to `grep` if unavailable)

> The script relies on GNU `grep -P` and GNU `stat -c`. It will not run unmodified on macOS or other BSD userlands.

### PowerShell-specific

- Windows PowerShell 5.1 (primary target). PowerShell 7 on Windows should also work; the script uses `System.Net.HttpWebRequest` and `ServicePointManager` rather than `Invoke-RestMethod`.
- No external modules required.
- Windows ACLs are used to restrict the temporary PEM file; on non-Windows hosts the script attempts `chmod 600` instead.

## Files

| File | Platform | Description |
|---|---|---|
| `Linux/kemp_loadmaster_awr.sh` | Linux (GNU userland) | Bash implementation using `curl` for API calls |
| `Windows/kemp_loadmaster_awr.ps1` | Windows | PowerShell implementation using `HttpWebRequest` |

### File encoding

- `kemp_loadmaster_awr.ps1` is saved as **UTF-8 with BOM** and LF line endings. The BOM is intentional: the legal notice header contains non-ASCII characters (`©`, `—`), and Windows PowerShell 5.1 reads BOM-less `.ps1` files using the system ANSI code page. Keep the BOM when editing the file.
- `kemp_loadmaster_awr.sh` is saved as **UTF-8 without BOM** and LF line endings. Do not add a BOM — it would break the `#!/bin/bash` shebang.

## Arguments

Both scripts receive their configuration via the TLM Agent `DC1_POST_SCRIPT_DATA` environment variable, which contains a Base64-encoded JSON payload. The `args` array within this payload maps to the following arguments:

| Argument | Name | Required | Description | Example |
|---|---|---|---|---|
| `args[0]` | Base URL | Yes | LoadMaster API endpoint including scheme, credentials, host, and port | `https://user:pass@loadmaster.example.com:8444` |
| `args[1]` | VS IP | Yes | Virtual Service IP address to update | `172.31.7.5` |
| `args[2]` | VS Port | Yes | Virtual Service port to update | `443` |
| `args[3]` | Cert Name | Yes | Certificate identifier on the LoadMaster (how it appears in the LM UI) | `my-certificate` |
| `args[4]` | *(Reserved)* | No | Parsed and logged, but not used | — |

The scripts also read `certfolder` and `files` from the JSON payload to locate the `.crt` and `.key` files written by the agent.

> **Note:** Credentials in the base URL are obfuscated in all log output (first three characters of the username and password are shown, the rest is replaced with `***`).

### Argument constraints

- **All whitespace is stripped** from every argument by both scripts. Do not use values that contain spaces.
- **Bash:** the `args` array is split on commas. No argument (including the password) may contain a `,` character. The password may not contain `@`.
- **PowerShell:** arguments are parsed with `ConvertFrom-Json`, so commas are safe. The credential part of the URL is matched with `[^@/]+`, so the password may not contain `@` or `/`. Username and password are percent-decoded, so `%40` can be used to represent `@` — this decoding is **not** done by the Bash script.
- **Cert name:** PowerShell URL-encodes the certificate name in the `addcert` and `modvs` query strings. Bash passes it through verbatim, so keep the name to URL-safe characters (letters, digits, `-`, `_`, `.`).

## Configuration

Both scripts ship with the legal notice **not accepted**. You must edit the variables at the top of the script before use.

### Bash

```bash
LEGAL_NOTICE_ACCEPT="false"                                     # Change to "true" to run
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/kemp.log"     # Change to your agent's log directory
```

The Bash script does **not** create the log directory. If the directory in `LOGFILE` does not exist, no log is written but the script still runs.

### PowerShell

```powershell
$LEGAL_NOTICE_ACCEPT = "false"                                       # Change to "true" to run
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\kemp_data.log"   # Log file location
```

The PowerShell script creates the log directory if it does not exist.

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

The scripts interact with the Kemp LoadMaster REST API as follows. Credentials are removed from the URL and sent as HTTP Basic auth (`curl -u` in Bash, `NetworkCredential` with `PreAuthenticate` in PowerShell).

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
         │   Content-Type:           │
         │   x-x509-ca-cert          │
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

- **Bash** calls `curl -k --location`, so redirects are followed and TLS verification is disabled.
- **PowerShell** disables TLS verification via `ServerCertificateValidationCallback`, forces TLS 1.2, and uses a 30-second request timeout.

## Logging

Both scripts produce timestamped logs. What is logged:

- Environment variable presence and length
- Extracted arguments (base URL obfuscated; other arguments in clear)
- Certificate and key file metadata (path, size, certificate count in the `.crt`, key type)
- API request URLs (with obfuscated credentials)
- HTTP status codes for `listcert`, `addcert`, and `modvs`
- **API response bodies:** Bash logs the full `addcert` response body. PowerShell logs the full `addcert` and `modvs` response bodies, the first 200 characters of the `listcert` response, and the response body of any `WebException`.

What is **not** logged: the raw decoded JSON payload, the private key content, and (in Bash) the `listcert` response body.

## Error Handling

Both scripts exit `1` on:

- Legal notice not accepted
- Missing `DC1_POST_SCRIPT_DATA` environment variable
- Missing required arguments (base URL, VS IP, VS port, cert name)
- Certificate or key file not found in the certificate folder
- `addcert` returning any HTTP status other than `200` or `201`

Additional PowerShell-only exit conditions:

- Base64 decode failure or JSON parse failure (Bash does not validate these; a malformed payload surfaces as an empty Argument 1)
- Failure to write the combined PEM file
- HTTP `422` on `addcert` logs troubleshooting guidance (PEM format, cert/key mismatch, incomplete chain) before exiting
- Any unexpected exception in the deployment section

> **Important:** a failed `modvs` (any status other than `200`/`201`) is logged as a **WARNING** in both scripts and the script still exits `0`. Check the log or the LoadMaster UI to confirm the certificate was actually assigned to the Virtual Service.

## Behavioural Differences Between the Two Scripts

| Behaviour | Bash | PowerShell |
|---|---|---|
| Temporary PEM cleanup | **Not removed.** The `trap 'rm -f ...' EXIT` line is commented out, so `<CertName>.pem` (cert + private key, `chmod 600`) remains in the certificate folder after the run. | Removed in a `finally` block after upload. |
| JSON parsing | `grep -P` / `awk` text extraction; args split on `,` | `ConvertFrom-Json` |
| Base64 / JSON validation | None | Exits `1` on failure |
| `listcert` parsing | `xmllint` XPath, fallback to `grep` | `[xml]` cast with `//name` XPath, fallback to regex |
| Cert name URL-encoding | None | `[uri]::EscapeDataString` |
| Credential percent-decoding | None | Yes |
| HTTP 422 guidance | No | Yes |
| Log directory creation | No | Yes |
| Follows redirects | Yes (`--location`) | No |

## Security Considerations

- **Credential obfuscation** — Log entries mask usernames and passwords embedded in URLs, showing only the first three characters of each.
- **PEM file permissions** — The combined PEM (cert + key) is written to the agent's certificate folder with `chmod 600` (Bash) or an owner-only ACL (PowerShell).
- **PEM cleanup** — PowerShell deletes the PEM after upload. **Bash does not** (see table above). If this matters in your environment, uncomment the `trap 'rm -f "$COMBINED_PEM_PATH"' EXIT` line in the Bash script.
- **TLS verification** — The LoadMaster API is accessed with TLS certificate verification disabled (`curl -k` / `SkipCertValidation`) to support self-signed management certificates. Adjust if your LoadMaster has a trusted certificate.
- **Response bodies in logs** — `addcert` / `modvs` response bodies are logged in full. These normally contain only a status message, but review the log file permissions accordingly.

## Troubleshooting

| Symptom | Possible Cause | Resolution |
|---|---|---|
| `ERROR: Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` still `"false"` | Edit the variable at the top of the script |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script not running as an AWR post-enrollment hook | Ensure the script is configured in TLM as a post-enrollment script |
| `ERROR: Argument 1 (Base URL with credentials) is not provided` (Bash) with arguments configured | Base64/JSON extraction failed, or a comma in an argument shifted the fields | Check the payload; remove commas from all argument values |
| `ERROR: Missing certificate or key file.` | `certfolder` / `files` in the payload do not match files on disk | Confirm the agent wrote `.crt` and `.key` files to the logged paths |
| `Extracted CRT_FILE:` / `Extracted KEY_FILE:` are empty, then `Failed to create combined PEM: ... [System.Object[]] does not contain a method named 'EndsWith'` (PowerShell) | The `files` array in the payload contains no `*.crt` / `*.key` entries. The delivery format wrote other extensions (for example `_.domain.com.cer`, `.p7b`, `_ica.cer`), so the file paths collapse to the bare folder. | Check the certificate folder for the actual file names. The delivery location must produce a PEM `.crt` and a PEM `.key`; the script does not match `.cer` or `.p7b`. |
| `addcert HTTP status: 422` | Certificate format issue | Verify the cert and key are valid PEM, the key matches the cert, and the chain is complete |
| `addcert HTTP status: 401` | Bad API credentials or API access not enabled | Check the user/password in Argument 1 and the LoadMaster API Access setting |
| `WARNING: modvs returned non-success status` (Bash) / `WARNING: modvs returned status <code>` (PowerShell) | VS IP/port mismatch or cert name not found | Confirm the Virtual Service exists with `prot=tcp` and the cert name matches what was uploaded. The script still exits `0`. |
| No log file written (Bash) | Log directory does not exist | Create the directory in `LOGFILE` or point it at the agent's existing log folder |
| `grep: invalid option -- 'P'` or `stat: illegal option` (Bash) | Non-GNU userland (e.g. macOS) | Run on a Linux host with GNU coreutils and grep |
| Connection timeout | Network or firewall blocking access | Verify the agent host can reach the LoadMaster API port |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice header in each script file for full terms.
