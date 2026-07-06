# DigiCert TLM Agent — Microsoft Exchange Server Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment to **Microsoft Exchange Server**. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate into the local machine store, enables it for the configured Exchange services (POP, IMAP, IIS, SMTP), repoints the IIS SSL bindings, restarts the affected services, and verifies the result.

## How It Works

```
TLM Agent (AWR)
    │
    ▼
Enrollment / Renewal completes
    │
    ▼
DC1_POST_SCRIPT_DATA (Base64-encoded JSON)
    │
    ▼
Post-enrollment script
    ├── Decode & extract PFX path + password
    ├── Read the certificate CN and archive a timestamped copy of the PFX
    ├── Import PFX into LocalMachine\My store
    ├── Enable-ExchangeCertificate for $ExchangeServices (via Exchange Management Shell)
    ├── Update IIS SSL bindings ($IISSiteBindings) to the new thumbprint
    ├── Restart IIS + Exchange services
    ├── Verify the HTTP.sys SSL bindings via netsh
    └── Clean up temporary files
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile
- **Microsoft Exchange Server 2013/2016/2019** (V15) installed on the target host
- Exchange Management Shell available (`exshell.psc1` or `Microsoft.Exchange.Management.PowerShell.SnapIn`)
- Script runs with sufficient privileges to import certificates and manage Exchange services
- PFX enrollment output configured in the TLM AWR profile

## Configuration

### Legal Notice

The script will not execute until the legal notice is accepted:

```powershell
$legal_notice_accept = $true  # Set to $true after reviewing the legal notice
```

### Script Settings

All environment-specific settings live in the `# ── Config ──` block near the top of the script:

| Variable | Default | Description |
|---|---|---|
| `$LogFilePath` | `C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log` | Timestamped log file for all operations |
| `$ExchangeShellPsc` | `C:\Program Files\Microsoft\Exchange Server\V15\bin\exshell.psc1` | Exchange Management Shell console file (Exchange 2013/2016/2019 all use the `V15` path) |
| `$ExchangeServices` | `POP,IMAP,IIS,SMTP` | Comma-separated (no spaces) list of services the cert is enabled for via `Enable-ExchangeCertificate`. Trim this list to enable only the services you need (e.g. `IIS,SMTP`). |
| `$IISSiteBindings` | `Default Web Site`→`443`, `Exchange Back End`→`444` | IIS sites and HTTPS ports whose SSL bindings are repointed to the new certificate |

Unlike earlier revisions, services are **not** toggled with individual `$Enable_*` flags — edit the `$ExchangeServices` string and the `$IISSiteBindings` hashtable directly.

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string** with the following structure:

```json
{
  "certfolder": "C:\\path\\to\\certs",
  "files": ["certificate.pfx"],
  "password": "pfx-password",
  "args": ["arg1", "arg2"]
}
```

The script extracts:

- **`certfolder`** + **`files[0]`** — combined to build the full path to the PFX file
- **`password`** — PFX import password (converted to `SecureString` at runtime)
- **`args`** — optional custom arguments from the AWR profile

## What the Script Does

1. **Legal notice check** — exits if `$legal_notice_accept` is not `$true`
2. **Decode** — Base64-decodes `DC1_POST_SCRIPT_DATA`, parses the JSON, and validates that the PFX file exists at the expected path
3. **Read CN & archive** — reads the certificate's common name and expiry, then copies the PFX into a timestamped `<CN>_pfx_<timestamp>` folder for audit/rollback
4. **Import** — imports the PFX into `Cert:\LocalMachine\My` (with `-Exportable`) and captures the thumbprint
5. **Enable for Exchange** — creates a temporary script, run in a **separate PowerShell process**, that:
   - Loads the Exchange snap-in (`Microsoft.Exchange.Management.PowerShell.SnapIn`)
   - Runs `Enable-ExchangeCertificate` for the thumbprint against `$ExchangeServices`
   - Detects unsupported key algorithm errors (e.g. an ECC certificate on an Exchange version that doesn't support it)
   - Launches via `exshell.psc1` if present, otherwise falls back to direct snap-in loading
6. **Update IIS bindings** — for each site in `$IISSiteBindings`, binds the new thumbprint to the HTTPS binding (creating the binding if missing)
7. **Restart services** — runs `iisreset /noforce` and restarts `MSExchangeTransport`, `MSExchangeImap4`, and `MSExchangePop3`
8. **Verify** — uses `netsh http show sslcert` to confirm each HTTP.sys binding resolves to the new thumbprint
9. **Clean up** — removes the temporary Exchange script

## Exchange Management Shell Execution

The script uses a two-tier approach to load the Exchange Management Shell:

1. **Primary** — loads via `C:\Program Files\Microsoft\Exchange Server\V15\bin\exshell.psc1`
2. **Fallback** — direct execution with `Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn`

A temporary `.ps1` script is created in `%TEMP%` and executed in a separate PowerShell process to ensure the Exchange snap-in loads cleanly. The temporary script includes its own `Log-Message` function since it runs in an isolated process.

## Logging

All operations are logged with timestamps to:

```
C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log
```

The log includes:

- Decoded JSON payload
- Certificate CN, expiry, and archive folder location
- Certificate import result and thumbprint
- Exchange Management Shell loading status (child-process lines are tagged `[CHILD]`)
- IIS binding updates, service restarts, and `netsh` verification results
- Success or detailed error messages

Example log output:

```
2026-07-06 10:30:01 : DigiCert TLM Post-Script starting...
2026-07-06 10:30:01 : Legal notice accepted - proceeding with script execution
2026-07-06 10:30:01 : Decoded JSON: {"certfolder":"C:\\certs","files":["cert.pfx"],...}
2026-07-06 10:30:01 : Certificate CN      : mail.contoso.com
2026-07-06 10:30:01 : Archive folder created: C:\certs\mail.contoso.com_pfx_2026_07_06_10_30_01
2026-07-06 10:30:02 : Certificate imported successfully. Thumbprint: A1B2C3D4E5...
2026-07-06 10:30:03 : [CHILD] Enable-ExchangeCertificate succeeded. Thumbprint: A1B2C3D4E5...
2026-07-06 10:30:03 : IIS 'Default Web Site':443 bound to thumbprint A1B2C3D4E5...
2026-07-06 10:30:08 : IIS restarted successfully.
2026-07-06 10:30:10 : VERIFIED: 'Default Web Site':443 is using the correct certificate.
2026-07-06 10:30:10 : COMPLETE: Certificate replacement finished. CN=mail.contoso.com Thumbprint=A1B2C3D4E5... Archive=C:\certs\mail.contoso.com_pfx_2026_07_06_10_30_01
```

## Error Handling

The script exits with code `1` on critical failures:

- `DC1_POST_SCRIPT_DATA` is empty or cannot be decoded
- PFX file does not exist at the expected path
- The archive folder cannot be created
- Certificate import fails (`Import-PfxCertificate`)
- `Enable-ExchangeCertificate` fails (including unsupported key algorithm detection)
- The `WebAdministration` module cannot be loaded, or an IIS binding cannot be set

The script exits with code `0` (non-error) when:

- Legal notice is not accepted (script declines to run)

> **Note:** Service restarts (STEP 6) and binding verification (STEP 7) are logged as **warnings** on failure rather than aborting the run, since the certificate is already imported and bound at that point.

## Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| `KeyAlgorithmUnsupported` error | ECC certificate used with Exchange version that doesn't support it | Use an RSA key algorithm in the TLM enrollment profile |
| Exchange snap-in fails to load | Exchange Management Tools not installed | Install Exchange Management Tools or run on an Exchange server |
| PFX import fails | Incorrect password or corrupted PFX | Verify the AWR profile password configuration |
| `netsh` verification reports a thumbprint mismatch | HTTP.sys binding didn't update after the IIS change | Re-check the IIS binding and re-run `iisreset`, or set the binding manually |
| Certificate not enabled for the expected service | Service missing from `$ExchangeServices` | Add the service (POP/IMAP/IIS/SMTP) to the `$ExchangeServices` string |

## Security Notes

- The PFX password is passed via the `DC1_POST_SCRIPT_DATA` environment variable and converted to a `SecureString` at runtime. Ensure the log file has appropriate access controls as the decoded JSON is logged.
- The temporary script is created in `%TEMP%` and cleaned up after execution (including on failure).
- The script uses `-ExecutionPolicy Bypass` for the child PowerShell process — ensure this aligns with your organisation's execution policy requirements.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.