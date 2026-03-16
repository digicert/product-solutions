# DigiCert TLM Agent — AWR Post-Enrollment Script Templates

A set of starter templates for building **Admin Web Request (AWR) post-enrollment scripts** with the DigiCert Trust Lifecycle Manager (TLM) Agent. Templates are provided in both **Bash** (Linux/macOS) and **PowerShell** (Windows) and cover two certificate output formats: **CRT/KEY** (separate PEM files) and **PFX/P12** (PKCS#12 bundle).

---

## Overview

When TLM Agent issues or renews a certificate, it can invoke a post-enrollment script automatically via the AWR mechanism. The agent passes certificate data to the script through the `DC1_POST_SCRIPT_DATA` environment variable — a Base64-encoded JSON payload containing file paths, arguments, and metadata.

These templates handle all the boilerplate: decoding the payload, extracting file paths and custom arguments, validating file existence, and logging every step. Your automation logic goes into a clearly marked custom section at the bottom of each script.

---

## Repository Contents

| File | Platform | Format | Use Case |
|---|---|---|---|
| `awr-template-crt.sh` | Linux / macOS | CRT + KEY | Nginx, Apache, HAProxy, Linux services |
| `awr-template-pfx.sh` | Linux / macOS | PFX / P12 | Java keystores, mixed environments |
| `awr-template-crt.ps1` | Windows | CRT + KEY | OpenSSL-based Windows toolchains |
| `awr-template-pfx.ps1` | Windows | PFX / P12 | IIS, Windows cert store, .NET services |

---

## Prerequisites

### Bash templates
- Bash 4.0+
- `grep` with Perl-compatible regex (`-oP`) — standard on most Linux distributions
- `openssl` — required only for PFX inspection; not needed for basic operation
- `base64` — standard on all target platforms

### PowerShell templates
- PowerShell 5.1+ (Windows PowerShell) or PowerShell 7+ (cross-platform)
- No external modules required for core operation
- `WebAdministration` module — only needed for the IIS example snippets
- OpenSSL for Windows — only needed for the PFX-to-CRT extraction examples

---

## How It Works

### The `DC1_POST_SCRIPT_DATA` Payload

The TLM Agent base64-encodes a JSON object and passes it to the script via the `DC1_POST_SCRIPT_DATA` environment variable. A decoded example looks like this:

```json
{
  "certfolder": "/opt/digicert/certs/my-service",
  "files": [
    "my-service.crt",
    "my-service.key"
  ],
  "args": [
    "nginx",
    "admin@example.com",
    "",
    "",
    ""
  ]
}
```

For PFX output, the `files` array contains a single `.pfx` or `.p12` filename, and a `password` field (or similar) holds the bundle password.

### Argument Mapping

Up to five custom arguments can be configured in the AWR profile in the TLM console. These are passed in the `args` array and extracted as `ARGUMENT_1` through `ARGUMENT_5` (Bash) or `$ARGUMENT_1` through `$ARGUMENT_5` (PowerShell). Use them to pass target hostnames, service names, notification email addresses, or any other deployment-specific values.

### Execution Flow

```
TLM Agent issues/renews certificate
    │
    ▼
Script invoked with DC1_POST_SCRIPT_DATA set
    │
    ▼
Legal notice check (LEGAL_NOTICE_ACCEPT must be "true")
    │
    ▼
Base64 decode → JSON parse
    │
    ▼
Extract: certfolder, filenames, arguments
    │
    ▼
Validate files exist, inspect cert metadata (key type, chain depth, etc.)
    │
    ▼
── CUSTOM SECTION ──────────────────────────────
│  Your deployment logic lives here             │
│  All variables are ready to use               │
────────────────────────────────────────────────
    │
    ▼
Log completion and exit 0
```

---

## Quick Start

### 1. Accept the Legal Notice

Before the script will run, set `LEGAL_NOTICE_ACCEPT` to `"true"` at the top of the file:

**Bash:**
```bash
LEGAL_NOTICE_ACCEPT="true"
```

**PowerShell:**
```powershell
$LEGAL_NOTICE_ACCEPT = "true"
```

### 2. Set the Log File Path

Update the `LOGFILE` path to a location writable by the TLM Agent process:

**Bash (CRT template default):**
```bash
LOGFILE="/home/ubuntu/tls-guru.log"
```

**Bash (PFX template default):**
```bash
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/template.log"
```

**PowerShell (both templates default):**
```powershell
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\dc1_data.log"
```

Adjust these to match your TLM Agent installation path and permissions.

### 3. Add Your Custom Logic

Locate the clearly marked custom section near the bottom of the script:

```bash
# ADD CUSTOM LOGIC HERE:
# ----------------------------------------




# ----------------------------------------
# END CUSTOM LOGIC
```

All extracted variables are available at this point. See the [Available Variables](#available-variables) section below for a full reference.

---

## Available Variables

All of the following are populated before the custom section is reached.

### CRT/KEY templates

| Variable | Description |
|---|---|
| `CERT_FOLDER` / `$CERT_FOLDER` | Directory where the agent wrote certificate files |
| `CRT_FILE` / `$CRT_FILE` | Certificate filename (e.g. `my-service.crt`) |
| `KEY_FILE` / `$KEY_FILE` | Private key filename (e.g. `my-service.key`) |
| `CRT_FILE_PATH` / `$CRT_FILE_PATH` | Full path to the certificate file |
| `KEY_FILE_PATH` / `$KEY_FILE_PATH` | Full path to the private key file |
| `CERT_COUNT` / `$CERT_COUNT` | Number of certificates found in the CRT file |
| `KEY_TYPE` / `$KEY_TYPE` | Key algorithm: `RSA`, `ECC`, or `PKCS#8 format` |
| `FILES_ARRAY` / `$FILES_ARRAY` | Raw list of all files in the JSON payload |

### PFX/P12 templates

| Variable | Description |
|---|---|
| `CERT_FOLDER` / `$CERT_FOLDER` | Directory where the agent wrote certificate files |
| `PFX_FILE` / `$PFX_FILE` | PFX filename (e.g. `my-service.pfx`) |
| `PFX_FILE_PATH` / `$PFX_FILE_PATH` | Full path to the PFX file |
| `PFX_PASSWORD` / `$PFX_PASSWORD` | Bundle password, extracted from the JSON payload |
| `CERT_COUNT` / `$CERT_COUNT` | Number of certificates in the PFX (requires OpenSSL) |
| `KEY_TYPE` / `$KEY_TYPE` | Key algorithm detected from the PFX (requires OpenSSL) |
| `CERT_SUBJECT` / `$CERT_SUBJECT` | Certificate subject DN (requires OpenSSL) |
| `FILES_ARRAY` / `$FILES_ARRAY` | Raw list of all files in the JSON payload |

### Arguments (all templates)

| Variable | Maps to |
|---|---|
| `ARGUMENT_1` / `$ARGUMENT_1` | AWR Parameter 1 |
| `ARGUMENT_2` / `$ARGUMENT_2` | AWR Parameter 2 |
| `ARGUMENT_3` / `$ARGUMENT_3` | AWR Parameter 3 |
| `ARGUMENT_4` / `$ARGUMENT_4` | AWR Parameter 4 |
| `ARGUMENT_5` / `$ARGUMENT_5` | AWR Parameter 5 |

### JSON payload (all templates)

| Variable | Description |
|---|---|
| `JSON_STRING` / `$JSON_STRING` | Full decoded JSON string |
| `ARGS_ARRAY` / `$ARGS_ARRAY` | Raw args array from the payload |
| `$JSON_OBJECT` | (PowerShell only) Parsed JSON object |

### Logging utility

**Bash:** `log_message "your message"` — writes a timestamped line to `$LOGFILE`

**PowerShell:** `Write-LogMessage "your message"` — writes a timestamped line to `$LOGFILE`

---

## Example Custom Logic

The templates include commented-out examples to help you get started quickly. A selection is shown below.

### Deploy to Nginx (Bash, CRT)

```bash
NGINX_CERT_DIR="/etc/nginx/ssl"
mkdir -p "$NGINX_CERT_DIR"
cp "$CRT_FILE_PATH" "$NGINX_CERT_DIR/server.crt"
cp "$KEY_FILE_PATH" "$NGINX_CERT_DIR/server.key"
chmod 644 "$NGINX_CERT_DIR/server.crt"
chmod 600 "$NGINX_CERT_DIR/server.key"
systemctl reload nginx
log_message "Certificate deployed and nginx reloaded"
```

### Import to Windows Certificate Store (PowerShell, PFX)

```powershell
$securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
$pfxCert = Import-PfxCertificate `
    -FilePath $PFX_FILE_PATH `
    -Password $securePwd `
    -CertStoreLocation "Cert:\LocalMachine\My"
Write-LogMessage "Imported to store. Thumbprint: $($pfxCert.Thumbprint)"
```

### Import to Java Keystore (Bash, PFX)

```bash
KEYSTORE_PATH="/opt/app/keystore.jks"
KEYSTORE_PASS="changeit"
ALIAS_NAME="$ARGUMENT_1"

keytool -importkeystore \
    -srckeystore "$PFX_FILE_PATH" \
    -srcstoretype pkcs12 \
    -srcstorepass "$PFX_PASSWORD" \
    -destkeystore "$KEYSTORE_PATH" \
    -deststoretype JKS \
    -deststorepass "$KEYSTORE_PASS" \
    -alias "$ALIAS_NAME" \
    -noprompt
log_message "Certificate imported to keystore with alias: $ALIAS_NAME"
```

### Update IIS Binding (PowerShell, PFX)

```powershell
Import-Module WebAdministration
$securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
$pfxCert = Import-PfxCertificate -FilePath $PFX_FILE_PATH -Password $securePwd -CertStoreLocation "Cert:\LocalMachine\My"

$siteName = $ARGUMENT_1   # Pass site name as AWR Parameter 1
$binding = Get-WebBinding -Name $siteName -Protocol https
if ($binding) {
    $binding.AddSslCertificate($pfxCert.Thumbprint, "My")
    Write-LogMessage "Updated SSL certificate for IIS site: $siteName"
    Restart-Service -Name W3SVC -Force
}
```

### Verify Cert and Key Match (Bash, CRT)

```bash
CRT_MODULUS=$(openssl x509 -noout -modulus -in "$CRT_FILE_PATH" | openssl md5)
KEY_MODULUS=$(openssl rsa -noout -modulus -in "$KEY_FILE_PATH" 2>/dev/null | openssl md5)
if [ "$CRT_MODULUS" = "$KEY_MODULUS" ]; then
    log_message "SUCCESS: Certificate and private key match"
else
    log_message "ERROR: Certificate and private key DO NOT match"
    exit 1
fi
```

### Conditional Service Restart Based on Argument (Bash)

```bash
if [ "$ARGUMENT_1" = "restart_nginx" ]; then
    systemctl restart nginx
    log_message "nginx restarted"
elif [ "$ARGUMENT_1" = "restart_apache" ]; then
    systemctl restart apache2
    log_message "apache2 restarted"
fi
```

---

## Logging

Every template writes timestamped entries to a configurable log file throughout execution. The log covers:

- Script start and configuration summary
- Legal notice acceptance check
- Raw decoded JSON payload (useful during initial testing)
- Each extracted variable with its value and length
- File existence and size checks
- Certificate chain depth and key algorithm
- Custom section start and completion
- Script exit

During development, tail the log file in a separate terminal to watch execution in real time:

```bash
tail -f /path/to/your/logfile.log
```

---

## Choosing the Right Template

```
Do you need the private key accessible separately?
├── Yes → Use CRT/KEY template (.sh or .ps1)
└── No  → Use PFX template (.sh or .ps1)

What OS does the TLM Agent run on?
├── Linux / macOS → Use .sh template
└── Windows       → Use .ps1 template
```

Common pairings:

| Target platform | Recommended template |
|---|---|
| Nginx, Apache, HAProxy | `awr-template-crt.sh` |
| OpenSSL-based Linux toolchains | `awr-template-crt.sh` |
| Java / Tomcat (Linux) | `awr-template-pfx.sh` |
| IIS | `awr-template-pfx.ps1` |
| Windows Certificate Store / .NET | `awr-template-pfx.ps1` |
| Java / Tomcat (Windows) | `awr-template-pfx.ps1` |
| Windows + OpenSSL workflow | `awr-template-crt.ps1` |

---

## Security Notes

- **The legal notice gate** prevents accidental execution before a script is reviewed and configured. Do not set `LEGAL_NOTICE_ACCEPT = "true"` in shared or un-reviewed scripts.
- **PFX passwords** are extracted from the JSON payload and masked in logs (only the first three characters are shown). Never log the full password.
- **Private key files** should be readable only by the service account running the TLM Agent (`chmod 600` on Linux; restricted ACL on Windows).
- **Log files** may contain certificate metadata including subject DNs and thumbprints. Ensure they are stored in a location with appropriate access controls.

---

## License

Copyright © 2024 DigiCert. All rights reserved.

DigiCert and its logo are registered trademarks of DigiCert, Inc. Use of these scripts is subject to the terms and conditions of your agreement with DigiCert. See the legal notice embedded in each script file for full details.