# DigiCert TLM Agent AWR Post-Enrollment Script – Mailcow

## Overview

This bash script automates SSL/TLS certificate deployment to a [Mailcow](https://mailcow.email/) dockerized mail server following certificate enrollment or renewal via the DigiCert Trust Lifecycle Manager (TLM) Agent. It is designed to run as an **Admin Web Request (AWR) post-enrollment script**, triggered automatically when a new certificate is issued or renewed.

The script reads certificate data provided by the TLM Agent, backs up the existing certificates, installs the new certificate and private key, and restarts the Mailcow Nginx container to apply the changes.

## Prerequisites

- **DigiCert TLM Agent** (v3.0.15 or later) installed and configured on the host
- **Mailcow Dockerized** installed at `~/mailcow-dockerized` (relative to the executing user) or `/root/mailcow-dockerized`
- **Docker Compose** available on the system PATH
- **bash** shell environment (Linux)
- The TLM Agent must be configured to set the `DC1_POST_SCRIPT_DATA` environment variable when invoking post-enrollment scripts

## How It Works

### Data Flow

1. The TLM Agent completes certificate enrollment/renewal and sets the `DC1_POST_SCRIPT_DATA` environment variable containing a Base64-encoded JSON payload.
2. The script decodes the payload to extract the certificate folder path and filenames.
3. The existing PEM certificates are backed up from the Mailcow SSL directory.
4. The new certificate (`.crt`) and private key (`.key`) files are copied into place as `cert.pem` and `key.pem`.
5. The `nginx-mailcow` Docker container is restarted to load the new certificate.

### JSON Payload Structure

The `DC1_POST_SCRIPT_DATA` environment variable contains a Base64-encoded JSON string with the following structure:

```json
{
  "certfolder": "/path/to/certificate/directory",
  "files": ["certificate.crt", "privatekey.key"]
}
```

## Configuration

### Legal Notice Acceptance

Before the script will execute, you must accept the legal notice by editing the script and setting:

```bash
LEGAL_NOTICE_ACCEPT="true"
```

### File Paths

| Path | Description |
|------|-------------|
| `/home/ubuntu/tlm_agent_3.0.15_linux64/log/mailcow.log` | Log file location |
| `~/mailcow-dockerized/data/assets/ssl/` | Mailcow SSL certificate directory |
| `/root/mailcow-dockerized` | Mailcow installation directory (used for Docker Compose commands) |
| `/home/ubuntu/` | Backup destination for existing PEM files |

Adjust these paths in the script to match your environment if they differ from the defaults.

## Script Execution Steps

1. **Decode payload** – Reads and Base64-decodes the `DC1_POST_SCRIPT_DATA` environment variable.
2. **Extract filenames** – Parses the JSON to identify the `.crt` and `.key` files and the certificate folder.
3. **Backup existing certificates** – Moves current `*.pem` files from the Mailcow SSL directory to `/home/ubuntu/`.
4. **Install new certificate** – Copies the `.crt` file to `cert.pem` and the `.key` file to `key.pem` in the Mailcow SSL directory.
5. **Restart Nginx** – Runs `docker-compose restart nginx-mailcow` from the Mailcow installation directory.

## Logging

All output (stdout and stderr) is appended to the log file at:

```
/home/ubuntu/tlm_agent_3.0.15_linux64/log/mailcow.log
```

Each log entry is timestamped. The script logs the start and end of execution, decoded JSON data, extracted file paths, and the result of each operation.

## Deployment

1. Copy the script to the TLM Agent's scripts directory (e.g., `/home/ubuntu/tlm_agent_3.0.15_linux64/scripts/`).
2. Make it executable:
   ```bash
   chmod +x mailcow.sh
   ```
3. Set `LEGAL_NOTICE_ACCEPT="true"` in the script.
4. Configure the TLM Agent to use this script as the post-enrollment hook for the relevant certificate profile.
5. Ensure the user account running the TLM Agent has permissions to write to the Mailcow SSL directory and execute `docker-compose` commands.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script not invoked by TLM Agent, or agent version mismatch | Verify the TLM Agent is configured to pass post-enrollment data |
| `Failed to decode base64 string` | Corrupted or truncated environment variable | Check the TLM Agent logs for enrollment errors |
| `Could not extract .crt / .key filename` | Unexpected JSON structure | Inspect the decoded JSON in the log file |
| `Failed to copy ... to cert.pem` | Permission denied or missing source file | Verify file permissions and that the certificate folder exists |
| `Failed to restart nginx-mailcow` | Docker Compose not found, or container not running | Run `docker-compose ps` in the Mailcow directory to check status |
| Backup warning | No existing PEM files to back up (first run) | Safe to ignore on initial deployment |

## Security Considerations

- The script handles private key material — ensure appropriate file permissions (`600`) on both the script and the certificate directory.
- The backup step moves existing PEM files to the home directory; consider implementing a rotation or cleanup policy.
- Run the script with the minimum required privileges. If `docker-compose` requires root, consider adding the service account to the `docker` group rather than running the entire script as root.

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.