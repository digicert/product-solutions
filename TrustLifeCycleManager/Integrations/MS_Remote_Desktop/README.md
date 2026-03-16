# DigiCert TLM Agent — RDP Certificate Replacement (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate replacement for **Remote Desktop Protocol (RDP)** listeners. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate into the local machine store, repairs private key permissions, sets the certificate on the RDP-Tcp listener via WMI, and restarts Terminal Services.

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
    ├── Step 1: Decode JSON, extract PFX path + password
    ├── Step 2: Read thumbprint from PFX, save to file
    ├── Step 3: Import PFX into LocalMachine\My store
    ├── Step 4: Repair private key permissions (certutil)
    ├── Step 5: Set RDP listener certificate via WMI
    └── Step 6: Restart Terminal Services
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- **Remote Desktop Services** role enabled on the target server
- Script runs with administrative privileges (required for certificate store access, WMI operations, and service restart)

## Configuration

### Legal Notice

The script will not execute until the legal notice is accepted:

```powershell
$LEGAL_NOTICE_ACCEPT = $true  # Set to $true after reviewing the legal notice
```

### Log File

Default log path:

```
C:\CertificateImport.log
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

- **`certfolder`** + **`files[0]`** — combined to build the full path to the PFX file
- **`password`** — PFX import password
- **`args`** — optional custom arguments from the AWR profile

## Execution Steps

### Step 1 — Extract Thumbprint

Opens the PFX using `X509Certificate2` to extract the certificate thumbprint before importing into the store. The thumbprint is saved to `certificate_thumbprint.txt` in the certificate folder for reference or use by other scripts.

### Step 2 — Import Certificate

Imports the PFX into `Cert:\LocalMachine\My` using `Import-PfxCertificate`. Validates that the import returns a certificate object.

### Step 3 — Repair Private Key Permissions

Runs `certutil -repairstore my <thumbprint>` to ensure the private key has correct permissions and is accessible by system services. This is critical for RDP — the Terminal Services process needs read access to the private key.

### Step 4 — Set RDP Listener Certificate

Uses WMI to update the RDP-Tcp listener's SSL certificate:

```
Root\CIMv2\TerminalServices → Win32_TSGeneralSetting → SSLCertificateSHA1Hash
```

The `Win32_TSGeneralSetting` WMI class is filtered by `TerminalName='RDP-Tcp'` (the default RDP listener). The thumbprint is written to the `SSLCertificateSHA1Hash` property and committed via `.Put()`.

### Step 5 — Restart Terminal Services

Restarts the `TermService` service with `-Force` to apply the new certificate. Active RDP sessions will be terminated during the restart.

## Logging

All operations are logged with timestamps to `C:\CertificateImport.log`. Example:

```
2025-03-16 10:30:01: Script execution started
2025-03-16 10:30:01: Legal notice accepted - proceeding with script execution
2025-03-16 10:30:01: Retrieved environment variable DC1_POST_SCRIPT_DATA
2025-03-16 10:30:01: Decoded base64 string successfully
2025-03-16 10:30:02: PFX file exists
2025-03-16 10:30:02: Retrieved certificate thumbprint: A1B2C3D4E5...
2025-03-16 10:30:02: Saved thumbprint to file: C:\certs\certificate_thumbprint.txt
2025-03-16 10:30:03: Certificate imported successfully
2025-03-16 10:30:03: Successfully ran certutil repair command
2025-03-16 10:30:04: Successfully updated certificate thumbprint via WMI
2025-03-16 10:30:05: Successfully restarted the Terminal Services service
2025-03-16 10:30:05: Script execution completed successfully
```

## Error Handling

The script exits with code `1` on any critical failure. All steps are wrapped in try/catch blocks — a failure at any stage halts execution:

| Scenario | Behaviour |
|---|---|
| Legal notice not accepted | Exits with code `1` |
| `DC1_POST_SCRIPT_DATA` decode fails | Exits with code `1` |
| PFX file does not exist | Exits with code `1` |
| Invalid PFX password or corrupted file | Exits with code `1`, specific `CryptographicException` logged |
| Certificate import fails | Exits with code `1` |
| `certutil -repairstore` fails | Exits with code `1` |
| WMI `Win32_TSGeneralSetting` not found | Exits with code `1` (RDP may not be configured) |
| WMI thumbprint update fails | Exits with code `1` |
| Terminal Services restart fails | Exits with code `1` |

## Important Notes

### Session Disruption

Restarting `TermService` **terminates all active RDP sessions**. Schedule certificate renewals during maintenance windows, or warn connected users in advance.

### Certificate Requirements for RDP

The certificate must meet these requirements to work with RDP:

- Must have a private key
- Must be in `Cert:\LocalMachine\My` (Personal store)
- Enhanced Key Usage must include Server Authentication (`1.3.6.1.5.5.7.3.1`)
- Subject or SAN should match the server's FQDN for clients to trust the connection without warnings

### WMI vs Group Policy

This script sets the RDP certificate via WMI (`Win32_TSGeneralSetting`). If your environment uses **Group Policy** to configure RDP certificates (Computer Configuration → Administrative Templates → Remote Desktop Services → Security), the GPO setting will override the WMI value on the next policy refresh. In GPO-managed environments, consider updating the certificate thumbprint in the registry directly at:

```
HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services\SSLCertificateSHA1Hash
```

## Security Notes

- The PFX password is logged in partial form (first 2 characters and length) for debugging. Remove or disable this in production.
- The thumbprint is saved to `certificate_thumbprint.txt` in the certificate folder — ensure this location has appropriate access controls.
- `certutil -repairstore` runs via `cmd.exe` — the command is not logged to the standard log by the child process.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.