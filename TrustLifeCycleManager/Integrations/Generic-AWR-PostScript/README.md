# DigiCert ONE – Linux Agent AWR Generic Certificate Deployment Script

A post-delivery script for use with the **DigiCert ONE Trust Lifecycle Manager Admin Web Request (AWR)** workflow. It automates the end-to-end replacement of TLS certificates and private keys on Linux endpoints managed by the DigiCert Agent, with safe backups, permission preservation, SELinux support, and an optional service restart.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [AWR Workflow Setup](#awr-workflow-setup)
- [What the Script Does](#what-the-script-does)
- [Parameters](#parameters)
- [Logging](#logging)
- [Error Handling](#error-handling)
- [Security Considerations](#security-considerations)

---

## Overview

When DigiCert ONE issues or renews a certificate via an AWR workflow, this script is executed on the target Linux host by the DigiCert Agent. It:

1. Captures the existing file permissions and ownership before making any changes.
2. Creates timestamped backups of the current certificate and private key.
3. Verifies backups using SHA-256 checksums.
4. Deploys the newly issued certificate and key files to the application's expected paths.
5. Verifies the deployed files using SHA-256 checksums.
6. Restores the original permissions and ownership (or applies safe defaults for new files).
7. Reapplies SELinux file contexts if `restorecon` is available.
8. Optionally runs a post-deployment command (e.g. a service restart).

---

## Prerequisites

- A Linux host enrolled with the **DigiCert Agent**.
- `bash`, `stat`, `sha256sum`, `cp`, `chmod`, `chown` — all standard on modern Linux distributions.
- `restorecon` — optional; used automatically on SELinux-enabled systems (RHEL/CentOS/Rocky/Fedora).
- The script must be run with sufficient privileges to write to the target certificate directory (typically `root`).

---

## Configuration

Before deploying, open the script and set the following variable at the top:

```bash
LEGAL_NOTICE_ACCEPT="true"   # Must be set to "true" to allow execution
```

Two fallback permission modes are also configurable for cases where no pre-existing file is found to inherit permissions from:

```bash
DEFAULT_CRT_MODE="644"   # Fallback mode applied to new .crt files
DEFAULT_KEY_MODE="600"   # Fallback mode applied to new .key files
```

A fixed log path is used by default:

```bash
LOGFILE="/var/log/digicert-awr-generic-script.log"
```

---

## AWR Workflow Setup

### Step 1 — Certificate Request
Complete the standard fields: profile selection, common name, SANs, and renewal period.

### Step 2 — Agent Configuration

| Field | Value |
|---|---|
| **Certificate format** | `.crt` |
| **Target path** | A **subfolder** of the application's certificate directory (e.g. `/etc/nginx/ssl/digicert`). The script promotes the files up one level. |
| **Run post-delivery scripts** | ✅ Enabled |
| **Script** | This script |
| **Parameter 1** | Name of the `.crt` file the application expects (e.g. `nginx.crt`) |
| **Parameter 2** | Name of the `.key` file the application expects (e.g. `nginx.key`) |
| **Parameter 3** | Command to reload/restart the application (e.g. `systemctl restart nginx.service`) |

### Step 3 — Submit
Review the configuration, accept the terms and conditions, and submit the request.

---

## What the Script Does

```
DC1_POST_SCRIPT_DATA (base64 JSON)
        │
        ▼
 Decode & extract paths/arguments
        │
        ▼
 Capture existing CRT + KEY metadata
 (mode, owner, group)
        │
        ├──► Backup existing CRT  ──► SHA-256 verify backup
        │
        ├──► Backup existing KEY  ──► SHA-256 verify backup
        │
        ├──► Deploy new CRT       ──► SHA-256 verify deploy
        │
        ├──► Deploy new KEY       ──► SHA-256 verify deploy
        │
        ├──► Restore permissions/ownership (or apply defaults)
        │
        ├──► restorecon (if SELinux present)
        │
        └──► Run APP_SERVICE_COMMAND (if provided)
```

### Key Behaviours

**Permission preservation** — `capture_metadata` reads the mode, owner, and group of the existing file before any changes are made. `apply_metadata` restores those values after deployment. If no prior file existed, `DEFAULT_CRT_MODE` (`644`) or `DEFAULT_KEY_MODE` (`600`) is applied instead.

**Checksum verification** — every `cp` operation (backup and deployment) is followed immediately by a SHA-256 comparison between source and destination. The script aborts with exit code `2` on any mismatch.

**Timestamped backups** — backups are written alongside the originals using the naming convention:
```
/etc/nginx/ssl/nginx.crt-20250514_153012.bak
```

**SELinux awareness** — if `restorecon` is present, it is called on both deployed files so that policy-defined contexts are reapplied automatically.

**Structured logging** — every significant action is timestamped and written to the log file, including extracted arguments, file metadata, checksums, command output, and exit codes.

---

## Parameters

The script receives its inputs via the `DC1_POST_SCRIPT_DATA` environment variable, which the DigiCert Agent populates with a base64-encoded JSON payload. The following values are extracted:

| Variable | Source | Description |
|---|---|---|
| `ARGUMENT_1` | Parameter 1 | Filename of the application's expected `.crt` file |
| `ARGUMENT_2` | Parameter 2 | Filename of the application's expected `.key` file |
| `ARGUMENT_3` | Parameter 3 | Post-deployment command or script |
| `CERT_FOLDER` | JSON payload | Delivery subfolder used by the Agent |
| `CRT_FILE_PATH` | Derived | Full path to the newly issued `.crt` |
| `KEY_FILE_PATH` | Derived | Full path to the newly issued `.key` |
| `APP_CRT_FILE_PATH` | Derived | Full path where the application's `.crt` lives (one level up from `CERT_FOLDER`) |
| `APP_KEY_FILE_PATH` | Derived | Full path where the application's `.key` lives (one level up from `CERT_FOLDER`) |

---

## Logging

All output is appended to `/var/log/digicert-awr-generic-script.log`. Each entry is prefixed with a timestamp:

```
[2025-05-14 15:30:12] Capturing existing file metadata for permission/ownership preservation...
[2025-05-14 15:30:12] Captured metadata for [/etc/nginx/ssl/nginx.crt]: mode=644, owner=root, group=root
[2025-05-14 15:30:12] [/etc/nginx/ssl/nginx.crt] CRT file exists. Creating backup: /etc/nginx/ssl/nginx.crt-20250514_153012.bak
[2025-05-14 15:30:12] Checksum [/etc/nginx/ssl/nginx.crt] = [a3f1...]
[2025-05-14 15:30:12] Checksum [/etc/nginx/ssl/nginx.crt-20250514_153012.bak] = [a3f1...]
[2025-05-14 15:30:12] File copied successfully and verified.
```

---

## Error Handling

| Exit Code | Meaning |
|---|---|
| `0` | Script completed successfully |
| `1` | Legal notice not accepted, or `DC1_POST_SCRIPT_DATA` not set |
| `2` | Checksum verification failure, missing source file, or metadata apply failure |
| `127` | Post-deployment command not found on the system |
| Other | Exit code propagated directly from the post-deployment command |

---

## Security Considerations

- **Private key permissions** — the `DEFAULT_KEY_MODE` of `600` ensures private keys are never world- or group-readable when no prior file exists to inherit from.
- **No use of `eval`** — indirect variable assignment uses `printf -v` throughout to avoid shell injection risks.
- **Checksum gating** — deployment is aborted if any file copy cannot be verified, preventing a partially-written certificate from being put into service.
- **Legal notice gate** — the script will not execute unless `LEGAL_NOTICE_ACCEPT` is explicitly set to `"true"` in the script body, serving as a conscious acceptance checkpoint before deployment.

---

> **License & Legal**
> Copyright © 2024 DigiCert. All rights reserved. Use of this script is subject to your agreement with DigiCert. See the `LEGAL_NOTICE` block at the top of the script for full terms.