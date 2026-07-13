# DigiCert TLM Agent — RDP & Remote Desktop Services Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment across the **RDP-Tcp listener**, **RD Connection Broker Publishing**, **RD Web Access**, and **RD SSO / Redirector** roles. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script decodes the `DC1_POST_SCRIPT_DATA` payload, imports the delivered PFX, and applies it to whichever Remote Desktop Services roles are enabled. Any enabled step that fails is recorded and the script exits non-zero, so TLM reflects the true outcome instead of a false "success".

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
    ├── Decode JSON, extract PFX path + password + args
    ├── Import PFX into LocalMachine\My store, read thumbprint, save to file
    ├── Repair private key permissions (certutil -repairstore)
    ├── Confirm host is an RDS server (Get-RDServer) — otherwise skip RDS config
    ├── (Optional) Set RDP-Tcp listener certificate via WMI + restart TermService
    ├── (Optional) Set RD Publishing certificate via Set-RDCertificate
    ├── (Optional) Set RD Web Access certificate via Set-RDCertificate
    └── (Optional) Set RD SSO / Redirector certificate via Set-RDCertificate
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- Script runs with administrative privileges
- The target host must be part of an RDS deployment — `Get-RDServer` must return a result, otherwise **all** RDS configuration (including the RDP listener) is skipped
- For the RD Publishing / Web Access / SSO roles: the **RemoteDesktop** PowerShell module must be installed (part of the RDS role)
- PFX enrollment output configured in the TLM AWR profile

## Configuration

### Legal Notice

The legal notice is accepted via a **string** value (must be the literal `"true"`):

```powershell
$LEGAL_NOTICE_ACCEPT = "true"   # Set to "true" to accept the legal notice and allow execution.
```

If this is not `"true"`, the script logs the reason and exits `1`.

### Service Role Flags

Enable the roles that should receive the deployed certificate. **All four default to `$true`.**

| Variable | Default | Description |
|---|---|---|
| `$Install_RDP_Listener_Certificate` | `$true` | Configure the RDP-Tcp listener certificate via WMI (`Win32_TSGeneralSetting`) and restart Terminal Services |
| `$Install_RDS_Publishing_Certificate` | `$true` | Set the RD Connection Broker Publishing certificate via `Set-RDCertificate -Role RDPublishing` |
| `$Install_RDS_WebAccess_Certificate` | `$true` | Set the RD Web Access certificate via `Set-RDCertificate -Role RDWebAccess` |
| `$Install_RDS_SSO_Certificate` | `$true` | Set the RD SSO / Redirector certificate via `Set-RDCertificate -Role RDRedirector` |

The certificate is always imported into `LocalMachine\My`. If a given flag is `$false`, that role is simply skipped.

### RDS Connection Broker

Optional. Leave empty to operate against the local deployment. When set, it is passed as `-ConnectionBroker` to the RDS cmdlets and the certificate must be resolvable by that broker.

```powershell
$RDS_Connection_Broker_FQDN = ""   # e.g. "broker.corp.local"
```

This value can also be supplied at runtime via **AWR Parameter 1** (`$ARGUMENT_1`), which takes precedence when non-empty.

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\awr-template-logfile.log
```

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string**:

```json
{
  "certfolder": "C:\\path\\to\\certs",
  "files": ["certificate.pfx"],
  "password": "pfx-password",
  "args": ["arg1", "arg2"]
}
```

The script extracts:

- **`certfolder`** + the first `.pfx`/`.p12` entry in **`files`** — full path to the PFX file
- **`password`** — PFX import password. The following field names are also accepted as fallbacks: `pfx_password`, `keystore_password`, `passphrase`
- **`args`** — up to 15 optional custom arguments from the AWR profile (`$ARGUMENT_1` … `$ARGUMENT_15`). `$ARGUMENT_1` is used as an optional Connection Broker FQDN override

## What the Script Does

### Common Steps (Always Run)

1. **Legal notice check** — exits `1` if `$LEGAL_NOTICE_ACCEPT` is not `"true"`
2. **Environment check** — exits `1` if `DC1_POST_SCRIPT_DATA` is not set
3. **Decode & parse** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload (exits `1` on failure)
4. **Extract** — pulls the arguments, `certfolder`, PFX filename, and password from the JSON
5. **Inspect** — if the PFX exists and a password is available, logs subject/issuer/thumbprint/validity/key details

### RDS Configuration Section

6. **RDS server check** — runs `Get-RDServer`. If the host is **not** an RDS server, all RDS configuration (including the RDP listener) is skipped and the script exits `0`
7. **Import** — imports the PFX into `Cert:\LocalMachine\My`, captures the thumbprint, and saves it to `certificate_thumbprint.txt` in the certificate folder
8. **Repair permissions** — runs `certutil -repairstore my <thumbprint>` to ensure private key accessibility

Steps 9–12 below run only if the import succeeded and the corresponding flag is `$true`.

### RDP Listener (When `$Install_RDP_Listener_Certificate = $true`)

- Queries `Win32_TSGeneralSetting` via WMI for the `RDP-Tcp` terminal
- Sets `SSLCertificateSHA1Hash` to the new thumbprint
- Restarts the `TermService` service (this **terminates active RDP sessions**)

### RD Publishing / Web Access / SSO (When the matching flag is `$true`)

- Imports the `RemoteDesktop` PowerShell module
- Runs `Set-RDCertificate -Role <RDPublishing | RDWebAccess | RDRedirector> -Thumbprint <thumbprint> -Force` (adding `-ConnectionBroker <FQDN>` when configured)
- Verifies the certificate was applied by reading it back with `Get-RDCertificate` and comparing thumbprints
- Note (Web Access): the IIS HTTPS binding for the RD Web Access site may also need updating separately

## Logging

All operations are logged with timestamps in the format `[yyyy-MM-dd HH:mm:ss] message`. Example:

```
[2026-07-13 10:30:01] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)
[2026-07-13 10:30:01] Legal notice accepted, proceeding with script execution.
[2026-07-13 10:30:02] PFX file exists: C:\path\to\certs\certificate.pfx
[2026-07-13 10:30:02] Certificate imported to LocalMachine\My. Thumbprint: A1B2C3D4E5...
[2026-07-13 10:30:03] certutil repair command completed
[2026-07-13 10:30:04] Updated RDP listener certificate thumbprint via WMI
[2026-07-13 10:30:05] Restarted Terminal Services (TermService)
[2026-07-13 10:30:06] Set-RDCertificate succeeded for role RDPublishing
[2026-07-13 10:30:06] Verified RDPublishing certificate is correctly applied
[2026-07-13 10:30:07] Script execution completed
```

## Error Handling

The script tracks failures in a list (`$RdsFailures`). Instead of stopping at the first problem, it records each failure, attempts the remaining roles, and then reports the true outcome at the end.

### Exit Code 1 (Hard Stops)

Emitted immediately, before the RDS section:

- `LEGAL_NOTICE_ACCEPT` is not `"true"`
- `DC1_POST_SCRIPT_DATA` is not set
- Base64 decode or JSON parse fails

### Exit Code 1 (Recorded Failures)

Any of the following are recorded and cause a **non-zero exit at the end of the run** (all failures are logged as a summary):

- PFX file not found, or no PFX password available (when the host is an RDS server)
- Certificate import into `LocalMachine\My` fails
- `certutil -repairstore` returns a non-zero exit code or cannot be launched
- RDP listener WMI update fails, or `TermService` restart fails (when enabled)
- `Set-RDCertificate` fails for Publishing, Web Access, or SSO (when enabled)
- `Get-RDCertificate` verification fails or the applied thumbprint does not match (when enabled)
- The `RemoteDesktop` module is unavailable while an RDS role is enabled

### Clean Exit (Exit Code 0)

- The host is not an RDS server (`Get-RDServer` returns nothing) — certificate steps are skipped
- All enabled steps completed without recording a failure

## Common Configuration Examples

### RDP Listener Only

```powershell
$Install_RDP_Listener_Certificate    = $true
$Install_RDS_Publishing_Certificate  = $false
$Install_RDS_WebAccess_Certificate   = $false
$Install_RDS_SSO_Certificate         = $false
```

> Note: the host must still be part of an RDS deployment (`Get-RDServer` must succeed), otherwise even the RDP listener step is skipped.

### Full RDS Deployment (Connection Broker + Web Access + SSO)

```powershell
$Install_RDP_Listener_Certificate    = $true
$Install_RDS_Publishing_Certificate  = $true
$Install_RDS_WebAccess_Certificate   = $true
$Install_RDS_SSO_Certificate         = $true
$RDS_Connection_Broker_FQDN          = "broker.corp.local"
```

### RD Web Access Only

```powershell
$Install_RDP_Listener_Certificate    = $false
$Install_RDS_Publishing_Certificate  = $false
$Install_RDS_WebAccess_Certificate   = $true
$Install_RDS_SSO_Certificate         = $false
$RDS_Connection_Broker_FQDN          = "broker.corp.local"
```

## Important Notes

- **Session disruption**: Enabling `$Install_RDP_Listener_Certificate` restarts `TermService`, which terminates all active RDP sessions. Schedule renewals accordingly.
- **RDS deployment required**: The entire RDS configuration section is gated behind `Get-RDServer`. On a host that is not part of an RDS deployment, the certificate is **not** imported or configured and the script exits `0`.
- **Connection Broker FQDN**: When set (via `$RDS_Connection_Broker_FQDN` or AWR Parameter 1), the broker must be reachable and the server must be part of the RDS deployment for the Publishing, Web Access, and SSO roles to succeed.
- **IIS binding for Web Access**: `Set-RDCertificate -Role RDWebAccess` configures the RDS role but may not update the IIS HTTPS binding. You may need a separate IIS binding update or combine this with the IIS certificate binding script.
- **Group Policy**: If GPO manages RDP certificates, the WMI-set value will be overridden on the next policy refresh.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.
