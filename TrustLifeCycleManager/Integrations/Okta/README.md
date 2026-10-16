# DigiCert TLM Agent — Okta Custom Domain Certificate Automation AWR Post-Delivery Script

## Overview

PowerShell automation script that updates the TLS certificate for an Okta custom domain using the Okta Management API.

The script is designed to be invoked as a post-delivery script by the DigiCert TLM Agent. It receives a PFX file and credentials at runtime, extracts the leaf certificate, intermediate chain, and private key as PEM, and then:

1. Locates the target Okta custom domain by name (or falls back to the certificate Common Name).
2. Upserts the certificate via the Okta Management API.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `okta_certificate_automation.ps1` | Windows | PowerShell 5.1+ |

## Requirements

- PowerShell 5.1 or later.
- Network access to:
  - `https://<yourorg>.okta.com` (Okta Management API)
- An Okta SSWS API token with sufficient admin permissions.
- The target Okta custom domain must be in `VERIFIED` state before a certificate can be uploaded.

## Permissions

The admin user who generates the SSWS token must have a role that includes the **Manage customizations** permission (under Security → Administrators → Roles). This covers creating, editing, and deleting branding customizations including custom domains and their certificates.

> **Note:** API calls made with an SSWS token must originate from the same IP address or network zone as the admin session used to create the token. Ensure the TLM Agent host's IP is added to a trusted network zone under **Security → Networks** before generating the token.

### Create a least-privilege service account (recommended)

1. Admin Console → **Security → Administrators → Roles** → **Create role**
2. Name: `TLM Certificate Automation`
3. Enable permission: **Manage customizations**
4. Admin Console → **Directory → People → Add person** — create a dedicated service account user
5. Admin Console → **Security → Administrators → Admins** → **Add administrator** — assign the role above to the service account
6. Sign in as the service account → **Security → API → Tokens → Create Token** — copy the token value immediately

## API Endpoints Used

| Operation | HTTP | Endpoint |
|-----------|------|----------|
| List custom domains | `GET` | `/api/v1/domains` |
| Upsert domain certificate | `PUT` | `/api/v1/domains/{domainId}/certificate` |

## Auth Mode

Uses an Okta SSWS API token passed directly as ARGUMENT_2, formatted as `SSWS <token>` in the `Authorization` header.

### Argument reference

| # | Name | Required | Description |
|---|------|----------|-------------|
| ARGUMENT_1 | Okta base URL | Yes | Okta org base URL, e.g. `https://yourorg.okta.com` |
| ARGUMENT_2 | SSWS API token | Yes | Okta SSWS API token — keep secret |
| ARGUMENT_3 | Target domain | Conditional | Custom domain name, e.g. `myorg.okta.com`; derived from the certificate CN when empty. Required when the certificate is a wildcard, since the CN cannot be used to resolve a specific domain |

### Production execution steps

    Step 1: Upload script to DigiCert ONE Portal
        1. Go to Discovery and Automation tools > Scripts
        2. Click Add script for > DigiCert Agents
        3. Enter script name and set:
                - Operating System: Windows
                - Script type: Admin request post-delivery
        4. Click Add and verify script

    Step 2: Configure Admin Web Request (AWR)
        5. Go to Inventory > Admin web request
        6. In STEP 1, fill in the parameters
        7. In STEP 2:
                - Click Add
                - Select Agent
                - Click Apply

    Step 3: Set certificate delivery
        8. Under DigiCert Agents, select the appropriate Agent
        9. Under Destination 1, configure:
                - Format: PKCS12
                - Target path: certificate folder path
                - Provide password
       10. Enable Run post delivery Scripts
       11. Select the uploaded script
       12. Fill the arguments as listed in the Argument reference above

    Step 4: Complete request
       13. Proceed with the remaining configuration steps

Note: The TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script during delivery.

## Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and resolve arguments.
2. Locate PKCS12 file (`.pfx` or `.p12`) from the delivery folder.
3. Build the authorization header: format `SSWS <token>` directly.
4. Load and parse the PFX file, extracting:
   - Leaf certificate PEM (cert with private key).
   - CA chain PEM (remaining certs, concatenated).
   - Private key PEM — PKCS#8 on PS7+; PKCS#1 RSA on PS5.1 via manual DER encoding.
5. Resolve target domain — use ARGUMENT_3 if provided; otherwise extract the CN from the leaf certificate subject.
6. Call `GET /api/v1/domains` to list all custom domains and find the target by name (case-insensitive).
7. Validate domain eligibility:
   - `validationStatus` must be `VERIFIED` — stop if not.
   - Warn if `certificateSourceType` is `OKTA_MANAGED` (certificate ownership will transfer to `MANUAL`).
8. Call `PUT /api/v1/domains/{domainId}/certificate` with the PEM payload. Retries up to 3 times on HTTP 429.
9. Log success with domain name, domain ID, and org URL.

## Logging

Logs are written to:

- `C:\Program Files\DigiCert\TLM Agent\log\okta_certificate_automation.log`

INFO, WARN, ERROR, and SUCCESS messages are printed to the console. DEBUG messages are written to the log file only.

Sensitive values — SSWS token, PFX password, certificate content, and private key — are always redacted in logs.

## Exit codes

- `0` — certificate upsert completed successfully.
- `1` — legal notice not accepted, validation failed, authentication failed, domain not found, or API call failed.

## Security Considerations

- Do not hardcode secrets in the script file. Pass credentials via AWR arguments and keep local test values out of version control.
- Ensure least-privilege permissions: the SSWS admin role should cover only the **Manage customizations** permission.
- Uploading a manual certificate to an `OKTA_MANAGED` domain disables Okta's automatic certificate renewal. Ensure TLM renewals are scheduled before expiry.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Script exits with legal notice error | `$LEGAL_NOTICE_ACCEPT` is not `"true"` | Set `$LEGAL_NOTICE_ACCEPT = "true"` at the top of the script |
| `DC1_POST_SCRIPT_DATA` not set | Script not invoked through expected flow | Verify TLM Agent post-delivery configuration and execution context |
| List domains fails (401) | SSWS token is invalid or expired, or was created from a different IP | Regenerate the token from the TLM Agent's network; check trusted network zones |
| List domains fails (403) | Admin role lacks Manage customizations permission | Grant the permission as described in the Permissions section |
| Upsert certificate fails (400) — "not supported for this domain" | Domain `validationStatus` is not `VERIFIED`, or domain is a built-in Okta domain | Complete domain verification in Okta Admin Console (Customizations → Brands → Domains) |
| Upsert certificate fails (403) | SSWS admin lacks **Manage customizations** | Grant the required permission, then issue a new SSWS token |
| Domain not found | Domain name mismatch, or domain does not exist in the org | Check the exact domain name in Okta Admin Console; verify ARGUMENT_3 or the certificate CN |
| No CN found in certificate | Certificate subject has no CN field | Provide the target domain explicitly via ARGUMENT_3 |
| Private key export fails on PS5.1 | Certificate uses an EC (ECDSA) key | EC key export requires PS7+; re-enroll with an RSA key or upgrade PowerShell |
| No PFX file found | AWR delivery format is not PKCS12, or target path is wrong | Set delivery format to PKCS12 in the AWR configuration |

## Legal

See the header comment block in `okta_certificate_automation.ps1` for the full DigiCert legal notice. `$LEGAL_NOTICE_ACCEPT` must be `"true"` for the script to run.

## Version

Script version is tracked in the `$SCRIPT_VERSION` constant (currently `1.0.0`).
