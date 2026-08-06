# DigiCert TLM Agent – Azure Web App Certificate Automation

Automated SSL/TLS certificate deployment to Azure Web Apps using DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment scripting.

## Overview

This PowerShell script runs as an **Admin Web Request (AWR) post-enrollment script** triggered by the DigiCert TLM Agent. After the agent enrols or renews a certificate, the script automatically uploads the PFX to an Azure Web App, optionally adds a custom domain, enforces HTTPS-only, and binds the certificate using SNI — with no manual intervention required.

## Workflow

```
┌──────────────────────┐
│  DigiCert TLM        │
│  (Certificate        │
│   Authority)          │
└─────────┬────────────┘
          │ Enrol / Renew
          ▼
┌──────────────────────┐     DC1_POST_SCRIPT_DATA      ┌──────────────────────┐
│  DigiCert TLM        │ ──────────────────────────▶    │  AWR Script          │
│  Agent (Windows)     │      (Base64 JSON)             │  (This Script)       │
└──────────────────────┘                                └─────────┬────────────┘
                                                                  │
                            ┌─────────────────┬─────────┴─────────┬─────────────────┐
                            │                 │                   │                 │
                            ▼                 ▼                   ▼                 ▼
                    1. Upload PFX     2. Add custom      3. Enable         4. Bind cert
                       to Web App        domain (opt.)      HTTPS-only        via SNI
                            │                 │                   │                 │
                            └─────────────────┴─────────┬─────────┴─────────────────┘
                                                                  ▼
                                                        ┌──────────────────┐
                                                        │  Azure Web App   │
                                                        │  (App Service)   │
                                                        └──────────────────┘
```

## What the Script Does

The script executes the following stages in order:

**1. Certificate Extraction** — Reads the `DC1_POST_SCRIPT_DATA` environment variable set by the TLM Agent, decodes the Base64 JSON payload, and extracts the PFX file path, password, and any AWR arguments.

**2. PFX Validation** — Loads the PFX file to verify the password is correct and logs certificate details (subject, issuer, thumbprint, validity period, key type).

**3. Azure Authentication** — Authenticates to Azure using a service principal with client secret via the Azure CLI.

**4. Pre-upload Verification** — Confirms the resource group exists, the Web App is accessible, and the certificate file is present before attempting the upload.

**5. Certificate Upload** — Uploads the PFX to the Web App using `az webapp config ssl upload` and captures the returned thumbprint.

**6. Custom Domain (Optional)** — If a custom domain is configured, the script checks whether the hostname already exists on the Web App and adds it if missing. A failure here is non-fatal — the script logs a warning and continues to binding.

**7. Enable HTTPS-only** — Sets `httpsOnly=true` on the Web App before binding. This is required, not cosmetic: see [HTTPS-only and Azure Policy](#https-only-and-azure-policy) below. If this step fails the script aborts, because the bind that follows cannot succeed.

**8. Certificate Binding** — Binds the uploaded certificate to the custom domain using SNI SSL.

**9. Verification** — Lists all certificates in the resource group, confirms the uploaded thumbprint is present, and verifies the **active SNI binding** by checking that the Web App's SSL binding for that thumbprint includes the custom domain. Verification failures are logged as warnings (the binding may still be propagating), not treated as deployment failures.

**10. Cleanup** — Logs out of Azure and clears sensitive variables (client secret, PFX password) from memory.

### Exit behaviour

The script exits non-zero if the upload returns no thumbprint, if HTTPS-only cannot be enabled, or if the SSL bind fails. Adding the custom hostname and the post-deployment verification checks are the only steps that log a warning and continue.

## HTTPS-only and Azure Policy

`az webapp config ssl bind` issues a write to `Microsoft.Web/sites`. Where the CIS Microsoft Azure Foundations Benchmark v2.0.0 policy *"App Service apps should only be accessible over HTTPS"* (definition `a4af4a39-4135-47fb-b175-47fbdf85311d`, effect **Deny**) is assigned, that write is rejected with `RequestDisallowedByPolicy` whenever the Web App currently has `httpsOnly=false`. The `ssl bind` command does not set `httpsOnly` itself, so the bind fails even though the certificate uploaded fine.

The script therefore sets `httpsOnly=true` before binding. This satisfies the policy and is correct configuration for any site serving TLS certificates — but note it is a **change to the Web App's configuration**: any plain-HTTP traffic to the site will be redirected to HTTPS after the first run.

## Prerequisites

- **Windows** with PowerShell 5.1+
- **Azure CLI** installed (the script auto-detects both 32-bit and 64-bit installation paths)
- **DigiCert TLM Agent** installed and configured with an AWR profile
- **Azure Service Principal** with the following permissions:
  - `Microsoft.Web/certificates/Write` — to upload certificates
  - `Microsoft.Web/certificates/Read` — to verify the deployed certificate and its binding
  - `Microsoft.Web/sites/Read` — to verify the Web App
  - `Microsoft.Web/sites/Write` — to enable HTTPS-only before binding (see [HTTPS-only and Azure Policy](#https-only-and-azure-policy))
  - `Microsoft.Web/sites/hostNameBindings/Write` — to add custom domains and bind certificates
  - `Microsoft.Resources/subscriptions/resourceGroups/read` — to verify the resource group

  The built-in **Website Contributor** role covers all of the above.
- **DNS** — if using a custom domain, a CNAME record pointing to `<webapp-name>.azurewebsites.net` must exist before binding

## Configuration

### Azure Service Principal

Update the authentication section near the top of the custom script section:

```powershell
$AZURE_TENANT_ID     = "< TENANT ID HERE >"
$AZURE_CLIENT_ID     = "< CLIENT ID HERE >"
$AZURE_CLIENT_SECRET = "< CLIENT SECRET HERE >"
```

For production deployments, the script includes a commented-out section for loading the client secret from an encrypted file instead of hardcoding it.

### Azure Web App Target

The target Web App can be configured either by hardcoding values in the script or by passing them as AWR arguments from TLM:

| Source | Parameter | Description |
|--------|-----------|-------------|
| AWR Argument 1 | `$AZURE_RESOURCE_GROUP` | Azure resource group containing the Web App |
| AWR Argument 2 | `$AZURE_WEBAPP_NAME` | Name of the Azure Web App |
| AWR Argument 3 | `$AZURE_CUSTOM_DOMAIN` | Custom domain to bind (optional) |

> **Pass the Web App name as Argument 2 — not the App Service Plan name.** These are easy to confuse because they usually differ by a single prefix:
>
> ```
> Web App:          aas-go02-eas-u-compco01-acc   <-- correct
> App Service Plan: asp-go02-eas-u-compco01-acc   <-- wrong
> ```
>
> Supplying the plan name produces `Web app not found`; the script then lists the Web Apps in the resource group to help you pick the right one.

To use AWR arguments instead of hardcoded values, uncomment these lines:

```powershell
$AZURE_RESOURCE_GROUP = $ARGUMENT_1
$AZURE_WEBAPP_NAME    = $ARGUMENT_2
$AZURE_CUSTOM_DOMAIN  = $ARGUMENT_3
```

### Legal Notice

The script includes a legal notice gate that must be accepted before execution:

```powershell
$LEGAL_NOTICE_ACCEPT = "true"
```

## Logging

All operations are written to a timestamped log file at:

```
C:\Program Files\DigiCert\TLM Agent\log\azure-webapp_data.log
```

The log includes certificate details, Azure authentication status, upload results, domain binding outcomes, and a final deployment summary with the access URL.

## Troubleshooting

| Symptom | Likely Cause |
|---------|--------------|
| `Azure CLI not found at expected locations` | Azure CLI is not installed or is in a non-standard path. Install from `https://aka.ms/installazurecliwindows`. |
| `Azure authentication failed` | Service principal credentials are incorrect or the client secret has expired. |
| `Resource group not found` | The resource group name is wrong or the service principal lacks read access to it. |
| `Web app not found` | The Web App name or resource group is incorrect. The script lists available Web Apps to help diagnose. |
| `Certificate upload failed` | Invalid PFX password, corrupted PFX file, or the service principal lacks certificate write permissions. The Azure CLI's own error text is captured in the log under `Azure CLI Error:`. |
| `Failed to add custom domain` | DNS is not configured correctly. Ensure a CNAME record exists pointing to `<webapp>.azurewebsites.net`. Non-fatal — the script continues to binding. |
| `Failed to enable HTTPS-only` | The service principal lacks `Microsoft.Web/sites/Write`, or another Azure Policy is denying the site update. Fatal — the bind cannot succeed without it. |
| `Failed to bind certificate` / `RequestDisallowedByPolicy` | Azure Policy denied the write to `Microsoft.Web/sites`. See [HTTPS-only and Azure Policy](#https-only-and-azure-policy). Otherwise: the custom domain was not successfully added, or the thumbprint could not be extracted from the upload response. |
| `No thumbprint available after upload` | The upload returned a response the script could not parse and no 40-character thumbprint could be recovered from it. Check the raw upload output in the log. |
| `Could not confirm active SNI binding` | Warning only. The binding is usually still propagating; confirm in the Azure Portal if it persists. |
| `DC1_POST_SCRIPT_DATA is not set` | The script is not being invoked by the TLM Agent, or the AWR profile is misconfigured. |

## Security Considerations

- The script clears the Azure client secret and PFX password from memory after use and logs out of Azure CLI on completion.
- For production environments, use the encrypted file approach for the client secret rather than hardcoding it in the script.
- The PFX password is logged only as a masked value (first 3 characters) for debugging purposes. Consider removing this in production.
- The TLM Agent runs as `LocalSystem`, so the Azure CLI path is resolved explicitly rather than relying on the system PATH.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in the script for full terms.