# Admin Web Request Post Script – F5 Distributed Cloud (XC) Certificate Upload

Automated certificate deployment to **F5 Distributed Cloud** (formerly Volterra) using DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment scripting. The script uploads or replaces a named certificate object in an F5 XC namespace via the F5 XC Configuration API.

## Overview

This script runs as an **Admin Web Request (AWR) post-enrollment script** triggered by the DigiCert TLM Agent. After the agent enrols or renews a certificate, the script:

1. Decodes the AWR payload and extracts the certificate, key, and configuration arguments
2. Checks whether the named certificate object already exists in the target F5 XC namespace
3. **Creates** a new certificate object if it doesn't exist, or **replaces** it if it does
4. Verifies the certificate object was stored in F5 XC

The operation is idempotent: running it again against the same object name simply replaces the object.

## Script

| File | Platform | Shell |
|------|----------|-------|
| [`f5_xc-awr.sh`](f5_xc-awr.sh) | Linux | Bash |

Only a Linux version is provided at present. The script relies on GNU coreutils behaviour (`base64 -w 0`, `stat -c%s`) and `grep -P`, so it is intended for the TLM Agent for Linux.

## Workflow

```
┌──────────────────────┐
│  DigiCert TLM        │
│  (Certificate        │
│   Authority)         │
└─────────┬────────────┘
          │ Enrol / Renew
          ▼
┌──────────────────────┐     DC1_POST_SCRIPT_DATA     ┌──────────────────────┐
│  DigiCert TLM        │ ──────────────────────────▶   │  f5_xc-awr.sh        │
│  Agent               │       (Base64 JSON)           │                      │
└──────────────────────┘                               └─────────┬────────────┘
                                                                 │
                                                                 ▼
                                              ┌──────────────────────────────┐
                                              │ GET  /certificates/{name}    │  exists?
                                              └────────┬─────────────────────┘
                                                  Yes  │  No
                                                  ▼    ▼
                                            ┌───────┐ ┌───────┐
                                            │ PUT   │ │ POST  │  Base64 cert + key
                                            │Replace│ │Create │  as string:/// URIs
                                            └───┬───┘ └───┬───┘
                                                └────┬────┘
                                                     ▼
                                              ┌──────────────────────────────┐
                                              │ GET  /certificates/{name}    │  verify name + expiry
                                              └──────────────────────────────┘
                                                     ▼
                                              ┌──────────────────┐
                                              │  F5 Distributed  │
                                              │  Cloud namespace │
                                              └──────────────────┘
```

## What the Script Does

**1. Payload extraction** — Reads the `DC1_POST_SCRIPT_DATA` environment variable set by the TLM Agent, decodes the Base64 JSON payload, and extracts the certificate folder, the `.crt` and `.key` filenames, and the AWR arguments. The API token is obfuscated before any part of the payload is logged.

**2. File inspection** — Confirms the certificate and key files exist, logs their sizes, counts the certificates in the chain, and detects the private key type (RSA, EC, or PKCS#8).

**3. Existence check** — Issues a `GET` for the named certificate object in the target namespace. HTTP 200 means it exists.

**4. Create or replace** — Base64-encodes the certificate chain and private key, wraps them in the `string:///` URI scheme F5 XC expects, and either `POST`s a new certificate object or `PUT`s over the existing one.

**5. Verification** — Reads the object back and logs its name and expiry timestamp.

## Prerequisites

### F5 Distributed Cloud

- An **F5 XC tenant** with API access enabled
- An **F5 XC API token** with permission to manage certificate objects in the target namespace

### TLM Agent

- **DigiCert TLM Agent for Linux** installed and configured with a certificate profile that outputs PEM certificate and key files and invokes this script as its post-enrollment script

### Host tooling

| Requirement | Notes |
|-------------|-------|
| `bash` | |
| `curl` | All API calls |
| `base64` | GNU coreutils, `-w 0` is used |
| `grep` with PCRE (`-P`) | JSON field extraction |
| `awk`, `sed`, `tr`, `stat` | GNU versions |

The script does not depend on `jq` or `openssl`.

## Configuration

### Script variables

Edit the configuration block at the top of the script:

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/etc/digicert/AWR-Logs/f5-xc.log"
```

| Variable | Description |
|----------|-------------|
| `LEGAL_NOTICE_ACCEPT` | Must be set to `"true"` before the script will execute. |
| `LOGFILE` | Path of the timestamped log file. The directory must exist and be writable by the account the TLM Agent runs as. |

### AWR arguments

Everything that identifies the F5 XC target is supplied through the certificate profile's AWR arguments rather than hard-coded in the script, so the same script file can serve many profiles. The TLM Agent passes them inside the `DC1_POST_SCRIPT_DATA` payload.

| Argument | Description | Example | Required |
|----------|-------------|---------|----------|
| `Argument 1` | F5 XC tenant short name | `my-company` | Yes |
| `Argument 2` | F5 XC namespace | `production` | Yes |
| `Argument 3` | Certificate object name in F5 XC | `www-example-com` | Yes |
| `Argument 4` | F5 XC API token | `(token)` | Yes |
| `Argument 5` | _(Reserved, not used)_ | — | No |

The arguments array is split on commas, so no argument value may contain a comma. Whitespace is stripped from every value.

If any of the four required arguments is empty, the script logs the problem and skips the upload rather than calling the API.

## Certificate Payload Format

The certificate and key are Base64-encoded and submitted using the `string:///` URI scheme:

```json
{
  "metadata": {
    "name": "<cert-name>",
    "namespace": "<namespace>"
  },
  "spec": {
    "certificate_url": "string:///<base64-cert-chain-pem>",
    "private_key": {
      "clear_secret_info": {
        "url": "string:///<base64-key-pem>"
      }
    }
  }
}
```

## F5 XC API Endpoints Used

All endpoints share the base URL:

```
https://{tenant}.console.ves.volterra.io/api/config/namespaces/{namespace}/certificates
```

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/{cert-name}` | Check whether the object exists; verify after upload |
| `POST` | `/` | Create a new certificate object |
| `PUT` | `/{cert-name}` | Replace an existing certificate object |

Authentication is via the `Authorization: APIToken {token}` header.

## Logging

The script writes detailed, timestamped entries to `LOGFILE`. The API token is obfuscated everywhere it could appear, including the raw payload dump and any error response bodies. Only the first and last four characters are shown (`abcd****wxyz`); tokens of eight characters or fewer are fully redacted.

The log includes:

- Configuration summary
- AWR payload extraction details
- Certificate and key file metadata (size, key type, certificate count)
- F5 XC API call results with HTTP status codes
- Post-upload verification (object name and expiry timestamp)

Default log location: `/etc/digicert/AWR-Logs/f5-xc.log`

## Security Considerations

- The **API token** is the most sensitive value. It travels inside the AWR payload and is redacted from all log output.
- The private key is Base64-encoded in memory and sent over HTTPS to the F5 XC API. The encoded form is never written to disk.
- The `LEGAL_NOTICE_ACCEPT` flag must be explicitly set to `"true"` before the script will execute.
- Issue a dedicated F5 XC API token with the minimum required permissions (certificate management in the target namespace only) and rotate it regularly.
- The log file contains the decoded payload with only the token masked, so protect the log directory accordingly.

## Supported Key Types

The script detects and logs the private key type from the PEM header:

- RSA (`BEGIN RSA PRIVATE KEY`)
- EC (`BEGIN EC PRIVATE KEY`)
- PKCS#8 (`BEGIN PRIVATE KEY`)

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Script exits immediately with legal notice error | `LEGAL_NOTICE_ACCEPT` not set to `"true"` | Edit the variable at the top of the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script not invoked by the TLM Agent AWR flow | Verify the post-enrollment script path in the certificate profile |
| `Missing required F5 XC parameters` | One of Arguments 1 to 4 is empty | Check the AWR argument configuration in the profile |
| `Certificate file not found` / `Private key file not found` | Profile does not output PEM `.crt` and `.key` files | Adjust the profile's output format |
| HTTP 401 on API calls | Invalid or expired API token | Regenerate the token in the F5 XC console and update `Argument 4` |
| HTTP 403 on API calls | Insufficient permissions | Ensure the token can manage certificates in the target namespace |
| HTTP 409 on `POST` | Object already exists but the existence `GET` did not return 200 | Check that the `GET` is succeeding, usually a token or namespace problem |
| Certificate not visible in the XC console | Wrong namespace | Confirm `Argument 2` matches the intended namespace |
| No log file written | `LOGFILE` directory missing or not writable | Create the directory and grant the agent account write access |
| `base64: invalid input` | Corrupted certificate or key file | Verify the TLM Agent produced valid PEM files |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in the script for full terms.
