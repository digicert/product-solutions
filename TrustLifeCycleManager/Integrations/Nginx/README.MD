# DigiCert TLM AWR Post-Enrollment Script — Nginx

Automates TLS certificate deployment to Nginx web servers, triggered by DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment hooks (AWR).

## Overview

This bash script is designed to run as an **Admin Web Request (AWR) post-enrollment script** within the DigiCert TLM Agent on Linux. After the agent enrolls or renews a certificate, this script automatically deploys the certificate and private key to the Nginx SSL directory, optionally validates the configuration, and restarts the service.

### What It Does

1. **Decodes** the `DC1_POST_SCRIPT_DATA` environment variable (Base64-encoded JSON) to extract certificate paths and metadata.
2. **Backs up** existing certificate and key files with a UTC timestamp (configurable).
3. **Deploys** the new certificate and private key atomically — writes to a temp file in the destination directory, sets permissions, then performs an `mv` to avoid partial-file races.
4. **Validates** the Nginx configuration with `nginx -t` (configurable).
5. **Restarts** Nginx via `systemctl`, `service`, or `nginx -s reload` as a fallback chain (configurable), skipping the restart if validation failed.

### Key Features

- **Atomic file deployment** — uses temp files and `mv` to prevent Nginx from reading a half-written certificate.
- **Automatic backup** — timestamped copies of the previous cert and key are saved before replacement.
- **Safe restart logic** — will not restart Nginx if `nginx -t` validation fails, preventing accidental downtime.
- **Flexible service management** — supports `systemctl`, `service`, and direct `nginx -s reload` for compatibility across distributions and container environments.
- **Strict key permissions** — private keys are deployed with mode `0600`; certificates with `0644`.
- **Comprehensive logging** — every step, file operation, and error is written to a timestamped log file.

## Prerequisites

| Requirement | Details |
|---|---|
| **DigiCert TLM Agent** | Installed and configured on the Linux host with AWR post-enrollment enabled |
| **Nginx** | Installed and configured with `ssl_certificate` / `ssl_certificate_key` directives pointing to the target paths |
| **Shell** | Bash with standard utilities (`base64`, `grep`, `awk`, `mktemp`, `stat`) |
| **Permissions** | The script must run with sufficient privileges to write to the Nginx SSL directory and restart the service (typically root) |

## Configuration

Edit the variables at the top of the script to match your environment:

```bash
# Must be set to "true" to accept the legal notice
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/home/ubuntu/tlm_agent_3.1.4_linux64/log/nginx.log"

# Back up existing certs before replacing (true/false)
BACKUP_OLD_CERTS="true"

# Restart Nginx after deployment (true/false)
RESTART_NGINX="true"

# Validate Nginx config with 'nginx -t' before restart (true/false)
VALIDATE_NGINX_CONFIG="true"

# Target paths matching your Nginx ssl_certificate / ssl_certificate_key directives
NGINX_CERT_PATH="/etc/nginx/ssl/example.com.crt"
NGINX_KEY_PATH="/etc/nginx/ssl/example.com.key"
```

### Configuration Options

| Variable | Default | Description |
|---|---|---|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be `"true"` for the script to execute |
| `LOGFILE` | (see script) | Path to the log file |
| `BACKUP_OLD_CERTS` | `"true"` | Create timestamped backups of existing cert/key before overwriting |
| `RESTART_NGINX` | `"true"` | Restart Nginx after deploying certificates |
| `VALIDATE_NGINX_CONFIG` | `"true"` | Run `nginx -t` before restarting; skip restart on failure |
| `NGINX_CERT_PATH` | — | Destination path for the certificate file |
| `NGINX_KEY_PATH` | — | Destination path for the private key file |

## How It Works

```
TLM Agent enrolls/renews cert
        │
        ▼
AWR triggers this script
        │
        ▼
Decode DC1_POST_SCRIPT_DATA (Base64 → JSON)
        │
        ▼
Extract cert/key files from JSON
        │
        ▼
Verify source files exist
        │
        ▼
Back up existing cert & key (if enabled)
        │
        ▼
Deploy cert (0644) & key (0600) atomically
        │
        ▼
Run nginx -t (if enabled) ─── FAIL ──▶ Skip restart, log error
        │
        PASS
        │
        ▼
Restart Nginx (systemctl → service → nginx -s reload)
```

## AWR Arguments

The script supports up to five arguments passed via the TLM Agent AWR configuration (available as `$ARGUMENT_1` through `$ARGUMENT_5`). The current Nginx deployment logic does not require any arguments — all configuration is set via the variables at the top of the script. The arguments are available for custom extensions.

## Logging

All output is written to the path configured in `$LOGFILE`, for example:

```
/home/ubuntu/tlm_agent_3.1.4_linux64/log/nginx.log
```

## Troubleshooting

| Symptom | Likely Cause |
|---|---|
| `ERROR: Legal notice not accepted` | Set `LEGAL_NOTICE_ACCEPT="true"` in the script |
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | The script is not being invoked by the TLM Agent AWR framework |
| `ERROR: Source certificate not found` | The TLM Agent cert folder or filename could not be resolved from the JSON payload |
| `nginx -t: configuration test FAILED` | The deployed certificate may not match the Nginx config (wrong path, missing chain, etc.) |
| `ERROR: systemctl restart nginx failed` | Check `journalctl -u nginx` for details; verify the script runs as root |
| Restart skipped after validation failure | By design — fix the Nginx config issue, then manually reload |

## File Structure

```
nginx-awr.sh          # Main AWR post-enrollment script
```

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. Use of this software is subject to the terms and conditions of your agreement with DigiCert. See the legal notice embedded in the script header for full details.