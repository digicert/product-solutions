# Kemp LoadMaster — DigiCert TLM Agent AWR Post-Enrollment Scripts

Automated certificate deployment to [Kemp LoadMaster](https://kemptechnologies.com/loadmaster) load balancers using [DigiCert Trust Lifecycle Manager (TLM)](https://www.digicert.com/trust-lifecycle-manager) Agent post-enrollment hooks (AWR).

Available in **Bash** (Linux) and **PowerShell** (Windows). Both scripts follow the same four-step flow, but they are not byte-for-byte equivalent — the differences that matter are called out in [Behavioural Differences](#behavioural-differences-between-the-two-scripts).

---

## Overview

These scripts run automatically after the DigiCert TLM Agent enrolls or renews a certificate. They perform four steps:

1. **Locate and combine** the issued PEM certificate and private key into a single PEM bundle named `<CertName>.pem` in the agent's certificate folder. Files are found by extension (`.crt`, `.cer`, `.pem` for the certificate, `.key` for the key) and confirmed by PEM content, with a content scan of all delivered files as a fallback. See [Certificate File Matching](#certificate-file-matching).
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

Both scripts receive their configuration via the TLM Agent `DC1_POST_SCRIPT_DATA` environment variable, which contains a Base64-encoded JSON payload. The `args` array within this payload is read in order as Argument 1 through Argument 5. These are the values you enter in the AWR configuration in TLM.

```
ARGUMENT_1  Base URL including scheme, credentials, host and port of
            the LoadMaster REST API endpoint.                          (Required)
            Example:
            https://<api_user>:<api_password>@<loadmaster_host>:8444

ARGUMENT_2  Virtual Service IP address to update.                      (Required)
            Example: 172.31.7.5

ARGUMENT_3  Virtual Service port to update.                            (Required)
            Example: 443

ARGUMENT_4  Certificate name (identifier) on the LoadMaster.           (Required)
            This is how the certificate will appear in the LM UI/API.
            Example: my-certificate

ARGUMENT_5  Reserved for future use. Parsed and logged, but not used.  (Optional)
```

The scripts also read `certfolder` and `files` from the JSON payload to locate the certificate and key files written by the agent.

### Certificate file matching

The TLM delivery format determines what lands on disk, and not every format produces `.crt` and `.key` files. Both scripts therefore locate the files in three passes and log every file name they see:

1. **By extension, confirmed by content.** Private key: the first `*.key` containing a `PRIVATE KEY` block. Certificate: the first `*.crt`, then `*.cer`, then `*.pem` containing a `BEGIN CERTIFICATE` block, skipping chain files (names containing `_ica.`, `chain`, `intermediate`, or `ca.`) and the key file.
2. **By content only.** If nothing matched by extension, every delivered file is scanned for the PEM markers. A single combined `.pem` holding both cert and key is accepted and used once.
3. **Folder listing.** Files present in `certfolder` but missing from the payload's `files` array are included as candidates.

If either file is still not found, the script logs the file names it saw and exits `1` with a pointer to the delivery format. PKCS#7 (`.p7b`) and PKCS#12 (`.pfx`, `.p12`) containers are detected and named in the message but are **not** converted. A file with the right extension that is empty or not PEM-encoded is ignored.

**Required TLM delivery format:** PEM with a separate certificate and private key file, and private key export enabled.

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
4. Enter Arguments 1 to 4 with your LoadMaster details as described in [Arguments](#arguments). Argument 5 can be left empty.
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
- File names listed in the payload's `files` array and present in the certificate folder
- Which certificate and key file were selected, and whether they were found by extension or by content
- Certificate and key file metadata (path, size, certificate count, key type)
- API request URLs (with obfuscated credentials)
- HTTP status codes for `listcert`, `addcert`, and `modvs`
- **API response bodies:** Bash logs the full `addcert` response body. PowerShell logs the full `addcert` and `modvs` response bodies, the first 200 characters of the `listcert` response, and the response body of any `WebException`.

What is **not** logged: the raw decoded JSON payload, the private key content, and (in Bash) the `listcert` response body.

## Error Handling

Both scripts exit `1` on:

- Legal notice not accepted
- Missing `DC1_POST_SCRIPT_DATA` environment variable
- Missing required arguments (base URL, VS IP, VS port, cert name)
- No PEM certificate or no PEM private key found among the delivered files (see [Certificate File Matching](#certificate-file-matching))
- Certificate or key file missing on disk at PEM creation time
- `addcert` returning any HTTP status other than `200` or `201`

Additional PowerShell-only exit conditions:

- Base64 decode failure or JSON parse failure (Bash does not validate these; a malformed payload surfaces as an empty Argument 1)
- Failure to write the combined PEM file, or a certificate/key file that is empty or not PEM-encoded
- HTTP `422` on `addcert` logs troubleshooting guidance (PEM format, cert/key mismatch, incomplete chain) before exiting
- Any unexpected exception in the deployment section

> **Important:** a failed `modvs` (any status other than `200`/`201`) is logged as a **WARNING** in both scripts and the script still exits `0`. Check the log or the LoadMaster UI to confirm the certificate was actually assigned to the Virtual Service.

## Behavioural Differences Between the Two Scripts

| Behaviour | Bash | PowerShell |
|---|---|---|
| Temporary PEM cleanup | **Not removed.** The `trap 'rm -f ...' EXIT` line is commented out, so `<CertName>.pem` (cert + private key, `chmod 600`) remains in the certificate folder after the run. | Removed in a `finally` block after upload. |
| JSON parsing | `grep -P` / `awk` text extraction; args split on `,` | `ConvertFrom-Json` |
| Certificate / key file matching | Identical three-pass logic (extension + content, content scan, folder listing) | Identical |
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
| `ERROR: Could not locate the PEM certificate and/or private key among the delivered files.` | The delivery format did not produce a PEM certificate and a PEM private key. The log lines `Files listed in payload` and `Files available` show what was delivered (for example `.p7b` only, or `.cer` files with no key). | Change the TLM delivery format to PEM with separate certificate and private key files and enable private key export. If a `.p7b`, `.pfx` or `.p12` is named in the message, the format is a container the script does not convert. |
| `Failed to create combined PEM: ... [System.Object[]] does not contain a method named 'EndsWith'` (PowerShell) | Older script version. Empty `CRT_FILE` / `KEY_FILE` collapsed to the folder path and the read returned nothing. | Update to the current script, which reports the previous row's message instead. Root cause is the same: delivery format. |
| `ERROR: Missing certificate or key file.` | A file that was found during matching disappeared before PEM creation | Check whether another process cleans the certificate folder between delivery and the post-script |
| `addcert HTTP status: 422` | Certificate format issue | Verify the cert and key are valid PEM, the key matches the cert, and the chain is complete |
| `addcert HTTP status: 401` | Bad API credentials or API access not enabled | Check the user/password in Argument 1 and the LoadMaster API Access setting |
| `WARNING: modvs returned non-success status` (Bash) / `WARNING: modvs returned status <code>` (PowerShell) | VS IP/port mismatch or cert name not found | Confirm the Virtual Service exists with `prot=tcp` and the cert name matches what was uploaded. The script still exits `0`. |
| No log file written (Bash) | Log directory does not exist | Create the directory in `LOGFILE` or point it at the agent's existing log folder |
| `grep: invalid option -- 'P'` or `stat: illegal option` (Bash) | Non-GNU userland (e.g. macOS) | Run on a Linux host with GNU coreutils and grep |
| Connection timeout | Network or firewall blocking access | Verify the agent host can reach the LoadMaster API port |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice header in each script file for full terms.
