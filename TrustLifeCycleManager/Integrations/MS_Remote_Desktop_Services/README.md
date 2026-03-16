# DigiCert TLM Agent — RDP & Remote Desktop Services Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment across **RDP listener**, **RD Connection Broker Publishing**, and **RD Web Access** roles. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate and selectively configures it for whichever Remote Desktop Services roles are enabled.

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
    ├── Decode JSON, extract PFX path + password
    ├── Read thumbprint, save to file
    ├── Import PFX into LocalMachine\My store
    ├── Repair private key permissions (certutil)
    ├── (Optional) Set RDP listener certificate via WMI
    ├── (Optional) Set RD Publishing certificate via Set-RDCertificate
    └── (Optional) Set RD Web Access certificate via Set-RDCertificate
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- Script runs with administrative privileges
- For RDP listener: **Remote Desktop Services** enabled on the target server
- For RD Publishing / Web Access: **RemoteDesktop** PowerShell module installed (part of the RDS role), and the server must be part of an RDS deployment
- PFX enrollment output configured in the TLM AWR profile

## Configuration

### Legal Notice

```powershell
$legal_notice_accept = $true  # Set to $true after reviewing the legal notice
```

### Service Role Flags

Enable the roles that should receive the deployed certificate:

| Variable | Default | Description |
|---|---|---|
| `$Install_RDP_Listener_Certificate` | `$false` | Configure the RDP-Tcp listener certificate via WMI (`Win32_TSGeneralSetting`) and restart Terminal Services |
| `$Install_RDS_Publishing_Certificate` | `$false` | Set the RD Connection Broker Publishing certificate via `Set-RDCertificate -Role RDPublishing` |
| `$Install_RDS_WebAccess_Certificate` | `$false` | Set the RD Web Access certificate via `Set-RDCertificate -Role RDWebAccess` |

If **all three flags are `$false`**, the certificate is imported into the store but no RDP/RDS configuration is performed, and the script exits cleanly.

### RDS Connection Broker

Required for the Publishing and Web Access roles:

```powershell
$RDS_Connection_Broker_FQDN = "rdp.rds.local"  # Your RD Connection Broker FQDN
```

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\rdp.log
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

- **`certfolder`** + **`files[0]`** — full path to the PFX file
- **`password`** — PFX import password
- **`args`** — optional custom arguments from the AWR profile

## What the Script Does

### Common Steps (Always Run)

1. **Legal notice check** — exits if `$legal_notice_accept` is not `$true`
2. **Decode** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload
3. **Validate** — confirms the PFX file exists at the expected path
4. **Extract thumbprint** — opens the PFX to read the thumbprint, saves it to `certificate_thumbprint.txt` in the certificate folder
5. **Import** — imports the PFX into `Cert:\LocalMachine\My`
6. **Check flags** — if all three role flags are `$false`, exits cleanly (certificate is in the store but no services are configured)
7. **Repair permissions** — runs `certutil -repairstore my <thumbprint>` to ensure private key accessibility

### RDP Listener (When `$Install_RDP_Listener_Certificate = $true`)

- Queries `Win32_TSGeneralSetting` via WMI for the `RDP-Tcp` terminal
- Sets `SSLCertificateSHA1Hash` to the new thumbprint
- Restarts the `TermService` service (this **terminates active RDP sessions**)

### RD Publishing (When `$Install_RDS_Publishing_Certificate = $true`)

- Imports the `RemoteDesktop` PowerShell module
- Runs `Set-RDCertificate -Role RDPublishing -Thumbprint <thumbprint> -ConnectionBroker <FQDN> -Force`
- Verifies the certificate was applied by reading it back with `Get-RDCertificate`
- Non-fatal if the module is unavailable or the server isn't part of an RDS deployment

### RD Web Access (When `$Install_RDS_WebAccess_Certificate = $true`)

- Imports the `RemoteDesktop` PowerShell module
- Runs `Set-RDCertificate -Role RDWebAccess -Thumbprint <thumbprint> -ConnectionBroker <FQDN> -Force`
- Verifies the certificate was applied by reading it back with `Get-RDCertificate`
- Non-fatal if the module is unavailable or the RD Web Access role is not installed
- Note: the IIS HTTPS binding for the RD Web Access site may also need updating separately

## Logging

All operations are logged with timestamps. Example:

```
2025-03-16 10:30:01: Script execution started
2025-03-16 10:30:01: Legal notice accepted - proceeding with script execution
2025-03-16 10:30:02: PFX file exists
2025-03-16 10:30:02: Retrieved certificate thumbprint: A1B2C3D4E5...
2025-03-16 10:30:02: Certificate imported successfully
2025-03-16 10:30:03: Successfully ran certutil repair command
2025-03-16 10:30:03: Install_RDP_Listener_Certificate is set to true - configuring RDP listener
2025-03-16 10:30:04: Successfully updated RDP listener certificate thumbprint via WMI
2025-03-16 10:30:05: Successfully restarted the Terminal Services service
2025-03-16 10:30:05: Install_RDS_Publishing_Certificate is set to true - configuring RDS Publishing certificate
2025-03-16 10:30:06: Successfully set RD Connection Broker Publishing certificate
2025-03-16 10:30:06: Verified RD Publishing certificate is correctly applied
2025-03-16 10:30:06: Script execution completed successfully
```

## Error Handling

### Critical Failures (Exit Code 1)

- `DC1_POST_SCRIPT_DATA` decode fails
- PFX file does not exist
- Certificate import fails
- `certutil -repairstore` fails
- RDP listener WMI update fails (when enabled)
- Terminal Services restart fails (when enabled)

### Non-Fatal Warnings (Logged, Execution Continues)

- `RemoteDesktop` module not available — skips RD Publishing / Web Access configuration
- `Set-RDCertificate` fails for Publishing or Web Access — logged as error but does not halt the script (the server may not be part of an RDS deployment)
- Thumbprint verification mismatch after `Set-RDCertificate` — logged as warning

### Clean Exit (Exit Code 0)

- Legal notice not accepted
- All three role flags set to `$false` (certificate imported but no services configured)

## Common Configuration Examples

### Standalone RDP Server

```powershell
$Install_RDP_Listener_Certificate    = $true
$Install_RDS_Publishing_Certificate  = $false
$Install_RDS_WebAccess_Certificate   = $false
```

### Full RDS Deployment (Connection Broker + Web Access)

```powershell
$Install_RDP_Listener_Certificate    = $true
$Install_RDS_Publishing_Certificate  = $true
$Install_RDS_WebAccess_Certificate   = $true
$RDS_Connection_Broker_FQDN         = "broker.corp.local"
```

### RD Web Access Only

```powershell
$Install_RDP_Listener_Certificate    = $false
$Install_RDS_Publishing_Certificate  = $false
$Install_RDS_WebAccess_Certificate   = $true
$RDS_Connection_Broker_FQDN         = "broker.corp.local"
```

## Important Notes

- **Session disruption**: Enabling `$Install_RDP_Listener_Certificate` restarts `TermService`, which terminates all active RDP sessions. Schedule renewals accordingly.
- **IIS binding for Web Access**: `Set-RDCertificate -Role RDWebAccess` configures the RDS role but may not update the IIS HTTPS binding. You may need a separate IIS binding update or combine this with the IIS certificate binding script.
- **Connection Broker FQDN**: The `$RDS_Connection_Broker_FQDN` must be reachable and the server must be part of the RDS deployment for Publishing and Web Access roles to succeed.
- **Group Policy**: If GPO manages RDP certificates, the WMI-set value will be overridden on the next policy refresh.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.