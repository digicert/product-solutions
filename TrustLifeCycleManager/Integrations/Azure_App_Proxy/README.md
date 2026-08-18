# DigiCert TLM Agent – Azure App Proxy Certificate Automation

Automate SSL/TLS certificate lifecycle management for Microsoft Entra (Azure AD) Application Proxy using DigiCert Trust Lifecycle Manager (TLM).

## Overview

This repository contains two PowerShell AWR post-enrollment scripts. Both automate certificate deployment to Azure App Proxy after the TLM Agent completes enrollment; they differ only in the Microsoft API they use to interact with Entra ID:

| Script | API Used | When to Use |
|--------|----------|-------------|
| `azure-app-proxy-awr-azure-ad-module.ps1` | **AzureAD PowerShell module** (legacy) | Existing environments already using the AzureAD module; certificate-based service principal auth. |
| `azure-app-proxy-awr-azure-microsoft-graph.ps1` | **Microsoft Graph** (current) | New deployments or environments migrating away from the deprecated AzureAD module; client-secret or certificate-based auth. |

> **Note:** Microsoft has deprecated the AzureAD PowerShell module. New deployments should use the Microsoft Graph script.

## How It Works

Both scripts follow the same overall workflow:

1. Read certificate data from the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON set by the TLM Agent).
2. Decode the JSON payload and extract the PFX file path and password.
3. Validate the PFX file and log certificate details (subject, issuer, thumbprint, validity dates).
4. Authenticate to Entra ID / Microsoft Graph.
5. Upload the PFX to the target App Proxy application.
6. Verify the upload by querying the App Proxy certificate metadata and comparing thumbprints.

### AzureAD Module Script (`azure-app-proxy-awr-azure-ad-module.ps1`)

- Authenticates using `Connect-AzureAD` with certificate-based service principal auth (`-CertificateThumbprint`).
- Uploads via `Set-AzureADApplicationProxyApplicationCustomDomainCertificate`.
- Verifies via `Get-AzureADApplicationProxyApplication`.
- Log location: `C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log`

### Microsoft Graph Script (`azure-app-proxy-awr-azure-microsoft-graph.ps1`)

- Authenticates using `Connect-MgGraph` with a client-secret credential (certificate-based auth is also supported — see the configuration comments).
- Uploads via `Invoke-MgGraphRequest PATCH` against the `beta/applications/{id}` endpoint (the `onPremisesPublishing` property is beta-only).
- Verifies via `Invoke-MgGraphRequest GET` against the `beta/applications/{id}/onPremisesPublishing` endpoint.
- Includes a **dry-run mode** (`$DRY_RUN = "true"`) that logs all intended Graph operations without executing them.
- Log location: `C:\Certs\azure-app-proxy.log`

## Prerequisites

- **PowerShell 5.1+** (Windows)
- **Azure AD App Registration** with:
  - API permissions for Application Proxy management granted with admin consent
  - The Object ID of the target App Proxy application

### AzureAD Module Script

- `AzureAD` PowerShell module — `Install-Module AzureAD`
- A client certificate installed on the machine, referenced by thumbprint for service principal auth
- `Application.ReadWrite.All` API permission (or equivalent)

### Microsoft Graph Script

- `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications` modules — `Install-Module Microsoft.Graph -Scope AllUsers`
  - Install with `-Scope AllUsers` so the modules are visible to the LocalSystem account (or whichever account runs the TLM Agent service)
- A client secret **or** client certificate configured for the app registration
- `Application.ReadWrite.All` API permission (or equivalent)

## Configuration

### AzureAD Module Script

Edit the configuration block at the top of `azure-app-proxy-awr-azure-ad-module.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT   = "true"                    # Accept the legal notice to enable execution
$AZURE_TENANT_ID       = "< Azure Tenant ID >"
$AZURE_CLIENT_ID       = "< Azure Client ID >"
$AZURE_CERT_THUMBPRINT = "< Azure Certificate Thumbprint >"
$APP_PROXY_OBJECT_ID   = "< Azure App Proxy Object ID >"
```

### Microsoft Graph Script

Edit the configuration block at the top of `azure-app-proxy-awr-azure-microsoft-graph.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT    = "true"                    # Accept the legal notice to enable execution
$DRY_RUN                = "false"                   # Set "true" to preview Graph operations without executing them
$AZURE_TENANT_ID        = "< Azure Tenant ID >"
$AZURE_CONNECTION_APPID = "< Azure Client ID >"
$AZURE_CLIENT_SECRET    = "< Azure Client Secret >"
$APP_PROXY_OBJECT_ID    = "< Azure App Proxy Object ID >"
```

> **Important:** Both scripts include a legal notice gate. You must set `$LEGAL_NOTICE_ACCEPT = "true"` before the script will execute.

## Usage

Configure either script as a post-enrollment script in your TLM Agent AWR profile. The TLM Agent will invoke it automatically after each certificate enrollment or renewal, passing certificate data via the `DC1_POST_SCRIPT_DATA` environment variable.

> **Do NOT add a `param()` block** to these scripts. The TLM Agent does not pass named PowerShell parameters; a `[Parameter(Mandatory)]` declaration will cause the agent run to fail or hang during parameter binding before any log line is written.

## Architecture

```
┌──────────────────────┐
│   DigiCert TLM       │
│   (Certificate       │
│    Authority)        │
└─────────┬────────────┘
          │ Enroll / Renew
          ▼
┌──────────────────────┐     DC1_POST_SCRIPT_DATA     ┌────────────────────────────────────┐
│   DigiCert TLM       │ ─────────────────────────▶   │  azure-app-proxy-awr-              │
│   Agent              │       (Base64 JSON)           │  azure-ad-module.ps1      (legacy) │
└──────────────────────┘                               │           — or —                   │
                                                       │  azure-app-proxy-awr-              │
                                                       │  azure-microsoft-graph.ps1         │
                                                       └──────────────┬─────────────────────┘
                                                                      │ Upload PFX
                                                                      ▼
                                                       ┌──────────────────────┐
                                                       │  Azure AD /          │
                                                       │  Entra ID            │
                                                       │  Application Proxy   │
                                                       └──────────────────────┘
```

## Logging

Both scripts write a detailed timestamped log including:

- Certificate details (subject, issuer, serial number, thumbprint, validity)
- Entra ID / Graph connection status
- Upload result and thumbprint verification
- Any errors encountered during processing

| Script | Default Log Path |
|--------|-----------------|
| `azure-app-proxy-awr-azure-ad-module.ps1` | `C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log` |
| `azure-app-proxy-awr-azure-microsoft-graph.ps1` | `C:\Certs\azure-app-proxy.log` |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.
