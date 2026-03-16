# DigiCert TLM — Oracle WebLogic Server Integration

Automated certificate lifecycle management for Oracle WebLogic Server using DigiCert Trust Lifecycle Manager (TLM). This repository contains AWR (Admin Web Request) post-enrollment scripts that convert PFX certificates issued by TLM into Java KeyStore (JKS) format for use by WebLogic.

Both scripts perform the same operation — choose the one that matches the operating system where the TLM Agent is running.

| Script | Platform | Runtime Requirements |
|--------|----------|---------------------|
| `weblogic-awr.sh` | Linux | `openssl`, `keytool` (Java) |
| `weblogic-awr.ps1` | Windows | `keytool` (Java), .NET Framework |

---

## How It Works

When the DigiCert TLM Agent completes a certificate enrollment or renewal, it executes the AWR post-enrollment script. The script performs the following steps:

1. **Decode** — Reads the `DC1_POST_SCRIPT_DATA` environment variable (base64-encoded JSON) to extract certificate file paths, PFX password, and any configured arguments.
2. **Select PFX** — Identifies the non-legacy PFX file from the enrollment output. If TLM delivers both a standard and a `_legacy` PFX, the standard (non-legacy) file is selected automatically.
3. **Inspect** — Validates the PFX file can be opened with the provided password and extracts certificate metadata (subject, issuer, validity dates, key type).
4. **Alias resolution** — Derives the keystore alias from either a fixed configured value or the certificate's Common Name (CN), depending on configuration.
5. **Backup** — Creates a timestamped backup of the existing JKS file before making changes.
6. **Import** — Uses `keytool -importkeystore` to convert the PFX into the JKS keystore. If the target alias already exists, it is deleted and replaced. A fallback import method (without specifying the source alias) is attempted if the primary import fails.
7. **Verify** — Lists the keystore contents and confirms the expected alias is present with the correct certificate details.

```
DigiCert TLM ──enroll/renew──▶ TLM Agent
                                   │
                                   └──post-enrollment──▶ AWR Script
                                                            │
                                                            ├── Decode DC1_POST_SCRIPT_DATA
                                                            ├── Select non-legacy PFX
                                                            ├── Backup existing JKS
                                                            ├── keytool -importkeystore (PFX → JKS)
                                                            └── Verify import
                                                                    │
                                                                    ▼
                                                            WebLogic JKS Keystore
```

---

## Prerequisites

- DigiCert TLM Agent (v3.0.15+) installed and configured
- Java JDK/JRE with `keytool` on the system PATH (or `JAVA_HOME` set on Windows)
- **Linux only:** `openssl` for PFX inspection
- **Windows only:** .NET Framework (used for certificate inspection via `X509Certificate2`)
- The TLM enrollment profile must be configured to deliver PFX (.pfx/.p12) format output

---

## Configuration

Edit the configuration section at the top of the appropriate script.

### Linux (`weblogic-awr.sh`)

```bash
# Accept the legal notice to enable execution
LEGAL_NOTICE_ACCEPT="true"

# Log file path (adjust to match your TLM Agent installation)
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/dc1_data.log"

# Java Keystore settings
JKS_PATH="/home/weblogic.jks"           # Path to the WebLogic keystore
JKS_PASSWORD="changeit"                  # Keystore password
JKS_BACKUP_DIR="/home/backups"           # Backup directory for existing keystores
JKS_ALIAS="server_cert"                  # Alias for the imported certificate
USE_CN_AS_ALIAS="false"                  # Set to "true" to derive alias from certificate CN
```

### Windows (`weblogic-awr.ps1`)

```powershell
# Accept the legal notice to enable execution
$LEGAL_NOTICE_ACCEPT = "true"

# Log file path (adjust to match your TLM Agent installation)
$LOGFILE = "C:\tlm_agent_3.0.15_win64\log\dc1_data.log"

# Java Keystore settings
$JKS_PATH = "C:\weblogic.jks"           # Path to the WebLogic keystore
$JKS_PASSWORD = "changeit"              # Keystore password
$JKS_BACKUP_DIR = "C:\backups"          # Backup directory for existing keystores
$JKS_ALIAS = "server_cert"              # Alias for the imported certificate
$USE_CN_AS_ALIAS = $false               # Set to $true to derive alias from certificate CN
```

### Alias Behaviour

The keystore alias determines how WebLogic references the certificate. You have two options:

- **Fixed alias** (default) — Set `JKS_ALIAS` to a static value such as `server_cert`. The same alias is reused on every renewal, so WebLogic's SSL configuration does not need updating.
- **CN-based alias** — Set `USE_CN_AS_ALIAS` to `true` / `$true`. The alias is derived from the certificate's Common Name (e.g. `www.example.com`). This is useful when multiple certificates are stored in the same keystore.

---

## Deployment

### Linux

```bash
chmod +x weblogic-awr.sh
```

Configure the script as the AWR post-enrollment hook in the TLM console. The TLM Agent will execute it automatically after each enrollment or renewal.

### Windows

Ensure PowerShell execution policy allows script execution:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Configure the script as the AWR post-enrollment hook in the TLM console. The PowerShell script will warn (but not fail) if it is not running with Administrator privileges.

---

## AWR Arguments

The scripts support up to five arguments passed via the `DC1_POST_SCRIPT_DATA` JSON payload. These are configured in the TLM AWR profile and are available as `ARGUMENT_1` through `ARGUMENT_5`. The current scripts do not require any arguments — all configuration is set within the script — but the argument extraction is in place for customisation (e.g. passing the JKS path or password dynamically).

---

## Logging

All operations are logged with timestamps to the configured `LOGFILE`. The logs include:

- Configuration summary
- Raw JSON payload (for debugging)
- PFX file details (size, certificate count, key type, subject, validity)
- Keystore backup location
- Import success/failure with keytool output
- Post-import verification (alias listing and certificate details)

### Example Log Output

```
[2026-03-16 10:30:01] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format with JKS update)
[2026-03-16 10:30:01] PFX password extracted from JSON
[2026-03-16 10:30:01] Identified non-legacy PFX file: server.pfx
[2026-03-16 10:30:02] Successfully accessed PFX file with provided password
[2026-03-16 10:30:02] Certificate CN: www.example.com
[2026-03-16 10:30:02] Backed up existing keystore to: /home/backups/weblogic_20260316_103002.jks
[2026-03-16 10:30:02] Alias 'server_cert' already exists in keystore, will be replaced
[2026-03-16 10:30:03] SUCCESS: PFX successfully imported into Java keystore
[2026-03-16 10:30:03] SUCCESS: Certificate alias 'server_cert' verified in keystore
```

---

## PFX File Selection

When TLM delivers multiple PFX files (e.g. both a modern and a `_legacy` variant), the scripts automatically select the **non-legacy** file for import. The legacy PFX is logged but not imported. If only one PFX file is present, it is used regardless of naming.

Supported file extensions: `.pfx`, `.p12`

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `ERROR: Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` is not set to `true` | Set the flag to `"true"` in the script configuration |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script was run outside the TLM Agent context | The script must be triggered by the TLM Agent as a post-enrollment hook |
| `ERROR: keytool command not found` | Java is not installed or not on PATH | Install a JDK/JRE and ensure `keytool` is accessible. On Windows, set `JAVA_HOME` |
| `ERROR: Could not access PFX file with provided password` | PFX password mismatch | Verify the TLM enrollment profile's PFX password setting |
| `ERROR: PFX file not found` | Certificate folder path incorrect | Check the TLM Agent's certificate output directory configuration |
| `WARNING: Alias not found after import` | Source alias in PFX didn't match expected value | The fallback import method imports all entries; check the keystore for the actual alias name |
| `WARNING: Not running as Administrator` (Windows) | Script launched without elevated privileges | Run PowerShell as Administrator, or ensure the TLM Agent service has sufficient permissions |

---

## WebLogic Configuration

After the keystore is updated, WebLogic must be configured to use it. In the WebLogic Admin Console:

1. Navigate to **Servers → [your server] → Configuration → Keystores**.
2. Set **Keystores** to *Custom Identity and Custom Trust* (or *Custom Identity and Java Standard Trust*).
3. Set **Custom Identity Keystore** to the JKS path (e.g. `/home/weblogic.jks`).
4. Set **Custom Identity Keystore Type** to `JKS`.
5. Enter the keystore password.
6. Under **SSL**, set the **Private Key Alias** to the alias configured in the script (e.g. `server_cert`).
7. Enter the private key passphrase (same as `JKS_PASSWORD`).

> **Note:** WebLogic does not require a restart to pick up a renewed certificate if the keystore path and alias remain the same, though this depends on your WebLogic version and SSL configuration. Some environments may require a graceful restart or a reload of the SSL context.

---

## Security Considerations

- The JKS and PFX passwords are stored in plaintext within the script. Restrict file permissions accordingly (`chmod 600` on Linux, ACLs on Windows).
- The PFX password is also present in the `DC1_POST_SCRIPT_DATA` environment variable during execution. Ensure the agent host is appropriately secured.
- Keystore backups accumulate in the backup directory. Implement a retention policy to remove old backups.
- Consider using a secrets manager or environment-level credential injection rather than hardcoding passwords for production deployments.

---

## Legal Notice

Copyright © 2024 DigiCert. All rights reserved. See the embedded legal notice in each script for full terms. The `LEGAL_NOTICE_ACCEPT` flag must be set to `"true"` to acknowledge acceptance before the scripts will execute.