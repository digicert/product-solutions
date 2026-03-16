# DigiCert TLM Agent — HAProxy AWR Post-Enrollment Scripts

Automated certificate deployment to HAProxy using DigiCert Trust Lifecycle Manager (TLM) Agent Admin Web Request (AWR) post-enrollment scripts.

Two scripts are provided — one for **HAProxy Enterprise** (HAPEE) and one for **HAProxy Community/OSS**. Both follow the same workflow: after the TLM Agent enrolls or renews a certificate, the script combines the certificate chain and private key into a single PEM file, deploys it to the correct location on disk, and optionally applies it via a service reload, full restart, or zero-downtime Runtime API hot update.

---

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [How It Works](#how-it-works)
- [Quick Start](#quick-start)
- [HAProxy Enterprise](#haproxy-enterprise)
- [HAProxy OSS](#haproxy-oss)
- [Shared Features](#shared-features)
  - [Certificate Path Detection](#certificate-path-detection)
  - [Backup and Overwrite Modes](#backup-and-overwrite-modes)
  - [Service Reload Methods](#service-reload-methods)
  - [Runtime API Hot Update](#runtime-api-hot-update)
- [Configuration Reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

| Script | Target | Version Detection | Service Name | Config File |
|---|---|---|---|---|
| `haproxy-enterprise-awr.sh` | HAProxy Enterprise (HAPEE) | Auto-detects from binaries, config dirs, running processes, or systemd | `hapee-{version}-lb` | `/etc/hapee-{version}/hapee-lb.cfg` |
| `haproxy-oss-awr.sh` | HAProxy Community (OSS) | Auto-detects from binary (`haproxy -v`) | `haproxy` | `/etc/haproxy/haproxy.cfg` |

Both scripts share the same core capabilities:

- Combined PEM creation (certificate chain + private key)
- Auto-detection of the certificate path from HAProxy configuration
- Three certificate location modes: `global`, `frontend`, and `crt-list`
- Timestamped certificate backup before replacement
- Configuration validation before service restart
- Runtime API hot update (zero-downtime, in-memory certificate swap)
- Graceful reload or full restart via systemd

---

## Prerequisites

- **DigiCert TLM Agent** (v3.1.7+) installed on the same Linux host as HAProxy
- **bash**, **base64**, **grep** with PCRE (`-P`) support
- **socat** (required only if using the Runtime API hot update feature)
- The TLM Agent user must have write permissions to the HAProxy certificate directory and read access to the HAProxy configuration file
- A TLM certificate template configured with the AWR post-enrollment script

---

## How It Works

HAProxy requires TLS certificates in a single PEM file containing the certificate chain followed by the private key. After a TLM certificate enrollment or renewal, the agent sets the `DC1_POST_SCRIPT_DATA` environment variable (base64-encoded JSON containing certificate file paths and user-defined arguments) and executes the post-enrollment script. The script then:

1. Decodes the JSON payload and locates the `.crt` and `.key` files on disk
2. Determines where HAProxy expects the certificate PEM file (auto-detected from the config or explicitly configured)
3. Optionally backs up the existing PEM file with a timestamp
4. Concatenates the certificate chain and private key into a single PEM file at the target path
5. Applies the new certificate via one of three methods: Runtime API hot update, graceful reload, or full restart

---

## Quick Start

1. Copy the appropriate script to the TLM Agent's user-scripts directory
2. Edit the configuration section at the top of the script:

   ```bash
   LEGAL_NOTICE_ACCEPT="true"    # Required — must be set to "true"
   CERT_CONFIG_LOCATION="frontend"
   FRONTEND_NAME="https_front"   # Match your HAProxy frontend name
   RESTART_HAPROXY="yes"
   RESTART_METHOD="reload"       # Recommended for zero-downtime
   ```

3. Configure the TLM certificate template to use the script as the AWR post-enrollment script
4. Enroll or renew a certificate — the script runs automatically

---

## HAProxy Enterprise

**Script:** `haproxy-enterprise-awr.sh`

Designed for HAProxy Enterprise (HAPEE) installations, which use a versioned directory layout (`/etc/hapee-{version}/`, `/opt/hapee-{version}/`).

### Enterprise Version Detection

The script auto-detects the installed HAPEE version using four methods in order:

1. Scans for binaries at `/opt/hapee-{version}/sbin/hapee-lb` (versions 3.2 down to 2.4)
2. Scans for config directories at `/etc/hapee-{version}/`
3. Checks running processes for `hapee-*` patterns
4. Queries systemd for `hapee-*` service units

You can skip auto-detection by setting `HAPEE_VERSION` explicitly.

### Enterprise Path Layout

All paths are derived from the detected version:

| Path | Default | Purpose |
|---|---|---|
| Config file | `/etc/hapee-{ver}/hapee-lb.cfg` | HAProxy Enterprise configuration |
| Certificates | `/etc/hapee-{ver}/certs/` | PEM file storage |
| Backups | `/etc/hapee-{ver}/certs-backup/` | Timestamped backup directory |
| Runtime socket | `/var/run/hapee-{ver}/hapee-lb.sock` | Runtime API socket |
| Service name | `hapee-{ver}-lb` | systemd service unit |

### Enterprise Configuration

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/tlm_agent/tlm_agent_3.1.7_linux64/log/haproxy.log"

# Version — leave empty for auto-detection
HAPEE_VERSION=""

# Or set manually:
# HAPEE_VERSION="3.2"
# HAPEE_BASE_DIR="/etc/hapee-3.2"
```

### Enterprise Config Validation

Before restarting, the script validates the configuration using the HAPEE binary:

```
/opt/hapee-{version}/sbin/hapee-lb -c -f /etc/hapee-{version}/hapee-lb.cfg
```

If validation fails, the restart is aborted to prevent service disruption. The certificate file is still updated on disk.

---

## HAProxy OSS

**Script:** `haproxy-oss-awr.sh`

Designed for HAProxy Community (open source) installations using the standard OS package layout.

### OSS Path Layout

| Path | Default | Purpose |
|---|---|---|
| Config file | `/etc/haproxy/haproxy.cfg` | HAProxy configuration |
| Certificates | `/etc/haproxy/certs/` | PEM file storage |
| Backups | `/etc/haproxy/certs-backup/` | Timestamped backup directory |
| Runtime socket | `/run/haproxy/admin.sock` | Runtime API socket |
| Binary | `/usr/sbin/haproxy` | HAProxy binary |
| Service name | `haproxy` | systemd service unit |

All paths are configurable. The script also searches alternative binary locations (`/usr/local/sbin/haproxy`, `/usr/bin/haproxy`) during version detection.

### OSS Configuration

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/tlmagent/tlm_agent_3.1.7_linux64/log/haproxy-oss-awr.log"

# Paths — defaults work for standard Debian/Ubuntu and RHEL/CentOS installs
HAPROXY_CONFIG_FILE="/etc/haproxy/haproxy.cfg"
HAPROXY_BASE_DIR="/etc/haproxy"
HAPROXY_CERTS_DIR="/etc/haproxy/certs"
HAPROXY_BINARY="/usr/sbin/haproxy"
HAPROXY_SERVICE="haproxy"
```

### OSS — Docker Deployments

For Docker-based HAProxy, update the paths to match the container layout:

```bash
HAPROXY_CONFIG_FILE="/usr/local/etc/haproxy/haproxy.cfg"
HAPROXY_BASE_DIR="/usr/local/etc/haproxy"
HAPROXY_CERTS_DIR="/usr/local/etc/haproxy/certs"
```

### OSS — File Ownership

The OSS script automatically sets ownership of the deployed PEM file to `haproxy:haproxy` if the `haproxy` user exists on the system. This ensures HAProxy can read the certificate when running as a non-root user.

---

## Shared Features

The following features work identically in both the Enterprise and OSS scripts.

### Certificate Path Detection

The script can auto-detect where HAProxy expects its certificate PEM file by parsing the HAProxy configuration. Set `CERT_CONFIG_LOCATION` to control where the script looks:

**`global`** — Reads the `ssl-default-bind-crt` directive from the `global` section:

```
global
    ssl-default-bind-crt /etc/haproxy/certs/default.pem
```

**`frontend`** — Parses the `crt` parameter from the `bind` line of a named frontend (set via `FRONTEND_NAME`):

```
frontend https_front
    bind *:443 ssl crt /etc/haproxy/certs/site.pem
```

**`crt-list`** — Reads the first entry from a crt-list file (set via `CRT_LIST_FILE`):

```
/etc/haproxy/certs/site1.pem  site1.example.com
/etc/haproxy/certs/site2.pem  site2.example.com
```

If auto-detection fails, set `TARGET_CERT_PATH` explicitly to bypass parsing entirely.

### Backup and Overwrite Modes

Controlled by `CERT_BACKUP_MODE`:

**`backup`** (default) — Creates a timestamped directory and copies the existing PEM file (plus any associated `.key`, `.ocsp`, `.issuer`, `.sctl` files) before replacement. Backups are stored under the configured backup directory (e.g., `/etc/haproxy/certs-backup/20250316_143022/`).

**`overwrite`** — Replaces the existing PEM file directly without creating a backup.

### Service Reload Methods

Controlled by `RESTART_HAPROXY` and `RESTART_METHOD`:

| Setting | Behaviour |
|---|---|
| `RESTART_HAPROXY="no"` | Certificate is deployed to disk only. You must reload/restart HAProxy manually. |
| `RESTART_METHOD="reload"` | Graceful reload via `systemctl reload`. No dropped connections. **Recommended.** |
| `RESTART_METHOD="restart"` | Full restart via `systemctl restart`. May briefly interrupt active connections. |

Both methods validate the HAProxy configuration (`haproxy -c -f ...`) before executing. If validation fails, the restart is aborted.

### Runtime API Hot Update

For true zero-downtime certificate updates without any service reload, set `USE_RUNTIME_API="yes"`. The script uses `socat` to issue `set ssl cert` and `commit ssl cert` commands via the HAProxy Runtime API UNIX socket.

Requirements for Runtime API:

- HAProxy 2.1+ (or any HAPEE version)
- `socat` installed on the host
- A stats socket configured in `haproxy.cfg` with admin-level access:

  ```
  global
      stats socket /run/haproxy/admin.sock mode 660 level admin
  ```

The Runtime API updates the certificate **in memory only**. The script always also writes the PEM file to disk, so the change persists across service restarts. If the Runtime API update fails, the script falls back to the configured reload/restart method.

---

## Configuration Reference

All settings are in the configuration section at the top of each script.

| Setting | Values | Default | Description |
|---|---|---|---|
| `LEGAL_NOTICE_ACCEPT` | `"true"` / `"false"` | `"false"` | Must be `"true"` to run |
| `LOGFILE` | File path | _(varies)_ | Log file location |
| `CERT_CONFIG_LOCATION` | `"global"` / `"frontend"` / `"crt-list"` | `"frontend"` | Where to find the certificate path in HAProxy config |
| `FRONTEND_NAME` | Frontend name | _(varies)_ | HAProxy frontend name (when using `"frontend"` mode) |
| `CRT_LIST_FILE` | File path | _(empty)_ | Path to crt-list file (when using `"crt-list"` mode) |
| `TARGET_CERT_PATH` | File path | _(auto-detect)_ | Explicit PEM deployment path (skips auto-detection) |
| `CERT_BACKUP_MODE` | `"backup"` / `"overwrite"` | `"backup"` | Whether to back up the existing certificate |
| `RESTART_HAPROXY` | `"yes"` / `"no"` | `"yes"` | Reload or restart HAProxy after deployment |
| `RESTART_METHOD` | `"reload"` / `"restart"` | `"restart"` | Graceful reload vs full restart |
| `USE_RUNTIME_API` | `"yes"` / `"no"` | `"no"` | Hot update via Runtime API (zero-downtime) |
| `RUNTIME_API_SOCKET` | Socket path | _(auto/varies)_ | Path to HAProxy Runtime API UNIX socket |

**Enterprise-specific settings:**

| Setting | Values | Default | Description |
|---|---|---|---|
| `HAPEE_VERSION` | e.g., `"3.2"` | _(auto-detect)_ | HAProxy Enterprise version |
| `HAPEE_BASE_DIR` | Directory path | `/etc/hapee-{ver}` | Override base directory |

**OSS-specific settings:**

| Setting | Values | Default | Description |
|---|---|---|---|
| `HAPROXY_CONFIG_FILE` | File path | `/etc/haproxy/haproxy.cfg` | HAProxy configuration file |
| `HAPROXY_BASE_DIR` | Directory path | `/etc/haproxy` | HAProxy base directory |
| `HAPROXY_CERTS_DIR` | Directory path | `/etc/haproxy/certs` | Certificate storage directory |
| `HAPROXY_BINARY` | File path | `/usr/sbin/haproxy` | Path to haproxy binary |
| `HAPROXY_SERVICE` | Service name | `haproxy` | systemd service name |

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set `LEGAL_NOTICE_ACCEPT="true"` |
| "Could not auto-detect certificate path" | Frontend name doesn't match or config has unexpected format | Set `TARGET_CERT_PATH` explicitly, or check `FRONTEND_NAME` matches your config |
| "Configuration validation failed" | Invalid `haproxy.cfg` (unrelated to the certificate) | Run `haproxy -c -f /path/to/config` manually and fix the errors |
| "socat is not installed" | `USE_RUNTIME_API="yes"` but socat missing | Install socat (`apt install socat`) or set `USE_RUNTIME_API="no"` |
| "Runtime API socket not found" | Socket path doesn't match or HAProxy not running | Check `RUNTIME_API_SOCKET` matches the `stats socket` directive in your config |
| "HAProxy Enterprise version not detected" | No HAPEE installation found at standard paths | Set `HAPEE_VERSION` and optionally `HAPEE_BASE_DIR` manually |
| Certificate updated but not taking effect | Restart/reload disabled and Runtime API not in use | Set `RESTART_HAPROXY="yes"` or `USE_RUNTIME_API="yes"` |
| Permission denied writing PEM file | TLM Agent user lacks write access to cert directory | Ensure the agent user can write to the certificate directory (e.g., `/etc/haproxy/certs/`) |
| HAProxy won't start after deployment | PEM file incomplete or malformed | Check the log — the combined PEM should contain at least one certificate and one private key block |

### Reading the Logs

Both scripts produce detailed timestamped logs. To follow an execution in real time:

```bash
# Enterprise
tail -f /home/ubuntu/tlm_agent/tlm_agent_3.1.7_linux64/log/haproxy.log

# OSS
tail -f /home/ubuntu/tlmagent/tlm_agent_3.1.7_linux64/log/haproxy-oss-awr.log
```

---

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. These scripts are provided under the terms of the DigiCert software license. See the legal notice within each script for full details.