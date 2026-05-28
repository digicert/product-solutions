# DigiCert TLM — Fortinet Certificate Automation Scripts

Automated post-enrollment scripts for deploying certificates issued by **DigiCert Trust Lifecycle Manager (TLM)** directly to Fortinet appliances via their REST APIs.

These scripts are designed to run as **automation scripts** within the DigiCert TLM Agent after a certificate is issued or renewed. They receive certificate data via the `DC1_POST_SCRIPT_DATA` environment variable and handle the full deployment lifecycle for each Fortinet product.

---

## Contents

| Script | Target Product | Purpose |
|--------|---------------|---------|
| [FortiGATE/fortigate-awr.sh](FortiGATE/fortigate-awr.sh) | Fortinet FortiGate | Import cert + reassign SSL-VPN / Admin / IPsec references |
| [FortiWEB/fortiweb-awr.sh](FortiWEB/fortiweb-awr.sh) | Fortinet FortiWeb | Upload cert (delete/replace on renewal) |
| [FortiNAC/fortinac-awr.sh](FortiNAC/fortinac-awr.sh) | Fortinet FortiNAC | Upload cert to RADIUS/RadSec/Portal/Agent/Admin UI + restart service |

---

## Prerequisites

All scripts require:

- **DigiCert TLM Agent** installed and configured with post-enrollment script execution enabled
- **Bash** 4.0 or later
- **curl** installed and accessible in `PATH`
- **python3** installed (FortiGate and FortiNAC scripts use it for JSON parsing and Base64 encoding)
- **openssl** CLI (FortiWeb only — used to extract the certificate Common Name)
- Network access from the TLM Agent host to the Fortinet appliance management interface
- A valid API token or Bearer token with sufficient permissions on the target appliance

---

## How It Works — Common Flow

All three scripts share the same entry point pattern driven by the TLM Agent:

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
Script calls Fortinet REST API to deploy certificate
        │
        ▼
Script logs result to LOGFILE
```

The `DC1_POST_SCRIPT_DATA` variable contains a Base64-encoded JSON object with the following structure:

```json
{
  "certfolder": "/path/to/cert/directory",
  "files": ["certificate.crt", "private.key"],
  "args": ["arg1", "arg2", "arg3", "..."]
}
```

**All scripts must have `LEGAL_NOTICE_ACCEPT` set to `"true"` inside the script before they will execute.**

---

## FortiGate (`fortigate-awr.sh`)

### Overview

Imports a certificate into FortiGate and optionally reassigns all existing references to the old certificate (SSL-VPN, Admin HTTPS, IPsec Phase1) to the newly imported one. Supports automatic cleanup of old certificates after reassignment.

### Script Configuration

Edit these variables at the top of the script before deploying:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to allow execution |
| `LOGFILE` | `/opt/digicert/fortigate.log` | Path to the script log file |

### Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTIGATE_URL` | Yes | FortiGate hostname or IP (no `https://` prefix) |
| 2 | `CERT_BASE_NAME` | Yes | Base name used to identify the certificate. New certs are named `<base>-YYYYMMDD-HHmmss` |
| 3 | `BEARER_TOKEN` | Yes | FortiGate API Bearer token |
| 4 | `DELETE_MODE` | No | `delete_old` — delete previously matched certs after reassignment. `keep_old` (default) — leave old certs in place |
| 5 | `ASSIGN_MODE` | No | `assign_refs` (default) — reassign all references to the new cert. `import_only` — only import, skip reassignment |

### Flow

```
1. Validate legal notice acceptance and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
3. Base64-encode cert + key → POST to /api/v2/monitor/vpn-certificate/local/import
4. If ASSIGN_MODE = assign_refs:
   a. GET SSL-VPN settings → if referencing old cert, PUT new cert name
   b. GET system/global (admin-server-cert) → if referencing old cert, PUT new cert name
   c. GET system/global (admin-server-certname) → if referencing old cert, PUT new cert name
   d. GET vpn.ipsec/phase1-interface → for each entry referencing old cert, PUT new cert name
   e. GET vpn.ipsec/phase1 → for each entry referencing old cert, PUT new cert name
5. If DELETE_MODE = delete_old: DELETE all previously matched old cert names
6. Log summary and exit
```

### FortiGate API Permissions Required

The API token must have read/write access to:
- `vpn.certificate/local` (import, delete)
- `vpn.ssl/settings` (read, write)
- `system/global` (read, write)
- `vpn.ipsec/phase1-interface` (read, write)
- `vpn.ipsec/phase1` (read, write)

### Log File

`/opt/digicert/fortigate.log`

---

## FortiWeb (`fortiweb-awr.sh`)

### Overview

Uploads a certificate and private key to FortiWeb using its REST API. On renewal, it detects an existing certificate by Common Name, deletes it, then uploads the new one. After a successful upload, it performs a verification GET to confirm the certificate appears in the FortiWeb certificate list.

### Script Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to allow execution |
| `LOGFILE` | `/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log` | Path to the script log file |

### Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTIWEB_URL` | Yes | FortiWeb hostname or IP (no `https://` prefix; port 8443 is appended automatically) |
| 2 | `AUTH_TOKEN` | Yes | FortiWeb authorization token |

### Flow

```
1. Validate legal notice acceptance and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
3. Extract the certificate Common Name using openssl
4. GET /api/v2.0/system/certificate.local → check if CN already exists (renewal detection)
5. If cert exists:
   a. DELETE /api/v2.0/cmdb/system/certificate.local?mkey=<CN>
   b. Wait 2 seconds for FortiWeb to process deletion
6. POST /api/v2.0/system/certificate.local.import_certificate (multipart/form-data)
   - certificateFile = .crt file
   - keyFile = .key file
   - type = certificate
7. GET /api/v2.0/system/certificate.local → verify certificate appears in list
8. Log result and exit
```

### FortiWeb API Permissions Required

The API token must have read/write access to the certificate management endpoints on port **8443**:
- `GET /api/v2.0/system/certificate.local`
- `POST /api/v2.0/system/certificate.local.import_certificate`
- `DELETE /api/v2.0/cmdb/system/certificate.local`

### Notes

- FortiWeb names certificates based on the certificate **Common Name (CN)**. The script extracts this automatically using `openssl x509`.
- If the CN cannot be extracted, the deletion-before-reimport step is skipped and the upload proceeds directly (may fail if the certificate already exists).
- If an existing certificate is in use by a FortiWeb server policy, deletion will fail with HTTP 200 error body. The certificate must be unassigned before renewal can proceed.

### Log File

`/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log`

---

## FortiNAC (`fortinac-awr.sh`)

### Overview

Manages certificate deployment to FortiNAC services including RADIUS (EAP), RadSec, Portal, Persistent Agent, and Admin UI. Supports using pre-existing certificate targets or creating a new RADIUS target via CSR generation. Optionally restarts the target service after upload.

### Script Configuration

This script has an extended configuration section. Edit these variables before deploying:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to allow execution |
| `LOGFILE` | `/home/ubuntu/fortinac.log` | Path to the script log file |
| `CERT_TYPE` | `"RADSEC"` | The FortiNAC service to update. Valid: `RADIUS`, `RADSEC`, `PORTAL`, `AGENT`, `TOMCAT` |
| `USE_EXISTING_TARGET` | `"true"` | `"true"` to upload to a pre-existing target. `"false"` to create a new RADIUS target via CSR (only valid for `CERT_TYPE=RADIUS`) |
| `EXISTING_TARGET_ALIAS` | `"default"` | Alias of the existing target. Use `"default"` for the factory-default service target, or a custom alias name |
| `NEW_TARGET_ALIAS` | `"custom_alias"` | Alias for a new RADIUS target (only used when `USE_EXISTING_TARGET="false"`, must be alphanumeric + underscores only) |
| `RESTART_SERVICE` | `"true"` | `"true"` to restart the FortiNAC service after certificate upload |

#### CSR Generation Parameters (only when creating a new target)

| Variable | Default | Description |
|----------|---------|-------------|
| `CSR_KEY_LENGTH` | `2048` | RSA key length for CSR |
| `CSR_COUNTRY` | `"US"` | Country code |
| `CSR_STATE` | `"Utah"` | State |
| `CSR_CITY` | `"Lehi"` | City |
| `CSR_ORG` | `"DigiCert"` | Organization |
| `CSR_OU` | `"Product"` | Organizational Unit |
| `CSR_CN` | `"fortinac-temporary-csr"` | Common Name (temporary, will be replaced by the TLM-issued cert) |

### Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTINAC_HOST` | Yes | FortiNAC hostname or IP (port 8443 is appended automatically) |
| 2 | `BEARER_TOKEN` | Yes | FortiNAC API Bearer token |

### CERT_TYPE to FortiNAC Service Mapping

| `CERT_TYPE` | FortiNAC Service Name | Default Alias |
|-------------|----------------------|---------------|
| `RADIUS` | Local RADIUS Server (EAP) | `radius` |
| `RADSEC` | Local RADIUS Server (RadSec) | `radsec` |
| `PORTAL` | Portal | `portal` |
| `AGENT` | Persistent Agent | `agent` |
| `TOMCAT` | Admin UI | `tomcat` |

### Flow

```
1. Validate legal notice, CERT_TYPE, alias format, and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
3. Step 1 — Target preparation:
   a. If USE_EXISTING_TARGET="false" (RADIUS only):
      POST /api/v2/settings/security/certificate-server/csr/generate
      (creates a new RADIUS EAP target with the given alias)
   b. If USE_EXISTING_TARGET="true": skip CSR generation
4. Step 2 — Certificate upload:
   POST /api/v2/settings/security/certificate-server/<target-path>
   Multipart form fields: targetType, privateKeyType, certOwnerType, appliedTo, certs, privateKey
5. Step 3 — Service restart (if RESTART_SERVICE="true"):
   POST /api/v2/settings/security/certificate-server/restart
   with target=<target-path>
6. Log summary and exit
```

### FortiNAC API Permissions Required

The API token must have access on port **8443** to:
- `POST /api/v2/settings/security/certificate-server/csr/generate` (only if creating new targets)
- `POST /api/v2/settings/security/certificate-server/<target>` (certificate upload)
- `POST /api/v2/settings/security/certificate-server/restart` (service restart)

### Important Constraints

- Creating new targets (`USE_EXISTING_TARGET="false"`) is **only supported for `CERT_TYPE=RADIUS`**. All other service types (RADSEC, PORTAL, AGENT, TOMCAT) must use existing targets.
- Target aliases may only contain **alphanumeric characters and underscores** (`_`). No hyphens, spaces, or dots are allowed.
- Using alias `"default"` maps to the known factory-default target name for the selected service type.

### Log File

`/home/ubuntu/fortinac.log`

---

## Common Troubleshooting

| Symptom | Likely Cause |
|---------|-------------|
| Script exits immediately with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is still `"false"` in the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script was not triggered via the TLM Agent post-enrollment hook |
| HTTP 401 | API token is incorrect or expired |
| HTTP 403 | API token lacks required permissions |
| HTTP 404 | Appliance URL is wrong or API path has changed |
| Certificate file not found | TLM Agent did not write the cert files before the script ran, or `certfolder` path is incorrect |
| FortiWeb delete fails with error body | The certificate is currently assigned to a server policy — unassign it first |
| FortiNAC: alias validation error | Alias contains disallowed characters (use only `[a-zA-Z0-9_]`) |
| FortiNAC: "only supported for CERT_TYPE=RADIUS" | Attempted to create new target for a non-RADIUS service type |

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in each script for full terms.
