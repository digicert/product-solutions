# DigiCert TLM — Oracle WebLogic Server Integration

Automated certificate lifecycle management for Oracle WebLogic Server using DigiCert Trust Lifecycle Manager (TLM). This repository contains AWR (Admin Web Request) post-enrollment scripts that convert PFX certificates issued by TLM into the WebLogic identity keystore (JKS or PKCS12), import the full CA chain as trusted entries, and then restart WebLogic so the renewed certificate goes live automatically.

WebLogic uses the **same keystore as both its identity store and its trust store**, so the keystore must contain the leaf certificate + private key (a `PrivateKeyEntry`) *and* the intermediate/root CA certificates (as `trustedCertEntry` entries). The scripts populate all of these from a single PFX. Without the CA chain, WebLogic logs `No trusted certificates have been loaded` and SSL fails to start on the HTTPS port.

Both scripts perform the same operation — choose the one that matches the operating system where the TLM Agent is running.

| Script | Platform | Runtime Requirements |
|--------|----------|---------------------|
| `weblogic-awr.sh` | Linux | `keytool` (Java), `openssl`, `curl`, WebLogic `stopWebLogic.sh`/`startWebLogic.sh` |
| `weblogic-awr.ps1` | Windows | `keytool` (Java), .NET (`X509Certificate2Collection`, for CA-chain extraction — built into PowerShell), WebLogic `stopWebLogic.cmd`/`startWebLogic.cmd` |

---

## How It Works

When the DigiCert TLM Agent completes a certificate enrollment or renewal, it executes the AWR post-enrollment script. The script performs the following steps:

1. **Decode** — Reads the `DC1_POST_SCRIPT_DATA` environment variable (base64-encoded JSON) to extract certificate file paths, PFX password, and any configured arguments. Carriage returns (`\r`) are stripped from the decoded payload so Windows-style CRLF line endings don't corrupt extracted values such as the password.
2. **Select PFX** — Identifies the non-legacy PFX file from the enrollment output. If TLM delivers both a standard and a `_legacy` PFX, the standard (non-legacy) file is selected automatically.
3. **Inspect** — Validates the PFX file can be opened with the provided password and extracts certificate metadata (subject/CN, key type) and the source alias.
4. **Alias resolution** — Derives the keystore alias from either a fixed configured value or the certificate's Common Name (CN), depending on configuration.
5. **Backup & type detection** — Creates a timestamped backup of the existing keystore and auto-detects its actual storetype (`JKS` or `PKCS12`) rather than trusting the file extension. New keystores are created as PKCS12.
6. **Import leaf certificate** — Imports the PFX into a *fresh temporary keystore* using `keytool -importkeystore`, then (after the CA chain is added) atomically replaces the destination file. The existing alias is **not** deleted in place, because deleting from a PKCS12 keystore breaks its internal MAC integrity. The import is retried across combinations of the `-J-Dkeystore.pkcs12.legacy` flag (for OpenSSL-created PFX files that newer JDKs reject by default) and with/without an explicit source alias. If the entries are imported under their original alias, `keytool -changealias` renames them to the configured alias.
7. **Import CA chain** — Extracts every CA certificate from the PFX and imports each as a `trustedCertEntry` so the keystore also serves as WebLogic's trust store. On Linux this uses `openssl pkcs12 ... -cacerts` (with a fallback that skips the leaf cert) piped into `keytool -importcert`; on Windows it uses .NET `X509Certificate2Collection` to enumerate the chain and imports each non-leaf cert. CA aliases are derived from each cert's CN (e.g. `ca-1-digicertglobalrootca`). If no CA certs are found, a warning is logged noting WebLogic SSL may fail to start.
8. **Verify** — Lists the keystore contents and confirms the expected alias is present with the correct certificate details.
9. **Restart WebLogic** — Stops WebLogic (via the domain `stopWebLogic` script, falling back to killing the JVM), waits for it to exit, restarts it, and probes the HTTP and SSL ports to confirm the server comes back up with the new certificate live.

```
DigiCert TLM ──enroll/renew──▶ TLM Agent
                                   │
                                   └──post-enrollment──▶ AWR Script
                                                            │
                                                            ├── Decode DC1_POST_SCRIPT_DATA (strip CRLF)
                                                            ├── Select non-legacy PFX
                                                            ├── Backup existing keystore + detect storetype
                                                            ├── Import leaf PFX → temp keystore (keytool)
                                                            ├── Import CA chain as trustedCertEntry
                                                            ├── Atomically replace destination keystore
                                                            ├── Verify import
                                                            └── Restart WebLogic + probe ports
                                                                    │
                                                                    ▼
                                              WebLogic keystore = identity + trust store (renewed cert live)
```

---

## Prerequisites

- DigiCert TLM Agent (v3.0.15+) installed and configured
- Java JDK/JRE with `keytool` — the scripts call `keytool` by an **explicit, configured path** (`KEYTOOL`), not via PATH, so the TLM Agent always uses the correct JDK
- **Linux only:** `openssl` (PFX inspection and CA-chain extraction) and `curl` (port probing after restart)
- The TLM enrollment profile must be configured to deliver PFX (.pfx/.p12) format output containing the **full certificate chain** (leaf + intermediate + root), so the scripts can populate the trust store
- WebLogic domain start/stop scripts (`startWebLogic`/`stopWebLogic`) present under the configured domain `bin` directory, and sufficient privileges to stop and start WebLogic (on Linux, the script can run the restart as the configured `WL_USER` when launched as root)

---

## Configuration

Edit the configuration section at the top of the appropriate script.

> **Important:** `LEGAL_NOTICE_ACCEPT` ships set to **false**. The script will exit immediately until you set it to `true` / `$true`.

### Linux (`weblogic-awr.sh`)

```bash
# Accept the legal notice to enable execution (ships as "false")
LEGAL_NOTICE_ACCEPT="false"

# Log file path
LOGFILE="/opt/tlm_agent_3.1.11_linux64/log/dc1_data.log"

# Java Keystore settings — WebLogic uses this ONE keystore as both identity AND trust store
JKS_PATH="/home/admin/Oracle/Middleware/Oracle_Home/user_projects/domains/base_domain/security/DemoIdentity.jks"
JKS_PASSWORD="DemoIdentityKeyStorePassPhrase"   # Keystore password
JKS_BACKUP_DIR="/home/backups"                   # Backup directory for existing keystores
JKS_ALIAS="DemoIdentity"                         # Must match the alias in WebLogic's SSL config (case-sensitive)
USE_CN_AS_ALIAS="false"                          # Set to "true" to derive alias from certificate CN

# Explicit keytool path — avoids the TLM Agent environment picking the wrong JDK
KEYTOOL="/usr/lib/jvm/java-11-openjdk-11.0.22.0.7-2.el9.x86_64/bin/keytool"

# WebLogic restart settings
WL_DOMAIN_BIN="/home/admin/Oracle/Middleware/Oracle_Home/user_projects/domains/base_domain/bin"
WL_USER="admin"            # OS user that owns/runs WebLogic — restart runs as this user when script runs as root
WL_RESTART_TIMEOUT=120     # Seconds to wait for WebLogic to respond after restart
```

### Windows (`weblogic-awr.ps1`)

```powershell
# Accept the legal notice to enable execution (ships as $false)
$LEGAL_NOTICE_ACCEPT = $false

# Log file path
$LogFile = "C:\Program Files\DigiCert\TLM Agent\log\WebLogicCertUpdate.log"

# Java Keystore settings
$JKS_PATH      = "C:\Oracle\Middleware\Oracle_Home\user_projects\domains\base_domain\security\DemoIdentity.jks"
$JKS_PASSWORD  = "DemoIdentityKeyStorePassPhrase"  # Keystore password
$JKS_BACKUP_DIR = "C:\backups\weblogic"            # Backup directory for existing keystores
$JKS_ALIAS     = "demoidentity"                    # Must match WebLogic's SSL config (case-sensitive; PKCS12 lowercases aliases)
$USE_CN_AS_ALIAS = $false                          # Set to $true to derive alias from certificate CN

# Explicit keytool path — bypasses PATH so the TLM Agent always uses the correct JDK
$KEYTOOL = "C:\Program Files\Java\jdk-11\bin\keytool.exe"

# WebLogic restart settings
$WL_DOMAIN_BIN      = "C:\Oracle\Middleware\Oracle_Home\user_projects\domains\base_domain\bin"
$WL_HTTP_PORT       = 7001   # HTTP port probed after restart to confirm WebLogic is up
$WL_HTTPS_PORT      = 7002   # HTTPS/SSL port probed after restart
$WL_RESTART_TIMEOUT = 120    # Seconds to wait for WebLogic to respond after restart
```

> The example defaults target WebLogic's built-in `DemoIdentity` keystore. Replace them with your real identity keystore path, password, and alias before use.

### Alias Behaviour

The keystore alias determines how WebLogic references the certificate. You have two options:

- **Fixed alias** (default) — Set `JKS_ALIAS` to a static value. The same alias is reused on every renewal, so WebLogic's SSL configuration does not need updating. It **must match exactly** the Private Key Alias in WebLogic's SSL config (case-sensitive). Note that PKCS12 keystores lowercase aliases, so use a lowercase value when the destination is PKCS12.
- **CN-based alias** — Set `USE_CN_AS_ALIAS` to `true` / `$true`. The alias is derived from the certificate's Common Name (e.g. `www.example.com`). This is useful when multiple certificates are stored in the same keystore.

### Keystore Contents (Identity + Trust)

WebLogic points at a single keystore for both its **Custom Identity** and **Custom Trust**, so the scripts populate it with everything needed for SSL:

| Entry type | Alias | Source |
|------------|-------|--------|
| `PrivateKeyEntry` | `JKS_ALIAS` (or the CN) | The leaf certificate + private key from the PFX |
| `trustedCertEntry` | `ca-1-<cn>`, `ca-2-<cn>`, … | Each intermediate/root CA certificate extracted from the PFX |

The CA-chain import is what allows the same file to act as the trust store. If the PFX contains no CA certificates, the leaf is still imported but the script logs a warning that WebLogic may report `No trusted certificates have been loaded` and SSL may not start.

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

Configure the script as the AWR post-enrollment hook in the TLM console. The account running the TLM Agent service must have permission to write the keystore and to stop/start WebLogic.

---

## WebLogic Restart

After the keystore is updated and verified, both scripts **restart WebLogic automatically** so the renewed certificate is loaded into the running server:

1. **Stop** — Runs the domain `stopWebLogic` script (`stopWebLogic.sh` / `stopWebLogic.cmd`). On Linux, if the script is running as root it stops/starts WebLogic as `WL_USER` (via `su -`) and fixes file ownership afterward. If the stop script is missing or WebLogic does not exit cleanly within 60 seconds, the WebLogic JVM is force-killed.
2. **Start** — Launches the domain `startWebLogic` script in the background.
3. **Health probe** — Polls the HTTP port (default `7001`) until WebLogic responds, up to `WL_RESTART_TIMEOUT` seconds, then checks the SSL port (default `7002`) to confirm the new certificate is live. If the server does not respond within the timeout, a warning is logged so the operator can investigate — the script does not hang indefinitely.

Adjust `WL_DOMAIN_BIN`, the port values, `WL_RESTART_TIMEOUT`, and (Linux) `WL_USER` in the configuration section to match your environment.

---

## AWR Arguments

The scripts do not require any AWR arguments — all settings (keystore path, password, alias, keytool path, restart parameters) are configured directly in the configuration section at the top of each script. The only data consumed from the `DC1_POST_SCRIPT_DATA` payload is the certificate folder, the delivered file list, and the PFX password.

---

## Logging

All operations are logged with timestamps to the configured `LOGFILE`. The logs include:

- Configuration summary
- Decoded JSON payload with passwords masked (`"password":"***"`)
- PFX file details (size, certificate count, subject/CN) and the detected source alias
- Detected destination keystore type and backup location
- Import attempts (legacy-flag and source-alias combinations) with keytool output
- CA-chain import (one line per trusted CA certificate added)
- Post-import verification (alias listing and certificate details)
- WebLogic stop/start and port-probe results

### Example Log Output

```
[2026-03-16 10:30:01] Starting WebLogic cert automation script
[2026-03-16 10:30:01] keytool is available: /usr/lib/jvm/java-11-openjdk/bin/keytool
[2026-03-16 10:30:01] Non-legacy PFX: server.pfx
[2026-03-16 10:30:02] Certificate CN: www.example.com
[2026-03-16 10:30:02] Detected destination keystore type: pkcs12
[2026-03-16 10:30:02] Backed up existing keystore to: /home/backups/weblogic_20260316_103002.jks
[2026-03-16 10:30:02] Found source alias in PFX: '1'
[2026-03-16 10:30:03] Import succeeded (legacy=true)
[2026-03-16 10:30:03] Importing CA cert 1 (alias: ca-1-digicert-intermediate)...
[2026-03-16 10:30:03] CA cert 1 imported successfully as 'ca-1-digicert-intermediate'
[2026-03-16 10:30:04] Importing CA cert 2 (alias: ca-2-digicert-global-root)...
[2026-03-16 10:30:04] CA cert 2 imported successfully as 'ca-2-digicert-global-root'
[2026-03-16 10:30:04] CA chain import complete: 2 certificate(s) added as trusted entries
[2026-03-16 10:30:04] SUCCESS: Keystore updated at /home/admin/.../DemoIdentity.jks
[2026-03-16 10:30:04] SUCCESS: Certificate alias 'DemoIdentity' verified in keystore
[2026-03-16 10:30:05] Stopping WebLogic...
[2026-03-16 10:30:20] WebLogic stopped.
[2026-03-16 10:30:21] Starting WebLogic...
[2026-03-16 10:31:05] WebLogic is up on port 7001 after 44s.
[2026-03-16 10:31:10] SSL port 7002 is responding - new certificate is live.
```

---

## PFX File Selection

When TLM delivers multiple PFX files (e.g. both a modern and a `_legacy` variant), the scripts automatically select the **non-legacy** file for import. The legacy PFX is logged but not imported. If only one PFX file is present, it is used regardless of naming.

Supported file extensions: `.pfx`, `.p12`

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `ERROR: Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` is not set to `true` (ships as false) | Set the flag to `true` / `$true` in the script configuration |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script was run outside the TLM Agent context | The script must be triggered by the TLM Agent as a post-enrollment hook |
| `ERROR: keytool not found at <path>` | The `KEYTOOL` path is wrong or Java is not installed there | Update the `KEYTOOL` variable to the absolute path of `keytool`/`keytool.exe` for your JDK |
| `keystore password was incorrect` on import | Password carried a trailing `\r` from CRLF payload, or alias was deleted from a PKCS12 store | The scripts strip `\r` and use the temp-keystore strategy to avoid this; verify the TLM profile's PFX password if it persists |
| `Invalid keystore format` | Wrong destination storetype assumed from the file extension | The scripts auto-detect the storetype; ensure the configured `JKS_PASSWORD` is correct so detection can read the keystore |
| All import methods failed | PFX uses encryption the JDK rejects, or password mismatch | The scripts retry with the `-J-Dkeystore.pkcs12.legacy` flag; confirm the PFX password and JDK version |
| `ERROR: PFX file not found` | Certificate folder path incorrect | Check the TLM Agent's certificate output directory configuration |
| `WARNING: Alias ... not found after import` | Source alias in PFX didn't match expected value | The script imports all entries and renames via `keytool -changealias`; check the keystore for the actual alias name |
| `No trusted certificates have been loaded` (WebLogic log) / SSL fails on 7002 | The PFX contained no CA certificates, so the trust store is empty | Ensure the TLM enrollment profile delivers the full chain in the PFX; look for the `WARNING: ... trust store will be empty` line in the script log |
| `WARNING: WebLogic did not respond within <timeout>s` | WebLogic did not come back up in time | Increase `WL_RESTART_TIMEOUT`, verify `WL_DOMAIN_BIN` and the start/stop scripts, and check the WebLogic logs |
| `WARNING: stopWebLogic ... not found` | `WL_DOMAIN_BIN` points to the wrong domain `bin` directory | Set `WL_DOMAIN_BIN` to the domain's `bin` folder containing the start/stop scripts |

---

## WebLogic Configuration

After the keystore is updated, WebLogic must be configured to use it. In the WebLogic Admin Console:

1. Navigate to **Servers → [your server] → Configuration → Keystores**.
2. Set **Keystores** to *Custom Identity and Custom Trust*.
3. Set both the **Custom Identity Keystore** and the **Custom Trust Keystore** to the same keystore path (matching `JKS_PATH`) — the scripts import both the leaf certificate and the CA chain into this one file.
4. Set the **Keystore Type** for both to match the keystore — `JKS` or `PKCS12`. New keystores created by these scripts are PKCS12.
5. Enter the keystore password for both identity and trust.
6. Under **SSL**, set the **Private Key Alias** to the alias configured in the script (matching `JKS_ALIAS`, case-sensitive).
7. Enter the private key passphrase (same as `JKS_PASSWORD`).

> **Note:** This is a one-time setup. On each renewal the scripts update the keystore in place and **restart WebLogic automatically** (see [WebLogic Restart](#weblogic-restart)) so the new certificate is loaded — no manual restart is needed.

---

## Security Considerations

- The JKS and PFX passwords are stored in plaintext within the script. Restrict file permissions accordingly (`chmod 600` on Linux, ACLs on Windows).
- The PFX password is also present in the `DC1_POST_SCRIPT_DATA` environment variable during execution. Ensure the agent host is appropriately secured.
- Keystore backups accumulate in the backup directory. Implement a retention policy to remove old backups.
- Consider using a secrets manager or environment-level credential injection rather than hardcoding passwords for production deployments.

---

## Legal Notice

Copyright © 2026 DigiCert. All rights reserved. See the embedded legal notice in each script for full terms. The `LEGAL_NOTICE_ACCEPT` flag must be set to `"true"` to acknowledge acceptance before the scripts will execute.