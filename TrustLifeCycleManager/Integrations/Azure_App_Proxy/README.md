# DigiCert TLM Agent – Azure App Proxy Certificate Automation

Automate SSL/TLS certificate lifecycle management for Microsoft Entra (Azure AD) Application Proxy using DigiCert Trust Lifecycle Manager (TLM).

## Overview

This repository contains two PowerShell AWR post-enrollment scripts. Both automate certificate deployment to Azure App Proxy after the TLM Agent completes enrollment; they differ only in the Microsoft API they use to interact with Entra ID:

| Script | API Used | When to Use |
|--------|----------|-------------|
| `azure-app-proxy-awr-azure-ad-module.ps1` | **AzureAD PowerShell module** (legacy) | Existing environments already using the AzureAD module; certificate auth is the default, with managed identity also supported. |
| `azure-app-proxy-awr-azure-microsoft-graph.ps1` | **Microsoft Graph** (current) | New deployments or environments migrating away from the deprecated AzureAD module; client-secret auth is the default, with managed identity also supported. |

> **Note:** Microsoft has deprecated the AzureAD PowerShell module. New deployments should use the Microsoft Graph script.

> **Deprecation notice:** Hardcoding configuration values in the script is deprecated. Support for this option will be removed in the next version.

## How It Works

Both scripts follow the same overall workflow:

1. Read certificate data from the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON set by the TLM Agent).
2. Decode the JSON payload and extract the PFX file path and password.
3. Validate the PFX file and log certificate details (subject, issuer, thumbprint, validity dates).
4. Authenticate to Entra ID / Microsoft Graph.
5. Upload the PFX to the App Proxy application, addressed by the **App Registration (Application) Object ID** (see [Which Object ID to use](#which-object-id-to-use)).
6. Verify the upload by querying the App Proxy certificate metadata and comparing thumbprints.

### AzureAD Module Script (`azure-app-proxy-awr-azure-ad-module.ps1`)

- Authenticates using `Connect-AzureAD` with either certificate-based service principal auth (`-CertificateThumbprint`) or managed identity access tokens.
- Managed identity supports a system-assigned identity or a user-assigned identity selected by client ID.
- Uploads via `Set-AzureADApplicationProxyApplicationCustomDomainCertificate`.
- Verifies via `Get-AzureADApplicationProxyApplication`.
- Log location: `C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log`

### Microsoft Graph Script (`azure-app-proxy-awr-azure-microsoft-graph.ps1`)

- Authenticates using `Connect-MgGraph` with a client-secret credential or managed identity.
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
- For certificate auth, a client certificate installed on the machine and referenced by thumbprint.
- For managed identity auth, run the TLM Agent on Azure compute with a system-assigned or user-assigned managed identity enabled.
- Grant the authentication principal (`$AZURE_CLIENT_ID` app registration or managed identity service principal) the `Application.ReadWrite.All` and `OnPremisesPublishingProfiles.ReadWrite.All` Microsoft Graph **Application** permissions, with admin consent.

### Microsoft Graph Script

- `Microsoft.Graph.Authentication` and `Microsoft.Graph.Applications` modules — `Install-Module Microsoft.Graph -Scope AllUsers`
  - Install with `-Scope AllUsers` so the modules are visible to the LocalSystem account (or whichever account runs the TLM Agent service)
- For client-secret auth, configure the app registration credentials.
- For managed identity auth, run the TLM Agent on Azure compute with a system-assigned or user-assigned managed identity enabled.
- Grant the authentication principal (app registration or managed identity service principal) the `Application.ReadWrite.All` and `OnPremisesPublishingProfiles.ReadWrite.All` Microsoft Graph **Application** permissions, with admin consent.

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
$AZURE_TENANT_ID       = ""                        # ARGUMENT_2 is used when blank
$AZURE_AUTH_MODE       = "Certificate"             # "Certificate" (default) or "ManagedIdentity"
$AZURE_CLIENT_ID       = ""                        # Certificate mode: ARGUMENT_3 when blank
$AZURE_CERT_THUMBPRINT = ""                        # Certificate mode: ARGUMENT_4 when blank
$AZURE_MANAGED_IDENTITY_CLIENT_ID = ""             # ManagedIdentity mode: optional ARGUMENT_3
$APP_PROXY_OBJECT_ID   = ""                        # ARGUMENT_1 when blank; App Registration (Application) Object ID
```

Certificate authentication is the default. Configure the tenant ID, connection app client ID, and certificate thumbprint (in the script or through the AWR arguments). To use managed identity instead, set `$AZURE_AUTH_MODE = "ManagedIdentity"`; leave `$AZURE_MANAGED_IDENTITY_CLIENT_ID` blank for a system-assigned identity, or set it to the client ID of the user-assigned identity. The script uses the Azure managed identity endpoint when available, otherwise the VM IMDS endpoint.

Non-empty configuration values take precedence over AWR arguments. When a setting is blank, the AzureAD script uses:

**ManagedIdentity mode**

| AWR argument | Configuration field | Description |
|--------------|----------------------|-------------|
| `ARGUMENT_1` | `$APP_PROXY_OBJECT_ID` | App Proxy app registration's application object ID (not its service principal or client ID). |
| `ARGUMENT_2` | `$AZURE_TENANT_ID` | Entra ID tenant (directory) ID. |
| `ARGUMENT_3` (optional) | `$AZURE_MANAGED_IDENTITY_CLIENT_ID` | User-assigned managed identity client ID; omit or leave blank for system-assigned identity. |

**Certificate mode**

| AWR argument | Configuration field | Description |
|--------------|----------------------|-------------|
| `ARGUMENT_1` | `$APP_PROXY_OBJECT_ID` | App Proxy app registration's application object ID (not its service principal or client ID). |
| `ARGUMENT_2` | `$AZURE_TENANT_ID` | Entra ID tenant (directory) ID. |
| `ARGUMENT_3` | `$AZURE_CLIENT_ID` | Client ID of the connection app registration. |
| `ARGUMENT_4` | `$AZURE_CERT_THUMBPRINT` | Thumbprint of the authentication certificate installed on the machine. |

**Managed identity mode (`$AZURE_AUTH_MODE = "ManagedIdentity"`)**

| Variable | Requirement |
|----------|-------------|
| `$LEGAL_NOTICE_ACCEPT` | Required (`"true"`) |
| `$AZURE_AUTH_MODE` | Required |
| `$AZURE_TENANT_ID` | Required |
| `$APP_PROXY_OBJECT_ID` | Required |
| `$AZURE_MANAGED_IDENTITY_CLIENT_ID` | Optional (blank = system-assigned; set for user-assigned) |

**Certificate mode (`$AZURE_AUTH_MODE = "Certificate"`)**

| Variable | Requirement |
|----------|-------------|
| `$LEGAL_NOTICE_ACCEPT` | Required (`"true"`) |
| `$AZURE_AUTH_MODE` | Required |
| `$AZURE_TENANT_ID` | Required |
| `$AZURE_CLIENT_ID` | Required |
| `$AZURE_CERT_THUMBPRINT` | Required |
| `$APP_PROXY_OBJECT_ID` | Required |

### Microsoft Graph Script

Edit the configuration block at the top of `azure-app-proxy-awr-azure-microsoft-graph.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT    = "true"                    # Accept the legal notice to enable execution
$DRY_RUN                = "false"                   # Set "true" to preview Graph operations without executing them
$AZURE_AUTH_MODE        = "ClientSecret"            # "ClientSecret" (default) or "ManagedIdentity"
$AZURE_TENANT_ID        = ""                        # ClientSecret mode: ARGUMENT_2 when blank
$AZURE_CONNECTION_APPID = ""                        # ClientSecret mode: ARGUMENT_3 when blank
$AZURE_CLIENT_SECRET    = ""                        # ClientSecret mode: ARGUMENT_4 when blank
$AZURE_MANAGED_IDENTITY_CLIENT_ID = ""              # ManagedIdentity mode: optional ARGUMENT_2
$APP_PROXY_OBJECT_ID    = ""                        # ARGUMENT_1 when blank; App Registration (Application) Object ID
```

Client-secret authentication is the default. In this version, configure the tenant ID, connection app client ID, and client secret in the script or through the AWR arguments. To use managed identity instead, set `$AZURE_AUTH_MODE = "ManagedIdentity"`; leave `$AZURE_MANAGED_IDENTITY_CLIENT_ID` blank for a system-assigned identity or set the client ID of a user-assigned identity. No tenant ID, app client ID, or client secret is needed in managed identity mode.

Non-empty configuration values take precedence over AWR arguments. When a setting is blank, the Microsoft Graph script uses:

**ManagedIdentity mode**

| AWR argument | Configuration field | Description |
|--------------|----------------------|-------------|
| `ARGUMENT_1` | `$APP_PROXY_OBJECT_ID` | App Proxy app registration's application object ID (not its service principal or client ID). |
| `ARGUMENT_2` (optional) | `$AZURE_MANAGED_IDENTITY_CLIENT_ID` | User-assigned managed identity client ID; omit or leave blank for system-assigned identity. |

**ClientSecret mode**

| AWR argument | Configuration field | Description |
|--------------|----------------------|-------------|
| `ARGUMENT_1` | `$APP_PROXY_OBJECT_ID` | App Proxy app registration's application object ID (not its service principal or client ID). |
| `ARGUMENT_2` | `$AZURE_TENANT_ID` | Entra ID tenant (directory) ID. |
| `ARGUMENT_3` | `$AZURE_CONNECTION_APPID` | Client ID of the Graph connection app registration. |
| `ARGUMENT_4` | `$AZURE_CLIENT_SECRET` | Client secret value for the connection app; handle as a secret. |

> **Secret handling:** The current Microsoft Graph script logs the raw AWR argument array. Do not pass a real client secret as `ARGUMENT_4`; configure it through an approved protected mechanism and remove raw-argument logging before using that fallback. Never commit secrets to source control.

**Managed identity mode (`$AZURE_AUTH_MODE = "ManagedIdentity"`)**

| Variable | Requirement |
|----------|-------------|
| `$LEGAL_NOTICE_ACCEPT` | Required (`"true"`) |
| `$AZURE_AUTH_MODE` | Required |
| `$APP_PROXY_OBJECT_ID` | Required |
| `$AZURE_MANAGED_IDENTITY_CLIENT_ID` | Optional (blank = system-assigned; set for user-assigned) |
| `$DRY_RUN` | Optional |

**Client secret mode (`$AZURE_AUTH_MODE = "ClientSecret"`)**

| Variable | Requirement |
|----------|-------------|
| `$LEGAL_NOTICE_ACCEPT` | Required (`"true"`) |
| `$AZURE_AUTH_MODE` | Required |
| `$AZURE_TENANT_ID` | Required |
| `$AZURE_CONNECTION_APPID` | Required |
| `$AZURE_CLIENT_SECRET` | Required |
| `$APP_PROXY_OBJECT_ID` | Required |
| `$DRY_RUN` | Optional |

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
┌──────────────────────┐     DC1_POST_SCRIPT_DATA      ┌────────────────────────────────────┐
│   DigiCert TLM       │ ─────────────────────────▶    │  azure-app-proxy-awr-              │
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

## Changelog

### 1.2.0

- `azure-app-proxy-awr-azure-ad-module.ps1`: Supports system-assigned and user-assigned managed identities. Hardcoding configuration values is deprecated and will be removed in the next version.
- `azure-app-proxy-awr-azure-microsoft-graph.ps1`: Supports system-assigned and user-assigned managed identities. Hardcoding configuration values is deprecated and will be removed in the next version.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.
