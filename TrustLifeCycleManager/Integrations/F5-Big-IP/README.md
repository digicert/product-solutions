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
| `Linux/f5_big_ip-awr-both-server-client.sh` | Linux | Bash |
| `Windows/f5_big_ip-awr-both-server-client.ps1` | Windows | PowerShell 6+ |

Both scripts are functionally equivalent and follow the same six-step BIG-IP workflow.

## Prerequisites

### DigiCert TLM Agent

- **TLM Agent** installed and configured with an active certificate profile
- The certificate profile must produce a **separate `.crt` and `.key` file** (PEM). The scripts locate the first `*.crt` and first `*.key` in the AWR `files` array — a PFX-only profile will not work
- The post-enrollment (AWR) script must be registered in the agent configuration with the **three arguments** described in [AWR Arguments](#awr-arguments)
- **Linux:** the script needs the execute bit (`chmod +x`) and must be readable by the account the agent runs as
- **Linux:** the directory in `LOGFILE` **must already exist and be writable** — the Bash script does not create it, and if it is missing every log write fails silently. (The PowerShell script does create its log directory automatically.)

### F5 BIG-IP

- **iControl REST API** enabled and reachable from the TLM Agent host (`/mgmt` on the management port — 443 by default, or whatever `tmsh list sys httpd ssl-port` reports)
- A BIG-IP account meeting the requirements in [BIG-IP Account Permissions](#big-ip-account-permissions-minimum-required)
- **Advanced shell (bash) access is required** if `UPDATE_CLIENT_SSL_PROFILE="true"` — the Client SSL update runs a `tmsh` command through `/mgmt/tm/util/bash`
- The BIG-IP must **not be running in Appliance Mode** if the Client SSL update is used. Appliance Mode disables advanced shell entirely, so `/mgmt/tm/util/bash` will be rejected regardless of role. Set `UPDATE_CLIENT_SSL_PROFILE="false"` on Appliance Mode devices
- The **Server SSL and/or Client SSL profiles must already exist** in the `/Common` partition. The scripts update existing profiles — they never create them
- The Client SSL profile must already have **at least one `cert-key-chain` entry**; the scripts modify the first entry in place rather than adding one
- Certificate/key objects are created in **`/Common`** (hardcoded). Other partitions and route domains are not supported

### Client tooling

**Bash script (Linux):**

- `curl`, `base64`, `awk`, `sed`, `tr`, `wc`, `date`
- **GNU `grep` with PCRE support** (`grep -oP`) — required, not optional
- **GNU `stat`** (`stat -c%s`) — the script is Linux/coreutils-specific and will not run unmodified on macOS or BSD
- `jq` is optional; a `grep`/`sed` fallback is used when it is absent

**PowerShell script (Windows):**

- **PowerShell 6+ (Core) is recommended** — it uses `Invoke-RestMethod -SkipCertificateCheck`
- PowerShell 5.1 works via a fallback `TrustAllCertsPolicy` type that disables certificate validation process-wide. Note that this fallback is global to the process, so prefer PowerShell 7 where possible
- The TLM Agent must invoke the script with `pwsh` (or `powershell.exe` for the 5.1 path), and the effective execution policy must allow it to run

## BIG-IP Account Permissions (minimum required)

The scripts touch three classes of endpoint, and each has its own floor. The account must satisfy **all** of the ones you enable.

| Script step | Endpoint | Minimum requirement |
|-------------|----------|---------------------|
| 1–2 Upload cert/key | `POST /mgmt/shared/file-transfer/uploads/…` | Administrator-level account. The `/mgmt/shared/*` file-transfer workers reject lower roles (401/403) |
| 3–4 Install cert/key | `POST /mgmt/tm/sys/crypto/{cert,key}` | Certificate Manager or higher |
| 5 Server SSL profile | `PATCH /mgmt/tm/ltm/profile/server-ssl/…` | Manager or higher, with write access to the profile's partition |
| 6 Client SSL profile | `POST /mgmt/tm/util/bash` | Administrator **or** Resource Administrator role **and** Terminal Access = **Advanced shell (bash)** |

### Practical minimum

Because the file-transfer upload and the `util/bash` call both demand an administrative account, the realistic minimum for the **full** workflow is:

| Setting | Value |
|---------|-------|
| **Role** | **Resource Administrator** (or Administrator) |
| **Terminal Access** | **Advanced shell (bash)** |
| **Partition Access** | `All` — or at minimum `Common` with write access |

> **Advanced shell is only assignable to the Administrator and Resource Administrator roles.** Every other role (Manager, Certificate Manager, Application Editor, …) is limited to `tmsh` or `Disabled` terminal access, which makes the Client SSL step impossible. This is why lower-privilege roles cannot be used for the full workflow — it is an F5 platform constraint, not a script limitation.

If you set `UPDATE_CLIENT_SSL_PROFILE="false"`, advanced shell is no longer needed for step 6 — but the file-transfer upload in steps 1–2 still requires an administrative account, so **Resource Administrator with `tmsh` terminal access** is the floor for the Server-SSL-only workflow.

### Creating the account

**GUI:** *System → Users → User List → Create*, then set Role, Partition Access, and Terminal Access.

**tmsh (Resource Administrator with advanced shell):**

```bash
tmsh create auth user digicert-svc \
    password '<password>' \
    partition-access add { all-partitions { role resource-admin } } \
    shell bash
tmsh save sys config
```

Substitute `role admin` for a full Administrator account.

### Remote (LDAP / AD / RADIUS / TACACS+) accounts

Remotely-authenticated users take their terminal access from the global remote-user setting, which defaults to no shell. If you authenticate the service account remotely, either grant the remote-user shell explicitly:

```bash
tmsh modify auth remote-user { default-role resource-admin default-partition Common remote-console-access bash }
```

…or, preferably, use a **local** BIG-IP account for this integration so the permissions are explicit and unaffected by directory changes.

## Configuration

### Script Variables

Edit the variables at the top of the script before deployment:

```bash
# Legal notice must be accepted to run — ships as "false", you MUST change it
LEGAL_NOTICE_ACCEPT="false"

# Log file location (Linux default shown; directory must already exist)
LOGFILE="/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5server.log"

# Enable/disable profile updates and set the profile names
UPDATE_SERVER_SSL_PROFILE="true"
SERVER_SSL_PROFILE_NAME="serverssl"   # Name of the Server SSL profile to update
UPDATE_CLIENT_SSL_PROFILE="true"
CLIENT_SSL_PROFILE_NAME="clientssl"   # Name of the Client SSL profile to update
```

The PowerShell script uses the same names with a `$` prefix (`$LEGAL_NOTICE_ACCEPT`, `$LOGFILE`, …).

`LEGAL_NOTICE_ACCEPT` ships as `"false"` in both scripts and must be set to `"true"` or the script exits immediately with code 1.

`SERVER_SSL_PROFILE_NAME` is only used when `UPDATE_SERVER_SSL_PROFILE="true"`, and `CLIENT_SSL_PROFILE_NAME` is only used when `UPDATE_CLIENT_SSL_PROFILE="true"`. Set each profile name to match the exact profile name configured on your BIG-IP appliance.

### AWR Arguments

The scripts receive three arguments via the TLM Agent AWR configuration, passed through the `DC1_POST_SCRIPT_DATA` environment variable as a Base64-encoded JSON payload:

| Argument | Description | Example | Required |
|----------|-------------|---------|----------|
| `Argument 1` | BIG-IP credentials (`user:pass`) | `admin:P@ssw0rd` | Yes |
| `Argument 2` | BIG-IP hostname or IP (with optional port) | `bigip.example.com:8443` | Yes |
| `Argument 3` | Certificate object name on BIG-IP | `www.example.com` | Yes |

> **Note:** SSL profile names are no longer passed as AWR arguments. Configure `SERVER_SSL_PROFILE_NAME` and `CLIENT_SSL_PROFILE_NAME` directly in the script instead.

#### Password character constraints (Linux script)

The Bash script splits the JSON `args` array with `awk -F','` and then strips all whitespace from each argument. As a result the BIG-IP password **must not contain**:

- a **comma** (`,`) — breaks argument splitting, and Arguments 2 and 3 will be parsed from the wrong fields
- a **space** — silently removed before use, producing a 401
- a **double quote** (`"`) — stripped along with the JSON quoting

Only the first `:` is treated as the user/password separator, so colons inside the password are safe. The PowerShell script parses the payload with `ConvertFrom-Json` and is not subject to the comma/space restrictions.

## How It Works

### Step-by-Step Workflow

Step numbers below match the `Step N:` entries written to the log file.

```
TLM Agent enrolls/renews cert
        │
        ▼
┌─────────────────────────┐
│ Decode AWR payload      │  ← DC1_POST_SCRIPT_DATA (Base64 → JSON)
│    Extract cert + key   │
│    Parse arguments      │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 1. Upload cert to       │  ← POST /mgmt/shared/file-transfer/uploads/{name}.crt
│    BIG-IP file store    │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 2. Upload key to        │  ← POST /mgmt/shared/file-transfer/uploads/{name}.key
│    BIG-IP file store    │
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 3. Install certificate  │  ← POST /mgmt/tm/sys/crypto/cert
│    into crypto store    │     from /var/config/rest/downloads/{name}.crt
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 4. Install key into     │  ← POST /mgmt/tm/sys/crypto/key
│    crypto store         │     from /var/config/rest/downloads/{name}.key
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 5. Update Server SSL    │  ← PATCH /mgmt/tm/ltm/profile/server-ssl/{profile}
│    profile (if enabled) │     cert + key = /Common/{name}
└────────┬────────────────┘
         ▼
┌─────────────────────────┐
│ 6. Update Client SSL    │  ← GET profile → extract cert-key-chain entry
│    profile (if enabled) │     POST /mgmt/tm/util/bash (tmsh modify)
└─────────────────────────┘
```

Each step logs its own success or failure. **The scripts do not abort on a failed step** — a failed upload is logged as an `ERROR` and execution continues to the next step, and both scripts always `exit 0`. Check the log file to confirm the run actually succeeded; the exit code will not tell you.

### Client SSL Profile Handling

The Client SSL profile update is more involved than the Server SSL update because BIG-IP manages client-facing certificates through a `cert-key-chain` structure. The script:

1. Queries the existing Client SSL profile to retrieve the current `cert-key-chain` entry name (via `jq`, or a `grep`/`sed` fallback on Linux)
2. Uses the BIG-IP `tmsh` utility (via the `/mgmt/tm/util/bash` REST endpoint) to modify the existing entry with the new certificate, key, and chain

This preserves the profile structure and avoids needing to recreate the `cert-key-chain` from scratch.

The entry's `chain` is pointed at the same `/Common/{cert-name}` object as the certificate, which relies on the TLM-issued `.crt` containing the end-entity certificate **and** its issuing chain in one PEM bundle.

## BIG-IP API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/mgmt/shared/file-transfer/uploads/{name}` | Upload cert/key files |
| `POST` | `/mgmt/tm/sys/crypto/cert` | Install certificate |
| `POST` | `/mgmt/tm/sys/crypto/key` | Install private key |
| `PATCH` | `/mgmt/tm/ltm/profile/server-ssl/{name}` | Update Server SSL profile |
| `GET` | `/mgmt/tm/ltm/profile/client-ssl/{name}` | Read Client SSL profile |
| `POST` | `/mgmt/tm/util/bash` | Execute tmsh command |

## Assumptions and Limitations

Read these before deploying — several affect whether the change survives a reboot.

- **Running configuration only.** Neither script runs `tmsh save sys config`. The updated profiles take effect immediately but are **lost on reboot** unless the configuration is saved by other means. Add a save step, or ensure your operational process saves config after renewal.
- **No HA config-sync.** On an HA pair the scripts update only the device they are pointed at. The peer is not synced (`tmsh run cm config-sync to-group <group>`). Either point the AWR script at the active device and sync separately, or run against each device.
- **`/Common` partition only.** The cert, key, and profile references are hardcoded to `/Common/`. Objects in other administrative partitions are not supported.
- **Profiles must pre-exist**, and the Client SSL profile must already have a `cert-key-chain` entry. Nothing is created.
- **Only the first `cert-key-chain` entry is updated.** Multi-certificate Client SSL profiles (for example, an RSA entry plus an ECDSA entry) will only have entry `[0]` changed.
- **No rollback.** If a later step fails after the cert/key are installed, the profile may be left referencing the previous certificate with no cleanup or retry.
- **Reused object name.** Installing over an existing object of the same name is what makes in-place renewal work; it also means the previous certificate for that name is replaced, not archived.
- **Management TLS verification is disabled** (`curl -k` / `SkipCertificateCheck`).

## Logging

Both scripts produce detailed, timestamped logs. Credentials are obfuscated in all log output. The log includes:

- Configuration summary
- AWR payload extraction details (raw JSON with `args[0]` masked)
- Certificate and key file metadata (size, key type, cert count)
- Each API call result (success/failure with HTTP codes)
- Full extraction summary with argument values

Default log locations:

- **Linux:** `/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5server.log`
- **Windows:** `C:\Program Files\DigiCert\TLM Agent\log\f5_data.log`

Adjust the `LOGFILE` variable to match your TLM Agent installation path. On Linux, create the directory first — the Bash script will not create it. Neither script rotates or truncates the log; it appends indefinitely.

## Security Considerations

- **Credentials** are passed via the AWR argument payload and are never written to logs in cleartext
- On Linux, credentials are handed to `curl` via `-u` on the command line, which makes them briefly visible in the process list (`ps`) to other local users on the agent host. Restrict shell access on that host accordingly
- The scripts disable TLS certificate verification for API calls to the BIG-IP (`-k` / `SkipCertificateCheck`) to support self-signed management certificates — consider using a trusted certificate on your BIG-IP management interface in production
- The Client SSL path executes a command through `/mgmt/tm/util/bash`, which runs as **root** on the BIG-IP. Only the certificate name and profile name from your configuration are interpolated into that command — keep both under administrative control and do not source them from untrusted input
- The BIG-IP user account should follow the principle of least privilege. Because of the F5 platform constraints described in [BIG-IP Account Permissions](#big-ip-account-permissions-minimum-required), that floor is Resource Administrator with advanced shell for the full workflow — use a **dedicated service account** scoped to the partition you need rather than a shared `admin` login
- The `LEGAL_NOTICE_ACCEPT` flag must be explicitly set to `"true"` before the script will execute

## Supported Key Types

The scripts detect and log the private key type:

- RSA (`BEGIN RSA PRIVATE KEY`)
- ECC (`BEGIN EC PRIVATE KEY`)
- PKCS#8 (`BEGIN PRIVATE KEY`)

Detection is for logging only — an unrecognised header is logged as `Unknown` and deployment still proceeds.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Script exits immediately | `LEGAL_NOTICE_ACCEPT` not set to `"true"` | Edit the variable at the top of the script |
| No log file at all (Linux) | `LOGFILE` directory does not exist or is not writable | Create the directory and grant write access to the agent's account |
| `DC1_POST_SCRIPT_DATA` not set | Script not invoked by TLM Agent AWR | Verify the post-enrollment script path in TLM Agent config |
| `grep: invalid option -- 'P'` | Non-GNU `grep` without PCRE | Install GNU grep, or run the script on a glibc/coreutils Linux host |
| Cert/key file "not found" in log | Profile does not emit separate PEM `.crt`/`.key` files | Change the TLM certificate profile output format |
| Upload succeeds but install fails | Certificate name conflict on BIG-IP | Check if a cert with that name already exists on the appliance |
| HTTP 401 on API calls | Invalid credentials — or a password containing a comma/space on the Linux script | Verify `Argument 1` format is `username:password`; see [password character constraints](#password-character-constraints-linux-script) |
| HTTP 403 on upload or `util/bash` | Account role too low, or terminal access is not advanced shell | Grant Resource Administrator + **Advanced shell (bash)**; see [BIG-IP Account Permissions](#big-ip-account-permissions-minimum-required) |
| `util/bash` rejected on an otherwise admin account | BIG-IP is in **Appliance Mode** (bash disabled platform-wide) | Set `UPDATE_CLIENT_SSL_PROFILE="false"`, or use a device not in Appliance Mode |
| Client SSL update fails | No existing `cert-key-chain` entry | Ensure the Client SSL profile has at least one cert-key-chain entry configured |
| Server/Client SSL update skipped with warning | Profile name not configured | Set `SERVER_SSL_PROFILE_NAME` / `CLIENT_SSL_PROFILE_NAME` in the script |
| Profile updated, but reverts after reboot | Running config was never saved | Run `tmsh save sys config` after deployment |
| Only one device in an HA pair updated | Scripts do not config-sync | Sync from the active device after deployment |
| Script logs `SUCCESS` for every step but nothing changed | Wrong partition — objects/profiles are not in `/Common` | Move the profile to `/Common` or adapt the script's hardcoded partition |
| Exit code 0 despite errors | By design — steps log failures and continue | Grep the log for `ERROR` rather than relying on the exit code |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.
