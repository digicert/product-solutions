# DigiCert – Cloudflare Custom Certificate Automation

Automated SSL/TLS certificate issuance and deployment to Cloudflare using DigiCert ONE mPKI and the Cloudflare API.

## Overview

This repository contains three scripts that automate the lifecycle of Cloudflare custom SSL certificates backed by DigiCert. There are two approaches depending on how the certificate is obtained:

**Approach A — Standalone script** that handles the full lifecycle end-to-end: generates a CSR at Cloudflare, submits it to DigiCert for signing, uploads the issued certificate back to Cloudflare, and cleans up old CSRs. Designed for interactive use or unattended renewal via cron.

**Approach B — TLM Agent AWR scripts** that handle only the Cloudflare upload step. The DigiCert TLM Agent manages certificate enrollment, and these scripts are triggered automatically after issuance to push the certificate to Cloudflare. Available for both Linux and Windows.

| Script | Approach | Platform | Trigger |
|--------|----------|----------|---------|
| `csr-in-cloudflare-api.sh` | A – Standalone | Linux (bash) | Interactive or `--renewal` via cron |
| `csr_in_digicert_awr.sh` | B – AWR | Linux (bash) | TLM Agent (`DC1_POST_SCRIPT_DATA`) |
| `csr_in_digicert_awr.ps1` | B – AWR | Windows (PowerShell) | TLM Agent (`DC1_POST_SCRIPT_DATA`) |

## Architecture

```
APPROACH A — Standalone (csr-in-cloudflare-api.sh)

┌──────────────┐  1. Create CSR   ┌──────────────┐  2. Submit CSR  ┌──────────────┐
│  Script      │ ──────────────▶  │  Cloudflare  │                │  DigiCert    │
│  (cron or    │                  │  API         │                │  ONE mPKI    │
│   interactive)│ ◀────────────── │              │                │  API         │
│              │  5. Upload cert  └──────────────┘                └──────┬───────┘
│              │ ──────────────────────────────────────────────────────▶ │
│              │ ◀────────────────────────── 3. Signed certificate ──── │
└──────────────┘  6. CSR cleanup                                        


APPROACH B — TLM Agent AWR (csr_in_digicert_awr.sh / .ps1)

┌──────────────┐                  ┌──────────────┐  DC1_POST_     ┌──────────────┐
│  DigiCert    │  Enrol / Renew   │  DigiCert    │  SCRIPT_DATA   │  AWR Script  │
│  TLM         │ ──────────────▶  │  TLM Agent   │ ─────────────▶ │  (bash/PS1)  │
│  (CA)        │                  │  (host)      │  (Base64 JSON) │              │
└──────────────┘                  └──────────────┘                └──────┬───────┘
                                                                        │ Upload
                                                                        ▼
                                                                 ┌──────────────┐
                                                                 │  Cloudflare  │
                                                                 │  API         │
                                                                 └──────────────┘
```

## Feature Comparison

| Feature | Standalone (`csr-in-cloudflare-api.sh`) | AWR bash (`csr_in_digicert_awr.sh`) | AWR PS1 (`csr_in_digicert_awr.ps1`) |
|---------|---------------------------------------|-------------------------------------|--------------------------------------|
| CSR generation (Cloudflare) | Yes | No | No |
| DigiCert mPKI API call | Yes | No | No |
| Certificate source | DigiCert API response | CRT + KEY files from TLM Agent | CRT + KEY files from TLM Agent |
| Interactive mode | Yes (with prompts) | No | No |
| Renewal mode (`--renewal`) | Yes (cron-friendly) | N/A (always automated) | N/A (always automated) |
| Certificate delete modes | `none` / `all` / `matching` | `none` / `all` / `matching` | `none` / `all` / `matching` |
| Certificate type selection | No (hardcoded `sni_custom`) | Yes (`sni_custom` / `legacy_custom`) | Yes (`sni_custom` / `legacy_custom`) |
| Bundle method | Hardcoded `force` | Configurable via AWR arg | Configurable via AWR arg |
| CSR cleanup | Yes (retention policy) | No | No |
| Debug mode | No | Yes | Yes |
| OpenSSL auto-detection | Assumes available | Assumes available | Multi-path auto-detection with fallback |
| File output (cert + info) | Yes | No | No |

## Standalone Script (`csr-in-cloudflare-api.sh`)

### How It Works

1. **Step 0** — Fetches zone details from Cloudflare to determine the domain name.
2. **Step 1** — Checks for existing certificates and handles deletion based on the configured mode.
3. **Step 2** — Creates a new CSR at Cloudflare (RSA 2048, zone-scoped, with `www.` SAN).
4. **Step 3** — Extracts the CSR content from the Cloudflare response.
5. **Step 4** — Submits the CSR to DigiCert ONE mPKI API for immediate certificate issuance.
6. **Step 5** — Uploads the signed certificate back to Cloudflare as an SNI custom certificate.
7. **Step 6** — Cleans up old CSRs based on the configured retention policy.

### Usage

**Interactive mode** — prompts for all configuration values with sensible defaults:

```bash
./csr-in-cloudflare-api.sh
```

**Renewal mode** — uses all default values with no prompts, suitable for cron:

```bash
./csr-in-cloudflare-api.sh --renewal
```

### Cron Scheduling

```bash
# Monthly renewal (1st of each month at 2:00 AM)
0 2 1 * * /path/to/csr-in-cloudflare-api.sh --renewal >> /var/log/cert_renewal.log 2>&1
```

### Configuration

Edit the default values near the top of the script:

| Variable | Description |
|----------|-------------|
| `DEFAULT_ZONE_ID` | Cloudflare Zone ID |
| `DEFAULT_AUTH_TOKEN` | Cloudflare API bearer token |
| `DEFAULT_DIGICERT_API_KEY` | DigiCert ONE mPKI API key |
| `DEFAULT_PROFILE_ID` | DigiCert certificate profile ID |
| `DEFAULT_CSR_RETENTION` | Number of old CSRs to keep (default: `5`) |
| `DEFAULT_CERT_DELETE_MODE` | Certificate deletion strategy (default: `matching`) |

### Prerequisites

- `bash`, `curl`, `jq`, `openssl`

## AWR Scripts (`csr_in_digicert_awr.sh` / `csr_in_digicert_awr.ps1`)

### How They Work

These scripts are triggered by the DigiCert TLM Agent after certificate enrollment. The agent sets the `DC1_POST_SCRIPT_DATA` environment variable containing a Base64-encoded JSON payload with the certificate file paths, password, and AWR arguments.

1. Decode the Base64 JSON payload and extract CRT + KEY file paths.
2. Read the certificate and private key files.
3. Optionally delete existing Cloudflare certificates based on the configured deletion mode.
4. Upload the certificate and key to Cloudflare via the custom certificates API.

### AWR Argument Mapping

Parameters are passed from the TLM AWR profile via the `args` array in the JSON payload:

| Argument | Field | Required | Description |
|----------|-------|----------|-------------|
| 1 | Zone ID | Yes | Cloudflare Zone ID (32-character hex string) |
| 2 | Auth Token | Yes | Cloudflare API bearer token |
| 3 | Bundle Method | No | `ubiquitous`, `optimal`, or `force` (default: `force`) |
| 4 | Cert Delete Mode | No | `none`, `all`, or `matching` (default: `matching`) |
| 5 | Certificate Type | No | `sni_custom` or `legacy_custom` (default: `sni_custom`) |

All optional arguments fall back to the defaults configured at the top of the script if not provided.

### Script-Level Configuration

Each AWR script has a configuration block at the top that sets defaults:

**Bash:**
```bash
LEGAL_NOTICE_ACCEPT="true"
BUNDLE_METHOD="force"
CERTIFICATE_TYPE="sni_custom"
CERT_DELETE_MODE="matching"
DEBUG_MODE="false"
```

**PowerShell:**
```powershell
$LEGAL_NOTICE_ACCEPT = "true"
$BUNDLE_METHOD = "force"
$CERTIFICATE_TYPE = "sni_custom"
$CERT_DELETE_MODE = "matching"
$DEBUG_MODE = "false"
```

### Platform Differences

While both AWR scripts are functionally equivalent, there are mechanical differences:

| Aspect | Bash | PowerShell |
|--------|------|------------|
| HTTP client | `curl` with `%{http_code}` extraction | `Invoke-WebRequest` with exception handling |
| JSON parsing | `grep -oP` (Perl regex) | `ConvertFrom-Json` (native) |
| JSON payload | Manual string escaping | `ConvertTo-Json` (automatic escaping) |
| Hostname extraction | `openssl` (assumed in PATH) | `openssl` with multi-path auto-detection |
| Temp files | `mktemp` + manual cleanup | `[System.IO.Path]::GetTempFileName()` |
| PS version check | N/A | Logs version; recommends PS 7+ |

### Prerequisites

**Linux (`csr_in_digicert_awr.sh`):**
- `bash`, `curl`, `openssl` (for `matching` delete mode), `jq` (optional, with `grep` fallback)

**Windows (`csr_in_digicert_awr.ps1`):**
- PowerShell 5.1+ (7+ recommended)
- OpenSSL for Windows (for `matching` delete mode) — auto-detected from common install paths

## Certificate Deletion Modes

All three scripts support the same deletion strategies, applied before uploading the new certificate:

| Mode | Behaviour |
|------|-----------|
| `none` | Keep all existing certificates. The new certificate is added alongside any existing ones. |
| `all` | Delete every custom certificate in the zone before uploading. Use with caution if the zone hosts certificates for multiple domains. |
| `matching` | **(Recommended)** Only delete certificates whose hostnames overlap with the certificate being uploaded. Determined by extracting SANs from the new certificate and comparing against each existing certificate's `hosts` array. |

After deletion, all scripts wait 2 seconds for Cloudflare to process the removal before uploading the new certificate.

## Certificate Type

The AWR scripts support choosing between Cloudflare's two custom certificate types:

| Type | Value | Description |
|------|-------|-------------|
| Custom Modern | `sni_custom` | Requires SNI. Recommended for modern environments. This is the default. |
| Custom Legacy | `legacy_custom` | Supports non-SNI clients. Broader compatibility for legacy environments. |

The standalone script currently uses `sni_custom` only.

## Debug Mode

The AWR scripts include a `DEBUG_MODE` flag (`"false"` by default) that, when set to `"true"`, enables verbose logging including decoded JSON payloads, raw argument values, auth token hex dumps, API response bodies, and certificate content snippets. This should only be enabled in test environments as it logs sensitive data.

## Logging

| Script | Log Location |
|--------|-------------|
| `csr-in-cloudflare-api.sh` | Configurable (default: `./digicert_cert_automation_<timestamp>.log`) |
| `csr_in_digicert_awr.sh` | `/home/ubuntu/tlm_agent_3.1.2_linux64/log/cloudflare-awr.log` |
| `csr_in_digicert_awr.ps1` | `C:\Program Files\DigiCert\TLM Agent\log\cloudflare-awr.log` |

Update the `LOGFILE` / `$LOGFILE` variable if your TLM Agent is installed in a different location.

## Troubleshooting

| Symptom | Likely Cause |
|---------|--------------|
| `DC1_POST_SCRIPT_DATA is not set` | AWR script is not being invoked by the TLM Agent, or the AWR profile is misconfigured. |
| `ZONE_ID format seems invalid` | The Zone ID in the AWR args is not a 32-character hex string. Check the TLM AWR parameter configuration. |
| `AUTH_TOKEN length seems unusual` | The Cloudflare API token in the AWR args is malformed. Verify it in the Cloudflare dashboard. |
| `Certificate file not found` | The TLM Agent AWR profile is not configured to output CRT + KEY format (PEM). |
| `Could not extract hostnames from new certificate` | OpenSSL is not installed or not in PATH. The `matching` delete mode requires OpenSSL to parse SANs. Use `none` or `all` as a workaround. |
| `ERROR: Certificate upload failed` (HTTP 400) | The certificate or key content may be malformed. Enable `DEBUG_MODE` to inspect the payload. |
| `ERROR: Certificate upload failed` (HTTP 403) | The Cloudflare API token lacks the required permissions. Ensure it has `Zone > SSL and Certificates > Edit`. |
| `No certificate received from DigiCert` | The DigiCert API key or profile ID is incorrect, or the profile does not support the requested SANs. |
| `Error creating CSR at Cloudflare` | The Cloudflare API token lacks CSR creation permissions, or the zone does not support custom certificates (requires a Business or Enterprise plan). |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.