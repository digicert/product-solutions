# DigiCert TLM Agent — F5 Distributed Cloud (XC) AWR Post-Enrollment Script

Automated certificate deployment to **F5 Distributed Cloud** (formerly Volterra) using a DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment (AWR) script. The script uploads or replaces certificates in an F5 XC namespace via the F5 XC Configuration API.

## Overview

This script is triggered automatically by the DigiCert TLM Agent after a certificate is enrolled or renewed. It handles idempotent certificate management on F5 Distributed Cloud:

1. Decode the AWR payload and extract the certificate, key, and configuration arguments
2. Check whether the named certificate already exists in the target F5 XC namespace
3. **Create** a new certificate object if it doesn't exist, or **replace** it if it does
4. Verify the certificate was successfully stored in F5 XC

## Script

| File | Platform | Shell |
|------|----------|-------|
| `f5_xc-awr.sh` | Linux | Bash |

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an active certificate profile
- **F5 Distributed Cloud** tenant with API access enabled
- An **F5 XC API Token** with permissions to manage certificates in the target namespace
- `curl`, `base64`, `grep` (with `-P` / PCRE support) on the TLM Agent host
- Optionally `jq` for enhanced JSON parsing

## Configuration

### Script Variables

Edit the variables at the top of the script before deployment:

```bash
# Legal notice must be accepted to run
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/path/to/tlm_agent/log/f5_xc-data.log"
```

### AWR Arguments

The script receives four arguments (plus one reserved) via the TLM Agent AWR configuration, passed through the `DC1_POST_SCRIPT_DATA` environment variable as a Base64-encoded JSON payload:

| Argument | Description | Example | Required |
|----------|-------------|---------|----------|
| `Argument 1` | F5 XC tenant name | `my-company` | Yes |
| `Argument 2` | F5 XC namespace | `production` | Yes |
| `Argument 3` | Certificate object name in F5 XC | `www-example-com` | Yes |
| `Argument 4` | F5 XC API Token | `(token)` | Yes |
| `Argument 5` | _(Reserved — not used)_ | — | No |

## How It Works

### Step-by-Step Workflow

```
TLM Agent enrolls/renews cert
        │
        ▼
┌──────────────────────────────┐
│ 1. Decode AWR payload        │  ← DC1_POST_SCRIPT_DATA (Base64 → JSON)
│    Extract cert, key, args   │
└────────┬─────────────────────┘
         ▼
┌──────────────────────────────┐
│ 2. Check if cert exists      │  ← GET /api/config/namespaces/{ns}/certificates/{name}
│    in F5 XC namespace        │
└────────┬─────────────────────┘
         ▼
    ┌────┴────┐
    │ Exists? │
    └────┬────┘
    Yes  │  No
    ▼    ▼
┌───────┐ ┌───────┐
│ PUT   │ │ POST  │  ← Replace or create certificate object
│Replace│ │Upload │     with Base64-encoded cert + key
└───┬───┘ └───┬───┘
    └────┬────┘
         ▼
┌──────────────────────────────┐
│ 3. Verify certificate        │  ← GET /api/config/namespaces/{ns}/certificates/{name}
│    in F5 XC                  │     Confirm name and expiry
└──────────────────────────────┘
```

### Certificate Payload Format

The script Base64-encodes the certificate and private key files, then submits them to the F5 XC API using the `string:///` URI scheme expected by the platform:

```json
{
  "metadata": {
    "name": "<cert-name>",
    "namespace": "<namespace>"
  },
  "spec": {
    "certificate_url": "string:///<base64-cert>",
    "private_key": {
      "clear_secret_info": {
        "url": "string:///<base64-key>"
      }
    }
  }
}
```

## F5 XC API Endpoints Used

All endpoints use the base URL pattern:

```
https://{tenant}.console.ves.volterra.io/api/config/namespaces/{namespace}/certificates
```

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/{cert-name}` | Check if certificate exists / verify after upload |
| `POST` | `/` | Create a new certificate object |
| `PUT` | `/{cert-name}` | Replace an existing certificate object |

Authentication is via the `Authorization: APIToken {token}` header.

## Logging

The script produces detailed, timestamped logs. The API token is obfuscated throughout — only the first and last four characters are shown (e.g., `abcd****wxyz`). Tokens of eight characters or fewer are fully redacted.

The log includes:

- Configuration summary
- AWR payload extraction details
- Certificate and key file metadata (size, key type, cert count)
- F5 XC API call results (success/failure with HTTP codes)
- Post-upload verification (certificate name and expiry timestamp)

Default log location: `/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5_xc-data.log`

Adjust the `LOGFILE` variable to match your TLM Agent installation path.

## Security Considerations

- The **API Token** is the most sensitive value — the script obfuscates it in all log output and error responses using the `obfuscate_token()` function
- The private key is Base64-encoded and transmitted over HTTPS to the F5 XC API; it is never written to disk in encoded form
- The `LEGAL_NOTICE_ACCEPT` flag must be explicitly set to `"true"` before the script will execute
- Generate a dedicated F5 XC API token with the minimum required permissions (certificate management only) and rotate it regularly

## Supported Key Types

The script detects and logs the private key type:

- RSA (`BEGIN RSA PRIVATE KEY`)
- ECC (`BEGIN EC PRIVATE KEY`)
- PKCS#8 (`BEGIN PRIVATE KEY`)

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Script exits immediately | `LEGAL_NOTICE_ACCEPT` not set to `"true"` | Edit the variable at the top of the script |
| `DC1_POST_SCRIPT_DATA` not set | Script not invoked by TLM Agent AWR | Verify the post-enrollment script path in TLM Agent config |
| HTTP 401 on API calls | Invalid or expired API token | Regenerate the token in the F5 XC console and update `Argument 4` |
| HTTP 403 on API calls | Insufficient permissions | Ensure the API token has certificate management access to the target namespace |
| HTTP 409 on POST (create) | Certificate name already exists | The script handles this automatically by checking first, but verify the `GET` call is succeeding |
| Certificate not visible in XC console | Wrong namespace | Confirm `Argument 2` matches the namespace where the cert should appear |
| `base64: invalid input` | Corrupted cert/key files | Verify the TLM Agent produced valid PEM files in the cert folder |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in the script for full terms.