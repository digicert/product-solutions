# DigiCert TLM Agent — Rocket/LiteSpeed Certificate Deployment (AWR Post-Enrollment Script)

A bash post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment to a **Rocket.Chat** or **LiteSpeed Web Server** instance. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script extracts certificate data from the `DC1_POST_SCRIPT_DATA` environment variable, deploys the certificate and private key to the target directory, sets ownership and permissions, and optionally restarts the service.

## How It Works

```
TLM Agent (AWR)
    │
    ▼
Enrollment / Renewal completes
    │
    ▼
DC1_POST_SCRIPT_DATA (Base64-encoded JSON)
    │
    ▼
Post-enrollment script
    ├── Decode & extract cert + key paths
    ├── Backup existing certs (.orig)
    ├── Deploy new cert + key to target dir
    ├── Set ownership & permissions
    ├── Verify deployment
    └── (Optional) Restart service
```

## Prerequisites

- **DigiCert TLM Agent 3.1.2+** installed and configured with an AWR enrollment profile
- Target certificate directory exists (default: `/usr/local/rocket/etc`)
- Target service account exists (default: `srv-62-relay`)
- Script runs with sufficient privileges to write to the target directory and restart the service

## Configuration

All configuration is managed via variables at the top of the script:

| Variable | Default | Description |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to run the script |
| `LOGFILE` | `/home/ubuntu/tlm_agent_3.1.2_linux64/log/lightspeed.log` | Path to the log file |
| `ROCKET_CERT_DIR` | `/usr/local/rocket/etc` | Target directory for deployed certificates |
| `ROCKET_CERT_FILE` | `${ROCKET_CERT_DIR}/cert.pem` | Deployed certificate filename |
| `ROCKET_KEY_FILE` | `${ROCKET_CERT_DIR}/cert_key.pem` | Deployed private key filename |
| `TARGET_OWNER` | `srv-62-relay` | Owner for deployed files |
| `TARGET_GROUP` | `srv-62-relay` | Group for deployed files |
| `TARGET_PERMISSIONS` | `664` | File permissions (`rw-rw-r--`) |
| `SERVICE_NAME` | `lsws` | Systemd service to restart |
| `SERVICE_RESTART` | `"false"` | Set to `"true"` to restart the service after deployment |

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string** with the following structure:

```json
{
  "certfolder": "/path/to/certs",
  "files": ["certificate.crt", "private.key"],
  "args": ["arg1", "arg2", "arg3", "arg4", "arg5"]
}
```

The script extracts:

- **`certfolder`** — directory containing the enrolled certificate and key
- **`files`** — filenames for the `.crt` and `.key` files
- **`args`** — up to five custom arguments passed from the AWR profile

## What the Script Does

1. **Legal notice check** — exits immediately if `LEGAL_NOTICE_ACCEPT` is not `"true"`
2. **Decode** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload
3. **Extract** — pulls certificate path, key path, and custom arguments from the JSON
4. **Inspect** — logs certificate count, key type (RSA / ECC / PKCS#8), and file sizes
5. **Backup** — moves existing `cert.pem` and `cert_key.pem` to `.orig` backups
6. **Deploy** — copies the new certificate and key to the target directory
7. **Permissions** — sets ownership (`chown`) and permissions (`chmod`) on deployed files
8. **Verify** — confirms file existence, permissions, ownership, and size post-deployment
9. **Restart** *(optional)* — restarts the configured systemd service and verifies it is active
10. **Rollback on failure** — if any copy operation fails, backups are automatically restored

## Usage

1. Place the script in your TLM Agent's post-enrollment script directory.

2. Set `LEGAL_NOTICE_ACCEPT="true"` after reviewing the legal notice.

3. Adjust the configuration variables to match your environment.

4. Configure the AWR profile in TLM to execute this script after enrollment/renewal.

5. *(Optional)* Set `SERVICE_RESTART="true"` to automatically restart the web server.

## Logging

All operations are logged with timestamps to the configured `LOGFILE`. The log includes:

- Full decoded JSON payload (for debugging)
- Extracted certificate metadata (file paths, cert count, key type)
- Each deployment step with success/failure status
- Post-deployment verification (permissions, ownership, size)
- Service restart status (if enabled)

Example log output:

```
[2025-03-16 10:30:01] Starting DC1_POST_SCRIPT_DATA extraction script
[2025-03-16 10:30:01] Certificate file exists: /path/to/cert.crt
[2025-03-16 10:30:01] Total certificates in file: 3
[2025-03-16 10:30:01] Key type: RSA (BEGIN RSA PRIVATE KEY found)
[2025-03-16 10:30:01] Copying new certificate: /path/to/cert.crt -> /usr/local/rocket/etc/cert.pem
[2025-03-16 10:30:01] Certificate copy successful
[2025-03-16 10:30:01] Rocket certificate deployment completed successfully
```

## Error Handling

The script exits with code `1` on any critical failure:

- Legal notice not accepted
- `DC1_POST_SCRIPT_DATA` not set
- Source certificate or key file missing
- Target directory does not exist
- File copy, ownership, or permission operations fail
- Service restart fails (if enabled)

On copy failure, the script attempts to restore `.orig` backups automatically.

## Available Variables for Customisation

The script's custom logic section provides access to all extracted data:

| Variable | Description |
|---|---|
| `$CRT_FILE_PATH` | Full path to the source certificate |
| `$KEY_FILE_PATH` | Full path to the source private key |
| `$CERT_FOLDER` | Certificate folder from the JSON payload |
| `$CERT_COUNT` | Number of certificates in the bundle |
| `$KEY_TYPE` | Key type (RSA, ECC, PKCS#8, Unknown) |
| `$ARGUMENT_1` – `$ARGUMENT_5` | Custom arguments from the AWR profile |
| `$JSON_STRING` | Complete decoded JSON string |

## Security Notes

- The private key permissions default to `664` — consider tightening to `600` or `640` depending on your security requirements.
- Review and adjust `TARGET_OWNER` / `TARGET_GROUP` to match your service account.
- The script logs the raw JSON payload; ensure the log file has appropriate access controls.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.