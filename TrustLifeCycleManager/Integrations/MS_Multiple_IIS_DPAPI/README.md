# DigiCert TLM Agent — IIS Certificate Binding, Local + Remote (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment and HTTPS binding across **local and remote IIS servers**. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate locally, binds it to configured IIS sites, then pushes the same certificate to remote servers over **WinRM** — using **DPAPI-encrypted credentials** that never exist in plaintext on disk.

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
    ├── Step 1: Load & decrypt DPAPI credentials (tlm-creds.txt)
    ├── Step 2: Decode JSON, locate PFX in .secrets directory
    ├── Step 3: Read CN and expiry from PFX
    ├── Step 4: Import PFX into local LocalMachine\My store
    ├── Step 5: Bind certificate to local IIS site(s), restart IIS, verify
    └── Step 6: For each remote server:
                ├── Establish WinRM session
                ├── Copy PFX (with size verification)
                ├── Import PFX into remote store
                ├── Bind to remote IIS site(s)
                ├── Restart remote IIS, verify bindings
                └── Clean up temp PFX, close session
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- **IIS** installed on the local server and all remote targets
- **WinRM** enabled on remote servers (`Enable-PSRemoting -Force`)
- A **domain service account** with permissions to import certificates and manage IIS on all target servers
- **DPAPI-encrypted credential file** created as SYSTEM on the TLM Agent host (see setup below)
- PowerShell `WebAdministration` module available on all servers

## Configuration

### Legal Notice

The script will not execute until the legal notice is accepted:

```powershell
$LEGAL_NOTICE_ACCEPT = $true  # Set to $true after reviewing the legal notice
```

### Local IIS Bindings

Configure the IIS sites on the local server (where the TLM Agent runs):

```powershell
$LocalSiteBindings = @{
    "Default Web Site" = 443
    # "My Custom Site" = 8443   # Add additional sites as needed
}
```

### Remote Servers

Define remote servers and their IIS site bindings:

```powershell
$RemoteServers = @(
    @{
        Server       = "web01.lab.com"
        SiteBindings = @{
            "Default Web Site" = 443
        }
    },
    @{
        Server       = "exchange1.lab.com"
        SiteBindings = @{
            "Default Web Site" = 443
            "My Custom Site"   = 8443
        }
    }
)
```

### File Paths

| Variable | Default | Description |
|---|---|---|
| `$LogFilePath` | `C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log` | Log file location |
| `$SecretsDir` | `C:\Program Files\DigiCert\TLM Agent\.secrets` | Directory where TLM Agent delivers PFX files |
| `$CredsFile` | `C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt` | DPAPI-encrypted credential file |

## One-Time Credential File Setup

The script uses **Windows DPAPI** to protect the remote service account password. The credential file must be created once as SYSTEM on the machine where the TLM Agent runs.

### How DPAPI Protection Works

DPAPI encrypts using AES-256 with a key derived from three factors:

1. The identity of the SYSTEM account on the machine
2. The machine's unique LSA (Local Security Authority) secret (TPM-backed if available)
3. A random entropy value generated at encryption time

This means the encrypted blob **cannot be decrypted on any other machine**, under any other account, or brute-forced without the machine's LSA secret. The plaintext password never exists on disk.

### Step 1 — Create the Encrypted Credential File

Run this as Administrator. Update `$domain`, `$username`, and `$password` with your values:

```powershell
$domain   = "LAB"
$username = "PKIAdmin"
$password = "YourPasswordHere"

$cmd = @"
`$securePass = ConvertTo-SecureString -String '$password' -Force -AsPlainText
`$encrypted  = ConvertFrom-SecureString -SecureString `$securePass
`$outPath    = 'C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt'
Set-Content -Path `$outPath -Value '${domain}\${username}|' -NoNewline
Add-Content -Path `$outPath -Value `$encrypted
"@

$action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"$cmd`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet
Register-ScheduledTask -TaskName "CreateTLMCreds" -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force
Start-Sleep -Seconds 20
Unregister-ScheduledTask -TaskName "CreateTLMCreds" -Confirm:$false
```

### Step 2 — Verify the File

```powershell
Get-Content "C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt"
# Expected: LAB\PKIAdmin|01000000d08c9ddf0115d1118c7a00c04...
# If you see your plaintext password, redo Step 1.
```

### Step 3 — Lock File Permissions

```powershell
$credsPath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt"
$acl = Get-Acl $credsPath
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "SYSTEM","FullControl","Allow")))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators","FullControl","Allow")))
Set-Acl -Path $credsPath -AclObject $acl
```

### Step 4 — Password Rotation

Re-run Step 1 with the new password. The new encrypted blob overwrites the old one — no script changes needed.

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

The script extracts `files[0]` (PFX filename) and `password`. Rather than using `certfolder` directly, it searches `$SecretsDir` recursively for the PFX filename, as the TLM Agent delivers files into timestamped subfolders (e.g. `.secrets\iis4servers.lab.com_pfx_2026_03_13_14_40_56\iis4servers.lab.com.pfx`).

## Execution Steps

### Step 1 — Load Credentials

Reads `tlm-creds.txt`, splits into `DOMAIN\Username` and the DPAPI-encrypted blob, decrypts the blob into a `PSCredential` object. Fails fast if the file is missing, malformed, or was encrypted under a different account/machine.

### Step 2 — Decode and Locate PFX

Decodes `DC1_POST_SCRIPT_DATA`, extracts the PFX filename, and searches `$SecretsDir` recursively. Uses the most recently created match (sorted by `CreationTime` descending).

### Step 3 — Read Certificate Metadata

Opens the PFX to extract the CN (Common Name) and expiry date. Falls back to the PFX filename if the certificate cannot be read.

### Step 4 — Local Import

Imports the PFX into `Cert:\LocalMachine\My` with the `-Exportable` flag (required for WinRM push to remote servers).

### Step 5 — Local IIS Binding

For each entry in `$LocalSiteBindings`:

1. Checks the IIS site exists
2. Looks for an existing HTTPS binding on the configured port
3. Creates the binding if it doesn't exist
4. Binds the certificate using `AddSslCertificate()`
5. Runs `iisreset /restart /noforce`
6. Verifies the binding via `netsh http show sslcert`

### Step 6 — Remote Server Deployment

For each entry in `$RemoteServers`:

1. Establishes a WinRM session using the DPAPI credentials
2. Copies the PFX to `C:\Windows\Temp\` on the remote server
3. Verifies the file size matches the local copy
4. Executes a remote script block that imports the PFX, binds IIS sites, restarts IIS, and verifies bindings
5. Deletes the temporary PFX from the remote server
6. Closes the WinRM session

If a remote server fails, the script logs the error and **continues to the next server** — one failure does not block the rest.

## Logging

All operations are logged with timestamps to:

```
C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log
```

Example output:

```
2025-03-16 10:30:01 : DigiCert TLM Post-Script starting...
2025-03-16 10:30:01 : Remote credentials loaded and decrypted for account: LAB\PKIAdmin
2025-03-16 10:30:02 : PFX found   : C:\...\iis4servers.lab.com.pfx
2025-03-16 10:30:02 : Certificate CN      : iis4servers.lab.com
2025-03-16 10:30:02 : Certificate imported locally. Thumbprint: A1B2C3D4E5...
2025-03-16 10:30:03 : LOCAL: 'Default Web Site':443 bound to thumbprint A1B2C3D4E5...
2025-03-16 10:30:04 : VERIFIED [LOCAL]: 'Default Web Site':443 is using the correct certificate.
2025-03-16 10:30:05 : --- Connecting to remote server: web01.lab.com ---
2025-03-16 10:30:05 : [web01.lab.com] WinRM session established.
2025-03-16 10:30:06 : [web01.lab.com] PFX size check - local=3456 bytes, remote=3456 bytes.
2025-03-16 10:30:07 : VERIFIED [web01.lab.com]: 'Default Web Site':443 is using the correct certificate.
2025-03-16 10:30:07 : [web01.lab.com] Temp PFX removed.
2025-03-16 10:30:08 : COMPLETE: Certificate replacement finished. CN=iis4servers.lab.com Thumbprint=A1B2C3D4E5...
```

## Error Handling

| Scenario | Behaviour |
|---|---|
| Legal notice not accepted | Exits with code `1` |
| Credential file missing or malformed | Exits with code `1` |
| DPAPI decryption fails (wrong account/machine) | Exits with code `1` |
| `DC1_POST_SCRIPT_DATA` empty or decode fails | Exits with code `1` |
| PFX not found in `.secrets` | Exits with code `1` |
| Local PFX import fails | Exits with code `1` |
| Local IIS binding fails | Exits with code `1` |
| Local `iisreset` fails | Warning logged, continues |
| Remote WinRM connection fails | Error logged, **skips to next server** |
| Remote PFX size mismatch | Error logged, skips server |
| Remote IIS site not found | Warning logged, skips site |
| Remote binding verification mismatch | Warning logged |

## Security Model

### Credential Protection (DPAPI)

```
Password (in memory only, never written to disk)
    │
    ▼  ConvertFrom-SecureString — DPAPI AES-256 encrypt
Encrypted blob ──→ tlm-creds.txt (safe on disk)

tlm-creds.txt (encrypted blob)
    │
    ▼  ConvertTo-SecureString — DPAPI AES-256 decrypt
SecureString in memory ──→ PSCredential ──→ New-PSSession
    (never written to disk or log)
```

### Key Security Properties

- The encrypted blob **cannot be decrypted on any other machine** (bound to the machine's LSA secret)
- The encrypted blob **cannot be decrypted under any other account** (bound to SYSTEM identity)
- The plaintext password **never exists on disk** at any point
- The credential file should be locked to SYSTEM and Administrators only (see setup Step 3)
- Temporary PFX files on remote servers are **deleted after import**
- Remote PFX integrity is **verified by file size comparison** before import

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.