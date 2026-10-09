# FortiNAC — Admin Web Request post-enrollment script

`fortinac-awr.sh` deploys a certificate issued by **DigiCert Trust Lifecycle Manager (TLM)** to a **Fortinet FortiNAC** service over its REST API. It runs as a **post-enrollment automation script** inside the DigiCert TLM Agent after a certificate is issued or renewed.

| Script | Platform | Location |
|--------|----------|----------|
| `fortinac-awr.sh` | Linux (Bash) | [fortinac-awr.sh](fortinac-awr.sh) |

---

## Overview

Manages certificate deployment to FortiNAC services including RADIUS (EAP), RadSec, Portal, Persistent Agent, and Admin UI. Supports using pre-existing certificate targets or creating a new RADIUS target via CSR generation. Optionally restarts the target service after upload.

---

## Prerequisites

- **DigiCert TLM Agent** installed and configured with post-enrollment script execution enabled
- Network access from the TLM Agent host to the FortiNAC management interface on port **8443**
- A FortiNAC API Bearer token with the permissions listed below
- **Bash** 4.0 or later, **curl** in `PATH`, **python3** (JSON parsing and Base64 encoding)

---

## How it is triggered

The TLM Agent writes the cert + key to disk, sets `DC1_POST_SCRIPT_DATA` (Base64-encoded JSON with `certfolder`, `files` and `args`) and executes the script. See the [FortiGate script README](../FortiGATE/admin-webrequest-post-script/README.md#how-it-is-triggered) for the payload structure, which is identical for every AWR script.

---

## Script configuration

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

### CSR generation parameters (only when creating a new target)

| Variable | Default | Description |
|----------|---------|-------------|
| `CSR_KEY_LENGTH` | `2048` | RSA key length for CSR |
| `CSR_COUNTRY` | `"US"` | Country code |
| `CSR_STATE` | `"Utah"` | State |
| `CSR_CITY` | `"Lehi"` | City |
| `CSR_ORG` | `"DigiCert"` | Organization |
| `CSR_OU` | `"Product"` | Organizational Unit |
| `CSR_CN` | `"fortinac-temporary-csr"` | Common Name (temporary, will be replaced by the TLM-issued cert) |

---

## Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTINAC_HOST` | Yes | FortiNAC hostname or IP (port 8443 is appended automatically) |
| 2 | `BEARER_TOKEN` | Yes | FortiNAC API Bearer token |

---

## CERT_TYPE to FortiNAC service mapping

| `CERT_TYPE` | FortiNAC Service Name | Default Alias |
|-------------|----------------------|---------------|
| `RADIUS` | Local RADIUS Server (EAP) | `radius` |
| `RADSEC` | Local RADIUS Server (RadSec) | `radsec` |
| `PORTAL` | Portal | `portal` |
| `AGENT` | Persistent Agent | `agent` |
| `TOMCAT` | Admin UI | `tomcat` |

---

## Flow

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

---

## FortiNAC API permissions required

The API token must have access on port **8443** to:

- `POST /api/v2/settings/security/certificate-server/csr/generate` (only if creating new targets)
- `POST /api/v2/settings/security/certificate-server/<target>` (certificate upload)
- `POST /api/v2/settings/security/certificate-server/restart` (service restart)

---

## Important constraints

- Creating new targets (`USE_EXISTING_TARGET="false"`) is **only supported for `CERT_TYPE=RADIUS`**. All other service types (RADSEC, PORTAL, AGENT, TOMCAT) must use existing targets.
- Target aliases may only contain **alphanumeric characters and underscores** (`_`). No hyphens, spaces, or dots are allowed.
- Using alias `"default"` maps to the known factory-default target name for the selected service type.

---

## Log file

`/home/ubuntu/fortinac.log`

---

## Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| Script exits immediately with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is still `"false"` in the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script was not triggered via the TLM Agent post-enrollment hook |
| HTTP 401 | API token is incorrect or expired |
| HTTP 403 | API token lacks required permissions |
| HTTP 404 | Appliance URL is wrong or API path has changed |
| Alias validation error | Alias contains disallowed characters (use only `[a-zA-Z0-9_]`) |
| "only supported for CERT_TYPE=RADIUS" | Attempted to create a new target for a non-RADIUS service type |
| Certificate file not found | TLM Agent did not write the cert files before the script ran, or `certfolder` path is incorrect |

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in the script for full terms.
