# DigiCert TLM Agent — SQL Server TLS Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates TLS certificate deployment to **Microsoft SQL Server**. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate, grants the SQL Server service account read access to the private key, writes the thumbprint to the SQL Server registry, and restarts the service to enable encrypted connections.

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
    ├── Import PFX into LocalMachine\My store
    ├── Extract thumbprint (lowercase)
    ├── Locate private key container file via certutil
    ├── Grant SQL Server service account read access to key file
    ├── Write thumbprint to SQL Server SuperSocketNetLib registry
    └── Restart SQL Server service
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- **Microsoft SQL Server** installed on the target host
- Script runs with administrative privileges (required for certificate import, ACL changes, registry writes, and service restart)
- The certificate must meet SQL Server's requirements: RSA key, placed in `LocalMachine\My`, with Server Authentication EKU

## Configuration

### Legal Notice

```powershell
$LEGAL_NOTICE_ACCEPT = $true  # Set to $true after reviewing the legal notice
```

### SQL Server Settings

Adjust these variables to match your SQL Server instance:

| Variable | Default | Description |
|---|---|---|
| `$SqlRegistryPath` | `HKLM:\...\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib` | Registry path for the SQL Server instance's network configuration |
| `$SqlServiceName` | `MSSQLSERVER` | SQL Server Windows service name |
| `$SqlServiceAccount` | `NT Service\MSSQLSERVER` | Service account that needs private key read access |

### Registry Path by SQL Server Version

| SQL Server Version | Registry Key Prefix |
|---|---|
| SQL Server 2019 | `MSSQL15` |
| SQL Server 2022 | `MSSQL16` |
| SQL Server 2017 | `MSSQL14` |
| SQL Server 2016 | `MSSQL13` |

For **named instances**, replace `MSSQLSERVER` with the instance name in both the registry path and the service name (e.g. `MSSQL15.MYINSTANCE` and `MSSQL$MYINSTANCE`).

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\sqlserver_cert.log
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

## Execution Steps

### Step 1 — Import Certificate

Imports the PFX into `Cert:\LocalMachine\My` and extracts the thumbprint. The thumbprint is **converted to lowercase** — SQL Server requires the lowercase form in the registry.

### Step 2 — Locate Private Key File

Runs `certutil -store my <thumbprint>` and parses the output to find the **Unique container name**. This maps to a file under:

```
C:\ProgramData\Microsoft\Crypto\Keys\<unique-container-name>
```

### Step 3 — Grant Private Key Permissions

Adds a **Read** ACL entry for the SQL Server service account on the private key file. Without this, SQL Server cannot access the private key and TLS connections will fail with errors like:

```
A connection was successfully established with the server, but then an error occurred
during the pre-login handshake. (provider: SSL Provider, error: 0)
```

### Step 4 — Configure Registry

Writes the lowercase thumbprint to the SQL Server `SuperSocketNetLib` registry key:

```
HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\<version.instance>\MSSQLServer\SuperSocketNetLib
    Certificate = <thumbprint>
```

This is the equivalent of configuring the certificate through SQL Server Configuration Manager.

### Step 5 — Restart SQL Server

Restarts the SQL Server service (`Restart-Service -Force`) to apply the new certificate. Active connections will be dropped during the restart.

## Logging

All operations are logged with timestamps. Example:

```
2025-03-16 10:30:01: Script execution started
2025-03-16 10:30:01: Legal notice accepted - proceeding with script execution
2025-03-16 10:30:02: PFX file exists
2025-03-16 10:30:02: Certificate imported successfully
2025-03-16 10:30:02: Certificate thumbprint (lowercase): a1b2c3d4e5f6...
2025-03-16 10:30:02: Unique container name: abc123def456...
2025-03-16 10:30:02: Key file found at: C:\ProgramData\Microsoft\Crypto\Keys\abc123def456...
2025-03-16 10:30:03: Read permissions added for NT Service\MSSQLSERVER to the key file
2025-03-16 10:30:03: Successfully configured SQL Server registry with thumbprint: a1b2c3d4e5f6...
2025-03-16 10:30:05: MSSQLSERVER service restarted successfully
2025-03-16 10:30:05: Script execution completed successfully
```

## Error Handling

The script exits with code `1` on any failure — every step is critical for a working TLS configuration:

| Scenario | Behaviour |
|---|---|
| Legal notice not accepted | Exits with code `1` |
| PFX file does not exist | Exits with code `1` |
| Certificate import fails | Exits with code `1` |
| Unique container name not found in certutil output | Exits with code `1` |
| Private key file not found at expected path | Exits with code `1` |
| Registry path does not exist (wrong version/instance) | Exits with code `1` |
| Registry write fails | Exits with code `1` |
| SQL Server service restart fails | Exits with code `1` |

## Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| Registry path does not exist | Wrong SQL Server version or instance name in `$SqlRegistryPath` | Check `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server` for the correct version prefix and instance name |
| Key file not found under `Crypto\Keys` | Certificate uses CNG key storage instead of CSP | CNG keys are stored under `C:\ProgramData\Microsoft\Crypto\Keys` (same path) but may have a different container name format — verify with `certutil -store my <thumbprint>` |
| SQL Server won't start after cert change | Certificate doesn't meet SQL Server requirements | Ensure the cert has an RSA private key, Server Authentication EKU (`1.3.6.1.5.5.7.3.1`), and the CN or SAN matches the server FQDN |
| TLS connection fails after restart | Service account can't read private key | Verify ACLs on the key file with `icacls` and confirm `$SqlServiceAccount` matches the actual service account |
| Named instance not picking up cert | Service name or registry path mismatch | For named instances, use `MSSQL$InstanceName` as the service name and `MSSQLxx.INSTANCENAME` in the registry path |

## Important Notes

- **Service disruption**: Restarting SQL Server drops all active connections. Schedule certificate renewals during maintenance windows.
- **Lowercase thumbprint**: SQL Server requires the thumbprint in lowercase in the registry. The script handles this automatically via `.ToLower()`.
- **SQL Server Agent**: The script only restarts the SQL Server engine service. If SQL Server Agent or other dependent services need restarting, add them to the script or handle them separately.
- **Always On / Failover Clusters**: In HA environments, coordinate certificate deployment across all nodes. Consider running this script on each node with staggered restarts.
- **Force Encryption**: This script configures the certificate but does not enable the "Force Encryption" flag. To require TLS for all connections, also set `ForceEncryption = 1` in the same registry path or via SQL Server Configuration Manager.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.