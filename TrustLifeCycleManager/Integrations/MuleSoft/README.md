# MuleSoft CloudHub 2.0 — Admin Web Request post-enrollment script

`MuleSoftCH2CertDeploy-PEM.ps1` deploys a certificate issued by **DigiCert Trust Lifecycle Manager (TLM)** to a **MuleSoft Anypoint CloudHub 2.0 private space** as a **TLS context** (the ingress certificate for the private space). It runs as a **post-enrollment automation script** inside the DigiCert TLM Agent after a certificate is issued or renewed, and talks to the CloudHub 2.0 REST API with an Anypoint **Connected App**.

| Script | Platform | Location |
|--------|----------|----------|
| `MuleSoftCH2CertDeploy-PEM.ps1` | Windows (PowerShell 5.1+, PowerShell 7+ supported) | [MuleSoftCH2CertDeploy-PEM.ps1](MuleSoftCH2CertDeploy-PEM.ps1) |

---

## Overview

A CloudHub 2.0 private space terminates TLS at its ingress using a **TLS context** that holds a certificate, a private key and an optional CA path. The script keeps one TLS context current:

- **TLS context does not exist** → it is created (`POST`) with a TLS 1.2 / 1.3 ECDHE-GCM / ChaCha20 cipher set.
- **TLS context already carries this certificate** → nothing is changed, exit 0. The leaf thumbprint is embedded in the keystore file names that Anypoint stores, so the script can tell exactly which certificate is deployed. CN and expiry date alone cannot: a reissue often has the same CN and the same expiry date.
- **TLS context carries an older certificate** → the keystore is replaced in place (`PATCH`). The context keeps its ID, so applications and ingress bindings that reference it are not touched.

After the change the script waits, re-reads the TLS context and verifies that the new CN, expiry date and thumbprint-stamped file name landed. The leaf is sent as the certificate and the intermediates as the CA path. The self-signed root is excluded by default.

API endpoints used (base `https://anypoint.mulesoft.com/runtimefabric/api`, or the EU / GOV equivalent):

```
POST  /accounts/api/v2/oauth2/token                                         (client credentials)
GET   /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts
POST  /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts
PATCH /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts/{tlsContextId}
```

Every API call is bounded by a timeout. HTTP 429 and 5xx responses are retried with exponential back-off.

---

## Prerequisites

- **DigiCert TLM Agent** on a Windows host with post-enrollment script execution enabled.
- **PowerShell 5.1** or later. PowerShell 7+ is required only if the TLM profile delivers a **PFX** instead of PEM, because the private key has to be exported to PEM on the agent.
- Outbound HTTPS from the agent host to the Anypoint control plane (`anypoint.mulesoft.com`, `eu1.anypoint.mulesoft.com` or `gov.anypoint.mulesoft.com`).
- An Anypoint **Connected App** of type *App acts on its own behalf* (client credentials) with these **Runtime Manager** scopes on the business group that owns the private space:
  - **Cloudhub Network Administrator** — create / update TLS contexts
  - **Cloudhub Network Viewer** — read private spaces and TLS contexts
- A CloudHub 2.0 **private space** that already exists. The script does not create private spaces.

---

## How it is triggered

```
DigiCert TLM issues/renews certificate
        │
        ▼
TLM Agent writes cert + key (+ chain) files to disk
        │
        ▼
TLM Agent sets DC1_POST_SCRIPT_DATA (base64-encoded JSON payload)
        │
        ▼
TLM Agent executes MuleSoftCH2CertDeploy-PEM.ps1
        │
        ▼
Script decodes DC1_POST_SCRIPT_DATA → reads the PEM files and the arguments
        │
        ▼
Script validates every argument, authenticates to Anypoint, creates or patches the TLS context
        │
        ▼
Script re-reads the TLS context, verifies the deployment and logs the result
```

`DC1_POST_SCRIPT_DATA` is a Base64-encoded JSON object:

```json
{
  "certfolder": "C:\\Program Files\\DigiCert\\TLM Agent\\certs\\<job>",
  "files": ["test.domain.com.pem"],
  "password": "<key passphrase, present when the key is encrypted>",
  "args": ["<ORG_ID>", "<PRIVATE_SPACE_ID>", "<TLS_CONTEXT_NAME>", "<CLIENT_ID>", "<CLIENT_SECRET>", "<CONTROL_PLANE>"]
}
```

The script accepts the certificate, key and chain as separate files or as one combined PEM in any order. Key formats: PKCS#8 (`PRIVATE KEY`), encrypted PKCS#8 (`ENCRYPTED PRIVATE KEY`), PKCS#1 (`RSA PRIVATE KEY`) and SEC1 (`EC PRIVATE KEY`). When the key is encrypted, the payload password is passed to Anypoint as `keyPassphrase`.

---

## TLM profile certificate delivery

| Delivery | Supported | Notes |
|----------|-----------|-------|
| **PEM** — certificate, private key and chain | Yes, recommended | Unencrypted or encrypted key. Separate files or one combined file. |
| **PFX / PKCS#12** | Yes | The agent must run the script with **PowerShell 7+** (`pwsh`) to export the key as PEM. |

---

## Script configuration

Edit these variables in the `SCRIPT SETTINGS` block near the top of the script before deploying:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"true"` | Must be `"true"` to allow execution. Any other value stops the script before it reads the payload, logs an error and exits 1. |
| `LOG_FILE` | `C:\Program Files\DigiCert\TLM Agent\log\mulesoft_ch2_data.log` | Path to the script log file. The directory is created if missing. |
| `CONTROL_PLANE_DEFAULT` | `US` | Control plane used when ARGUMENT_6 is blank. `US`, `EU` or `GOV`. |
| `API_TIMEOUT_SECONDS` | `120` | Timeout per Anypoint API call. |
| `API_MAX_ATTEMPTS` | `4` | Attempts for HTTP 429 / 5xx responses (exponential back-off between attempts). |
| `VERIFY_DELAY_SECONDS` | `5` | Wait before the TLS context is re-read for verification. |
| `INCLUDE_ROOT_CA` | `"false"` | `"true"` also sends the self-signed root in the CA path. Normally not required. |
| `NEW_CONTEXT_CIPHERS` | TLS 1.2 ECDHE-GCM / ChaCha20 + TLS 1.3 suites | Cipher set applied **only when a new TLS context is created**. Existing contexts keep their ciphers. |

---

## Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Name | Required | Description | Example |
|----------|------|----------|-------------|---------|
| 1 | `ORG_ID` | Yes | Anypoint organization / business group ID (GUID) that owns the private space | `3598da9f-eae1-4d5c-ad9e-8936732cf3cf` |
| 2 | `PRIVATE_SPACE_ID` | Yes | CloudHub 2.0 private space ID (GUID) | `16280aa6-5aad-4d56-aa33-5ef1b56b36ce` |
| 3 | `TLS_CONTEXT_NAME` | No | Name of the TLS context to create or update. Blank = derived from the certificate CN (`api.contoso.com` → `api-contoso-com`, `*.contoso.com` → `wildcard-contoso-com`). | `tlm-tls-context` |
| 4 | `CLIENT_ID` | Yes | Connected App client ID (32 hex characters) | `a2df3e44215e4007a3faa112a3f6d7c3` |
| 5 | `CLIENT_SECRET` | Yes | Connected App client secret | `********************************` |
| 6 | `CONTROL_PLANE` | No | Anypoint control plane: `US`, `EU` or `GOV`. Blank = `CONTROL_PLANE_DEFAULT`. | `US` |

**Position-independent form.** Any argument may be written as `NAME=value`, for example `TLS_CONTEXT_NAME=api-contoso-com` or `CONTROL_PLANE=EU`. A `NAME=value` argument is read by its name regardless of which slot it is in; that slot is then treated as used. Optional arguments can be left blank, entered as `-`, or left out at the end.

**Validation before any change.** The script checks every argument before it authenticates: GUID format for ORG_ID and PRIVATE_SPACE_ID, that the two are not identical, 32-hex format for CLIENT_ID, that TLS_CONTEXT_NAME does not look like a GUID or a client ID (shifted arguments), that CLIENT_SECRET does not look like a GUID, and that CONTROL_PLANE is one of `US`, `EU`, `GOV`. All validation errors are reported together and values are masked in the messages (first four characters plus length), because a shifted argument list can put the client secret in any position.

### Where to find the values

| Value | Location in Anypoint Platform |
|-------|-------------------------------|
| `ORG_ID` | Access Management → Business Groups → *your group* → **Organization ID** |
| `PRIVATE_SPACE_ID` | Runtime Manager → Private Spaces → *your space* → the GUID after `/privatespaces/` in the browser URL |
| `CLIENT_ID` / `CLIENT_SECRET` | Access Management → Connected Apps → *your app* (type **App acts on its own behalf**) |

---

## Flow

```
1. Check LEGAL_NOTICE_ACCEPT
2. Decode DC1_POST_SCRIPT_DATA; read the AWR arguments (positional or NAME=value)
3. Read every payload file: extract private key and certificate blocks (combined or separate PEM; PFX converted on PowerShell 7+)
4. Order the chain: leaf → intermediates (root excluded unless INCLUDE_ROOT_CA = "true")
   Refuse to deploy an already expired leaf
5. Derive TLS_CONTEXT_NAME from the CN if ARGUMENT_3 is blank
6. Validate every argument - stop here with a combined error if anything is wrong
7. Authenticate: POST /accounts/api/v2/oauth2/token (client credentials); the secret is cleared from memory afterwards
8. GET the private space TLS contexts and look for TLS_CONTEXT_NAME
   a. Found, type = default            → stop (the platform default context cannot be modified)
   b. Found, file name carries the new leaf thumbprint → "already deployed", exit 0 (unless -Force)
   c. Found, different certificate     → PATCH tlsConfig.keyStore (leaf + CA path)
   d. Not found                        → POST new TLS context (leaf + CA path + NEW_CONTEXT_CIPHERS)
   If the API rejects the CA path field (HTTP 400/422), the request is retried with the leaf only and a WARN is logged
9. Wait VERIFY_DELAY_SECONDS, re-read the TLS context
   - file name carries the thumbprint AND expiry matches  → "Verified"
   - only one of the two matches                          → WARN (Anypoint may still be applying)
   - neither matches                                      → error, exit 1
10. Log summary and exit
```

Keystore file names sent to Anypoint are `<context-name>-<first 16 hex of thumbprint>-cert.pem`, `-key.pem` and `-ca.pem`, truncated to the 64-character limit Anypoint enforces. Anypoint returns `fileName` on every read, which is how the next run recognises the deployed certificate.

---

## Example log

Default location: `C:\Program Files\DigiCert\TLM Agent\log\mulesoft_ch2_data.log`. The same lines are written to standard output so the TLM Agent captures them in its own job log.

A renewal run where the TLS context already existed with an older certificate (`PATCH` path):

```
2026-10-19 09:03:31 [INFO] ===== MuleSoft CloudHub 2.0 TLS context deploy v1.0.0 - start =====
2026-10-19 09:03:31 [INFO] Mode: TLM AWR (DC1_POST_SCRIPT_DATA present)
2026-10-19 09:03:31 [INFO] Payload file: test.domain.com.pem
2026-10-19 09:03:31 [INFO]   contains: 3 certificate(s) + encrypted private key
2026-10-19 09:03:31 [INFO] Leaf: CN=test.domain.com | Serial=6995DD957B2768E50977370247D0ED4D1B363EBA | Thumbprint=19D9B4EE1A0A760A4B9178E961595086405594DD | NotAfter=2026-10-28 23:59:59Z | chain certs=2
2026-10-19 09:03:31 [INFO] Settings: ORG_ID=3598da9f-eae1-4d5c-ad9e-8936732cf3cf | PRIVATE_SPACE_ID=16280aa6-5aad-4d56-aa33-5ef1b56b36ce | TLS_CONTEXT_NAME=tlm-tls-context | CLIENT_ID=a2df3e44215e4007a3faa112a3f6d7c3 | CLIENT_SECRET=*** | CONTROL_PLANE=US
2026-10-19 09:03:31 [INFO] Authenticated to Anypoint Platform (connected app).
2026-10-19 09:03:31 [INFO] Existing context id=dae4712b-c426-4b5b-9a16-1a8b40dc507f | CN=abc.domain.com | expires=2026-11-17 | file=abc.domain.com-leaf.pem
2026-10-19 09:03:31 [INFO] Deployed certificate differs from the new certificate - deploying.
2026-10-19 09:03:31 [INFO] Sending PATCH to Anypoint (timeout 120s): leaf certificate + CA path (intermediates)...
2026-10-19 09:03:33 [INFO] PATCH accepted (leaf + CA path chain)
2026-10-19 09:03:33 [INFO] PATCH succeeded. TLS context id=dae4712b-c426-4b5b-9a16-1a8b40dc507f
2026-10-19 09:03:38 [INFO] Verify: id=dae4712b-c426-4b5b-9a16-1a8b40dc507f | CN=test.domain.com | expires=2026-10-28 | file=tlm-tls-context-19d9b4ee1a0a760a-cert.pem | SAN=
2026-10-19 09:03:38 [INFO] Verified: deployed file carries thumbprint 19D9B4EE1A0A760A4B9178E961595086405594DD and expiry 2026-10-28 matches.
2026-10-19 09:03:38 [INFO] ===== Completed successfully =====
```

What to look for:

| Line | Meaning |
|------|---------|
| `contains: 3 certificate(s) + encrypted private key` | The payload file held leaf + intermediate + root and an encrypted key. The payload password is forwarded as `keyPassphrase`. |
| `chain certs=2` | Leaf + one intermediate are sent. The root was excluded (`INCLUDE_ROOT_CA = "false"`). |
| `CLIENT_SECRET=***` | The secret is never written to the log. |
| `Existing context ... file=abc.domain.com-leaf.pem` | The deployed file name does not carry the new thumbprint, so the context is on a different certificate. |
| `PATCH accepted (leaf + CA path chain)` | Anypoint accepted the intermediates in `capath`. If it had rejected the field, a WARN would show the leaf-only retry. |
| `file=tlm-tls-context-19d9b4ee1a0a760a-cert.pem` | The re-read context now carries the first 16 hex characters of the new thumbprint. |

A second run with the same certificate logs `Certificate already deployed (thumbprint ... matches the deployed file ...) - nothing to do.` followed by `===== Completed (no change) =====` and exits 0.

A failed argument validation looks like this and makes no change:

```
2026-10-22 16:23:32 [ERROR] Argument validation failed - no change made:
2026-10-22 16:23:32 [ERROR]   - ARGUMENT_1 and ARGUMENT_2 are identical - ORG_ID and PRIVATE_SPACE_ID are different values.
2026-10-22 16:23:32 [ERROR]   - ARGUMENT_3 TLS_CONTEXT_NAME '3598****' (length 36) looks like a GUID - arguments appear shifted.
2026-10-22 16:23:32 [ERROR]   - ARGUMENT_4 CLIENT_ID 's3cr****' (length 16) is not a 32-character hex Connected App ID (check for spaces or a shifted argument).
2026-10-22 16:23:32 [ERROR] ===== FAILED =====
```

---

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Certificate deployed and verified, or already current (no change) |
| `1` | Failure. TLM marks the AWR job as failed. The reason is the last `[ERROR]` lines in the log. |

---

## Manual / lab run (without the TLM Agent)

When `DC1_POST_SCRIPT_DATA` is not set the script reads its inputs from parameters:

```powershell
.\MuleSoftCH2CertDeploy-PEM.ps1 -CertFile .\api.crt -KeyFile .\api.key -ChainFile .\chain.pem `
    -OrgId <org-guid> -SpaceId <space-guid> -TlsContextName api-contoso-com `
    -ClientId <client-id> -ClientSecret <client-secret> -ControlPlane US -DryRun
```

| Parameter | Description |
|-----------|-------------|
| `-CertFile`, `-KeyFile`, `-ChainFile` | PEM files. `-ChainFile` is optional; a combined file can be given as `-CertFile`. |
| `-OrgId`, `-SpaceId`, `-TlsContextName`, `-ClientId`, `-ClientSecret`, `-ControlPlane` | Same meaning as ARGUMENT_1 to ARGUMENT_6. |
| `-DryRun` | Authenticates, reads the existing TLS context and logs the request that would be sent (private key and passphrase redacted) without changing anything. |
| `-Force` | Redeploys even when the deployed file name already carries the new thumbprint. |
| `-LogFile` | Overrides `LOG_FILE` for this run. |

Parameters are ignored for any value that the TLM AWR payload supplies.

---

## Troubleshooting

| Symptom | Cause / action |
|---------|----------------|
| `LEGAL_NOTICE_ACCEPT is not "true"` | Set the variable in `SCRIPT SETTINGS` after reviewing the legal notice in the script header. |
| `Argument validation failed` | Read the listed items. Most often the arguments are in the wrong slots or a GUID has a missing character. Nothing was changed. |
| `HTTP 401 POST .../oauth2/token` | Wrong client ID / secret, or the Connected App is not *App acts on its own behalf*. |
| `HTTP 403` on `tlsContexts` | The Connected App lacks **Cloudhub Network Administrator / Viewer** on the business group that owns the private space, or ORG_ID is a different business group. |
| `HTTP 404` on `tlsContexts` | PRIVATE_SPACE_ID is wrong or belongs to another business group. |
| `TIMEOUT after 120s` | Anypoint did not answer. If the private space shows *Saved changes are being applied* or a FAILED network, changes are queued until the space is healthy. |
| `TLS context '<name>' is the platform default context and cannot be modified` | Use a different TLS_CONTEXT_NAME. The default context is managed by MuleSoft. |
| `No private key found in the TLM payload` | Enable key delivery (PEM key or PFX) in the TLM profile. |
| `PFX delivery requires PowerShell 7+` | Switch the profile to PEM delivery or run the agent script with `pwsh`. |
| `Intermediate chain NOT attached` (WARN) | The API rejected `capath`; the leaf was deployed alone. Add the CA path in Runtime Manager if clients need it. |
| `Post-deploy check failed` | Anypoint did not report the new certificate after the verify delay. Check the TLS context in Runtime Manager; increase `VERIFY_DELAY_SECONDS` if the space is slow to apply changes. |

---

## Security notes

- The client secret is read from ARGUMENT_5, used once for the token request, and then cleared. It is masked as `***` in the log and in validation messages.
- ORG_ID and PRIVATE_SPACE_ID are validated as GUIDs before they are placed in any URL. The API host is fixed per control plane and never comes from an argument.
- TLS 1.2 is enforced for all API calls.

---
