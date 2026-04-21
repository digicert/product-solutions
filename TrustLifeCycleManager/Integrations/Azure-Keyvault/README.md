# DigiCert TLM Agent – Azure Key Vault Certificate Import

Automated certificate import to Azure Key Vault using DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment scripting.

## Overview

These scripts run as **Admin Web Request (AWR) post-enrollment scripts** triggered by the DigiCert TLM Agent. After the agent enrols or renews a certificate, the script authenticates to Azure AD via OAuth 2.0 client credentials, then imports the PFX directly into Azure Key Vault using the Key Vault REST API — no Azure CLI required.

Two functionally identical versions are provided:

| Script | Platform | TLM Agent |
|--------|----------|-----------|
| `azure-keyvault-awr.sh` | Linux (bash) | TLM Agent for Linux |
| `azure-keyvault-awr.ps1` | Windows (PowerShell) | TLM Agent for Windows |

Choose whichever matches the OS running your TLM Agent. Both follow the same workflow and produce the same outcome.

## Workflow

```
┌──────────────────────┐
│  DigiCert TLM        │
│  (Certificate        │
│   Authority)          │
└─────────┬────────────┘
          │ Enrol / Renew
          ▼
┌──────────────────────┐     DC1_POST_SCRIPT_DATA     ┌──────────────────────┐
│  DigiCert TLM        │ ──────────────────────────▶   │  AWR Script          │
│  Agent               │       (Base64 JSON)           │  (bash or PS1)       │
└──────────────────────┘                               └─────────┬────────────┘
                                                                 │
                                                    ┌────────────┼────────────┐
                                                    ▼            ▼            ▼
                                              1. Decode    2. Get OAuth   3. Import
                                                 PFX from     token from     PFX via
                                                 JSON         Azure AD       REST API
                                                    │            │            │
                                                    └────────────┼────────────┘
                                                                 ▼
                                                       ┌──────────────────┐
                                                       │  Azure Key Vault │
                                                       └──────────────────┘
```

## What the Scripts Do

**1. Certificate Extraction** — Reads the `DC1_POST_SCRIPT_DATA` environment variable set by the TLM Agent, decodes the Base64 JSON payload, and extracts the PFX file path, password, and any AWR arguments. Legacy PFX files (containing `_legacy` in the filename) are automatically excluded.

**2. PFX Validation** — Verifies the PFX file exists and can be loaded with the extracted password. On Linux this uses OpenSSL; on Windows the .NET `X509Certificate2` class is used. Certificate details (subject, issuer, thumbprint, validity, key type) are logged.

**3. Azure AD Authentication** — Obtains an OAuth 2.0 access token from `login.microsoftonline.com` using the client credentials grant (`client_id` + `client_secret`), scoped to `https://vault.azure.net/.default`. No Azure CLI or PowerShell modules are needed — authentication is handled via direct HTTP requests.

**4. Key Vault Import** — Imports the Base64-encoded PFX into Azure Key Vault using the [Certificates – Import](https://learn.microsoft.com/en-us/rest/api/keyvault/certificates/import-certificate/import-certificate?view=rest-keyvault-certificates-2025-07-01&tabs=HTTP) REST API. The import policy specifies RSA key type, exportable private key, and PKCS#12 content type. The certificate name in Key Vault is derived from the PFX filename with non-alphanumeric characters replaced by hyphens.

**5. Verification** — Logs the certificate ID and thumbprint returned by Key Vault to confirm the import succeeded.

## Prerequisites

### Azure

- **Azure Key Vault** instance.
- **Azure AD App Registration** (service principal) with:
  - A client secret (not expired)
  - Key Vault access policy granting `Import` permission on **Certificates**

### TLM Agent

- **DigiCert TLM Agent** installed and configured with an AWR profile that outputs PFX/P12 format.

### Platform-Specific

| Requirement | Linux (`azure-keyvault-awr.sh`) | Windows (`azure-keyvault-awr.ps1`) |
|-------------|----------------------------------|-------------------------------------|
| Shell | bash | PowerShell 5.1+ |
| HTTP client | `curl` (pre-installed on most distros) | `Invoke-RestMethod` (built-in) |
| JSON parsing | `jq` (recommended) or `grep` fallback | `ConvertFrom-Json` (built-in) |
| PFX inspection | `openssl` (optional) | .NET `X509Certificate2` (built-in) |
| Base64 | `base64` (coreutils) | `[System.Convert]::ToBase64String` (built-in) |

The bash script gracefully degrades if `jq` or `openssl` are not installed — it falls back to `grep`/`sed` for JSON parsing and skips PFX inspection respectively.

## Configuration

Edit the configuration block at the top of the script:

**Bash:**
```bash
LEGAL_NOTICE_ACCEPT="true"
AKV_TENANT_ID="<your-tenant-id>"
AKV_CLIENT_ID="<your-client-id>"
AKV_CLIENT_SECRET="<your-client-secret>"
AKV_VAULT_NAME="<your-vault-name>"
```

**PowerShell:**
```powershell
$LEGAL_NOTICE_ACCEPT = "true"
$AKV_TENANT_ID     = "<your-tenant-id>"
$AKV_CLIENT_ID     = "<your-client-id>"
$AKV_CLIENT_SECRET  = "<your-client-secret>"
$AKV_VAULT_NAME    = "<your-vault-name>"
```

| Variable | Description |
|----------|-------------|
| `LEGAL_NOTICE_ACCEPT` | Must be set to `"true"` before the script will execute. |
| `AKV_TENANT_ID` | Azure AD tenant ID from the app registration. |
| `AKV_CLIENT_ID` | Application (client) ID from the app registration. |
| `AKV_CLIENT_SECRET` | Client secret value (not the secret ID). |
| `AKV_VAULT_NAME` | Name of the Azure Key Vault instance (e.g. `kv-demo-DLauMZ`). |

## Certificate Naming

The certificate name in Key Vault is automatically derived from the PFX filename:

```
source file:   webapp.tlsguru.io.pfx
vault name:    webapp-tlsguru-io
```

All characters that are not alphanumeric or hyphens are replaced with hyphens. This ensures compatibility with Key Vault naming rules.

## Logging

Both scripts write timestamped logs to:

| Platform | Log Path |
|----------|----------|
| Linux | `/home/ubuntu/tlm_agent_3.1.2_linux64/log/keyvault.log` |
| Windows | `C:\Program Files\DigiCert\TLM Agent\log\keyvault.log` |

Update the `LOGFILE` variable if your TLM Agent is installed in a different location.

## Troubleshooting

| Symptom | Likely Cause |
|---------|--------------|
| `DC1_POST_SCRIPT_DATA is not set` | The script is not being invoked by the TLM Agent, or the AWR profile is misconfigured. |
| `No non-legacy PFX file found` | The AWR profile is not configured to output PFX/P12 format, or only legacy-format files were generated. |
| `Failed to obtain Azure AD access token` | Client ID, secret, or tenant ID is incorrect, or the client secret has expired. |
| `HTTP 401` on import | The access token is valid but the service principal lacks `Import` permission on the Key Vault certificates access policy. |
| `HTTP 403` on import | The Key Vault firewall is blocking access from the machine running the TLM Agent. Add the agent's IP to the vault's network rules. |
| `HTTP 409` on import | A certificate with the same name already exists and is in a conflicted state (e.g. pending). Check the certificate status in the Azure Portal. |
| `Failed to decode Base64` | The `DC1_POST_SCRIPT_DATA` payload is malformed. Check the TLM Agent logs for the raw value. |

## Implementation Differences

While both scripts are functionally equivalent, there are minor differences in how each platform handles certain operations:

| Aspect | Bash | PowerShell |
|--------|------|------------|
| HTTP requests | `curl` with `-w` for HTTP status extraction | `Invoke-RestMethod` with exception-based error handling |
| JSON parsing | `jq` preferred, `grep -oP` fallback | `ConvertFrom-Json` (native) |
| PFX validation | `openssl pkcs12 -info` (if available) | `X509Certificate2` .NET class |
| Error responses | HTTP status parsed from `curl` output | Status code from exception `Response` object |
| Base64 encoding | `base64 -w 0` (no line wrapping) | `[System.Convert]::ToBase64String` |

These are purely mechanical differences — the API calls, authentication flow, and import payload are identical.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.