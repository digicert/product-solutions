# DigiCert TLM – Palo Alto Networks Certificate Automation Scripts

## Overview

This collection of scripts automates SSL/TLS certificate lifecycle management on Palo Alto Networks PAN-OS firewalls using the DigiCert Trust Lifecycle Manager (TLM) platform and the DigiCert mPKI REST API. Three scripts are provided, covering different deployment scenarios and operating systems.

| Script | Type | Platform | Use Case |
|--------|------|----------|----------|
| `csr_in_digicert_paloalto-awr.sh` | AWR post-enrollment | Linux (bash) | Automated certificate deployment triggered by TLM Agent after enrollment/renewal |
| `csr_in_digicert_paloalto-awr.ps1` | AWR post-enrollment | Windows (PowerShell) | Same workflow as above, for Windows-based TLM Agent deployments |
| `csr_in_paloalto-api.sh` | Standalone interactive | Linux (bash) | End-to-end CSR generation on PAN-OS, submission to DigiCert mPKI, and signed certificate import — all from a single interactive session |

## Architecture

### AWR Scripts (`.sh` and `.ps1`)

These scripts are designed to run as **Admin Web Request (AWR) post-enrollment hooks**, invoked automatically by the DigiCert TLM Agent after a certificate is issued or renewed. The flow is:

1. TLM Agent completes certificate enrollment and sets the `DC1_POST_SCRIPT_DATA` environment variable with a Base64-encoded JSON payload.
2. The script decodes the payload to locate the certificate (`.crt`) and private key (`.key`) files on disk.
3. The certificate is uploaded to the Palo Alto firewall via the PAN-OS XML API import endpoint.
4. The private key is uploaded separately, associated with the same certificate name.
5. Optionally, a configuration commit is issued to activate the new certificate.

### Standalone Script (`csr_in_paloalto-api.sh`)

This interactive script performs the full certificate lifecycle in a single session with guided prompts:

1. Generates a CSR directly on the PAN-OS firewall via the XML API.
2. Extracts the CSR from PAN-OS and formats it for API submission.
3. Submits the CSR to the DigiCert mPKI REST API to obtain a signed certificate.
4. Imports the signed certificate back into PAN-OS.
5. Optionally commits the configuration.
6. Verifies the certificate installation.

## Prerequisites

### All Scripts

- **Palo Alto PAN-OS firewall** with XML API access enabled
- **PAN-OS API key** with sufficient privileges for certificate import and (optionally) commit operations
- **Network connectivity** from the script host to the firewall management interface
- `curl` and `openssl` available on the system PATH

### AWR Scripts Only

- **DigiCert TLM Agent** installed and configured to invoke post-enrollment scripts
- The `DC1_POST_SCRIPT_DATA` environment variable must be set by the agent at invocation time

### PowerShell AWR Script Only

- **Windows PowerShell 5.1** or **PowerShell 7+**
- OpenSSL on the system PATH (required for the `common_name` certificate naming method)

### Standalone Script Only

- **DigiCert ONE mPKI API key** and a configured certificate profile
- `jq` (optional, recommended for reliable JSON parsing; the script falls back to `grep`/`sed` if unavailable)

## Configuration

### AWR Scripts — `csr_in_digicert_paloalto-awr.sh` / `.ps1`

Edit the configuration block at the top of the script:

| Variable | Description | Example |
|----------|-------------|---------|
| `PA_URL` | Firewall management URL (HTTPS) | `https://192.168.1.1` |
| `PA_API_KEY` | PAN-OS API key | *(your API key)* |
| `CERT_NAME_METHOD` | How to name the certificate: `common_name` (extract CN from cert) or `manual` | `common_name` |
| `MANUAL_CERT_NAME` | Certificate name when using the `manual` method | `my-firewall-cert` |
| `COMMIT_CONFIG` | Automatically commit after upload (`true` / `false`) | `true` |
| `PRIVATE_KEY_PASSPHRASE` | Passphrase for the private key | *(your passphrase)* |
| `DEBUG_MODE` | Enable verbose logging including API call details (`true` / `false`) | `false` |
| `LEGAL_NOTICE_ACCEPT` | Must be set to `true` to allow execution | `true` |

**Log file locations:**

- **Bash:** Auto-detected under `<TLM_AGENT_DIR>/log/palo-alto-awr.log`
- **PowerShell:** `C:\Program Files\DigiCert\TLM Agent\log\palo-alto-awr.log`

### Standalone Script — `csr_in_paloalto-api.sh`

All configuration is collected interactively at runtime via prompted inputs with sensible defaults. The prompts cover firewall connectivity, certificate subject fields (CN, O, L, ST, C), DigiCert API credentials, and output directory.

## JSON Payload Structure (AWR Scripts)

The `DC1_POST_SCRIPT_DATA` environment variable contains a Base64-encoded JSON string:

```json
{
  "certfolder": "/path/to/certificate/directory",
  "files": ["certificate.crt", "privatekey.key"]
}
```

## PAN-OS API Endpoints Used

All scripts interact with the PAN-OS XML API at `https://<firewall>/api/`:

| Operation | API Parameters |
|-----------|---------------|
| Generate CSR (standalone only) | `type=op`, `cmd=<request><certificate><generate>...</generate></certificate></request>` |
| Extract CSR (standalone only) | `type=config`, `action=get`, `xpath=/config/shared/certificate/entry[@name='...']` |
| Import certificate | `type=import`, `category=certificate`, `certificate-name=...`, `format=pem` |
| Import private key (AWR only) | `type=import`, `category=private-key`, `certificate-name=...`, `format=pem`, `passphrase=...` |
| Commit configuration | `type=commit`, `cmd=<commit></commit>` |
| Verify installation (standalone only) | `type=config`, `action=get`, `xpath=/config/shared/certificate/entry[@name='...']` |

All API calls use `--insecure` / TLS validation bypass to accommodate self-signed management certificates on the firewall.

## Deployment

### AWR Scripts

1. Copy the appropriate script (`.sh` for Linux, `.ps1` for Windows) to the TLM Agent's scripts directory.
2. Make executable (Linux only):
   ```bash
   chmod +x csr_in_digicert_paloalto-awr.sh
   ```
3. Edit the configuration variables at the top of the script.
4. Set `LEGAL_NOTICE_ACCEPT="true"`.
5. Configure the TLM Agent to invoke this script as the post-enrollment hook for the relevant certificate profile.

### Standalone Script

1. Copy `csr_in_paloalto-api.sh` to any Linux host with network access to both the firewall and the DigiCert mPKI API.
2. Make executable:
   ```bash
   chmod +x csr_in_paloalto-api.sh
   ```
3. Run interactively:
   ```bash
   ./csr_in_paloalto-api.sh
   ```
4. Accept the legal notice and follow the prompts.

### Output Files (Standalone Script)

The standalone script creates the following files in the configured output directory:

| File | Contents |
|------|----------|
| `<cert_name>_clean.csr` | PEM-formatted CSR extracted from PAN-OS |
| `<cert_name>_single_line.txt` | Base64-only CSR (no headers) for API submission |
| `<cert_name>_digicert_response.json` | Full DigiCert mPKI API response |
| `<cert_name>_signed_certificate.crt` | Signed certificate in PEM format |
| `<cert_name>_raw_response.xml` | Raw PAN-OS XML API response |

## Logging

### AWR Scripts

Both AWR scripts write timestamped log entries to their respective log files. Each run is bracketed with start/end markers. When `DEBUG_MODE` is enabled, the decoded JSON payload and full API call details are logged. The API key is masked in normal mode (first and last 4 characters shown).

### Standalone Script

Progress is written directly to stdout with status indicators at each step.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `DC1_POST_SCRIPT_DATA is not set` (AWR) | Script not invoked by TLM Agent | Verify TLM Agent post-enrollment hook configuration |
| `Failed to decode base64 string` (AWR) | Corrupted environment variable | Check TLM Agent logs for enrollment errors |
| Certificate upload returns non-200 status | Invalid API key, incorrect firewall URL, or network issue | Verify `PA_URL` and `PA_API_KEY`; test with `curl` manually |
| Private key upload fails | Passphrase mismatch or key format issue | Verify `PRIVATE_KEY_PASSPHRASE` matches the key; ensure PEM format |
| Commit fails but uploads succeed | Pending configuration lock or insufficient privileges | Commit manually via the PAN-OS web UI; check API key permissions |
| CSR generation fails (standalone) | Certificate name already exists on PAN-OS | Delete the existing certificate entry or use a different name |
| DigiCert API returns error (standalone) | Invalid API key, profile ID, or seat ID | Verify DigiCert credentials; check the response in the saved JSON file |
| `Could not extract Common Name` (AWR) | Certificate format issue or OpenSSL not available | Switch to `manual` naming method, or install OpenSSL |

## Security Considerations

- **API keys and passphrases** are stored in plaintext within the scripts. For production deployments, consider sourcing these from a secrets manager or environment variables rather than hard-coding them.
- **Debug mode** logs sensitive information including decoded payloads and API call structures. Only enable in development/testing environments.
- The standalone script stores DigiCert API responses (including the signed certificate) on disk. Secure the output directory with appropriate file permissions.
- All PAN-OS API calls bypass TLS certificate verification (`--insecure`). In production, import the firewall's management certificate into the trusted store and remove this flag.
- Ensure the scripts and their log files have restrictive permissions (`600` or `640`) to protect private key material and API credentials.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within each script for full terms.