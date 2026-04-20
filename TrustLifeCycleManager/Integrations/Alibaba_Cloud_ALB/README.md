# DigiCert TLM – Alibaba Cloud ALB Post-Enrollment Automation (AWR)

This AWR (Admin Web Request) post-enrollment script automates the deployment of TLS certificates issued by DigiCert Trust Lifecycle Manager (TLM) to **Alibaba Cloud Application Load Balancer (ALB)** listeners via Alibaba Cloud Certificate Service (CAS).

## Overview

When a certificate is enrolled or renewed through DigiCert TLM, this script is triggered as a post-enrollment action. It performs the following steps:

1. Decodes the `DC1_POST_SCRIPT_DATA` payload to extract the certificate, private key, and deployment arguments.
2. Uploads the certificate and private key to **Alibaba Cloud Certificate Service (CAS)** using the `UploadUserCertificate` API.
3. Applies the uploaded certificate to the specified ALB HTTPS listener — either as the **default** certificate or as an **additional (SNI)** certificate.
4. Polls the listener until it returns to a `Running` state, confirming successful deployment.
5. Lists the final certificate configuration on the listener for audit purposes.

## Prerequisites

- **DigiCert Trust Lifecycle Manager** with AWR post-enrollment scripting enabled.
- An **Alibaba Cloud** account with:
  - An ALB instance with an HTTPS listener configured.
  - An AccessKey pair (AccessKey ID and AccessKey Secret) with permissions for:
    - `cas:UploadUserCertificate`
    - `alb:UpdateListenerAttribute`
    - `alb:AssociateAdditionalCertificatesWithListener`
    - `alb:GetListenerAttribute`
    - `alb:ListListenerCertificates`
- The following commands available on the host: `curl`, `jq`, `openssl`, `python3`, `base64`.

## Arguments

Arguments are passed via the `DC1_POST_SCRIPT_DATA` Base64-encoded JSON payload in the `args` array:

| Argument | Field | Required | Description |
|----------|-------|----------|-------------|
| `ARGUMENT_1` | Access Key ID | Yes | Alibaba Cloud AccessKey ID |
| `ARGUMENT_2` | Access Key Secret | Yes | Alibaba Cloud AccessKey Secret |
| `ARGUMENT_3` | Region ID | Yes | Alibaba Cloud region (e.g. `cn-hangzhou`, `ap-southeast-1`) |
| `ARGUMENT_4` | Listener ID | Yes | ALB HTTPS listener ID (e.g. `lsn-xxxxxxxxxxxxxxxxx`) |
| `ARGUMENT_5` | Deploy Type | No | `default` (replace primary cert) or `additional` (add SNI cert). Defaults to `default`. |

## Configuration

The following variables can be adjusted at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to run the script |
| `LOGFILE` | `/home/ubuntu/digicert-alibaba-alb-awr.log` | Path to the log file |
| `TMP_DIR` | `/tmp/digicert-alibaba-alb-awr` | Temporary working directory for staged files and API responses |
| `ALIBABA_CAS_ENDPOINT` | `cas.aliyuncs.com` | CAS API endpoint (override for regional endpoints) |
| `WAIT_TIMEOUT_SEC` | `300` | Maximum seconds to wait for listener readiness |
| `POLL_INTERVAL_SEC` | `10` | Seconds between listener status polls |

## Usage

### 1. Accept the Legal Notice

Set `LEGAL_NOTICE_ACCEPT="true"` at the top of the script.

### 2. Configure in DigiCert TLM

Add this script as a post-enrollment AWR script in DigiCert TLM, supplying the required parameters in the AWR profile:

```
Argument 1: <Alibaba Access Key ID>
Argument 2: <Alibaba Access Key Secret>
Argument 3: <Region ID, e.g. cn-hangzhou>
Argument 4: <ALB Listener ID>
Argument 5: <Deploy type: default or additional> (optional)
```

### 3. Enroll or Renew a Certificate

When a certificate is issued or renewed, TLM triggers the script automatically. The script uploads the certificate to CAS, applies it to the ALB listener, and confirms deployment.

## Deploy Types

- **`default`** — Replaces the primary (default) certificate on the listener using `UpdateListenerAttribute`. This is the certificate served when no SNI match is found.
- **`additional`** — Adds the certificate as an additional SNI certificate using `AssociateAdditionalCertificatesWithListener`. Use this when the listener serves multiple domains.

## How It Works

### API Authentication

The script uses Alibaba Cloud's RPC-style signed requests with HMAC-SHA1 signatures. Each API call includes a unique `SignatureNonce` and UTC timestamp to prevent replay attacks. No SDK installation is required — authentication is handled entirely with `curl`, `openssl`, and `python3`.

### Certificate Upload

The certificate and private key PEM content are passed as inline parameters to the CAS `UploadUserCertificate` API. Each upload receives a unique name with a UTC timestamp suffix to avoid collisions.

### Listener Update

Depending on the deploy type, the script calls either `UpdateListenerAttribute` (default) or `AssociateAdditionalCertificatesWithListener` (additional) on the ALB API, referencing the CAS `CertId` returned from the upload.

### Polling

After submitting the certificate update, the script polls `GetListenerAttribute` until the listener transitions from `Configuring` (or `Associating`) back to `Running` (or `Associated`). If the timeout is reached, the script exits with an error.

## Security

- **No hardcoded credentials** — all secrets are passed at runtime via `DC1_POST_SCRIPT_DATA`.
- **Credential masking** — the Access Key ID is partially masked in logs; the Access Key Secret is fully redacted.
- **Private key protection** — staged `.pem` copies are set to `chmod 600` and cleaned up after deployment.
- **Temporary files** — API response JSON files are retained in `TMP_DIR` for troubleshooting but contain no credentials.

## Logging

All operations are logged to the configured `LOGFILE` with timestamps. The log includes:

- Configuration summary (with masked credentials)
- Certificate file details (size, type, chain count)
- API call results and listener status transitions
- Final deployment summary with CAS Cert ID and listener confirmation

## Troubleshooting

| Symptom | Possible Cause | Resolution |
|---------|---------------|------------|
| `Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set the variable to `"true"` |
| `DC1_POST_SCRIPT_DATA is not set` | Script not triggered via TLM AWR | Verify the AWR profile configuration |
| `UploadUserCertificate did not return a CertId` | Invalid credentials or permissions | Check AccessKey permissions for CAS |
| `HTTP error 4xx from alb.*` | Incorrect region or listener ID | Verify `ARGUMENT_3` and `ARGUMENT_4` |
| `Timed out waiting for listener readiness` | ALB is stuck in `Configuring` state | Check the ALB console; increase `WAIT_TIMEOUT_SEC` if needed |
| `Unexpected listener status` | Listener in error state | Check ALB health in the Alibaba Cloud console |

Check `TMP_DIR` for API response JSON files (`upload_user_certificate.json`, `update_listener_attribute.json`, `get_listener_attribute_latest.json`) for detailed error messages.

## File Structure

```
alibaba-cloud-alb/
├── alibaba-cloud-alb-awr.sh    # Main AWR post-enrollment script
└── README.md                    # This file
```

## Related Resources

- [Alibaba Cloud ALB Documentation](https://www.alibabacloud.com/help/en/slb/application-load-balancer/)
- [Alibaba Cloud Certificate Service (CAS)](https://www.alibabacloud.com/help/en/ssl-certificate/)
- [DigiCert Trust Lifecycle Manager](https://www.digicert.com/trust-lifecycle-manager)
- [DigiCert Product Solutions Repository](https://github.com/digicert/product-solutions)