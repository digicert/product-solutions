# Alibaba Cloud WAF 3.0 — DigiCert TLM AWR Post-Enrollment Script

Automate TLS/SSL certificate deployment to **Alibaba Cloud Web Application Firewall (WAF) 3.0** using a DigiCert Trust Lifecycle Manager (TLM) Admin Web Request (AWR) post-enrollment script.

When a certificate is issued or renewed in TLM, this script automatically uploads the certificate to the WAF instance and binds it to the configured domain — eliminating manual certificate replacement and reducing the risk of expired-certificate outages.

## How It Works

```
DigiCert TLM ──▶ AWR Post-Enrollment ──▶ Alibaba Cloud CLI
                                              │
                                    ┌─────────┴──────────┐
                                    │  CreateCerts API    │
                                    │  (upload cert+key)  │
                                    └─────────┬──────────┘
                                              │
                                    ┌─────────┴──────────┐
                                    │ ModifyDomainCert    │
                                    │ (bind to domain)    │
                                    └────────────────────┘
```

1. TLM issues/renews a certificate and sets the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON containing certificate files, paths, and user-defined arguments).
2. The script decodes the payload, extracts the certificate, private key, and five configuration arguments.
3. Pre-flight checks validate all required inputs and confirm the certificate and key match.
4. The Alibaba Cloud CLI is configured with a temporary named profile using the supplied AccessKey credentials.
5. `CreateCerts` uploads the certificate and private key to the WAF instance.
6. `ModifyDomainCert` binds the new certificate to the target domain.
7. On exit (success, failure, or signal), the CLI profile and all temporary files are automatically cleaned up.

## Prerequisites

- **Alibaba Cloud CLI (`aliyun`)** — installed and available on `$PATH` on the TLM automation host. See [Alibaba Cloud CLI documentation](https://www.alibabacloud.com/help/en/cli/install-cli).
- **OpenSSL** — used to verify certificate/key pairing before upload.
- **Alibaba Cloud RAM credentials** — an AccessKey ID and AccessKey Secret with permissions for `waf-openapi:CreateCerts` and `waf-openapi:ModifyDomainCert`.
- **WAF 3.0 instance** — an active WAF instance ID and a domain already added to it.
- **DigiCert TLM** — an AWR automation profile configured to execute this script on certificate issuance or renewal.

## AWR Template Arguments

Configure these five arguments in the TLM AWR automation profile:

| Argument | Description | Example |
|----------|-------------|---------|
| `Argument 1` | Alibaba Cloud AccessKey ID | `LTAI5t...` |
| `Argument 2` | Alibaba Cloud AccessKey Secret | `gkJRR3...` |
| `Argument 3` | Region ID | `ap-southeast-1` |
| `Argument 4` | WAF Instance ID | `waf_v3-cn-...` |
| `Argument 5` | Domain name (as configured in WAF) | `www.example.com` |

## Configuration

Before deploying, update the following in the script:

```bash
# Set to "true" to accept the DigiCert legal notice
LEGAL_NOTICE_ACCEPT="false"

# Path to the log file on the automation host
LOGFILE="/home/ubuntu/tls-guru.log"
```

> **Important:** The script will not execute until `LEGAL_NOTICE_ACCEPT` is set to `"true"`.

### Optional Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TMP_DIR` | `/tmp/digicert-alibaba-waf3-awr` | Temporary working directory (auto-cleaned on exit) |
| `CLI_PROFILE` | `digicert-awr` | Named CLI profile (auto-cleaned on exit) |

## Security

- **Credential isolation** — a dedicated, ephemeral CLI profile is created for each run and deleted on exit via a `trap` handler, ensuring credentials are never left on disk.
- **Temporary file cleanup** — all working files are removed on any exit path (success, failure, or signal).
- **Credential masking** — AccessKey values are masked in log output.
- **Certificate/key validation** — the script verifies the certificate and private key match before uploading, preventing deployment of mismatched pairs.
- **No hardcoded secrets** — all credentials are passed via TLM AWR template arguments, not stored in the script.

## Logging

All operations are logged with timestamps to the file specified by `LOGFILE`. Log output includes:

- Environment variable and argument extraction details
- Certificate and key file validation results
- Alibaba Cloud API call results (`RequestId`, `CertIdentifier`)
- Error messages with context on failure

## Certificate Naming

Uploaded certificates are named using the pattern:

```
<original-cert-basename>-<UTC-timestamp>
```

For example: `www.example.com-20260506T143022Z`

This ensures each renewal creates a uniquely identifiable certificate in the WAF console.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set `LEGAL_NOTICE_ACCEPT="true"` in the script |
| `Required command not found: aliyun` | Alibaba Cloud CLI not installed or not on `$PATH` | Install the CLI and verify with `aliyun version` |
| `Certificate and private key do not match` | Mismatched cert/key delivered by TLM | Check the TLM certificate profile and key generation settings |
| `CreateCerts did not return CertIdentifier` | Invalid credentials, wrong region, or instance ID | Verify AccessKey permissions and region/instance values |
| `ModifyDomainCert did not return RequestId` | Domain not found in WAF instance | Confirm the domain is added to the WAF instance |

## API Reference

This script uses the [Alibaba Cloud WAF 3.0 OpenAPI](https://www.alibabacloud.com/help/en/waf/) (version `2021-10-01`):

- **CreateCerts** — uploads a certificate and private key to the WAF instance.
- **ModifyDomainCert** — binds a certificate (by `CertId`) to a domain protected by WAF.

## Legal Notice

Copyright © 2026 DigiCert, Inc. All rights reserved. See the `LEGAL_NOTICE` block at the top of the script for full terms.