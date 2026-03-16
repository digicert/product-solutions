# DigiCert TLM – Sophos Firewall Certificate Upload

Automated certificate deployment to Sophos Firewall appliances using DigiCert Trust Lifecycle Manager (TLM) Agent AWR (Admin Web Request) post-enrollment scripts.

When the TLM Agent enrols or renews a certificate, this script automatically uploads the certificate and private key to the Sophos Firewall via its XML API. Firewall credentials are stored securely using the PowerShell `SecretManagement` / `SecretStore` modules — no passwords are passed as AWR arguments or stored in the script.

## Architecture

```
┌──────────────────────┐         ┌──────────────────────┐
│   DigiCert TLM       │         │                      │
│   ┌────────────────┐ │  HTTPS  │   Sophos Firewall    │
│   │  TLM Agent     │ │───────▶ │                      │
│   │  + AWR Script  │ │  XML    │   /webconsole/       │
│   └────────────────┘ │  API    │   APIController      │
│   Windows Server     │         │                      │
└──────────────────────┘         └──────────────────────┘
```

## What It Does

- Reads the certificate (.crt) and private key (.key) files delivered by the TLM Agent
- Retrieves the Sophos admin password from the Windows SecretStore vault
- Constructs an XML API request with the `UploadCertificate` action
- Sends the certificate and key as a multipart form POST to the Sophos API endpoint
- Validates the API response (authentication status and certificate upload status)
- Logs all steps with optional `DEBUG` mode for detailed multipart inspection

## AWR Arguments

Configure these in the DigiCert TLM certificate profile under **Post-Enrollment Script**:

| Argument | Purpose | Example |
|----------|---------|---------|
| 1 | Sophos admin username | `admin` |
| 2 | SecretStore vault name | `SophosVault` |
| 3 | Firewall FQDN or IP | `fw.example.com` |
| 4 | Firewall admin HTTPS port | `4443` |
| 5 | Debug mode (optional) | `DEBUG` |

## Prerequisites

### PowerShell SecretStore Setup

The TLM Agent runs as the **SYSTEM account**, so the SecretStore modules must be installed and the secret created in a SYSTEM-level PowerShell session. Use `psexec` to get there:

```powershell
# Open a SYSTEM PowerShell session
psexec -i -s powershell.exe

# Verify you are SYSTEM
whoami   # → nt authority\system

# Install the modules
Install-Module Microsoft.PowerShell.SecretManagement -Scope AllUsers -Force
Install-Module Microsoft.PowerShell.SecretStore -Scope AllUsers -Force
Import-Module Microsoft.PowerShell.SecretManagement
Import-Module Microsoft.PowerShell.SecretStore

# Disable interactive authentication (required for unattended use)
Set-SecretStoreConfiguration -Authentication None -Interaction None -Confirm:$false

# Register a vault
Register-SecretVault -Name SophosVault -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault

# Store the password
# Secret name format: <username>:<host>:<port>
Set-Secret -Name "admin:fw.example.com:4443" `
    -Secret (Read-Host "Enter Sophos User Password" -AsSecureString) `
    -Vault SophosVault
```

The secret name is constructed automatically by the script from Arguments 1, 3, and 4 in the format `username:host:port`. If you change the firewall host, port, or username, create a new secret with the matching name.

### Other Requirements

- DigiCert TLM Agent installed and enrolled on the Windows server
- Network access from the TLM Agent host to the Sophos Firewall admin port (HTTPS)
- Sophos Firewall API enabled
- PowerShell 5.1 or later

## Workflow

```
Certificate Renewal Triggered (TLM)
        │
        ▼
TLM Agent delivers .crt + .key files
        │
        ▼
AWR script executes (windows-sophos_firewall-awr.ps1)
        │
        ├── 1. Decode DC1_POST_SCRIPT_DATA, extract cert/key paths
        ├── 2. Validate certificate and key files exist
        ├── 3. Load SecretManagement modules
        ├── 4. Retrieve admin password from SecretStore vault
        ├── 5. Build XML API payload (UploadCertificate action)
        ├── 6. Construct multipart form (XML + cert file + key file)
        ├── 7. POST to https://<host>:<port>/webconsole/APIController
        └── 8. Validate API response (auth status + upload status)
```

## Logging

Each execution creates a timestamped log file and a PowerShell transcript:

```
C:\Program Files\DigiCert\TLM Agent\log\DigiCert-AWR-SophosCertUpload_<timestamp>.log
C:\Program Files\DigiCert\TLM Agent\log\DigiCert-AWR-SophosCertUpload_<timestamp>.log.transcript.txt
```

Set **Argument 5** to `DEBUG` to enable verbose logging of the multipart request structure and XML payload (password is automatically redacted in debug output).

## Configuration

Before first use, update the `$LEGAL_NOTICE_ACCEPT` variable in the script from `"false"` to `"true"` to acknowledge the DigiCert legal notice.

```powershell
$LEGAL_NOTICE_ACCEPT = "true"
```

## TLM Profile Setup

1. In DigiCert TLM, navigate to the certificate profile for the Sophos Firewall certificate
2. Under **Post-Enrollment Script**, select `windows-sophos_firewall-awr.ps1`
3. Set Arguments 1–4 (and optionally 5) as documented above
4. Enrol or renew the certificate to trigger the script

## Troubleshooting

**Vault or secret not found** — Ensure the SecretStore modules were installed and the secret was created under the SYSTEM account, not your admin user account. Open a SYSTEM shell with `psexec -i -s powershell.exe` and verify with `Get-Secret -Name "admin:host:port" -Vault SophosVault -AsPlainText`.

**Authentication failed** — Verify the username (Argument 1) matches the Sophos admin account, and the secret name format matches `username:host:port` exactly. Check for trailing whitespace in the AWR arguments.

**HTTP request failed** — Check network connectivity from the TLM Agent host to the firewall admin port. The script enforces TLS 1.2. Ensure the Sophos API is enabled on the firewall.

**Legal notice error** — Set `$LEGAL_NOTICE_ACCEPT = "true"` in the script configuration section.

**Debug mode** — Set Argument 5 to `DEBUG` for detailed logging of the multipart request parts and the XML payload (with the password redacted).

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice in the script header for full terms.