# DigiCert TLM Agent — Cisco ISE Certificate Delivery AWR Post-Enrollment Script

## Overview

PowerShell automation script that imports a PEM certificate and private key into Cisco ISE system certificates using the Cisco ISE REST API. The script supports delivery to multiple ISE nodes and fails the overall run if any node import fails.

1. Certificate payload is parsed from PEM (certificate + PKCS#8 private key).
2. Certificate is imported into Cisco ISE system certificate endpoint for each configured node.
3. Service flags (admin/eap/ims/pxgrid/radius/saml/portal) are set from AWR arguments.
4. Per-node success/failure is tracked, summarized, and enforced.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `Windows/cisco_ise_certificate_delivery.ps1` | Windows | PowerShell 5.1+ |

## Requirements

- **Windows PowerShell 5.1 or later**
- Network access to all Cisco ISE nodes over HTTPS.
- Valid Cisco ISE API credentials with permission to import system certificates.
- Write permission to `C:\Program Files\DigiCert\TLM Agent\log\`.
- Legal notice gate must be accepted in the script (`$LEGAL_NOTICE_ACCEPT = "true"`) before execution.

## Permissions

The Cisco ISE API user identified by ARGUMENT_2 (account name) must have permissions to import portal/system certificates.

| Operation | REST API | Endpoint | Required permission |
|-----------|----------|----------|---------------------|
| Import system certificate | `POST` | `/api/v1/certs/system-certificate/import` | Certificate management / import privileges |

Consult Cisco ISE RBAC documentation to grant the exact API role/privilege set required in your environment.

## Modes

### Production Mode

#### Argument Reference

| # | Name | Required | Description |
|---|------|----------|-------------|
| ARGUMENT_1 | ISE nodes | Yes | Comma-separated Cisco ISE hostnames/IPs (for example: `192.168.3.12,192.168.3.13`) |
| ARGUMENT_2 | API account name | Yes | Cisco ISE API username |
| ARGUMENT_3 | API account password | Yes | Cisco ISE API password |
| ARGUMENT_4 | Portal tag | Conditional | Required only when `portal` is selected (implicitly or explicitly) |
| ARGUMENT_5 | Service flags | No | Comma-separated flags: `admin,eap,ims,pxgrid,radius,saml,portal` |

If `ARGUMENT_5` is omitted, the script defaults to `portal` only.

#### Production Execution Steps

1. Step 1: Upload the script to DigiCert ONE.
  1. Go to Discovery & Automation tools > Scripts.
  2. Click "Add script for" > DigiCert Agents.
  3. Enter a script name and set:
    - Operating System: Windows
    - Script type: Admin request post-delivery
  4. Click "Add and verify script".

2. Step 2: Configure Admin Web Request (AWR).
  1. Go to Inventory > Admin web request.
  2. In STEP 1, fill in the request metadata.
  3. In STEP 2:
    - Click "Add"
    - Select Agent
    - Click "Apply"

3. Step 3: Configure certificate delivery.
  1. Under "DigiCert Agents", select the target agent.
  2. Under "Destination 1", configure:
    - Format: `PEM`
    - Target path: folder containing the delivered `.pem` file
    - Password: provide the PEM private key password
  3. Enable "Run post-delivery scripts".
  4. Select `cisco_ise_certificate_delivery.ps1`.
  5. Fill `ARGUMENT_1` through `ARGUMENT_4` using the Argument Reference.
  6. Optional: add `ARGUMENT_5` in the AWR UI when you need services other than `portal`.

4. Step 4: Complete the request.
  1. Proceed with the remaining AWR steps and submit.

Note: TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script. Arguments above are supplied in AWR configuration.

## Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and validate required arguments and inputs.
2. Parse ARGUMENT_1 into a target ISE node list using comma-separated values.
3. Resolve certificate folder and find first `.pem` file.
4. Extract private key block and certificate block from the PEM (supports both `PRIVATE KEY` and `ENCRYPTED PRIVATE KEY`).
5. Enforce private key password behavior:
  - Encrypted key + blank password -> fail.
  - Unencrypted key + supplied password -> password is ignored with a warning.
6. Build Cisco ISE import payload.
  - `portalGroupTag` is included only when `portal` is enabled.
7. Generate certificate name using certificate CN + timestamp suffix (`yyyy-MM-dd_HHmmss`).
8. Skip blank or placeholder node values (for example, `ISE NODE X`).
9. Import certificate on each configured node using Cisco ISE REST API.
10. Force TLS 1.2 and apply configured TLS validation policy (standard trust, pinning fallback, or insecure bypass).
11. Log per-node result and summary; fail script if any node fails or is skipped.

Additional runtime notes:

- `ARGUMENT_5` values are normalized to lowercase; unknown service flags are ignored with a warning.
- Existing certificate lookup for old-vs-new portal tag context is best-effort and non-fatal.
- If no node succeeds, the script exits with failure.

## TLS Validation Configuration

The script is secure-by-default and validates TLS certificates using standard .NET trust checks.

### PinnedNodeThumbprints

Variable: `$PinnedNodeThumbprints` in `Windows/cisco_ise_certificate_delivery.ps1`

- Default: empty array (`@()`)
- Purpose: allow a node certificate only when its thumbprint matches one of your approved values.
- Recommended use: lab or transitional environments where ISE uses a self-signed or otherwise untrusted chain.
- Security effect: keeps protection against man-in-the-middle attacks by rejecting certificates with non-matching thumbprints.

Example:

```powershell
$PinnedNodeThumbprints = @(
  "AB12CD34EF56AB12CD34EF56AB12CD34EF56AB12",
  "00112233445566778899AABBCCDDEEFF00112233"
)
```

Notes:

- Use SHA-1 certificate thumbprints exactly as shown by your certificate tooling.
- The validator normalizes common separators (`:`, `-`, spaces), so pasted formats are accepted.
- Keep pinned values current when node certificates are rotated.

### PinnedIssuerThumbprints

Variable: `$PinnedIssuerThumbprints` in `Windows/cisco_ise_certificate_delivery.ps1`

- Default: empty array (`@()`)
- Purpose: restrict TLS trust to a specific Issuing CA (ICA) by thumbprint instead of relying solely on the Windows certificate store chain.
- Recommended use: environments where ISE node certificates are issued by an internal ICA that is present in the agent's certificate store, and you want to enforce which ICA is trusted.

#### Prerequisites

Ensure the Root CA and Issuing CA certificates are imported into the agent server's Windows certificate store:

- Root CA: `Cert:\LocalMachine\Root`
- Issuing CA: `Cert:\LocalMachine\CA`

#### Step 1 — Retrieve the ICA thumbprint

Run the following command on the agent server, substituting your Issuing CA's distinguished name:

```powershell
Get-ChildItem Cert:\LocalMachine\CA | Where-Object { $_.Subject -like "<Your-Issuing-CA-DN*>" } | Select-Object Subject, Thumbprint
```

Copy the `Thumbprint` value from the output.

#### Step 2 — Update the script

Open `Windows/cisco_ise_certificate_delivery.ps1` and update line 122:

```powershell
$PinnedIssuerThumbprints = @("<PASTE_ICA_THUMBPRINT_HERE>")
```

Example:

```powershell
$PinnedIssuerThumbprints = @("0836D29B72D4FEB9C431BC3FE6B2B79927943E6D")
```

To pin against multiple issuing CAs, add each thumbprint as a separate entry:

```powershell
$PinnedIssuerThumbprints = @(
  "0836D29B72D4FEB9C431BC3FE6B2B79927943E6D",
  "1A2B3C4D5E6F1A2B3C4D5E6F1A2B3C4D5E6F1A2B"
)
```

#### Step 3 — Import into TLM

Save the file and re-upload it in DigiCert TLM under Discovery & Automation tools > Scripts, replacing the previous version.

Notes:

- The thumbprint validator normalizes common separators (`:`, `-`, spaces), so pasted formats from certificate tooling are accepted.
- Keep pinned values current when the Issuing CA certificate is rotated.
- `PinnedIssuerThumbprints` enforces the issuer chain; `PinnedNodeThumbprints` enforces the leaf node certificate. Both can be used independently or together.

### AllowInsecureTlsBypass

Variable: `$AllowInsecureTlsBypass` in `Windows/cisco_ise_certificate_delivery.ps1`

- Default: `$false`
- Purpose: disables TLS certificate validation entirely for ISE API calls.
- Use only for short-lived lab troubleshooting when trust or pinning cannot be used.
- Security risk: disables chain, hostname, and trust validation for a call that carries API credentials and private key material.

Example:

```powershell
$AllowInsecureTlsBypass = $true
```

Important:

- Do not enable this in production.
- Revert to `$false` immediately after troubleshooting.
- Prefer CA-trusted certificates first, then thumbprint pinning, and use bypass only as a last resort.

## Logging

Two log files are written to `C:\Program Files\DigiCert\TLM Agent\log\`:

- `cisco_ise_cert_deploy_debug.log` — INFO, WARN, and ERROR flow messages.
- `cisco_ise_cert_deploy_api_calls.log` — API call trace entries.

If log paths are unavailable, script execution continues; logging failures are non-blocking.

## Exit Codes

- `0` — All provided nodes imported successfully (no failed or skipped nodes).
- `1` — Validation failure, parsing failure, API failure, or any failed/skipped node import.

## Legal

See the header comment block in `Windows/cisco_ise_certificate_delivery.ps1` for the full DigiCert legal notice.

## Version

Script version is tracked in `$SCRIPT_VERSION` (currently `2.1.0`).

## PowerShell Compatibility

This script is designed for **Windows PowerShell 5.1** and later. It uses PowerShell 5.1-compatible syntax and cmdlets for JSON decoding, credential construction, TLS handling, and REST invocation.

- Compatible shell: `powershell.exe` (Windows PowerShell 5.1+)

## Security Guidance

- Do not hardcode real credentials in source-controlled files.
- Sanitize all external input values before use.
- Treat API account password and PEM private key password as secrets.
