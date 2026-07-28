# DigiCert ONE – Linux Agent AWR Generic Post-Delivery Scripts

Post-delivery scripts for use with the **DigiCert ONE Trust Lifecycle Manager Admin Web Request (AWR)** workflow. They automate the replacement of TLS certificates and private keys on Linux endpoints managed by the DigiCert Agent, with safe backups, permission preservation, SELinux support, and optional post-deployment commands.

This folder contains two scripts that follow the same AWR operating pattern but serve different deployment models:

| | Script 1: Generic deployment | Script 2: Combined-PEM symlink deployment |
|---|---|---|
| **Script** | `generic_awr_postscript-awr.sh` | `generic_awr_combined_pem_symlink-awr.sh` |
| **Output** | Separate `.crt` and `.key` files deployed in place | Single combined PEM (end-entity cert + chain + key) |
| **Update model** | Overwrites the application's existing files | Versioned file + atomic update of a stable symbolic link |
| **Post commands** | One command (parameter 3) | Comma-separated list of commands, executed in order |
| **Rollback** | Timestamped backups | Timestamped backups plus automatic rollback on command failure |
| **Typical use** | Applications that read a fixed `.crt`/`.key` pair (e.g. Nginx) | One or more consumers referencing the same combined PEM pathname |

Use **Script 1** when the application expects a certificate and key as two separate files at fixed paths. Use **Script 2** when consumers read a single combined PEM and you want versioned, atomically-switched deployments with rollback.

---

# Script 1 — Generic Certificate Deployment (`generic_awr_postscript-awr.sh`)

A post-delivery script that automates the end-to-end replacement of TLS certificates and private keys, with safe backups, permission preservation, SELinux support, and an optional service restart.

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

## Prerequisites

- A Linux host enrolled with the **DigiCert Agent**.
- `bash`, `stat`, `sha256sum`, `cp`, `chmod`, `chown` — all standard on modern Linux distributions.
- `restorecon` — optional; used automatically on SELinux-enabled systems (RHEL/CentOS/Rocky/Fedora).
- The script must be run with sufficient privileges to write to the target certificate directory (typically `root`).

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

## Error Handling

| Exit Code | Meaning |
|---|---|
| `0` | Script completed successfully |
| `1` | Legal notice not accepted, or `DC1_POST_SCRIPT_DATA` not set |
| `2` | Checksum verification failure, missing source file, or metadata apply failure |
| `127` | Post-deployment command not found on the system |
| Other | Exit code propagated directly from the post-deployment command |

## Security Considerations

- **Private key permissions** — the `DEFAULT_KEY_MODE` of `600` ensures private keys are never world- or group-readable when no prior file exists to inherit from.
- **No use of `eval`** — indirect variable assignment uses `printf -v` throughout to avoid shell injection risks.
- **Checksum gating** — deployment is aborted if any file copy cannot be verified, preventing a partially-written certificate from being put into service.
- **Legal notice gate** — the script will not execute unless `LEGAL_NOTICE_ACCEPT` is explicitly set to `"true"` in the script body, serving as a conscious acceptance checkpoint before deployment.

---

# Script 2 — Combined-PEM Symlink Deployment (`generic_awr_combined_pem_symlink-awr.sh`)

**Revision 2026-07-22.3:** `decode_payload()` uses `base64`, `awk`, and Bash built-ins. `parse_command_list()` is implemented entirely with Bash string and array operations. The script contains no Python invocation.

This application-neutral post-delivery script adapts the DigiCert Generic AWR pattern for a Linux host where one or more consumers reference the same combined PEM pathname.

It accepts a DigiCert-delivered certificate bundle (`.crt` or `.cer`) and private key (`.key`), constructs a combined PEM, writes it under a versioned filename, and atomically updates a stable symbolic link.

The script does **not** assume that any of the following already exist:

- The destination directory.
- The stable PEM pathname.
- A symbolic link.
- An earlier versioned PEM.

## Files

- `generic_awr_combined_pem_symlink-awr.sh` - AWR post-delivery script.
- Default log: `/var/log/digicert-awr-combined-pem.log`.

## Dependencies

Required:

- Linux.
- Bash 4 or later.
- OpenSSL.
- `awk`.
- `base64`.
- Standard GNU/Linux commands used by the script: `stat`, `mktemp`, `ln`, `mv`, `readlink`, `grep`, `cp`, `chmod`, `chown`, `mkdir`, `rm`, `rmdir`, `cat`, `dirname`, `touch`, and `date`.

Optional:

- `flock` for file-descriptor locking. If unavailable, the script uses an atomic lock-directory fallback.
- `restorecon` for SELinux context restoration.

The script does **not** require Python, `jq`, Perl, or a third-party JSON utility. A small parser implemented in `awk` reads the known DigiCert AWR payload fields.

The script normally runs as `root`, particularly when writing below `/etc`, applying ownership, or invoking service-management commands.

## File encoding

Save the Bash script as **UTF-8 without a byte-order mark (BOM)**.

A BOM is sometimes used for Windows PowerShell files, but it must not be added to this `.sh` file. A Linux shebang must begin at byte 1; a BOM before `#!/usr/bin/env bash` can prevent direct execution.

Using `xxd`, the first three bytes should be `23 21 2f`, not `ef bb bf`:

```bash
head -c 3 generic_awr_combined_pem_symlink-awr.sh | xxd
```

Expected output resembles:

```text
00000000: 2321 2f                                  #!/
```

If `xxd` is unavailable, use the more commonly installed `od`:

```bash
od -An -tx1 -N3 generic_awr_combined_pem_symlink-awr.sh
```

Expected output:

```text
 23 21 2f
```

## Configuration

Review the configuration block near the beginning of the script:

```bash
LEGAL_NOTICE_ACCEPT="false"
LOGFILE="/var/log/digicert-awr-combined-pem.log"
LOCKFILE="/var/lock/digicert-awr-combined-pem.lock"
CREATE_DESTINATION_DIRECTORY="true"
DEFAULT_DIRECTORY_MODE="750"
DEFAULT_PEM_MODE="600"
DEFAULT_PEM_OWNER="root"
DEFAULT_PEM_GROUP="root"
ROLLBACK_ON_COMMAND_FAILURE="true"
RUN_COMMANDS_AFTER_ROLLBACK="true"
```

After reviewing the script and applicable DigiCert terms, change:

```bash
LEGAL_NOTICE_ACCEPT="true"
```

### First-deployment ownership and permissions

When the stable pathname does not exist, or an existing symbolic link is broken, the script uses:

```bash
DEFAULT_PEM_MODE="600"
DEFAULT_PEM_OWNER="root"
DEFAULT_PEM_GROUP="root"
```

Change these settings when a non-root process must read the private key. A common pattern is mode `640`, ownership by `root`, and a dedicated service group.

Do not make the combined PEM world-readable because it contains the private key.

When the stable pathname is an existing regular file, or an existing symbolic link resolves to a regular file, the new versioned PEM inherits the existing file's mode, UID, and GID.

### Destination-directory creation

With:

```bash
CREATE_DESTINATION_DIRECTORY="true"
```

all missing components of parameter 1 are created with `DEFAULT_DIRECTORY_MODE`. Existing ancestor directories are not modified.

Set the option to `false` when change control requires the destination directory to be provisioned separately.

## DigiCert AWR input

Configure the delivery to provide:

- Exactly one `.crt` or `.cer` file.
- Exactly one `.key` file.
- An unencrypted PEM private key.
- The three AWR parameters below.

The Agent delivery directory is obtained from `DC1_POST_SCRIPT_DATA`. It is separate from the destination directory supplied as parameter 1.

### AWR parameters

| Parameter | Meaning | Required |
|---|---|---|
| 1 | Absolute destination directory for the versioned PEM and stable link | Yes |
| 2 | Stable PEM filename only, without directory components | Yes |
| 3 | Comma-separated post-completion commands, executed in order | May be empty |

Generic example:

```text
Parameter 1: /etc/shared/tls
Parameter 2: current.pem
Parameter 3: /usr/local/sbin/validate-tls-config,systemctl restart service-one,systemctl reload service-two
```

Parameter 3 is split on commas that are outside shell single or double quotes. For example, the comma in the following quoted argument does not split the command:

```text
printf '%s\n' 'deployment,complete' >> /var/log/tls-update.log,systemctl reload service-one
```

Each command is intentionally executed using `bash -c`. Only trusted administrators should be permitted to configure AWR arguments. Do not place passwords, tokens, or other secrets in parameter 3 because command text and output are logged.

### Apache and TomEE example

Apache and Apache TomEE are only example consumers; no product-specific logic is embedded in the script.

```text
Parameter 1: /etc/apache2/ssl
Parameter 2: shared-tls.pem
Parameter 3: apache2ctl configtest,systemctl restart tomee,systemctl reload apache2
```

Use the actual unit names and validation commands present on the host.

## Deployment result

With:

```text
Parameter 1: /etc/shared/tls
Parameter 2: current.pem
```

the script creates a versioned file similar to:

```text
/etc/shared/tls/current-20260721_172414-50d07065583c.pem
```

It then atomically creates or replaces:

```text
/etc/shared/tls/current.pem -> current-20260721_172414-50d07065583c.pem
```

Consumers continue referencing the stable pathname:

```text
/etc/shared/tls/current.pem
```

## Existing-state handling

The script handles the stable pathname as follows:

| Existing state | Behaviour |
|---|---|
| Path absent | Creates the first versioned PEM and the stable symbolic link |
| Regular file | Creates a verified timestamped backup, then replaces the stable pathname with a symbolic link |
| Valid symbolic link | Records and backs up the link target, then atomically replaces the link |
| Broken symbolic link | Backs up the link text, uses default PEM metadata, then replaces the link |
| Directory or other special file | Stops without replacing it |

No pre-created placeholder file or symbolic link is required.

## Combined PEM construction

The delivered certificate bundle does not need to be in leaf-first order. The script:

1. Extracts every PEM certificate block.
2. Validates each certificate with OpenSSL.
3. Validates the delivered private key.
4. Compares public-key hashes to find the single certificate matching the private key.
5. Writes the matching end-entity certificate first.
6. Appends the remaining certificates in their original relative order.
7. Appends the private key last.

The result is:

```text
-----BEGIN CERTIFICATE-----
End-entity certificate
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
Remaining chain certificate(s)
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
Private key
-----END PRIVATE KEY-----
```

RSA, EC, and unencrypted PKCS#8 private keys are validated through `openssl pkey`.

## Atomic update

The versioned PEM is completely built, validated, copied, permissioned, and checksum-verified before the stable pathname changes.

The script creates a temporary symbolic link in the same destination directory and renames it over the stable pathname. This keeps the link replacement on one filesystem and avoids exposing a partially written PEM through the stable pathname.

## Backups and rollback

For an existing regular file, the script creates a timestamped backup such as:

```text
current.pem-20260721_172420.bak
```

For an existing symbolic link, it creates a timestamped backup link such as:

```text
current.pem-20260721_172420.link.bak
```

If a post-completion command fails and rollback is enabled, the script restores the previous regular file or symbolic link. When there was no prior stable pathname, rollback removes the newly created stable link.

The new versioned PEM is retained after rollback for diagnostics. Old versioned PEMs and backups are not deleted automatically; apply an external retention policy appropriate to the environment.

When `RUN_COMMANDS_AFTER_ROLLBACK="true"`, the configured commands are run again after restoration so consumers can reload the previous state. Use idempotent validation, restart, and reload commands. Set this option to `false` if any configured command is not safe to repeat.

## Logging

The log file is created with mode `600`. It records:

- Delivery and destination paths.
- Certificate subject, serial number, validity, and SHA-256 fingerprint.
- File checksums.
- Permission and ownership decisions.
- Stable-link changes.
- Command text, output, and exit status.
- Backup and rollback activity.

Private-key content is not intentionally logged.

## Recommended validation

Before production use, test these cases in a controlled environment:

1. Destination directory and stable pathname both absent.
2. Existing regular PEM converted to a stable symbolic link.
3. Existing valid symbolic link renewed successfully.
4. Existing broken symbolic link replaced successfully.
5. A deliberately failing second or third post-completion command restores the previous state.
6. The intended service accounts can read the resolved versioned PEM.
7. Every configured consumer presents the renewed certificate after its validation, reload, or restart command.
8. SELinux contexts remain correct where SELinux is enabled.

## Upstream reference

This is a custom rework based on the operating pattern documented by DigiCert in the `Generic-AWR-PostScript` example in the `digicert/product-solutions` GitHub repository. It is not a verbatim copy. Review it under the normal security and change-control process before deployment.

---

> **License & Legal**
> Copyright © 2024 DigiCert. All rights reserved. Use of these scripts is subject to your agreement with DigiCert. See the `LEGAL_NOTICE` block at the top of each script for full terms.
