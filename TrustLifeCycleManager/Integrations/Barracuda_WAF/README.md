# DigiCert TLM Agent — Barracuda WAF Certificate Delivery AWR Post-Enrollment Script(s)

## Overview

PowerShell automation script that uploads a signed PKCS12/PFX certificate to Barracuda WAF using REST API and binds it to a target virtual service. The script handles both RSA and ECDSA certificate key types.

1. Certificate is uploaded to Barracuda WAF with a specified or auto-generated name.
2. Certificate is bound to the target virtual service's SSL/TLS security configuration.
3. Supports both production and dry-run modes for validation.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `Windows/barracuda_waf_service_delivery.ps1` | Windows | PowerShell 5.1+ |

## Requirements

- **PowerShell 5.1 or later**
- Network access to Barracuda WAF REST API endpoint.
- Valid API credentials (username and password) with permission to upload certificates and modify virtual service bindings.
- A signed PKCS12/PFX certificate file with a password.

## Permissions

The Barracuda WAF API user identified by ARGUMENT_2 (username) must have permissions to:

| Operation | REST API | Endpoint | Required permission |
|-----------|----------|----------|---------------------|
| Authenticate | `POST` | `/restapi/v3.2/login` | API user account |
| Upload certificate | `POST` | `/restapi/v1/certificates?upload=signed` | Certificate management |
| Bind certificate to service | `PUT` | `/restapi/v3.2/services/{virtual-service-name}/ssl-security` | Service configuration |
| Logout | `DELETE` | `/restapi/v3.2/logout` | API user account |

Consult your Barracuda WAF documentation for role-based access control (RBAC) configuration to grant these permissions.

## Modes

### Production Mode

#### Argument Reference

| # | Name | Required | Description |
|---|------|----------|-------------|
| ARGUMENT_1 | Base URL | Yes | Barracuda WAF REST API endpoint. Example: `https://waf.example.com:8443` or `http://waf.example.com:8000` |
| ARGUMENT_2 | API username | Yes | Username for Barracuda WAF API authentication |
| ARGUMENT_3 | API password | Yes | Password for Barracuda WAF API authentication |
| ARGUMENT_4 | Service name | Yes | Name of the target service to bind the certificate |
| ARGUMENT_5 | Certificate name | No | Custom name for the uploaded certificate. If omitted, a unique name is auto-generated using the certificate filename with a timestamp suffix (e.g., `certname_20260626143052`). |
| ARGUMENT_6 | Input source | No | `AWRProduction` (default) executes calls; `AWRDryRun` logs the requests without invoking them |

#### Production Execution Steps

1. Step 1: Upload script to DigiCert ONE Portal.
    1. Go to Discovery & Automation tools > Scripts.
    2. Click "Add script for" > DigiCert Agents (top right corner).
    3. Enter script name and set:
        - Operating System: Windows
        - Script type: Admin request post-delivery
    4. Click "Add and verify script".

2. Step 2: Configure Admin Web Request (AWR).
    1. Go to Inventory > Admin web request.
    2. In STEP 1, fill in the parameters.
    3. In STEP 2:
        - Click "Add"
        - Select Agent
        - Click "Apply"

3. Step 3: Set certificate delivery.
    1. Under "DigiCert Agents", select the appropriate Agent.
    2. Under "Destination 1", configure:
        - Format: `PKCS12`
        - Target path: Certificate folder path
        - Provide password
    3. Enable "Run post delivery Scripts".
    4. Select the uploaded script.
    5. Fill the arguments as listed in Argument Reference.

4. Step 4: Complete request.
    1. Proceed with the remaining configuration steps.

Note: The TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script. The arguments listed above are the values to provide in the AWR setup.

### AWRDryRun

Pass `AWRDryRun` as argument 6. All Barracuda WAF API calls are logged but not executed; useful for verifying the request payload and authentication.

## Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and validate all required inputs (Base URL, credentials, virtual service name, certificate file, password).
2. Resolve certificate file from the certificate folder (searches for `.pfx` extension).
3. Detect certificate key type (RSA or ECDSA) by inspecting the private key.
4. Enable TLS 1.2+ for HTTPS connections to Barracuda WAF.
5. Authenticate to the Barracuda WAF REST API using Basic Authentication.
6. Upload the certificate to Barracuda WAF using multipart/form-data.
7. Bind the certificate to the target virtual service's SSL/TLS configuration (RSA or ECDSA as appropriate).
8. Logout from the Barracuda WAF API session.

## Logging

Two log files are written to `C:\Program Files\DigiCert\TLM Agent\log\`:

- `barracuda_waf_service_delivery.log` — All INFO, WARN, ERROR, and SUCCESS messages (console output also displayed).
- `barracuda_waf_service_delivery_api.log` — Reserved for API-specific debugging (currently not used).
If log paths are not accessible, messages are still printed to the console. Logging failures do not block certificate delivery.

## Exit codes

- `0` — Certificate uploaded and bound to virtual service successfully.
- `1` — Legal notice not accepted, validation error, authentication failure, API error, or other unrecoverable error (full exception details logged with stack trace).

## Legal

See the header comment block in [Windows/barracuda_waf_service_delivery.ps1](Windows/barracuda_waf_service_delivery.ps1) for the full DigiCert legal notice. `$LEGAL_NOTICE_ACCEPT` must be `"true"` for the script to run.

## Version

Script version is tracked in the `$SCRIPT_VERSION` constant (currently `1.0.0`).

## PowerShell Compatibility

This script is designed for **Windows PowerShell 5.1** and later. It includes:

- Defensive X509 certificate loading that falls back to `New-Object` if constructor syntax fails on older .NET Framework versions.
- PowerShell 5.1–compatible property access checks using `PSObject.Properties` instead of direct property access.
- Robust exception logging with fallbacks for missing or null exception properties.
- TLS 1.2+ protocol enforcement for HTTPS communication with Barracuda WAF.
