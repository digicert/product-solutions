# DigiCert TLM Agent — AWR Post-Enrollment Scripts

Automated certificate deployment to Fortinet appliances and Google Cloud Apigee X using DigiCert Trust Lifecycle Manager (TLM) Agent Admin Web Request (AWR) post-enrollment scripts.

These bash scripts run automatically after the TLM Agent enrolls or renews a certificate, pushing the resulting certificate and private key directly to target platforms via their REST APIs. Each script handles initial imports, renewals, comprehensive error handling, and detailed logging.

---

## Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [How AWR Post-Enrollment Scripts Work](#how-awr-post-enrollment-scripts-work)
- [FortiGate](#fortigate)
- [FortiWeb](#fortiweb)
- [FortiNAC](#fortinac)
- [Google Cloud Apigee X](#google-cloud-apigee-x)
- [Common Configuration](#common-configuration)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Overview

| Script | Target Platform | API Used | Auth Method | Key Use Cases |
|---|---|---|---|---|
| `fortigate-awr.sh` | FortiGate NGFW | REST API v2 | Bearer Token | VPN certificates, HTTPS admin, SSL inspection |
| `fortiweb-awr.sh` | FortiWeb WAF | REST API v2.0 | Authorization Token | WAF server certificates, reverse proxy SSL |
| `fortinac-awr.sh` | FortiNAC | REST API v2 | Bearer Token | RADIUS (EAP), RadSec, Portal, Agent, Admin UI |
| `apigee-awr.sh` | Google Cloud Apigee X | Apigee Management API v1 | GCP Service Account (OAuth) | API gateway TLS, keystore rotation, virtual host certs |

All scripts follow the same general pattern:

1. Decode the `DC1_POST_SCRIPT_DATA` environment variable (base64-encoded JSON) provided by the TLM Agent
2. Extract certificate files, private key, and user-defined arguments
3. Check if a certificate with the same name already exists on the target (renewal detection)
4. Delete the existing certificate if found, then import the new one
5. Log every step to a configurable log file

---

## Prerequisites

- **DigiCert TLM Agent** (v3.0.15+) installed on a Linux host
- **bash**, **curl**, **base64**, **grep** with PCRE (`-P`) support
- **openssl** (required by the FortiWeb script for CN extraction)
- **gcloud CLI** (required by the Apigee script for service account authentication)
- Network connectivity from the TLM Agent host to the target platform
- An API token / bearer token with appropriate permissions on each appliance, or a GCP service account key for Apigee
- A TLM certificate template configured with AWR post-enrollment script and the required arguments

---

## How AWR Post-Enrollment Scripts Work

When a TLM certificate template is configured with an AWR post-enrollment script, the TLM Agent executes the script after each successful enrollment or renewal. The agent passes certificate metadata via the `DC1_POST_SCRIPT_DATA` environment variable as a base64-encoded JSON payload containing:

- **`certfolder`** — Path to the directory containing the certificate files
- **`files`** — Array of filenames (`.crt` and `.key`)
- **`args`** — Array of user-defined arguments configured in the certificate template (appliance URL, certificate name, API token, etc.)

Each script decodes this payload, extracts the relevant fields, and uses them to drive the API calls.

---

## FortiGate

**Script:** `fortigate-awr.sh`

Imports certificates to a FortiGate firewall via the REST API. Supports both initial import and renewal (automatic delete-and-reimport). Imported certificates can be used for HTTPS admin access, SSL VPN, IPsec VPN, SSL/TLS inspection, and any other FortiGate feature that references local certificates.

### FortiGate API Endpoints

| Operation | Method | Endpoint |
|---|---|---|
| Check existing cert | `GET` | `/api/v2/cmdb/vpn.certificate/local/{certname}` |
| Delete existing cert | `DELETE` | `/api/v2/cmdb/vpn.certificate/local/{certname}` |
| Import certificate | `POST` | `/api/v2/monitor/vpn-certificate/local/import` |

### FortiGate Template Arguments

Configure these in the TLM certificate template AWR arguments:

| Argument | Description | Example |
|---|---|---|
| Argument 1 | FortiGate hostname or IP (without `https://`) | `fortigate.example.com` |
| Argument 2 | Certificate name on FortiGate | `web-server-cert` |
| Argument 3 | API Bearer Token | `your-api-token` |

### FortiGate Configuration

Edit the script header:

```bash
LEGAL_NOTICE_ACCEPT="true"   # Must be set to "true" to run
LOGFILE="/opt/digicert/tlm_agent_3.1.9_linux64/log/fortigate.log"
```

### FortiGate — Generating an API Token

1. Navigate to **System → Administrators** and create a new REST API Admin
2. Assign an admin profile with read/write access to **VPN → Certificate**
3. Optionally restrict trusted hosts to the TLM Agent IP
4. Copy the generated API token — this is your **Argument 3**

### FortiGate — Renewal Behaviour

On renewal, the script checks whether a certificate with the configured name already exists:

- **Exists (HTTP 200):** Deletes the existing certificate, waits 2 seconds, then imports the new one
- **Does not exist (HTTP 404):** Proceeds directly with import
- **In use (HTTP 424 on delete):** Exits with an error — the certificate is bound to a FortiGate object (e.g., HTTPS admin, VPN) and cannot be replaced via delete. Unbind it first or use a different certificate name

---

## FortiWeb

**Script:** `fortiweb-awr.sh`

Imports certificates to a FortiWeb Web Application Firewall via the REST API on port 8443. Automatically detects renewals by extracting the Common Name (CN) from the certificate using `openssl` and checking the existing certificate list on the appliance. Uploaded certificates can be bound to server policies for WAF-protected web applications.

### FortiWeb API Endpoints

| Operation | Method | Endpoint |
|---|---|---|
| List certificates | `GET` | `/api/v2.0/system/certificate.local` |
| Delete existing cert | `DELETE` | `/api/v2.0/cmdb/system/certificate.local?mkey={cn}` |
| Import certificate | `POST` | `/api/v2.0/system/certificate.local.import_certificate` |

### FortiWeb Template Arguments

| Argument | Description | Example |
|---|---|---|
| Argument 1 | FortiWeb hostname or IP (without `https://`) | `fortiweb.example.com` |
| Argument 2 | Authorization Token | `your-auth-token` |

### FortiWeb Configuration

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log"
```

### FortiWeb — Renewal Behaviour

FortiWeb names imported certificates based on the CN in the certificate. The script:

1. Extracts the CN from the new certificate using `openssl x509 -noout -subject`
2. Lists all certificates on the FortiWeb and searches for a matching name
3. If found, deletes the existing certificate via the CMDB endpoint, waits 2 seconds, then uploads the new one
4. If not found, proceeds directly with import

### FortiWeb — Important Notes

- FortiWeb uses port **8443** for API access (not the standard 443)
- Certificate names on FortiWeb are derived from the CN — dots in the CN (e.g., `tls.guru`) can cause issues with direct GET-by-name, which is why the script lists all certificates and searches the response
- Certificates bound to an active server policy may fail to delete — unbind them first if you encounter errors

---

## FortiNAC

**Script:** `fortinac-awr.sh`

The most feature-rich of the three scripts. Manages certificates for FortiNAC's multiple service types via the REST API on port 8443. Supports uploading to existing certificate targets or creating new RADIUS targets via CSR generation, with optional automatic service restart after upload.

### FortiNAC Supported Certificate Types

| `CERT_TYPE` | Service | Default Alias | Description |
|---|---|---|---|
| `RADIUS` | Local RADIUS Server (EAP) | `radius` | 802.1X EAP authentication |
| `RADSEC` | Local RADIUS Server (RadSec) | `radsec` | TLS-secured RADIUS transport |
| `PORTAL` | Portal | `portal` | Captive portal / guest access |
| `AGENT` | Persistent Agent | `agent` | Endpoint agent communication |
| `TOMCAT` | Admin UI | `tomcat` | FortiNAC management web interface |

### FortiNAC API Endpoints

| Operation | Method | Endpoint |
|---|---|---|
| Generate CSR / create target | `POST` | `/api/v2/settings/security/certificate-server/csr/generate` |
| Upload cert + key | `POST` | `/api/v2/settings/security/certificate-server/{target}` |
| Restart service | `POST` | `/api/v2/settings/security/certificate-server/restart` |

### FortiNAC Template Arguments

| Argument | Description | Example |
|---|---|---|
| Argument 1 | FortiNAC hostname or IP (without `https://`) | `fortinac.example.com` |
| Argument 2 | API Bearer Token | `your-bearer-token` |

### FortiNAC Configuration

The script has a detailed configuration section at the top:

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/fortinac.log"

# Certificate type: RADIUS | RADSEC | PORTAL | AGENT | TOMCAT
CERT_TYPE="RADIUS"

# Target configuration
USE_EXISTING_TARGET="true"       # "true" to use existing, "false" to create new (RADIUS only)
EXISTING_TARGET_ALIAS="default"  # Used when USE_EXISTING_TARGET="true"
NEW_TARGET_ALIAS="custom_alias"  # Used when USE_EXISTING_TARGET="false"

# Restart the relevant service after upload
RESTART_SERVICE="true"

# CSR parameters (only used when creating a new target)
CSR_KEY_LENGTH="2048"
CSR_COUNTRY="US"
CSR_STATE="Utah"
CSR_CITY="Lehi"
CSR_ORG="DigiCert"
CSR_OU="Product"
CSR_CN="fortinac-temporary-csr"
```

### FortiNAC — Target Modes

**Using an existing target** (`USE_EXISTING_TARGET="true"`):

- Set `EXISTING_TARGET_ALIAS` to `"default"` to use the factory-default target for the chosen `CERT_TYPE`
- Set it to a custom alias name (e.g., `"my_radius"`) for custom RADIUS targets previously created via CSR

**Creating a new RADIUS target** (`USE_EXISTING_TARGET="false"`):

- Only supported when `CERT_TYPE="RADIUS"` — the FortiNAC CSR API exclusively creates Local RADIUS Server (EAP) targets
- The script generates a CSR on FortiNAC (creating the target), then immediately uploads the TLM-issued certificate and key to replace the CSR-generated placeholder
- `NEW_TARGET_ALIAS` must contain only alphanumeric characters and underscores

### FortiNAC — Workflow

1. **Target creation** (optional) — If `USE_EXISTING_TARGET="false"`, generates a CSR on FortiNAC to create a new RADIUS target
2. **Certificate upload** — Uploads the certificate and private key to the target via multipart form POST
3. **Service restart** (optional) — If `RESTART_SERVICE="true"`, restarts the relevant service to apply the new certificate

---

## Google Cloud Apigee X

**Script:** `apigee-awr.sh`

Manages TLS certificates for Google Cloud Apigee X API gateways. Supports two deployment modes: **new** (creates a keystore, uploads the certificate, and creates a reference) and **rotate** (creates a new keystore, uploads the certificate, and updates an existing reference to point to the new keystore). This enables zero-downtime certificate rotation for Apigee virtual hosts and target endpoints.

### Apigee X API Endpoints

| Operation | Method | Endpoint |
|---|---|---|
| Create keystore | `POST` | `/v1/organizations/{org}/environments/{env}/keystores` |
| Upload cert + key | `POST` | `/v1/organizations/{org}/environments/{env}/keystores/{keystore}/aliases?alias={alias}&format=keycertfile` |
| Create reference | `POST` | `/v1/organizations/{org}/environments/{env}/references` |
| Update reference | `PUT` | `/v1/organizations/{org}/environments/{env}/references/{reference}` |

All endpoints are prefixed with `https://apigee.googleapis.com`.

### Apigee Template Arguments

| Argument | Description | Example |
|---|---|---|
| Argument 1 | Keystore name | `my-keystore-2025` |
| Argument 2 | Alias name within the keystore | `my-cert-alias` |
| Argument 3 | Reference name | `my-tls-reference` |
| Argument 4 | Deployment mode: `new` or `rotate` | `rotate` |

### Apigee Configuration

Edit the script header:

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/apigee.log"
PROJECT_ID="your-gcp-project-id"
ENVIRONMENT="your-apigee-environment"
SA_KEY_PATH="/home/ubuntu/tlm_agent_3.0.15_linux64/user-scripts/service-account-key.json"
```

### Apigee — Authentication

Unlike the Fortinet scripts which use static API tokens, the Apigee script authenticates via a **GCP service account**:

1. Place your service account JSON key file on the TLM Agent host
2. Set `SA_KEY_PATH` to the full path of the key file
3. The script activates the service account with `gcloud auth activate-service-account` and obtains a short-lived OAuth access token via `gcloud auth print-access-token`

The service account needs the **Apigee Environment Admin** role (or equivalent custom role with permissions on keystores and references) on the target GCP project.

### Apigee — Deployment Modes

**`new` — Initial installation:**

1. Creates a new keystore with the name from Argument 1
2. Uploads the certificate and private key as an alias (Argument 2)
3. Creates a new reference (Argument 3) pointing to the keystore

Use this mode the first time you set up TLS for a virtual host or target endpoint.

**`rotate` — Certificate rotation (zero-downtime):**

1. Creates a new keystore with the name from Argument 1 (use a unique name per rotation, e.g., `keystore-2025-03`)
2. Uploads the certificate and private key as an alias
3. Updates the existing reference (Argument 3) to point to the new keystore

Use this mode for renewals. Because Apigee virtual hosts reference a _reference_ (not a keystore directly), updating the reference atomically switches traffic to the new certificate.

> **Tip:** For rotation, include a timestamp or version in the keystore name (Argument 1) since Apigee keystore names must be unique. The reference name (Argument 3) stays constant across rotations.

### Apigee — Important Notes

- The `gcloud` CLI must be installed and available in the TLM Agent's `PATH`
- If Argument 4 (`DEPLOY`) is omitted, the script defaults to `new` mode
- Apigee X does not support in-place certificate updates within an existing keystore — this is why the rotate mode creates a new keystore and swings the reference

---

## Common Configuration

### Legal Notice Acceptance

All scripts contain a DigiCert legal notice. You must explicitly accept it by setting the following in each script before first use:

```bash
LEGAL_NOTICE_ACCEPT="true"
```

The scripts will exit immediately if this is not set.

### Log File Location

Each script writes detailed timestamped logs. Configure the path via the `LOGFILE` variable. Ensure the TLM Agent user has write permissions to the log directory.

### TLS Verification

The Fortinet scripts use `curl -k` to skip TLS certificate verification when connecting to the appliances. This is typical in environments where the appliances use self-signed certificates. If your appliances have trusted certificates, you can remove the `-k` flag and optionally specify a CA bundle with `--cacert`. The Apigee script connects to `apigee.googleapis.com` over standard TLS and does not skip verification.

### Key Type Support

All scripts support RSA, ECC, and PKCS#8 private keys. The key type is auto-detected from the PEM header and logged for debugging purposes.

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Script exits with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set `LEGAL_NOTICE_ACCEPT="true"` in the script |
| `DC1_POST_SCRIPT_DATA` not set | Script not being executed by TLM Agent | Verify the script is configured as an AWR post-enrollment script in the certificate template |
| HTTP 401 Unauthorized | Invalid or expired API token | Regenerate the API token on the appliance |
| HTTP 403 Forbidden | Token lacks required permissions | Check the admin profile / API permissions |
| HTTP 424 (FortiGate) | Certificate is bound to a configuration object | Unbind the certificate before renewal, or use a different name |
| Delete fails on FortiWeb | Certificate bound to a server policy | Unbind from the server policy before renewal |
| FortiNAC target creation fails | Using `USE_EXISTING_TARGET="false"` with non-RADIUS type | Only `CERT_TYPE="RADIUS"` supports new target creation |
| Connection refused | Wrong hostname, port, or network issue | Verify connectivity from the TLM Agent host to the appliance |
| Alias validation error (FortiNAC) | Special characters in alias | Use only alphanumeric characters and underscores |
| `gcloud` command not found (Apigee) | gcloud CLI not installed or not in PATH | Install the Google Cloud SDK and ensure `gcloud` is in the TLM Agent's PATH |
| Service account activation fails (Apigee) | Invalid or missing key file | Verify `SA_KEY_PATH` points to a valid service account JSON key |
| Keystore creation fails with HTTP 409 (Apigee) | Keystore name already exists | Use a unique keystore name (e.g., include a timestamp) for each rotation |

### Reading the Logs

All scripts produce detailed logs. To follow a script execution in real time:

```bash
tail -f /opt/digicert/tlm_agent_3.1.9_linux64/log/fortigate.log
tail -f /opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log
tail -f /home/ubuntu/fortinac.log
tail -f /home/ubuntu/tlm_agent_3.0.15_linux64/log/apigee.log
```

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. These scripts are provided under the terms of the DigiCert software license. See the legal notice within each script for full details.