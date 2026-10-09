# FortiGate — Admin Web Request post-enrollment scripts

`fortigate-awr.sh` (Linux) and `fortigate-awr.ps1` (Windows) deploy a certificate issued by **DigiCert Trust Lifecycle Manager (TLM)** to a **Fortinet FortiGate** (FortiOS) over its REST API. They run as **post-enrollment automation scripts** inside the DigiCert TLM Agent after a certificate is issued or renewed.

Two script variants are provided, identical in behaviour and argument structure, differing only in runtime platform:

| Script | Platform | Location |
|--------|----------|----------|
| `fortigate-awr.sh` | Linux (Bash) | [Linux/fortigate-awr.sh](Linux/fortigate-awr.sh) |
| `fortigate-awr.ps1` | Windows (PowerShell 5.1+) | [Windows/fortigate-awr.ps1](Windows/fortigate-awr.ps1) |

---

## Overview

The script imports the certificate into FortiGate and optionally reassigns all existing references to the old certificate (SSL-VPN, Admin HTTPS, IPsec Phase1, Firewall VIP SSL offloading) to the newly imported one. It supports automatic cleanup of the old certificate after reassignment.

FortiOS cannot overwrite a local certificate in place through the REST API: importing under an existing name is rejected, and a certificate that is referenced by any object cannot be deleted. Every renewal is therefore a **rotation**: the new certificate is imported under a new name, every reference is repointed, and the old certificate is optionally deleted.

---

## Prerequisites

- **DigiCert TLM Agent** installed and configured with post-enrollment script execution enabled
- Network access from the TLM Agent host to the FortiGate HTTPS administrative interface
- A FortiGate **REST API administrator** token with the permissions listed below

**Linux** (`fortigate-awr.sh`):

- **Bash** 4.0 or later
- **curl** in `PATH`
- **python3** (JSON parsing and payload construction)

**Windows** (`fortigate-awr.ps1`):

- **PowerShell** 5.1 or later (PowerShell 7+ also supported)
- TLM Agent running on a Windows host with script execution enabled

---

## How it is triggered

```
DigiCert TLM issues/renews certificate
        │
        ▼
TLM Agent writes cert + key files to disk
        │
        ▼
TLM Agent sets DC1_POST_SCRIPT_DATA (base64-encoded JSON payload)
        │
        ▼
TLM Agent executes the AWR script
        │
        ▼
Script decodes DC1_POST_SCRIPT_DATA → extracts file paths, args
        │
        ▼
Script calls the FortiGate REST API to import and rotate the certificate
        │
        ▼
Script logs result to the log file
```

`DC1_POST_SCRIPT_DATA` is a Base64-encoded JSON object:

```json
{
  "certfolder": "/path/to/cert/directory",
  "files": ["certificate.crt", "private.key"],
  "args": ["arg1", "arg2", "arg3", "..."]
}
```

---

## Script configuration

Edit these variables at the top of the script before deploying:

| Variable | Script | Default | Description |
|----------|--------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | Both | `"false"` | Must be set to `"true"` to allow execution |
| `LOGFILE` | Linux | `/opt/digicert/fortigate.log` | Path to the script log file |
| `MAX_CERT_NAME_LENGTH` | Both | `35` | FortiOS limit for certificate object names; do not change |
| `LOG_PATH` | Windows | `C:\Program Files\DigiCert\TLM Agent\log\fortigate-awr.log` | Path to the script log file |
| `SKIP_CERTIFICATE_CHECK` | Windows | `$false` | Set to `$true` to accept a self-signed FortiGate management certificate (the Linux script always uses `curl -k`) |

---

## Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTIGATE_URL` | Yes | FortiGate hostname or IP (no `https://` prefix) |
| 2 | `CERT_BASE_NAME` | Yes | Base name used to identify the certificate and to name the new one. A reference matches if its value equals the base name or starts with `<base>-` (a name produced by an earlier run). Ex: if the old cert is named `mydomain.com` or `mydomain.com-20250101-120000`, use `mydomain.com`. New certs are named `<base>-YYYYMMDD-HHmmss`. **Max 19 characters**: FortiOS caps certificate names at 35 characters and the suffix uses 16; the script aborts before importing if the new name would be longer. |
| 3 | `BEARER_TOKEN` | Yes | FortiGate REST API Bearer token |
| 4 | `DELETE_MODE` | No | `delete_old` — delete previously matched certs after reassignment. `keep_old` (default) — leave old certs in place |
| 5 | `ASSIGN_MODE` | No | Assignment strategy. One of:<br>`assign_refs` (default) — reassign all references to the new cert<br>`import_only` — only import, skip reassignment<br>Comma-separated selectors (e.g., `ssl_vpn,admin_https`) — reassign only the specified features:<br>&nbsp;&nbsp;• `ssl_vpn` — SSL-VPN settings<br>&nbsp;&nbsp;• `admin_https` — Admin HTTPS certificate<br>&nbsp;&nbsp;• `admin_https_fallback` — Admin HTTPS certificate fallback<br>&nbsp;&nbsp;• `ipsec_phase1_interface` — IPsec phase1-interface table<br>&nbsp;&nbsp;• `ipsec_phase1` — IPsec phase1 table<br>&nbsp;&nbsp;• `firewall_vip` — Firewall virtual servers / VIPs with SSL offloading (`ssl-certificate` list) |
| 6 | `OLD_CERT_NAME` | No | Exact name of a certificate to take over that was not named by this script (e.g. one uploaded manually or by the FortiGate automation plugin, such as `paolo-2909_digicert-de_39bc349182d8`). It is matched **in addition to** the prefix rule of argument 2, so the same arguments keep working on later renewals: the first run matches this name, later runs match the `<base>-*` name the script created, and the stale value is simply ignored. |

---

## Flow

```
1. Validate legal notice acceptance and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
3. Abort if "<base>-YYYYMMDD-HHmmss" would exceed 35 characters (FortiOS name limit)
   Base64-encode cert + key → POST to /api/v2/monitor/vpn-certificate/local/import
4. If ASSIGN_MODE != import_only, perform selective reassignment:
   a. If ssl_vpn enabled: GET SSL-VPN settings → if referencing old cert, PUT new cert name
   b. If admin_https enabled: GET system/global (admin-server-cert) → if referencing old cert, PUT new cert name
   c. If admin_https_fallback enabled: GET system/global (admin-server-certname) → if referencing old cert, PUT new cert name
   d. If ipsec_phase1_interface enabled: GET vpn.ipsec/phase1-interface → for each entry referencing old cert, PUT new cert name
   e. If ipsec_phase1 enabled: GET vpn.ipsec/phase1 → for each entry referencing old cert, PUT new cert name
   f. If firewall_vip enabled: GET firewall/vip → for each VIP whose ssl-certificate list contains the old cert,
      PUT the list back with only that member swapped (other certificates in the list are preserved)

   Reference matching (a reference matches if any rule applies):
   - it equals CERT_BASE_NAME or starts with "CERT_BASE_NAME-" (a name this script created earlier)
   - it equals OLD_CERT_NAME (argument 6) exactly

   Feature selection rules:
   - assign_refs (default): all features enabled
   - import_only: no features enabled, reassignment skipped
   - Comma-separated list (e.g., ssl_vpn,admin_https): only listed features enabled
5. If DELETE_MODE = delete_old: DELETE all previously matched old cert names
6. Log summary and exit
```

If any reassignment fails the script exits with an error **before** the delete step, so a certificate that is still in use is never removed.

---

## ASSIGN_MODE examples

| ASSIGN_MODE Value | Effect |
|-------------------|--------|
| `assign_refs` or empty | Reassign all features: SSL-VPN, Admin HTTPS, Admin HTTPS fallback, IPsec phase1-interface, IPsec phase1 and Firewall VIP |
| `import_only` | Import certificate only; skip all reassignments |
| `ssl_vpn` | Reassign SSL-VPN settings only |
| `admin_https` | Reassign Admin HTTPS certificate only |
| `firewall_vip` | Reassign firewall VIP / virtual server SSL offloading certificates only |
| `ssl_vpn,admin_https` | Reassign SSL-VPN and Admin HTTPS; skip Admin fallback, IPsec and VIPs |
| `admin_https,admin_https_fallback` | Reassign both Admin HTTPS references |
| `ipsec_phase1_interface,ipsec_phase1` | Reassign IPsec configurations only; skip VPN/Admin/VIP references |
| `ssl_vpn,admin_https,ipsec_phase1` | Reassign SSL-VPN, Admin HTTPS, and IPsec phase1 (skip Admin fallback, phase1-interface and VIPs) |

### Example: replacing a certificate bound to a virtual server (SSL offloading)

A FortiGate has `paolo-2909_digicert-de_39bc349182d8` bound to a virtual server under *Policy & Objects → Virtual Servers* (a `firewall/vip` entry with `ssl-certificate`). That name was created by the FortiGate automation plugin, is 35 characters long, and does not follow this script's `<base>-<timestamp>` pattern, so the prefix rule cannot match it and the base name cannot be reused.

Name the existing certificate in argument 6:

```json
"args": ["fgt.example.com", "paolo-vip", "<api-token>", "delete_old", "firewall_vip", "paolo-2909_digicert-de_39bc349182d8"]
```

First run: the script imports the certificate as `paolo-vip-20261009-101500`, rewrites the VIP's `ssl-certificate` list so that member becomes the new name (any other certificates in the list are kept), and deletes `paolo-2909_digicert-de_39bc349182d8`.

Later renewals with the **same arguments**: argument 6 no longer matches anything (that certificate is gone), but the prefix rule matches `paolo-vip-20261009-101500`, so the rotation continues normally. Argument 6 can stay in the TLM profile indefinitely or be removed, either works.

Use `assign_refs` instead of `firewall_vip` if the same certificate is also bound to SSL-VPN, admin HTTPS or IPsec.

---

## FortiGate API permissions required

The REST API administrator's profile must grant read/write access to:

- `vpn.certificate/local` (import, delete)
- `vpn.ssl/settings` (read, write)
- `system/global` (read, write)
- `vpn.ipsec/phase1-interface` (read, write)
- `vpn.ipsec/phase1` (read, write)
- `firewall/vip` (read, write)

The administrator's **trusted hosts** must include the TLM Agent host.

---

## Log file

| Platform | Path |
|----------|------|
| Linux | `/opt/digicert/fortigate.log` |
| Windows | `C:\Program Files\DigiCert\TLM Agent\log\fortigate-awr.log` |

The bearer token is redacted from every log line, including the raw JSON dump.

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| Script exits immediately with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is still `"false"` in the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script was not triggered via the TLM Agent post-enrollment hook |
| `Import HTTP Status: 000` / `Could not resolve host` | Argument 1 is wrong or not resolvable from the Agent host (check for typos such as `c2-…` instead of `ec2-…`) |
| HTTP 401 | API token is incorrect or expired |
| HTTP 403 | API token lacks required permissions, or the Agent host is not in the administrator's trusted hosts |
| HTTP 404 | Appliance URL is wrong or API path has changed |
| HTTP 500 on import | Certificate/key invalid or mismatched, or a certificate with that name already exists |
| `New certificate name … is N characters but FortiOS allows at most 35` | Argument 2 is longer than 19 characters; shorten it and, to take over the existing long name, pass it as argument 6 |
| `References reassigned: 0` on a box that clearly uses the certificate | The bound certificate's name matches neither the `<base>-` prefix rule nor argument 6, or the reference lives in an object type the script does not scan (see ASSIGN_MODE selectors) |
| Delete step returns an error | The old certificate is still referenced by an object the script does not scan; repoint it manually and the next run will delete it |
| Certificate file not found | TLM Agent did not write the cert files before the script ran, or `certfolder` path is incorrect |

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in each script for full terms.
