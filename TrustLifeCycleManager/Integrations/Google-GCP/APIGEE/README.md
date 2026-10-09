# DigiCert TLM — Google Cloud Apigee X

`google_apigee-awr.sh` deploys a certificate issued by **DigiCert Trust Lifecycle Manager (TLM)** to a **Google Cloud Apigee X** environment through the Apigee Management API. It runs as an **Admin Web Request (AWR) post-enrollment automation script** inside the TLM Agent after a certificate is issued or renewed, and handles renewal as a **zero-downtime rotation**: a new keystore is created, the certificate is uploaded into it, and the environment *reference* that the virtual host uses is swung to the new keystore.

| Script | Platform | Location |
|--------|----------|----------|
| `google_apigee-awr.sh` | Linux (Bash) | [google_apigee-awr.sh](google_apigee-awr.sh) |

---

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [How it is triggered](#how-it-is-triggered)
- [Arguments](#arguments)
- [Configuration](#configuration)
- [Authentication](#authentication)
- [Deployment modes](#deployment-modes)
- [API endpoints](#api-endpoints)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## How it works

Apigee X does not allow a certificate inside an existing keystore alias to be updated in place. Virtual hosts therefore do not point at a keystore directly but at an environment **reference**, and the reference is what gets repointed. Every renewal is a rotation:

```
TLM issues / renews certificate
        │
        ▼
TLM Agent writes cert + key to disk and sets DC1_POST_SCRIPT_DATA
        │
        ▼
google_apigee-awr.sh
        ├── activates the GCP service account and obtains an OAuth access token
        ├── creates a keystore            (Argument 1, must be a new, unique name)
        ├── uploads cert + key as an alias (Argument 2)
        └── new:    creates the reference  (Argument 3) → keystore
            rotate: updates the reference  (Argument 3) → keystore
```

Because the virtual host follows the reference, updating the reference switches traffic to the new certificate atomically. The old keystore is left in place and can be removed manually once the switch is confirmed.

---

## Prerequisites

- **DigiCert TLM Agent** (v3.0.15 or later) on a Linux host with post-enrollment script execution enabled
- **Bash** 4.0 or later, **curl**, **base64**, **awk**, and **grep** with PCRE support (`grep -P`)
- **gcloud CLI** installed and in the TLM Agent's `PATH`
- Outbound HTTPS from the TLM Agent host to `apigee.googleapis.com` and the Google OAuth endpoints
- A **GCP service account** JSON key with the **Apigee Environment Admin** role (or a custom role with permissions on keystores, aliases and references) on the target project
- A TLM certificate profile configured with the script as its AWR post-enrollment automation and the arguments listed below
- `LEGAL_NOTICE_ACCEPT="true"` set inside the script

---

## How it is triggered

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable to a Base64-encoded JSON payload and executes the script. The payload contains:

- **`certfolder`**: the directory the Agent wrote the certificate files to
- **`files`**: the file names, one `.crt` and one `.key`
- **`args`**: the arguments configured on the TLM profile, in order

The script decodes the payload, resolves the `.crt` and `.key` paths, and reads its four arguments from `args`. Decoded, the payload looks like this:

```json
{
  "certfolder": "/home/ubuntu/tlm_agent_3.0.15_linux64/certs/api.example.com",
  "files": ["api.example.com.crt", "api.example.com.key"],
  "args": ["web-keystore-2026-03", "web-cert", "web-tls-ref", "rotate"]
}
```

> **Note:** arguments are split on commas, so none of the values below may contain a comma.

---

## Arguments

| Position | Name | Required | Description | Example |
|----------|------|----------|-------------|---------|
| 1 | `KEYSTORE` | yes | Name of the keystore to **create**. Must not already exist in the environment. | `web-keystore-2026-03` |
| 2 | `ALIAS` | yes | Alias name for the certificate inside that keystore | `web-cert` |
| 3 | `REFERENCE` | yes | Name of the environment reference the virtual host uses | `web-tls-ref` |
| 4 | `DEPLOY` | yes | Deployment mode, `new` or `rotate` (see [Deployment modes](#deployment-modes)) | `rotate` |

Because the keystore is always created, **Argument 1 must be unique per run**. Put a date or version in the name and keep the reference name (Argument 3) constant across rotations.

> Argument 4 is listed as optional in the script's comments, but in the current version omitting it only logs a message and exits without creating anything. Always set it explicitly.

---

## Configuration

Edit the header of the script before first use:

```bash
LEGAL_NOTICE_ACCEPT="true"                                   # must be "true" or the script exits
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/apigee.log"
PROJECT_ID="< YOUR_PROJECT_ID >"                             # GCP project = Apigee organization
ENVIRONMENT="< YOUR_ENVIRONMENT >"                           # Apigee environment, e.g. prod
SA_KEY_PATH="/home/ubuntu/tlm_agent_3.0.15_linux64/user-scripts/service-account-key.json"
```

The TLM Agent user needs write access to the `LOGFILE` directory and read access to `SA_KEY_PATH`.

---

## Authentication

The script authenticates with a GCP service account rather than a static API token:

1. Place the service account JSON key on the TLM Agent host and restrict its permissions to the Agent user.
2. Set `SA_KEY_PATH` to its full path.
3. On every run the script calls `gcloud auth activate-service-account --key-file` and then `gcloud auth print-access-token` to obtain a short-lived OAuth bearer token, which it sends on each Apigee API call.

All calls go to `https://apigee.googleapis.com` over standard, verified TLS.

---

## Deployment modes

### `new` — first installation

1. Creates keystore **Argument 1**
2. Uploads the certificate and key as alias **Argument 2** (`format=keycertfile`)
3. Creates reference **Argument 3** with `resourceType: KeyStore` pointing at the keystore

Use this once per virtual host or target endpoint, then point the virtual host at the reference in the Apigee console.

### `rotate` — renewal

1. Creates keystore **Argument 1** (a new, unique name)
2. Uploads the certificate and key as alias **Argument 2**
3. Updates existing reference **Argument 3** so that `refers` is the new keystore

Use this for every renewal. The reference name never changes, so nothing on the virtual host needs editing.

---

## API endpoints

All paths are relative to `https://apigee.googleapis.com/v1/organizations/{PROJECT_ID}/environments/{ENVIRONMENT}`.

| Operation | Method | Path | Mode |
|-----------|--------|------|------|
| Create keystore | `POST` | `/keystores` | new, rotate |
| Upload cert + key | `POST` | `/keystores/{KEYSTORE}/aliases?alias={ALIAS}&format=keycertfile` (multipart: `certFile`, `keyFile`) | new, rotate |
| Create reference | `POST` | `/references` | new |
| Update reference | `PUT` | `/references/{REFERENCE}` | rotate |

---

## Troubleshooting

| Symptom | Likely cause | Resolution |
|---------|--------------|------------|
| "You must accept the legal notice" | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set it in the script header |
| "DC1_POST_SCRIPT_DATA environment variable is not set" | Script was run by hand, not by the TLM Agent | Configure it as the AWR post-enrollment automation on the TLM profile |
| "Failed to extract KEYSTORE / ALIAS / REFERENCE" | Fewer than three arguments on the profile, or a value contains a comma | Check the argument list on the TLM profile |
| Script logs "defaulting to new installation" and nothing is created | Argument 4 (`DEPLOY`) is empty | Set Argument 4 to `new` or `rotate` |
| "Invalid DEPLOY value" | Argument 4 is something other than `new` or `rotate` | Correct the value; it is case-sensitive |
| "Service account key file not found" / "Failed to activate service account" | Wrong `SA_KEY_PATH`, unreadable file, or invalid key | Verify the path, file permissions and that the key is not revoked |
| `gcloud: command not found` | gcloud CLI not installed or not in the Agent's `PATH` | Install the Google Cloud SDK and make it available to the TLM Agent user |
| Keystore creation returns HTTP 409 | Keystore name already exists | Use a unique name per run (include a date or version) |
| Reference update returns HTTP 404 (`rotate`) | Reference does not exist yet | Run once with `new`, or create the reference in the console first |
| HTTP 403 on any call | Service account lacks the Apigee Environment Admin role on the project | Grant the role or an equivalent custom role |

To follow a run in real time:

```bash
tail -f /home/ubuntu/tlm_agent_3.0.15_linux64/log/apigee.log
```

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. This script is provided under the terms of the DigiCert software license. See the legal notice within the script for full details.
