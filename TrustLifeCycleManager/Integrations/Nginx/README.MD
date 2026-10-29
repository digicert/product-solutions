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
| **Permissions** | The script must run with sufficient privileges to write to the Nginx SSL directory and restart the service (typically root). The TLM Agent runs the script as its own service user, so that user needs those rights. |
| **Script placement** | Copy `nginx-awr.sh` to the agent host and mark it executable (`chmod +x nginx-awr.sh`). Reference its absolute path in the AWR request. |

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

## AWR Workflow Setup

Configure the Admin Web Request (AWR) in the TLM console as follows. The script only works with the **CRT** output format because it looks for a `.crt` and a `.key` entry in the `files` array of the `DC1_POST_SCRIPT_DATA` payload.

### Step 1 — Certificate Request
Complete the standard fields: profile selection, common name, SANs, and renewal period.

### Step 2 — Agent Configuration

| Field | Value |
|---|---|
| **Certificate format** | `.crt` — the agent writes a PEM certificate (`<name>.crt`) and a PEM private key (`<name>.key`) as two separate files. Do **not** select PFX/PKCS#12; the script does not read a `.pfx` and will abort with `Missing one or more required inputs`. |
| **Target path** | A staging directory on the agent host that is **not** the live Nginx cert location, for example `/etc/nginx/ssl/digicert`. The script copies from this folder (`certfolder` in the payload) to `NGINX_CERT_PATH` / `NGINX_KEY_PATH`. If the target path is the same directory and filename as the live paths, the agent overwrites the live files before the script runs and the backup step saves the new certificate instead of the old one. |
| **Run post-delivery scripts** | ✅ Enabled |
| **Script** | Absolute path to `nginx-awr.sh` on the agent host (for example `/opt/digicert/scripts/nginx-awr.sh`) |
| **Parameter 1 – 5** | Not used. Leave blank. |

### Step 3 — Submit
Review the configuration, accept the terms and conditions, and submit the request.

### Matching the script to the AWR request

| AWR setting | Script variable | Note |
|---|---|---|
| Certificate format `.crt` | `CRT_FILE`, `KEY_FILE` (auto-extracted) | Filenames are taken from the `files` array; no configuration needed |
| Target path | `CERT_FOLDER` (auto-extracted) | Source directory for the copy |
| — | `NGINX_CERT_PATH` | Must equal the `ssl_certificate` path in your Nginx server block |
| — | `NGINX_KEY_PATH` | Must equal the `ssl_certificate_key` path in your Nginx server block |

The `.crt` written by the agent is used as-is for `ssl_certificate`. Nginx expects the leaf certificate followed by the intermediate chain in that file. The script logs `Total certificates in file: N` after extraction; if `N` is `1`, check the certificate profile or AWR request so the chain is included, otherwise clients will see an incomplete-chain error.

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

The script extracts the first five AWR parameters (available as `$ARGUMENT_1` through `$ARGUMENT_5`). The Nginx deployment logic does not use any of them — all configuration is set via the variables at the top of the script — so leave Parameters 1–5 empty in the AWR request. The arguments are available for custom extensions. The current Linux AWR template extracts fifteen parameters; this script is based on the earlier five-parameter revision.

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
| `ERROR: Missing one or more required inputs (CERT_FOLDER/CRT_FILE/KEY_FILE)` | The AWR request is not using the `.crt` certificate format (for example PFX was selected), so no `.crt`/`.key` entry exists in the payload |
| `ERROR: Source certificate not found` | The TLM Agent cert folder or filename could not be resolved from the JSON payload, or the target path in the AWR request is not readable by the script |
| Backup contains the new certificate, not the old one | The AWR target path and filename are the same as `NGINX_CERT_PATH`; use a separate staging directory as the target path |
| `nginx -t: configuration test FAILED` | The deployed certificate may not match the Nginx config (wrong path, missing chain, etc.) |
| `ERROR: systemctl restart nginx failed` | Check `journalctl -u nginx` for details; verify the script runs as root |
| Restart skipped after validation failure | By design — fix the Nginx config issue, then manually reload |

## File Structure

```
nginx-awr.sh          # Main AWR post-enrollment script
```

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. Use of this software is subject to the terms and conditions of your agreement with DigiCert. See the legal notice embedded in the script header for full details.