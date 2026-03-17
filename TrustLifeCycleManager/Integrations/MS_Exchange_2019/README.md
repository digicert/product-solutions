# DigiCert TLM Agent — Microsoft Exchange Server Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment to **Microsoft Exchange Server**. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate into the local machine store and enables it for configured Exchange services (IIS, SMTP, POP, IMAP).

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
    ├── Import PFX into LocalMachine\My store
    ├── Build services list from config flags
    ├── Load Exchange Management Shell
    ├── Enable-ExchangeCertificate for selected services
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

### Exchange Services

Enable the services that should use the deployed certificate:

| Variable | Default | Description |
|---|---|---|
| `$Enable_POP_Service` | `$false` | Enable certificate for POP3 service |
| `$Enable_IMAP_Service` | `$false` | Enable certificate for IMAP4 service |
| `$Enable_IIS_Service` | `$false` | Enable certificate for IIS (OWA, ECP, EWS, ActiveSync, Autodiscover) |
| `$Enable_SMTP_Service` | `$false` | Enable certificate for SMTP service |

At least one service must be enabled. If none are enabled, the certificate is imported into the store but not bound to any Exchange services, and the script exits with a warning.

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
2. **Decode** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload
3. **Validate** — confirms the PFX file exists at the expected path
4. **Import** — imports the PFX into `Cert:\LocalMachine\My` and captures the thumbprint
5. **Build service list** — constructs a comma-separated services string from the enabled flags
6. **Exchange Management Shell** — creates a temporary script that:
   - Loads the Exchange snap-in (`Microsoft.Exchange.Management.PowerShell.SnapIn`)
   - Runs `Enable-ExchangeCertificate` with the thumbprint and services list
   - Detects unsupported key algorithm errors (e.g. if an ECC certificate is used with an Exchange version that doesn't support it)
7. **Execute** — launches the temporary script via `exshell.psc1` if available, otherwise falls back to direct snap-in loading
8. **Clean up** — removes the temporary script file

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
- Certificate import result and thumbprint
- Services being enabled
- Exchange Management Shell loading status
- Success or detailed error messages

Example log output:

```
2025-03-16 10:30:01 : Script execution started
2025-03-16 10:30:01 : Legal notice accepted - proceeding with script execution
2025-03-16 10:30:01 : Decoded JSON: {"certfolder":"C:\\certs","files":["cert.pfx"],...}
2025-03-16 10:30:02 : Certificate imported successfully. Thumbprint: A1B2C3D4E5...
2025-03-16 10:30:02 : Enabling certificate for Exchange services: IIS,SMTP
2025-03-16 10:30:03 : Exchange certificate enabling process completed successfully
2025-03-16 10:30:03 : Script execution completed successfully
```

## Error Handling

The script exits with code `1` on critical failures:

- PFX file does not exist at the expected path
- Certificate import fails (`Import-PfxCertificate`)
- `Enable-ExchangeCertificate` fails (including unsupported key algorithm detection)
- Exchange Management Shell cannot be loaded

The script exits with code `0` (non-error) when:

- Legal notice is not accepted (script declines to run)
- No Exchange services are enabled (certificate is imported but not bound)

## Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| `KeyAlgorithmUnsupported` error | ECC certificate used with Exchange version that doesn't support it | Use an RSA key algorithm in the TLM enrollment profile |
| Exchange snap-in fails to load | Exchange Management Tools not installed | Install Exchange Management Tools or run on an Exchange server |
| PFX import fails | Incorrect password or corrupted PFX | Verify the AWR profile password configuration |
| No services enabled warning | All service flags set to `$false` | Set at least one `$Enable_*_Service` variable to `$true` |

## Security Notes

- The PFX password is passed via the `DC1_POST_SCRIPT_DATA` environment variable and converted to a `SecureString` at runtime. Ensure the log file has appropriate access controls as the decoded JSON is logged.
- The temporary script is created in `%TEMP%` and cleaned up after execution (including on failure).
- The script uses `-ExecutionPolicy Bypass` for the child PowerShell process — ensure this aligns with your organisation's execution policy requirements.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.