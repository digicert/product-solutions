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
3. The Palo Alto firewall URL and API key are extracted from the JSON `args` array (Argument 1 = `PA_URL`, Argument 2 = `PA_API_KEY`).
4. The certificate is uploaded to the Palo Alto firewall via the PAN-OS XML API import endpoint.
5. The private key is uploaded separately, associated with the same certificate name.
6. Optionally, a configuration commit is issued to activate the new certificate.

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

#### Arguments (from JSON `args` array)

The Palo Alto connection details are passed dynamically via the TLM automation profile's arguments, not hard-coded in the script. Configure these in the TLM AWR automation profile:

| Argument | Variable | Description | Example |
|----------|----------|-------------|---------|
| Argument 1 | `PA_URL` | Firewall management URL (must include `https://`) | `https://192.168.1.1` |
| Argument 2 | `PA_API_KEY` | PAN-OS API key | *(your API key)* |

#### Script configuration variables

Edit the configuration block at the top of the script:

| Variable | Description | Example |
|----------|-------------|---------|
| `CERT_NAME_METHOD` | How to name the certificate: `common_name` (extract CN from cert) or `manual` | `common_name` |
| `MANUAL_CERT_NAME` | Certificate name when using the `manual` method | `my-firewall-cert` |
| `COMMIT_CONFIG` | Automatically commit after upload (`true` / `false`) | `true` |
| `PRIVATE_KEY_PASSPHRASE` | Passphrase for the private key (leave empty if none) | *(your passphrase)* |
| `LEGAL_NOTICE_ACCEPT` | Must be set to `true` to allow execution | `true` |

**Log file locations:**

- **Bash:** `/home/ubuntu/palo-alto-awr.log`
- **PowerShell:** `C:\Program Files\DigiCert\TLM Agent\log\palo-alto-awr.log`

The log directory is created automatically if it does not exist.

### Standalone Script — `csr_in_paloalto-api.sh`

All configuration is collected interactively at runtime via prompted inputs with sensible defaults. The prompts cover firewall connectivity, certificate subject fields (CN, O, L, ST, C), DigiCert API credentials, and output directory.

## JSON Payload Structure (AWR Scripts)

The `DC1_POST_SCRIPT_DATA` environment variable contains a Base64-encoded JSON string:

```json
{
  "certfolder": "/path/to/certificate/directory",
  "files": ["certificate.crt", "privatekey.key"],
  "args": ["https://firewall.example.com", "your-api-key-here"]
}
```

| Field | Description |
|-------|-------------|
| `certfolder` | Directory path where the TLM Agent has written the certificate and key files |
| `files` | Array of filenames produced by enrollment (`.crt` and `.key`) |
| `args` | Arguments configured in the TLM automation profile — Argument 1 is the firewall URL, Argument 2 is the API key |

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
3. Edit the script configuration variables at the top of the script (`CERT_NAME_METHOD`, `COMMIT_CONFIG`, `PRIVATE_KEY_PASSPHRASE`).
4. Set `LEGAL_NOTICE_ACCEPT="true"`.
5. Configure the TLM AWR automation profile with the firewall URL (Argument 1) and API key (Argument 2).
6. Configure the TLM Agent to invoke this script as the post-enrollment hook for the relevant certificate profile.

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

Both AWR scripts write timestamped log entries to their respective log files. Each run is bracketed with start/end markers. The log directory is created automatically if it does not exist.

The scripts log a full extraction summary including arguments, certificate paths, file sizes, certificate count, and key type. The decoded JSON payload is logged for debugging. The API key is masked in log output (first and last 4 characters shown).

Connection errors are captured and logged with detail:

- **Bash:** curl errors (DNS resolution failures, connection refused, TLS handshake errors) are captured separately from the HTTP status code and logged explicitly.
- **PowerShell:** exception messages and inner exceptions are logged when `Invoke-WebRequest` calls fail.

### Standalone Script

Progress is written directly to stdout with status indicators at each step.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `DC1_POST_SCRIPT_DATA is not set` (AWR) | Script not invoked by TLM Agent | Verify TLM Agent post-enrollment hook configuration |
| `Failed to decode base64 string` (AWR) | Corrupted environment variable | Check TLM Agent logs for enrollment errors |
| `PA_URL (Argument 1) is empty` (AWR) | Firewall URL not configured in automation profile args | Add the firewall URL (including `https://`) as Argument 1 in the TLM AWR automation profile |
| `PA_API_KEY (Argument 2) is empty` (AWR) | API key not configured in automation profile args | Add the PAN-OS API key as Argument 2 in the TLM AWR automation profile |
| HTTP status `000` with curl error (bash AWR) | Connection failed before receiving a response — DNS failure, firewall blocking, TLS error, or missing `https://` in URL | Check the curl error detail in the log; verify `PA_URL` includes `https://` and the firewall is reachable |
| Certificate upload returns non-200 status | Invalid API key, incorrect firewall URL, or network issue | Verify `PA_URL` and `PA_API_KEY` in the automation profile args; test with `curl` manually |
| Private key upload fails | Passphrase mismatch or key format issue | Verify `PRIVATE_KEY_PASSPHRASE` matches the key; ensure PEM format |
| Commit fails but uploads succeed | Pending configuration lock or insufficient privileges | Commit manually via the PAN-OS web UI; check API key permissions |
| CSR generation fails (standalone) | Certificate name already exists on PAN-OS | Delete the existing certificate entry or use a different name |
| DigiCert API returns error (standalone) | Invalid API key, profile ID, or seat ID | Verify DigiCert credentials; check the response in the saved JSON file |
| `Could not extract Common Name` (AWR) | Certificate format issue or OpenSSL not available | Switch to `manual` naming method, or install OpenSSL |

## Security Considerations

- **API keys and passphrases:** The PAN-OS API key is passed via the TLM automation profile arguments (within the `DC1_POST_SCRIPT_DATA` JSON payload) rather than hard-coded in the script. The private key passphrase remains in the script configuration. For production deployments, consider sourcing passphrases from a secrets manager.
- The standalone script stores DigiCert API responses (including the signed certificate) on disk. Secure the output directory with appropriate file permissions.
- All PAN-OS API calls bypass TLS certificate verification (`--insecure`). In production, import the firewall's management certificate into the trusted store and remove this flag.
- Ensure the scripts and their log files have restrictive permissions (`600` or `640`) to protect private key material and API credentials.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within each script for full terms.