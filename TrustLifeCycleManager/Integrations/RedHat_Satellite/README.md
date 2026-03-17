# DigiCert TLM Agent AWR Post-Enrollment Script – Red Hat Satellite

## Overview

This bash script automates SSL/TLS certificate deployment to a [Red Hat Satellite](https://www.redhat.com/en/technologies/management/satellite) server following certificate enrollment or renewal via the DigiCert Trust Lifecycle Manager (TLM) Agent. It runs as an **Admin Web Request (AWR) post-enrollment script**, triggered automatically when a new certificate is issued or renewed.

The script reads certificate data provided by the TLM Agent, splits the certificate chain into server and CA components, validates the certificates using `katello-certs-check`, installs them via `satellite-installer`, and includes automatic rollback if installation fails.

## Prerequisites

- **DigiCert TLM Agent** installed and configured on the Satellite server (or a host with access to run Satellite installer commands)
- **Red Hat Satellite 6.x** with `satellite-installer` and `katello-certs-check` available at `/usr/sbin/`
- **bash** shell environment (RHEL/CentOS)
- **OpenSSL** on the system PATH
- Root or equivalent privileges (the script writes to `/root/satellite_cert/` and invokes `satellite-installer`)
- The TLM Agent must be configured to set the `DC1_POST_SCRIPT_DATA` environment variable when invoking post-enrollment scripts

## How It Works

### Data Flow

1. The TLM Agent completes certificate enrollment/renewal and sets `DC1_POST_SCRIPT_DATA` with a Base64-encoded JSON payload.
2. The script decodes the payload to extract the certificate folder path and filenames.
3. The bundled certificate file is split into the **server certificate** (first certificate in the chain) and the **CA chain** (all remaining certificates).
4. The server certificate is verified to contain the local hostname; the chain is checked for the DigiCert CA.
5. Existing certificates are backed up with a date-stamped suffix.
6. `katello-certs-check` validates the new certificate, key, and chain.
7. `satellite-installer` installs the certificates and updates both the server and CA trust.
8. If installation fails, the script automatically rolls back to the previous certificates and re-runs the installer.

### Certificate Chain Processing

The source `.crt` file from the TLM Agent typically contains a full chain (server certificate + intermediate/root CAs). The script splits this into two files:

- **Server certificate** — the first `BEGIN CERTIFICATE` block, saved as `rhn-sat-dev-2_crt.pem`
- **CA chain** — all subsequent certificate blocks, saved as `digicert-chain.pem`

If no separate chain certificates are found, the full source file is used as the chain.

## Configuration

Edit the configuration block at the top of the script:

| Variable | Description | Default |
|----------|-------------|---------|
| `LEGAL_NOTICE_ACCEPT` | Must be set to `true` to allow execution | `false` |
| `LOGFILE` | Log file location | `/var/log/satellite-cert-update.log` |
| `SATELLITE_CERT_DIR` | Directory for processed certificate files | `/root/satellite_cert` |
| `SATELLITE_SERVER_CERT` | Destination path for the server certificate | `<SATELLITE_CERT_DIR>/rhn-sat-dev-2_crt.pem` |
| `SATELLITE_SERVER_KEY` | Destination path for the private key | `<SATELLITE_CERT_DIR>/rhn-sat-dev-2_key.pem` |
| `SATELLITE_CHAIN_FILE` | Destination path for the CA chain file | `<SATELLITE_CERT_DIR>/digicert-chain.pem` |

Adjust the `SATELLITE_SERVER_CERT` and `SATELLITE_SERVER_KEY` filenames to match your Satellite server's naming convention.

## JSON Payload Structure

The `DC1_POST_SCRIPT_DATA` environment variable contains a Base64-encoded JSON string:

```json
{
  "certfolder": "/path/to/certificate/directory",
  "files": ["certificate.crt", "privatekey.key"]
}
```

## Script Execution Steps

1. **Decode payload** — Reads and Base64-decodes the `DC1_POST_SCRIPT_DATA` environment variable.
2. **Extract filenames** — Parses the JSON to identify the `.crt` and `.key` files.
3. **Split certificate chain** — Separates the server certificate from intermediate/root CA certificates.
4. **Verify certificates** — Checks that the server certificate contains the local hostname and the chain contains the DigiCert CA.
5. **Backup existing certificates** — Copies current files with a date-stamped suffix (e.g., `.20260316`).
6. **Set permissions** — Private key set to `600`, certificate and chain set to `644`.
7. **Validate with katello-certs-check** — Runs Red Hat's certificate validation tool against the new files.
8. **Install with satellite-installer** — Applies the certificates using `--certs-update-server` and `--certs-update-server-ca`.
9. **Rollback on failure** — If installation fails, restores backups and re-runs the installer to recover.
10. **Verify services** — Confirms Satellite services are running after the update.

## Rollback Behaviour

The script includes automatic rollback logic:

- If `satellite-installer` fails with the new certificates, the previous date-stamped backups are restored.
- The installer is re-run with the restored certificates to return Satellite to a working state.
- If even the rollback installation fails, the script exits with a critical error and requests manual intervention.

## Logging

All output is written to `/var/log/satellite-cert-update.log` (configurable) and echoed to stdout. Each run is bracketed with start/end markers. The output from both `katello-certs-check` and `satellite-installer` is captured line-by-line in the log.

## Deployment

1. Copy the script to the TLM Agent's scripts directory on the Satellite server.
2. Make it executable:
   ```bash
   chmod +x satellite-cert-update.sh
   ```
3. Set `LEGAL_NOTICE_ACCEPT="true"` in the script.
4. Adjust the `SATELLITE_SERVER_CERT`, `SATELLITE_SERVER_KEY`, and `SATELLITE_CHAIN_FILE` paths to match your environment.
5. Configure the TLM Agent to use this script as the post-enrollment hook for the relevant certificate profile.
6. Ensure the script runs with root privileges (required by `satellite-installer`).

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `DC1_POST_SCRIPT_DATA is not set` | Script not invoked by TLM Agent | Verify TLM Agent post-enrollment hook configuration |
| `Certificate file not found` | Incorrect cert folder or file not yet written to disk | Check the TLM Agent logs; verify the JSON payload paths |
| `Certificate validation failed` (katello-certs-check) | Mismatched key/cert, missing chain, or hostname mismatch | Run `katello-certs-check` manually with the same files to see detailed errors |
| `Satellite installer failed` | Service conflicts, permission issues, or invalid certificate | Review the installer output in the log file; check `/var/log/foreman-installer/` |
| `WARNING: Server certificate may not contain hostname` | Certificate CN/SAN does not match the server's short hostname | Verify the certificate profile includes the correct subject or SAN entries |
| `CRITICAL: Failed to install even with rolled-back certificates` | Satellite services in a broken state unrelated to certificates | Manual intervention required; check Satellite logs and service status |
| Backup warning on first run | No existing certificates to back up | Safe to ignore on initial deployment |

## Security Considerations

- The script handles private key material — ensure the script itself has restrictive permissions (`700` or `750`).
- The private key is installed with `600` permissions; certificate and chain files with `644`.
- Backup files retain the original permissions. Consider implementing a cleanup policy for date-stamped backups.
- The log file may contain certificate paths and chain details. Restrict access to `/var/log/satellite-cert-update.log`.
- Run the script only as root or via a dedicated service account with the minimum required privileges for `satellite-installer`.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.