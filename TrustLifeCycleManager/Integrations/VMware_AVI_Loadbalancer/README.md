# DigiCert TLM — VMware Avi Load Balancer Integration

Automated certificate lifecycle management for VMware (Broadcom) Avi Load Balancer using DigiCert Trust Lifecycle Manager (TLM). This repository contains two complementary scripts that together provide end-to-end certificate automation — from issuance through deployment.

| Script | Purpose | Trigger |
|--------|---------|---------|
| `vmware_avi_loadbalancer_control_script.py` | Certificate Management Profile — requests and renews certificates from DigiCert via ACME with EAB | Avi Controller (built-in certificate management) |
| `vmware_avi_loadbalancer_awr.sh` | AWR Post-Enrollment Script — uploads renewed certificates to Avi via REST API | DigiCert TLM Agent (post-enrollment hook) |

---

## Architecture Overview

There are two distinct integration patterns depending on your environment:

### Option A — Avi Certificate Management Profile (Control Script)

Avi Controller natively manages the certificate lifecycle using the Python control script as a **Certificate Management Profile**. When a certificate is created or nears expiry, Avi generates a CSR and invokes the script, which handles the full ACME flow against DigiCert — including account registration with External Account Binding (EAB), order creation, and certificate download. The signed certificate is returned directly to the Avi Controller.

```
Avi Controller ──CSR──▶ Control Script ──ACME──▶ DigiCert
                ◀──cert──                        (CertCentral / TLM)
```

### Option B — TLM Agent AWR Post-Enrollment (AWR Script)

The DigiCert TLM Agent manages the certificate lifecycle externally. After enrollment or renewal, the agent executes the AWR (Admin Web Request) post-enrollment script, which authenticates to the Avi Controller REST API and uploads (or updates) the certificate and private key.

```
TLM Agent ──enroll/renew──▶ DigiCert
     │
     └──post-enrollment──▶ AWR Script ──REST API──▶ Avi Controller
```

---

## Prerequisites

### Common

- VMware Avi Load Balancer (tested with API version 22.1.3)
- Avi Controller admin credentials
- DigiCert account (CertCentral or TLM)

### Control Script (Option A)

- Python 2.7+ or 3.x (runs within Avi Controller's Python environment)
- OpenSSL CLI available on the Avi Controller
- DigiCert ACME credentials:
  - ACME Directory URL
  - EAB Key ID (`eab_kid`)
  - EAB HMAC Key (`eab_hmac_key`)
- Pre-validated domains in DigiCert (for OV/EV certificates)

### AWR Script (Option B)

- DigiCert TLM Agent (v3.1.2+) installed and configured
- `curl`, `jq`, `openssl` available on the agent host
- Network connectivity from the agent host to the Avi Controller (HTTPS)

---

## Setup — Certificate Management Profile (Control Script)

### 1. Import the Script

1. Log in to the Avi Controller UI.
2. Navigate to **Templates → Security → Certificate Management**.
3. Click **Create** and paste the contents of `vmware_avi_loadbalancer_control_script.py`.

### 2. Configure Script Parameters

Create the following parameters in the Certificate Management profile:

| Parameter | Required | Description |
|-----------|----------|-------------|
| `acme_directory_url` | Yes | DigiCert ACME directory URL |
| `eab_kid` | Yes | External Account Binding Key ID |
| `eab_hmac_key` | Yes | EAB HMAC Key (mark as **Sensitive**) |
| `contact` | No | Email address for ACME account registration |
| `debug` | No | Set to `true` for verbose logging |

#### DigiCert ACME Directory URLs

| Product | URL |
|---------|-----|
| CertCentral | `https://acme.digicert.com/v2/acme/directory/` |
| Trust Lifecycle Manager | `https://one.digicert.com/mpki/api/v1/acme/v2/directory` |

### 3. Request a Certificate

1. Navigate to **Templates → Security → SSL/TLS Certificates**.
2. Click **Create → Application Certificate**.
3. Enter a name for the certificate.
4. Set **Type** to **CSR**.
5. Set **Common Name** to the target domain.
6. Select the Certificate Management profile created above.
7. Click **Save**. The script will request and import the certificate automatically.

### How It Works

The control script performs the following steps:

1. Generates (or reuses) an RSA 4096-bit ACME account key stored at `/tmp/digicert_acme.key`.
2. Parses the CSR provided by Avi to extract domain names (CN and SANs).
3. Fetches the ACME directory from DigiCert.
4. Registers an ACME account with External Account Binding.
5. Creates a new certificate order for the requested domains.
6. Verifies that all domain authorisations are valid (pre-validated in DigiCert).
7. Finalises the order by submitting the CSR in DER format.
8. Polls the order until the certificate is ready.
9. Downloads and returns the signed certificate PEM to Avi Controller.

> **Note:** This script is designed for **pre-validated domains** (OV/EV). Domain validation is performed out-of-band within DigiCert. For DV certificates requiring HTTP-01 or DNS-01 challenges, additional logic is required.

---

## Setup — TLM Agent AWR Post-Enrollment (AWR Script)

### 1. Configure the AWR Script

Edit `vmware_avi_loadbalancer_awr.sh` and set the following:

```bash
# Accept the legal notice to enable script execution
LEGAL_NOTICE_ACCEPT="true"

# Set the log file path (adjust to match your TLM Agent installation)
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/avi-upload.log"

# Set the Avi API version to match your controller
AVI_API_VERSION="22.1.3"
```

### 2. Configure TLM Agent AWR

In the DigiCert TLM console, configure the AWR post-enrollment script with the following arguments:

| Argument | Value | Description |
|----------|-------|-------------|
| `ARGUMENT_1` | e.g. `alb.example.com` | Avi Controller hostname or IP |
| `ARGUMENT_2` | e.g. `admin` | Avi Controller username |
| `ARGUMENT_3` | e.g. `P@ssw0rd` | Avi Controller password |

These are passed via the `DC1_POST_SCRIPT_DATA` environment variable as a base64-encoded JSON payload containing the arguments and certificate file paths.

### 3. Deploy the Script

Place the script in a location accessible to the TLM Agent and ensure it is executable:

```bash
chmod +x vmware_avi_loadbalancer_awr.sh
```

### How It Works

When the TLM Agent completes a certificate enrollment or renewal:

1. The agent sets the `DC1_POST_SCRIPT_DATA` environment variable containing base64-encoded JSON with the certificate file paths and configured arguments.
2. The script decodes the JSON to extract the Avi Controller address, credentials, and certificate/key file locations.
3. It derives the certificate name from the certificate's Common Name (CN).
4. It authenticates to the Avi Controller REST API using cookie-based authentication and obtains a CSRF token.
5. It uploads the certificate and private key via `POST /api/sslkeyandcertificate`.
6. If a certificate with the same name already exists, it automatically falls back to a `PUT` update using the existing certificate's UUID.
7. The certificate is then available in Avi under **Templates → Security → SSL/TLS Certificates** for assignment to Virtual Services.

---

## Logging

### Control Script

Output is printed to stdout/stderr and captured by the Avi Controller's certificate management logs. Set the `debug` parameter to `true` for additional detail.

### AWR Script

All operations are logged to the configured `LOGFILE` with timestamps. Example log output:

```
[2026-03-16 10:30:01] Starting DigiCert TLM - AVI Upload Script
[2026-03-16 10:30:01] Authenticating to Avi Controller: alb.example.com...
[2026-03-16 10:30:02] Authentication successful, CSRF token obtained
[2026-03-16 10:30:02] Uploading certificate to Avi...
[2026-03-16 10:30:03] Certificate uploaded successfully
[2026-03-16 10:30:03]   Name: www.example.com
[2026-03-16 10:30:03]   UUID: sslkeyandcertificate-abc123
```

---

## Troubleshooting

| Symptom | Cause | Resolution |
|---------|-------|------------|
| `ERROR: Legal notice not accepted` | `LEGAL_NOTICE_ACCEPT` is not set to `true` | Set `LEGAL_NOTICE_ACCEPT="true"` in the AWR script |
| `ERROR: Authentication failed (HTTP 401)` | Invalid Avi credentials | Verify username and password; check the account is not locked |
| `ERROR: Failed to obtain CSRF token` | Authentication succeeded but CSRF cookie missing | Verify Avi API version matches the controller version |
| `Domain requires validation` | Domain not pre-validated in DigiCert | Complete domain validation in the DigiCert console |
| `Missing required parameter: eab_kid` | ACME credentials not configured | Add all required script parameters in the Certificate Management profile |
| `Certificate already exists` | A certificate with the same CN exists | The AWR script handles this automatically by updating the existing entry |

---

## Security Considerations

- The AWR script passes Avi credentials via the `DC1_POST_SCRIPT_DATA` JSON payload. Ensure the TLM Agent host is appropriately secured.
- The EAB HMAC key should be marked as **Sensitive** in the Avi Certificate Management profile parameters.
- The ACME account key is stored at `/tmp/digicert_acme.key` on the Avi Controller. Consider restricting file permissions.
- Both scripts use `-k` / `verify=False` for TLS connections to the Avi Controller. For production environments, configure proper CA trust.

---

## Legal Notice

Copyright © 2026 DigiCert. All rights reserved. See the embedded legal notice in each script for full terms. The `LEGAL_NOTICE_ACCEPT` flag must be set to `"true"` in the AWR script to acknowledge acceptance.

---

## Version History

| Version | Date | Description |
|---------|------|-------------|
| 1.0.0 | 2024 | Initial release — ACME control script and AWR post-enrollment script |