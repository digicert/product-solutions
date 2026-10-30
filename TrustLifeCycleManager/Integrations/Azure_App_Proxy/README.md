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
5. Upload the PFX to the App Proxy application, addressed by the **App Registration (Application) Object ID** (see [Which Object ID to use](#which-object-id-to-use)).
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
- **Entra ID App Registration used for authentication** (the "connection" app) with the following **Application** permissions granted with admin consent:
  - `Application.ReadWrite.All`
  - `OnPremisesPublishingProfiles.ReadWrite.All` — Microsoft now requires this permission to read and write the `onPremisesPublishing` certificate data used by Application Proxy. Without it the upload fails with an authorization error even when `Application.ReadWrite.All` is granted.
- **The App Registration (Application) Object ID of the App Proxy application** whose certificate is being replaced. This is **not** the Enterprise Application (Service Principal) Object ID — see [Which Object ID to use](#which-object-id-to-use).

### AzureAD Module Script

- `AzureAD` PowerShell module — `Install-Module AzureAD`
- A client certificate installed on the machine, referenced by thumbprint for service principal auth
- `Application.ReadWrite.All` and `OnPremisesPublishingProfiles.ReadWrite.All` API permissions with admin consent

### Microsoft Graph Script

- `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications` modules — `Install-Module Microsoft.Graph -Scope AllUsers`
  - Install with `-Scope AllUsers` so the modules are visible to the LocalSystem account (or whichever account runs the TLM Agent service)
- A client secret **or** client certificate configured for the app registration
- `Application.ReadWrite.All` and `OnPremisesPublishingProfiles.ReadWrite.All` API permissions with admin consent

### Which Object ID to use

Every Application Proxy app exists twice in Entra ID, and both entries have an **Object ID**:

| Entra ID blade | Object type | Use in `$APP_PROXY_OBJECT_ID`? |
|----------------|-------------|--------------------------------|
| **Entra ID → App registrations → \<your App Proxy app\> → Overview → Object ID** | Application | **Yes** |
| **Entra ID → Enterprise applications → \<your App Proxy app\> → Overview → Object ID** | Service Principal | **No** |

Both scripts address the application object: the Graph script calls `beta/applications/{id}`, and the AzureAD cmdlets take the application `-ObjectId`. Supplying the Enterprise Application (Service Principal) Object ID does not work — the Graph script reports `Resource '<id>' does not exist` (HTTP 404) and the AzureAD script fails to find the application. Also note that the **Application (client) ID** shown on the same Overview page is a different value and is not accepted either.

To find the correct value:

1. In the Entra admin center, open **Identity → Applications → App registrations**.
2. Select **All applications** and search for the Application Proxy app by name (it has the same name as the Enterprise Application entry).
3. On the **Overview** page, copy **Object ID** (not **Application (client) ID**).

The App Proxy app registration is a different object from the app registration used for authentication (`$AZURE_CLIENT_ID` / `$AZURE_CONNECTION_APPID`). The authentication app needs the API permissions; the App Proxy app only needs its Object ID copied into the script.

## Configuration

### AzureAD Module Script

Edit the configuration block at the top of `azure-app-proxy-awr-azure-ad-module.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT   = "true"                    # Accept the legal notice to enable execution
$AZURE_TENANT_ID       = "< Azure Tenant ID >"
$AZURE_CLIENT_ID       = "< Azure Client ID >"
$AZURE_CERT_THUMBPRINT = "< Azure Certificate Thumbprint >"
$APP_PROXY_OBJECT_ID   = "< Azure App Proxy Object ID >"   # App Registration (Application) Object ID of the App Proxy app, NOT the Enterprise Application Object ID
```

### Microsoft Graph Script

Edit the configuration block at the top of `azure-app-proxy-awr-azure-microsoft-graph.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT    = "true"                    # Accept the legal notice to enable execution
$DRY_RUN                = "false"                   # Set "true" to preview Graph operations without executing them
$AZURE_TENANT_ID        = "< Azure Tenant ID >"
$AZURE_CONNECTION_APPID = "< Azure Client ID >"
$AZURE_CLIENT_SECRET    = "< Azure Client Secret >"
$APP_PROXY_OBJECT_ID    = "< Azure App Proxy Object ID >"   # App Registration (Application) Object ID of the App Proxy app, NOT the Enterprise Application Object ID
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

## Troubleshooting

| Symptom in the log | Likely cause | Fix |
|--------------------|--------------|-----|
| `Resource '<id>' does not exist or one of its queried reference-property objects are not present` (HTTP 404) | `$APP_PROXY_OBJECT_ID` is the Enterprise Application (Service Principal) Object ID or the Application (client) ID | Use the Object ID from **App registrations → Overview** — see [Which Object ID to use](#which-object-id-to-use). |
| `Insufficient privileges to complete the operation` / `Authorization_RequestDenied` (HTTP 403) | `OnPremisesPublishingProfiles.ReadWrite.All` is missing or admin consent was not granted | Add the permission as an **Application** permission on the authentication app registration and grant admin consent, then wait a few minutes for the token to pick it up. |
| Upload succeeds but verification shows the old thumbprint | Entra ID can take a short time to publish the new certificate metadata | Re-run the verification GET after a few minutes; no re-upload is needed. |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.
