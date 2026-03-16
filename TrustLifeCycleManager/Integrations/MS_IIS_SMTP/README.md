# DigiCert TLM Agent — IIS6 SMTP Certificate Replacement (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate replacement for **IIS6 SMTP (STARTTLS)** services. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports a PFX certificate, automatically removes old certificates for the same domain, sets private key permissions for service accounts, and restarts the SMTP service.

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
    ├── Phase 1: Analyse current SMTP certificate config
    ├── Phase 2: Extract domain from new certificate
    ├── Phase 2.5: Remove old certs for same domain
    ├── Phase 3: Remove old certificate bindings
    ├── Phase 4: Import PFX into LocalMachine\My store
    ├── Phase 5: Set private key permissions (NETWORK SERVICE, IIS_IUSRS, IUSR)
    ├── Phase 6: Add new certificate bindings
    ├── Phase 7: Restart SMTP service
    ├── Phase 8: Verify certificate in store
    └── Phase 9: Test SMTP STARTTLS functionality
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile
- **IIS6 SMTP service** (`smtpsvc`) installed and running on the target host
- PFX enrollment output configured in the TLM AWR profile
- Script runs with administrative privileges (required for certificate store access, service restart, and `icacls`/`certutil` operations)

## Configuration

### Legal Notice

The script will not execute until the legal notice is accepted:

```powershell
$LEGAL_NOTICE_ACCEPT = $true  # Set to $true after reviewing the legal notice
```

### Log File

Default log path:

```
C:\Program Files\DigiCert\TLM Agent\log\smtp_cert_replacement.log
```

If the DigiCert directory is not accessible, the script falls back to `C:\smtp_cert_replacement.log`.

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

## Execution Phases

### Phase 1 — Analyse Current Configuration

Discovers the currently active SMTP SSL certificate using three methods:

1. **adsutil.vbs** — queries `smtpsvc/1/SSLCertHash` (if IIS AdminScripts are installed)
2. **netsh** — parses `http show sslcert` output for port 465 bindings
3. **Certificate store** — enumerates valid certificates with private keys in `LocalMachine\My`

### Phase 2 — Process New Certificate

Opens the PFX file to extract:

- Certificate thumbprint
- Subject CN (used as the domain identifier for old certificate cleanup)

Saves the thumbprint to `certificate_thumbprint.txt` in the certificate folder for reference.

### Phase 2.5 — Automatic Old Certificate Cleanup

Searches **eight certificate stores** for certificates matching the same domain:

| Store Location |
|---|
| `Cert:\LocalMachine\My` |
| `Cert:\LocalMachine\Root` |
| `Cert:\LocalMachine\CA` |
| `Cert:\LocalMachine\TrustedPeople` |
| `Cert:\CurrentUser\My` |
| `Cert:\CurrentUser\Root` |
| `Cert:\CurrentUser\CA` |
| `Cert:\CurrentUser\TrustedPeople` |

Matching is performed against the certificate's Subject, CN, and DNS name list. The new certificate (identified by thumbprint) is excluded from deletion.

### Phase 3 — Remove Old Bindings

Handles removal of existing `netsh http` SSL certificate bindings. The netsh operations are currently commented out and can be enabled as needed for your environment.

### Phase 4 — Import New Certificate

Uses a two-tier import approach:

1. **Primary** — `X509Certificate2` with `MachineKeySet | PersistKeySet | Exportable` flags, added directly to the `X509Store`
2. **Fallback** — `Import-PfxCertificate` cmdlet

### Phase 5 — Set Private Key Permissions

Grants private key access to service accounts required by IIS6 SMTP. Uses a multi-method, multi-account approach:

**Accounts granted access:**

- `NETWORK SERVICE`
- `IIS_IUSRS`
- `IUSR`

**Permission methods (tried in order):**

1. **WinHttpCertCfg.exe** — if the Windows Resource Kit is installed
2. **Direct file access** — locates the CNG or CSP private key file and applies `icacls` permissions
3. **certutil** — runs `certutil -repairstore` and refreshes the certificate chain cache

### Phase 6 — Add New Bindings

Configures `netsh http` SSL certificate bindings for port 465. Currently commented out — enable as needed.

### Phase 7 — Restart SMTP Service

Stops and starts `smtpsvc` with a 3-second delay between operations. Handles cases where the service is not currently running.

### Phase 8 — Verification

Confirms the certificate is present in `LocalMachine\My` and logs subject, issuer, validity dates, and private key status.

### Phase 9 — SMTP STARTTLS Test

Performs a live SMTP connection test:

1. Connects to port 25 on localhost
2. Sends `EHLO` and parses the capabilities response
3. Issues `STARTTLS` and verifies acceptance (`220` response)

## Logging

All operations — including command stdout/stderr and exit codes — are logged with timestamps. Example:

```
2025-03-16 10:30:01: Certificate Replacement Script main execution started
2025-03-16 10:30:01: PHASE 1: Analyzing current certificate configuration
2025-03-16 10:30:02: PHASE 2: Processing new certificate and extracting domain
2025-03-16 10:30:02: Retrieved new certificate thumbprint: A1B2C3D4E5...
2025-03-16 10:30:02: Extracted domain from new certificate: mail.example.com
2025-03-16 10:30:02: PHASE 2.5: Removing old certificates for domain: mail.example.com
2025-03-16 10:30:03: Found 2 old certificate(s) to delete
2025-03-16 10:30:03: PHASE 4: Importing new certificate
2025-03-16 10:30:04: Certificate imported successfully with thumbprint: A1B2C3D4E5...
2025-03-16 10:30:05: PHASE 9: Testing SMTP SSL functionality
2025-03-16 10:30:05: SUCCESS: STARTTLS is supported
```

A summary block is logged at the end of every run:

```
===============================================
CERTIFICATE REPLACEMENT SUMMARY
===============================================
Domain Processed: mail.example.com
Old Certificate Thumbprint: F6G7H8I9J0...
New Certificate Thumbprint: A1B2C3D4E5...
Old Certificate Cleanup: SUCCESS
Certificate Import: SUCCESS
Permission Setting: SUCCESS
Binding Creation: SUCCESS
Service Restart: SUCCESS
SSL Test: SUCCESS
===============================================
```

## Error Handling

The script exits with code `1` on critical failures:

- `DC1_POST_SCRIPT_DATA` cannot be decoded
- PFX file does not exist
- Invalid PFX password or corrupted file
- Certificate import fails
- Any unhandled exception in the main try/catch block

Non-critical warnings are logged but do not halt execution:

- Certificate store inaccessible during old certificate cleanup
- Permission setting failures (manual intervention noted)
- netsh binding operations (currently skipped)

## Manual Steps (If Needed)

If the SMTP service still cannot see the certificate after the script completes:

1. Restart the IIS6 SMTP service manually (`net stop smtpsvc && net start smtpsvc`)
2. Set private key permissions manually via `certmgt.msc` → right-click certificate → All Tasks → Manage Private Keys
3. Verify the certificate is in the `LocalMachine\My` store
4. Confirm the certificate subject matches the server FQDN

## Customisation

### Enabling netsh Bindings

The `Remove-OldCertificateBindings` and `Add-NewCertificateBindings` functions contain commented-out netsh operations for port 465. Uncomment the relevant sections if your environment requires explicit SSL bindings:

```powershell
# In Add-NewCertificateBindings, uncomment:
$addResult = Execute-CommandWithLogging -Command "netsh" -Arguments "http add sslcert ipport=0.0.0.0:465 certhash=$NewThumbprint appid=$appId" ...
```

### Adding Service Accounts

To grant private key access to additional accounts, add entries to the `$accountsToGrant` array:

```powershell
$accountsToGrant = @("NETWORK SERVICE", "IIS_IUSRS", "IUSR", "YOUR_SERVICE_ACCOUNT")
```

## Security Notes

- The PFX password is logged in partial form (first 2 characters and length) for debugging. Remove or disable this in production.
- The script grants `Everyone:F` access to CNG private key files — tighten this to specific service accounts for production use.
- Old certificates are permanently deleted from all searched stores. Ensure backups exist if rollback may be required.
- The decoded JSON payload is logged. Restrict log file access accordingly.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.