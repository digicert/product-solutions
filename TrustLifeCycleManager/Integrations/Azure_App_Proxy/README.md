# DigiCert TLM Agent – Azure App Proxy Certificate Automation

Automate SSL/TLS certificate lifecycle management for Microsoft Entra (Azure AD) Application Proxy using DigiCert Trust Lifecycle Manager (TLM).

## Overview

This repository contains two PowerShell scripts that work together to provide end-to-end certificate management for Azure App Proxy custom domains:

| Script | Purpose |
|--------|---------|
| `azure-app-proxy-awr.ps1` | **Post-enrollment AWR script** — automatically uploads a newly issued certificate to Azure App Proxy after the TLM Agent completes enrollment. |
| `azure_app_proxy_retrieve_certificate.ps1` | **Retrieval & audit script** — connects to Azure AD and reports the current certificate and App Proxy configuration, including expiry status. |

## How It Works

### Certificate Upload (`azure-app-proxy-awr.ps1`)

This script is designed to run as an **Admin Web Request (AWR) post-enrollment script** triggered by the DigiCert TLM Agent. After the agent enrolls or renews a certificate, this script handles the deployment to Azure App Proxy automatically.

**Workflow:**

1. Reads certificate data from the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON set by the TLM Agent).
2. Decodes the JSON payload and extracts the PFX file path and password.
3. Validates the PFX file by loading it and logging certificate details (subject, issuer, thumbprint, validity dates).
4. Authenticates to Azure AD using certificate-based service principal authentication.
5. Uploads the PFX to the target App Proxy application via `Set-AzureADApplicationProxyApplicationCustomDomainCertificate`.
6. Verifies the upload by retrieving the App Proxy certificate metadata and comparing thumbprints.

All operations are logged to `C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log`.

### Certificate Retrieval (`azure_app_proxy_retrieve_certificate.ps1`)

A standalone utility script for inspecting the current state of an App Proxy's SSL certificate.

**Workflow:**

1. Authenticates to Azure AD using certificate-based service principal authentication.
2. Retrieves the App Proxy configuration (external URL, internal URL, authentication type).
3. Displays the current certificate details (subject, thumbprint, issue/expiry dates).
4. Calculates and reports certificate expiry status with colour-coded output (green/yellow/red).

## Prerequisites

- **PowerShell 5.1+** (Windows)
- **AzureAD PowerShell module** — `Install-Module AzureAD`
- **Azure AD App Registration** with:
  - A client certificate installed on the machine running the scripts
  - `Application.ReadWrite.All` (or equivalent) API permissions granted with admin consent
  - The application's Object ID for the target App Proxy application
- **DigiCert TLM Agent** installed and configured (for the AWR script)

## Configuration

### AWR Upload Script

Edit the configuration block at the top of `azure-app-proxy-awr.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT = "true"               # Accept the legal notice to enable execution
$AZURE_TENANT_ID     = "< Azure Tenant ID >"
$AZURE_CLIENT_ID     = "< Azure Client ID >"
$AZURE_CERT_THUMBPRINT = "< Azure Certificate Thumbprint >"
$APP_PROXY_OBJECT_ID = "< Azure App Proxy Object ID >"
```

### Retrieval Script

Edit the configuration block at the top of `azure_app_proxy_retrieve_certificate.ps1`:

```powershell
$LEGAL_NOTICE_ACCEPT = "true"
$tenantId            = "<your-tenant-id>"
$clientId            = "<your-client-id>"
$certThumbprint      = "<your-cert-thumbprint>"
$appProxyObjectId    = "<your-app-proxy-object-id>"
```

> **Important:** Both scripts include a legal notice gate. You must set `$LEGAL_NOTICE_ACCEPT = "true"` before the script will execute.

## Usage

### Automated Certificate Deployment (AWR)

Configure `azure-app-proxy-awr.ps1` as a post-enrollment script in your TLM Agent AWR profile. The TLM Agent will invoke it automatically after each certificate enrollment or renewal, passing certificate data via the `DC1_POST_SCRIPT_DATA` environment variable.

### Manual Certificate Audit

Run the retrieval script interactively to check the current certificate status:

```powershell
.\azure_app_proxy_retrieve_certificate.ps1
```

## Architecture

```
┌──────────────────────┐
│   DigiCert TLM       │
│   (Certificate       │
│    Authority)         │
└─────────┬────────────┘
          │ Enroll / Renew
          ▼
┌──────────────────────┐     DC1_POST_SCRIPT_DATA     ┌──────────────────────┐
│   DigiCert TLM       │ ──────────────────────────▶   │  azure-app-proxy-    │
│   Agent               │       (Base64 JSON)          │  awr.ps1             │
└──────────────────────┘                               └─────────┬────────────┘
                                                                 │ Upload PFX
                                                                 ▼
                                                       ┌──────────────────────┐
                                                       │  Azure AD /          │
                                                       │  Entra ID            │
                                                       │  Application Proxy   │
                                                       └──────────────────────┘
                                                                 ▲
                                                                 │ Query status
                                                       ┌────────┴─────────────┐
                                                       │  azure_app_proxy_    │
                                                       │  retrieve_cert.ps1   │
                                                       └──────────────────────┘
```

## Logging

The AWR upload script writes a detailed timestamped log including:

- Certificate details (subject, issuer, serial number, thumbprint, validity)
- Azure AD connection status
- Upload result and thumbprint verification
- Any errors encountered during processing

Log location: `C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log`

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.