# DigiCert TLM — Fortinet Certificate Automation Scripts

Automated post-enrollment scripts for deploying certificates issued by **DigiCert Trust Lifecycle Manager (TLM)** directly to Fortinet appliances via their REST APIs.

These scripts are designed to run as **automation scripts** within the DigiCert TLM Agent after a certificate is issued or renewed. They receive certificate data via the `DC1_POST_SCRIPT_DATA` environment variable and handle the full deployment lifecycle for each Fortinet product.

---

## Contents

| Script | Target Product | Purpose |
|--------|---------------|---------|
| [FortiGATE/fortigate-awr.sh](FortiGATE/fortigate-awr.sh) | Fortinet FortiGate | Import cert + reassign SSL-VPN / Admin / IPsec references |
| [FortiWEB/fortiweb-awr.sh](FortiWEB/fortiweb-awr.sh) | Fortinet FortiWeb | Upload cert under a unique name + rotate all references (policy / SNI / multi-cert), then delete the old cert |
| [FortiNAC/fortinac-awr.sh](FortiNAC/fortinac-awr.sh) | Fortinet FortiNAC | Upload cert to RADIUS/RadSec/Portal/Agent/Admin UI + restart service |

---

## Prerequisites

All scripts require:

- **DigiCert TLM Agent** installed and configured with post-enrollment script execution enabled
- **Bash** 4.0 or later
- **curl** installed and accessible in `PATH`
- **python3** installed (FortiGate and FortiNAC use it for JSON parsing and Base64 encoding; FortiWeb uses it for subject-CN / key-algorithm matching and reference discovery — it degrades gracefully to a name-convention fallback if python3 is absent)
- **openssl** CLI (FortiWeb only — used to extract the certificate Common Name, serial and key algorithm)
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

Uploads a certificate and private key to FortiWeb using its REST API and safely handles renewal by **rotating**, not overwriting.

FortiWeb has two hard limitations that a naive "delete then re-import under the same name" approach cannot satisfy:

1. Importing a certificate under a name that already exists fails with a **duplicate** error.
2. A certificate that is **bound to any object cannot be deleted** while it is in use.

To work around both, the script:

1. **Uploads the new certificate under a unique name** — `<sanitised-CN>_<serial-suffix>` (FortiWeb derives the stored name from the uploaded file name, so the file is staged under this name). A duplicate error can therefore never occur.
2. **Identifies the previous certificate(s) for this domain** by reading each existing cert's real **subject CN from the API** (not by trusting the stored name), constrained to the **same key algorithm** (`pkey_type`). This means an RSA renewal never touches an ECC certificate of the same CN, and vice versa.
3. **Repoints every reference** from the old cert to the new one across all three ways FortiWeb can reference a local certificate (see below).
4. **Deletes the old certificate** only after every reference has been cleared **and** FortiWeb reports `can_delete: true` for it (a safety gate against reference types the script does not scan).

The result is a zero-downtime rotation: the new certificate is in place and bound before the old one is removed, and nothing is deleted while still in use.

### Reference types handled

A FortiWeb local certificate can be referenced in three ways; the script scans and repoints all of them:

| # | Where the reference lives | Field repointed |
|---|---------------------------|-----------------|
| 1 | Server policy (direct / SSL fallback) | `server-policy/policy` → `certificate` |
| 2 | SNI configuration member (per-domain) | `system/certificate.sni` → member `local-cert` |
| 3 | Multi-certificate group (dual RSA/ECC/DSA on one hostname) | `system/certificate.multi-local` → `rsa-cert` / `ecc-cert` / `dsa-cert` |

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

No further arguments are required — the script auto-discovers every policy, SNI object and multi-cert group referencing the old certificate.

### Flow

```
1. Validate legal notice acceptance and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
   (the auth token is identified here and redacted from all subsequent logging)
3. Extract the new cert's CN, serial and key algorithm using openssl
4. Stage the cert/key under a unique name (<sanitised-CN>_<serial>) in a temp dir
5. Snapshot the existing certificate list
6. POST /api/v2.0/system/certificate.local.import_certificate (multipart/form-data)
   - certificateFile = .crt, keyFile = .key, type = certificate
   - the staged private key is securely removed immediately after upload
7. Confirm the name FortiWeb assigned (list diff), then select previous certs
   for this domain by subject CN AND matching pkey_type
8. For each previous cert:
   a. Repoint any SNI member local-cert -> new name
   b. Repoint any multi-cert group rsa/ecc/dsa-cert -> new name
   c. Repoint any server policy certificate -> new name
   d. Re-check can_delete; if true, DELETE the old cert, else skip for manual review
9. Log result and exit
```

### FortiWeb API Permissions Required

The API token must have read/write access to these endpoints on port **8443**:
- `GET  /api/v2.0/system/certificate.local`
- `POST /api/v2.0/system/certificate.local.import_certificate`
- `DELETE /api/v2.0/cmdb/system/certificate.local`
- `GET/PUT /api/v2.0/cmdb/server-policy/policy`
- `GET/PUT /api/v2.0/cmdb/system/certificate.sni` (and its `members` child table)
- `GET/PUT /api/v2.0/cmdb/system/certificate.multi-local`

### Notes

- **Version:** validated end-to-end against **FortiWeb 8.0.5**. The API it uses has existed since ~6.3, so 7.x is expected to work and possibly 6.4+, but only 8.0.5 is verified. It fails safe on version differences (failed repoints are logged; nothing in use is deleted). See [FortiWEB/README.md](FortiWEB/README.md#version-compatibility) for details and how to pre-flight another version.
- **Unique naming:** the new cert is stored as `<sanitised-CN>_<serial>` (non-alphanumerics in the CN become `_`). The old certificate keeps whatever name it had — matching is by subject CN, so off-convention names (e.g. a cert manually stored as `tls`) are still found and rotated.
- **Algorithm scoping:** RSA (`pkey_type 1`) and ECDSA (`pkey_type 3`) certs sharing a CN are treated independently. The value is read from the freshly-uploaded cert's own list entry, so no algorithm codes are hardcoded.
- **Safety gate:** if a previous cert is still referenced by something the script does not scan, its `can_delete` stays `false`; the script logs the skip and leaves the cert in place for manual review rather than firing a delete that would fail.
- **Token redaction:** the `AUTH_TOKEN` (which base64-decodes to admin credentials) is masked as `***REDACTED***` in every log line, including the raw JSON dump.
- **Graceful degradation:** if `python3` is unavailable, CN/algorithm matching falls back to a cert-name convention and SNI/multi-cert members are detected but not auto-repointed (the safety gate still prevents unsafe deletion).
- For inspecting a FortiWeb appliance's certificate/policy/SNI/multi-cert configuration during setup or debugging, see [FortiWEB/README.md](FortiWEB/README.md) and the `fortiweb-discovery.sh` helper (local/manual use only — never run by TLM).

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
| FortiWeb: old cert skipped with `can_delete=false` | The old cert is still referenced by an object the script does not scan — repoint/unassign it manually, then it can be removed |
| FortiWeb: "new cert uploaded but not bound" | On an initial import the cert is stored but not attached to any policy/SNI/group — bind it in FortiWeb; renewals then rotate it automatically |
| FortiNAC: alias validation error | Alias contains disallowed characters (use only `[a-zA-Z0-9_]`) |
| FortiNAC: "only supported for CERT_TYPE=RADIUS" | Attempted to create new target for a non-RADIUS service type |

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in each script for full terms.
