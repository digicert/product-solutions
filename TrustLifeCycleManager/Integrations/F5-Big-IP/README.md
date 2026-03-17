# DigiCert TLM Agent — F5 BIG-IP AWR Post-Enrollment Scripts

Automated certificate deployment to F5 BIG-IP load balancers using DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment (AWR) scripts. Supports both **Server SSL** and **Client SSL** profile updates via the BIG-IP iControl REST API.

## Overview

These scripts are triggered automatically by the DigiCert TLM Agent after a certificate is enrolled or renewed. They handle the full certificate lifecycle on a BIG-IP appliance:

1. Upload the certificate and private key to BIG-IP
2. Install both into the BIG-IP certificate/key store
3. Update the **Server SSL** profile (back-end connections)
4. Update the **Client SSL** profile (front-end/listener connections)

Each step is independently configurable — you can enable Server SSL only, Client SSL only, or both.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `f5_big_ip-awr-both-server-client.sh` | Linux | Bash |
| `f5_big_ip-awr-both-server-client.ps1` | Windows | PowerShell 6+ |

Both scripts are functionally equivalent and follow the same six-step workflow.

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an active certificate profile
- **F5 BIG-IP** with iControl REST API enabled (typically `/mgmt` on port 443 or 8443)
- A BIG-IP user account with at least **Certificate Manager** and **LTM** permissions
- **Bash script:** `curl`, `base64`, `grep` (with `-P` / PCRE support); optionally `jq`
- **PowerShell script:** PowerShell 6+ (Core) recommended; PowerShell 5.1 supported with fallback TLS handling

## Configuration

### Script Variables

Edit the variables at the top of the script before deployment:

```bash
# Legal notice must be accepted to run
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/path/to/tlm_agent/log/f5_data.log"

# Enable/disable profile updates
UPDATE_SERVER_SSL_PROFILE="true"
UPDATE_CLIENT_SSL_PROFILE="true"
```

### AWR Arguments

The scripts receive five arguments via the TLM Agent AWR configuration, passed through the `DC1_POST_SCRIPT_DATA` environment variable as a Base64-encoded JSON payload:

| Argument | Description | Example | Required |
|----------|-------------|---------|----------|
| `Argument 1` | BIG-IP credentials (`user:pass`) | `admin:P@ssw0rd` | Yes |
| `Argument 2` | BIG-IP hostname or IP (with optional port) | `bigip.example.com:8443` | Yes |
| `Argument 3` | Certificate object name on BIG-IP | `www.example.com` | Yes |
| `Argument 4` | Server SSL profile name | `my_serverssl` | If Server SSL enabled |
| `Argument 5` | Client SSL profile name | `my_clientssl` | If Client SSL enabled |

## How It Works

### Step-by-Step Workflow

```
TLM Agent enrolls/renews cert
        │
        ▼
┌─────────────────────────┐
│ 1. Decode AWR payload   │  ← DC1_POST_SCRIPT_DATA (Base64 → JSON)
│    Extract cert + key   │
│    Parse arguments      │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 2. Upload cert to       │  ← POST /mgmt/shared/file-transfer/uploads/{name}.crt
│    BIG-IP file store    │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 3. Upload key to        │  ← POST /mgmt/shared/file-transfer/uploads/{name}.key
│    BIG-IP file store    │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 4. Install certificate  │  ← POST /mgmt/tm/sys/crypto/cert
│    into crypto store    │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 5. Install key into     │  ← POST /mgmt/tm/sys/crypto/key
│    crypto store         │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 6. Update Server SSL    │  ← PATCH /mgmt/tm/ltm/profile/server-ssl/{profile}
│    profile (if enabled) │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 7. Update Client SSL    │  ← GET profile → extract cert-key-chain entry
│    profile (if enabled) │     POST /mgmt/tm/util/bash (tmsh modify)
└─────────────────────────┘
```

### Client SSL Profile Handling

The Client SSL profile update is more involved than the Server SSL update because BIG-IP manages client-facing certificates through a `cert-key-chain` structure. The script:

1. Queries the existing Client SSL profile to retrieve the current `cert-key-chain` entry name
2. Uses the BIG-IP `tmsh` utility (via the `/mgmt/tm/util/bash` REST endpoint) to modify the existing entry with the new certificate, key, and chain

This preserves the profile structure and avoids needing to recreate the `cert-key-chain` from scratch.

## BIG-IP API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/mgmt/shared/file-transfer/uploads/{name}` | Upload cert/key files |
| `POST` | `/mgmt/tm/sys/crypto/cert` | Install certificate |
| `POST` | `/mgmt/tm/sys/crypto/key` | Install private key |
| `PATCH` | `/mgmt/tm/ltm/profile/server-ssl/{name}` | Update Server SSL profile |
| `GET` | `/mgmt/tm/ltm/profile/client-ssl/{name}` | Read Client SSL profile |
| `POST` | `/mgmt/tm/util/bash` | Execute tmsh command |

## Logging

Both scripts produce detailed, timestamped logs. Credentials are obfuscated in all log output. The log includes:

- Configuration summary
- AWR payload extraction details
- Certificate and key file metadata (size, key type, cert count)
- Each API call result (success/failure with HTTP codes)
- Full extraction summary with argument values

Default log locations:

- **Linux:** `/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5server.log`
- **Windows:** `C:\Program Files\DigiCert\TLM Agent\log\f5_data.log`

Adjust the `LOGFILE` variable to match your TLM Agent installation path.

## Security Considerations

- **Credentials** are passed via the AWR argument payload and are never written to logs in cleartext
- The scripts disable TLS certificate verification for API calls to the BIG-IP (`-k` / `SkipCertificateCheck`) to support self-signed management certificates — consider using a trusted certificate on your BIG-IP management interface in production
- The BIG-IP user account should follow the principle of least privilege — only grant the permissions required for certificate and profile management
- The `LEGAL_NOTICE_ACCEPT` flag must be explicitly set to `"true"` before the script will execute

## Supported Key Types

The scripts detect and log the private key type:

- RSA (`BEGIN RSA PRIVATE KEY`)
- ECC (`BEGIN EC PRIVATE KEY`)
- PKCS#8 (`BEGIN PRIVATE KEY`)

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Script exits immediately | `LEGAL_NOTICE_ACCEPT` not set to `"true"` | Edit the variable at the top of the script |
| `DC1_POST_SCRIPT_DATA` not set | Script not invoked by TLM Agent AWR | Verify the post-enrollment script path in TLM Agent config |
| Upload succeeds but install fails | Certificate name conflict on BIG-IP | Check if a cert with that name already exists on the appliance |
| Client SSL update fails | No existing `cert-key-chain` entry | Ensure the Client SSL profile has at least one cert-key-chain entry configured |
| HTTP 401 on API calls | Invalid credentials | Verify `Argument 1` format is `username:password` |
| Connection refused | Wrong host/port | Confirm `Argument 2` includes the correct management port |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.