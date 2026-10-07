# DigiCert TLM Agent — F5 BIG-IP AWR Post-Enrollment Scripts

Automated certificate deployment to F5 BIG-IP load balancers using DigiCert Trust Lifecycle Manager (TLM) Agent post-enrollment (Admin Web Request, AWR) scripts. The scripts update existing **Client SSL** and **Server SSL** profiles through the BIG-IP iControl REST API. One variant also deploys the same certificate to a local **IIS** site.

- [Scripts in this folder](#scripts-in-this-folder)
- [Architecture](#architecture)
- [Common prerequisites](#common-prerequisites)
- [AWR arguments and payload](#awr-arguments-and-payload)
- [Script 1 and 2: f5_big_ip-awr-both-server-client (Bash / PowerShell)](#script-1-and-2-f5_big_ip-awr-both-server-client-bash--powershell)
- [Script 3: Multi-endpoints-IIS-F5 (PowerShell, F5 + IIS)](#script-3-multi-endpoints-iis-f5-powershell-f5--iis)
- [BIG-IP account permissions](#big-ip-account-permissions)
- [BIG-IP API endpoints used](#big-ip-api-endpoints-used)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)

## Scripts in this folder

| File | Agent OS | Shell | Targets | Object naming on BIG-IP |
|------|----------|-------|---------|-------------------------|
| `Linux/f5_big_ip-awr-both-server-client.sh` | Linux | Bash | BIG-IP Server SSL + Client SSL | `/Common/<Argument 3>` (overwritten on renewal) |
| `Windows/f5_big_ip-awr-both-server-client.ps1` | Windows | PowerShell 6+ (5.1 fallback) | BIG-IP Server SSL + Client SSL | `/Common/<Argument 3>` (overwritten on renewal) |
| `Linux/Multi-endpoints-IIS-F5-fixed-Final.ps1` | **Windows** (needs IIS) | PowerShell 7 recommended | BIG-IP Client SSL + Server SSL **and** local IIS | `/Common/<Argument 3>_expYYYYMMDD` (new object per renewal, old ones pruned) |

> `Multi-endpoints-IIS-F5-fixed-Final.ps1` is stored under `Linux/` but is a Windows-only script: it imports into `Cert:\LocalMachine\My` and uses the `WebAdministration` module.

The Bash and PowerShell `f5_big_ip-awr-both-server-client` scripts do the same thing and follow the same six-step workflow. The multi-endpoint script is a separate design with different naming, error handling and extra steps. It is described in [its own section](#script-3-multi-endpoints-iis-f5-powershell-f5--iis).

## Architecture

```
┌──────────────────────┐  issue / renew   ┌───────────────────────────────┐
│  DigiCert TLM        │ ───────────────▶ │  TLM Agent host               │
│  (certificate        │                  │  (Linux or Windows)           │
│   profile + AWR      │                  │                               │
│   post-script config)│                  │  1. writes .crt / .key to     │
└──────────────────────┘                  │     certfolder                │
                                          │  2. sets DC1_POST_SCRIPT_DATA │
                                          │     (Base64 JSON)             │
                                          │  3. runs the AWR script       │
                                          └──────────────┬────────────────┘
                                                         │ HTTPS, basic auth
                                                         │ iControl REST (/mgmt)
                                                         ▼
                                          ┌───────────────────────────────┐
                                          │  F5 BIG-IP                    │
                                          │  file-transfer upload         │
                                          │  → sys crypto cert / key      │
                                          │  → ltm profile client-ssl     │
                                          │  → ltm profile server-ssl     │
                                          └───────────────────────────────┘
                                          (multi-endpoint script only:
                                           also imports into the local
                                           Windows store and binds IIS)
```

Key points:

- **Push model.** The script runs on the TLM Agent host and makes outbound REST calls to the BIG-IP management interface. Nothing is installed on the BIG-IP.
- **Key generation happens on the agent host.** The private key file produced by the TLM Agent is uploaded to the BIG-IP.
- **Existing profiles only.** The scripts repoint profiles you name in the script. They do not create virtual servers or profiles.

## Common prerequisites

### DigiCert TLM Agent

- **TLM Agent** installed and configured with an active certificate profile.
- The certificate profile must produce a **separate PEM `.crt` and `.key` file**. A PFX-only profile will not work.
  - The PowerShell `f5_big_ip-awr-*` script picks the first `.crt` and `.key` in the AWR `files` array.
  - The Bash script assumes there is exactly one of each. More than one match breaks parsing.
  - The multi-endpoint script does **not** read the `files` array. It expects `<certfolder>/<Argument 3>.crt` and `<certfolder>/<Argument 3>.key`, so the output file names must match Argument 3.
- The post-enrollment (AWR) script must be registered in the agent configuration with the arguments described in [AWR arguments and payload](#awr-arguments-and-payload).
- **Linux:** the script needs the execute bit (`chmod +x`) and must be readable by the account the agent runs as.
- **Linux:** the directory in `LOGFILE` **must already exist and be writable**. The Bash script does not create it, and if it is missing every log write fails silently. The PowerShell scripts create their log directory automatically.

### F5 BIG-IP

- **iControl REST API** enabled and reachable from the TLM Agent host. It is served under `/mgmt` on the management port: 443 by default, 8443 on single-NIC VE, or whatever `tmsh list sys httpd ssl-port` reports.
- A BIG-IP account meeting [BIG-IP account permissions](#big-ip-account-permissions).
- The **Server SSL and/or Client SSL profiles must already exist** in `/Common`. All three scripts hard-code `/Common`. Other partitions and route domains are not supported.
- The Client SSL profile must already have **at least one `cert-key-chain` entry**.

### Client tooling

**Bash script (Linux):**

- `curl`, `base64`, `awk`, `sed`, `tr`, `wc`, `date`
- **GNU `grep` with PCRE support** (`grep -oP`). This is required.
- **GNU `stat`** (`stat -c%s`). The script needs Linux coreutils and will not run unmodified on macOS or BSD.
- `jq` is optional. A `grep`/`sed` fallback is used when it is absent.

**PowerShell scripts (Windows):**

- **PowerShell 7 (`pwsh`) is recommended.** It supports `Invoke-RestMethod -SkipCertificateCheck` and, for the multi-endpoint script, .NET `CreateFromPemFile`.
- PowerShell 5.1 works through a fallback that disables certificate validation for the whole process (`TrustAllCertsPolicy` / `ServerCertificateValidationCallback`). Prefer PowerShell 7 where you can.
- The TLM Agent must invoke the script with `pwsh` (or `powershell.exe` for 5.1), and the effective execution policy must allow it to run.

## AWR arguments and payload

The TLM Agent passes everything to the script in the `DC1_POST_SCRIPT_DATA` environment variable. It contains Base64-encoded JSON with the `args` array configured on the AWR post-script, the `certfolder`, and the `files` written there.

| Argument | Description | Example | Used by |
|----------|-------------|---------|---------|
| `Argument 1` | BIG-IP credentials `user:pass`. Only the first `:` separates user from password, so colons in the password are fine | `digicert-svc:P@ss:word` | All |
| `Argument 2` | BIG-IP management host or IP, with optional port | `bigip.example.com:8443` | All |
| `Argument 3` | Certificate object name on BIG-IP. In the multi-endpoint script it is also the base file name in `certfolder` and the IIS SNI host header | `www.example.com` | All |
| `Argument 4` | IIS site name, optionally `Site:Port`. Defaults to `$IIS_DEFAULT_SITE` | `Default Web Site` or `Shop:8443` | Multi-endpoint only |
| `Argument 5` | IIS HTTPS port. Overrides a port given in Argument 4. Defaults to `$IIS_DEFAULT_PORT` (443) | `443` | Multi-endpoint only |

SSL profile names are **not** AWR arguments. Set them in the script variables.

### Password character constraints (Bash script only)

The Bash script splits the JSON `args` array with `awk -F','` and then strips all whitespace from each argument. The BIG-IP password **must not contain**:

- a **comma** (`,`). It breaks argument splitting, so Arguments 2 and 3 are read from the wrong fields.
- a **space**. It is silently removed before use, which produces a 401.
- a **double quote** (`"`). It is stripped along with the JSON quoting.

The PowerShell scripts parse the payload with `ConvertFrom-Json` and do not have these restrictions.

---

## Script 1 and 2: f5_big_ip-awr-both-server-client (Bash / PowerShell)

### Configuration

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

The PowerShell script uses the same names with a `$` prefix (`$LEGAL_NOTICE_ACCEPT`, `$LOGFILE`, …). Its default log is `C:\Program Files\DigiCert\TLM Agent\log\f5_data.log`.

- `LEGAL_NOTICE_ACCEPT` ships as `"false"` and must be set to `"true"`, or the script exits immediately with code 1.
- `SERVER_SSL_PROFILE_NAME` is used only when `UPDATE_SERVER_SSL_PROFILE="true"`. `CLIENT_SSL_PROFILE_NAME` is used only when `UPDATE_CLIENT_SSL_PROFILE="true"`. Each must match the exact profile name on the BIG-IP.
- **Additional BIG-IP requirements for the Client SSL step:**
  - The account needs **Advanced shell (bash)**, because the step runs `tmsh` through `/mgmt/tm/util/bash`.
  - The device must **not be in Appliance Mode**. Appliance Mode disables advanced shell entirely. Set `UPDATE_CLIENT_SSL_PROFILE="false"` on those devices.

### Workflow

Step numbers match the `Step N:` entries in the log file.

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

**Error handling.** A failed step is logged as `ERROR` and the script continues to the next step. Both scripts still `exit 0` after the workflow, even if one or more steps failed. They `exit 1` only for preflight failures, such as `LEGAL_NOTICE_ACCEPT` not set to `"true"` or `DC1_POST_SCRIPT_DATA` missing. Check the log to confirm that a run succeeded. The exit code will not tell you.

### Client SSL profile handling

BIG-IP manages client-facing certificates through a `cert-key-chain` structure, so this step does more than the Server SSL update:

1. It reads the Client SSL profile to get the name of the existing `cert-key-chain` entry (via `jq`, or a `grep`/`sed` fallback on Linux).
2. It runs `tmsh modify` through `/mgmt/tm/util/bash` to update that entry in place with the new certificate, key and chain.

This keeps the profile structure and avoids recreating the `cert-key-chain`. The entry's `chain` is pointed at the same `/Common/{cert-name}` object as the certificate, so the TLM-issued `.crt` must contain the end-entity certificate **and** its issuing chain in one PEM bundle.

### Assumptions and limitations

Several of these affect whether the change survives a reboot.

- **Running configuration only.** Neither script runs `tmsh save sys config`. The updated profiles take effect immediately but are **lost on reboot** unless the configuration is saved some other way.
- **No HA config-sync.** On an HA pair only the target device is updated. Sync from the active device afterwards (`tmsh run cm config-sync to-group <group>`), or run the script against each device.
- **`/Common` only.** Cert, key and profile references are hard-coded to `/Common/`.
- **Profiles must already exist**, and the Client SSL profile must already have a `cert-key-chain` entry.
- **Only the first `cert-key-chain` entry is updated.** In a profile with several entries (for example RSA plus ECDSA), only entry `[0]` changes.
- **No rollback.** If a later step fails after the cert/key are installed, the profile can be left on the previous certificate with no cleanup or retry.
- **Object name is reused.** Installing over an existing object of the same name is what makes in-place renewal work. The previous certificate for that name is replaced, not archived.
- **Management TLS verification is disabled** (`curl -k` / `SkipCertificateCheck`).

### Logging

Both scripts write detailed, timestamped logs with credentials obfuscated:

- Configuration summary
- AWR payload extraction details (raw JSON with `args[0]` masked)
- Certificate and key file metadata (size, key type, certificate count)
- The result of each API call (success/failure with HTTP code)
- Extraction summary with argument values

Default locations are `/home/ubuntu/tlm_agent_3.1.2_linux64/log/f5server.log` (Linux) and `C:\Program Files\DigiCert\TLM Agent\log\f5_data.log` (Windows). Neither script rotates the log. It is appended indefinitely.

The scripts detect and log the key type: RSA (`BEGIN RSA PRIVATE KEY`), ECC (`BEGIN EC PRIVATE KEY`) or PKCS#8 (`BEGIN PRIVATE KEY`). Detection is for logging only. An unrecognised header is logged as `Unknown` and deployment continues.

---

## Script 3: Multi-endpoints-IIS-F5 (PowerShell, F5 + IIS)

`Linux/Multi-endpoints-IIS-F5-fixed-Final.ps1` deploys one TLM-issued certificate to two targets in a single AWR run:

1. **F5 BIG-IP:** native iControl REST only, with a new expiry-stamped object per renewal.
2. **Windows IIS on the agent host:** imports into `Cert:\LocalMachine\My` and creates or updates an SNI HTTPS binding.

Either target can be switched off, so the script can also serve as an F5-only deployer (with expiry-stamped naming, config save and pruning) or as an IIS-only deployer.

### Configuration

```powershell
$LEGAL_NOTICE_ACCEPT = "true"     # NOTE: ships as "true" in this script
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\f5IIS_data.log"

# --- F5 BIG-IP ---
$UPDATE_BIGIP              = "true"                     # Deploy to F5 at all
$UPDATE_SERVER_SSL_PROFILE = "true"
$SERVER_SSL_PROFILE_NAME   = "digicer-server-profile"   # change to your profile
$UPDATE_CLIENT_SSL_PROFILE = "true"
$CLIENT_SSL_PROFILE_NAME   = "digicer-client-profile"   # change to your profile
$SAVE_SYS_CONFIG           = "true"                     # POST /mgmt/tm/sys/config {command: save}
$AUTO_PRUNE_OLD_CERTS      = "true"                     # delete older <cert>_exp* objects

# --- Windows IIS ---
$UPDATE_IIS                = "true"                     # Deploy to local IIS at all
$IIS_DEFAULT_SITE          = "Default Web Site"         # used when Argument 4 is omitted
$IIS_DEFAULT_PORT          = 443                        # used when Argument 5 is omitted
```

The default profile names are placeholders. Set them to the exact Client SSL and Server SSL profile names in `/Common` on your BIG-IP.

### Workflow

```
Decode DC1_POST_SCRIPT_DATA → args, certfolder
Load <certfolder>/<Arg3>.crt + .key → read NotAfter, thumbprint
OBJECT_NAME = <Arg3>_exp<NotAfter yyyyMMdd>

── F5 (if $UPDATE_BIGIP) ────────────────────────────────────────────
 1  Upload <OBJECT_NAME>.crt        POST /mgmt/shared/file-transfer/uploads
 2  Upload <OBJECT_NAME>.key        POST /mgmt/shared/file-transfer/uploads
 3  Install cert                    POST /mgmt/tm/sys/crypto/cert
 4  Install key                     POST /mgmt/tm/sys/crypto/key
 4b If the .crt holds intermediates, install them as
    <OBJECT_NAME>-chain             (upload + POST /mgmt/tm/sys/crypto/cert)
 5  Client SSL profile              GET, then PATCH certKeyChain =
                                    [{name:<existing entry>, cert, key, chain}]
 6  Server SSL profile              PATCH cert + key = /Common/<OBJECT_NAME>
 7  Prune older <Arg3>_exp* certs   DELETE sys/crypto/cert + key
 8  Save config                     POST /mgmt/tm/sys/config {command: save}
 9  Remove uploaded files           POST /mgmt/tm/util/bash (rm -f …)

── IIS (if $UPDATE_IIS) ─────────────────────────────────────────────
 1  Import cert + key into LocalMachine\My
      A: .NET CreateFromPemFile (PowerShell 7+)
      B: fallback: openssl pkcs12 → Import-PfxCertificate
 2  HTTPS binding on <site>:<port>
      existing binding with matching or empty host header → set cert, SNI
      otherwise → New-WebBinding HostHeader=<Arg3>, SslFlags=1 (SNI)
 3  Log the resulting binding (info, SNI flag, cert hash)
```

### Behaviour details

- **Naming and renewals.** Each renewal creates a new object, `/Common/<Arg3>_expYYYYMMDD`. The profiles are repointed to it, and the previous objects are then pruned (step 7). Old objects stay available until the profiles have moved.
- **Chain handling (step 4b / 5).** If the issued `.crt` contains intermediates, they are installed as `<OBJECT_NAME>-chain`. That object is bound to the Client SSL entry **only when the entry has no chain yet**. A chain that is already bound is left unchanged, so if the issuing CA changes you must update the chain manually.
- **Client SSL update replaces the `certKeyChain` list.** The PATCH sends a single entry, reusing the name of the first existing entry. A profile with several entries (for example RSA plus ECDSA) ends up with only this one.
- **Pruning.** Pruning matches any cert object named `<Arg3>_exp*` other than the new one. Deletion of objects still referenced by another profile is refused by BIG-IP, and that refusal is ignored.
- **Error handling.** Any F5 failure in steps 1–6 exits with code 1 straight away, and IIS is not attempted. A chain extraction failure (4b) is logged and skipped. Failures in prune (7), save (8) and cleanup (9) are swallowed without a log line. Any IIS error exits 1. The script exits **0 only if nothing logged an error**, so unlike scripts 1 and 2 the exit code is meaningful.
- **Permissions.** All F5 steps except cleanup use standard REST endpoints, so **Resource Administrator with `tmsh` terminal access** is enough. Advanced shell is needed only for step 9. Without it, the uploaded files stay in `/var/config/rest/downloads`.
- **HA.** The configuration is saved but **not config-synced**. Sync the device group afterwards, or run against each device.
- **IIS host requirements.**
  - The script must run elevated, because it writes to the LocalMachine store and IIS config.
  - The IIS Management Scripts and Tools feature must be installed (`WebAdministration` module).
  - It needs PowerShell 7, or OpenSSL for Windows. OpenSSL is looked up on `PATH`, then in Git for Windows, `OpenSSL-Win64/Win32` and Chocolatey locations.
  - Imported certificates get the FriendlyName `<Arg3>-<yyyyMMdd>`. Old certificates are not removed from the Windows store.

---

## BIG-IP account permissions

The scripts touch several classes of endpoint, and each has its own minimum role. The account must meet every one that your configuration uses.

| Step | Endpoint | Minimum requirement |
|------|----------|---------------------|
| Upload cert/key | `POST /mgmt/shared/file-transfer/uploads/…` | Administrator-level account. The `/mgmt/shared/*` file-transfer workers reject lower roles (401/403) |
| Install cert/key | `POST /mgmt/tm/sys/crypto/{cert,key}` | Certificate Manager or higher |
| Server SSL / Client SSL via REST PATCH | `PATCH /mgmt/tm/ltm/profile/{server,client}-ssl/…` | Manager or higher, with write access to the profile's partition |
| Client SSL in scripts 1/2, cleanup in script 3 | `POST /mgmt/tm/util/bash` | Administrator **or** Resource Administrator role **and** Terminal Access = **Advanced shell (bash)** |
| Save config (script 3) | `POST /mgmt/tm/sys/config` | Resource Administrator or higher |

### Practical minimum

| Workflow | Role | Terminal access | Partition access |
|----------|------|-----------------|------------------|
| Scripts 1/2, Server SSL + Client SSL | Resource Administrator (or Administrator) | **Advanced shell (bash)** | `All`, or at least `Common` with write access |
| Scripts 1/2, Server SSL only (`UPDATE_CLIENT_SSL_PROFILE="false"`) | Resource Administrator | `tmsh` | `Common` |
| Script 3 | Resource Administrator | `tmsh` (bash only needed for upload cleanup) | `Common` |

> **Advanced shell can only be assigned to the Administrator and Resource Administrator roles.** Every other role (Manager, Certificate Manager, Application Editor, …) is limited to `tmsh` or `Disabled` terminal access. That is an F5 platform constraint, not a script limitation.

### Creating the account

**GUI:** *System → Users → User List → Create*, then set Role, Partition Access and Terminal Access.

**tmsh (Resource Administrator with advanced shell):**

```bash
tmsh create auth user digicert-svc \
    password '<password>' \
    partition-access add { all-partitions { role resource-admin } } \
    shell bash
tmsh save sys config
```

Use `role admin` for a full Administrator account, or `shell tmsh` when advanced shell is not needed.

### Remote (LDAP / AD / RADIUS / TACACS+) accounts

Remotely authenticated users get their terminal access from the global remote-user setting, which defaults to no shell. If the service account is authenticated remotely, grant the shell explicitly:

```bash
tmsh modify auth remote-user { default-role resource-admin default-partition Common remote-console-access bash }
```

Alternatively, and preferably, use a **local** BIG-IP account for this integration. Its permissions are then explicit and unaffected by directory changes.

## BIG-IP API endpoints used

| Method | Endpoint | Purpose | Scripts |
|--------|----------|---------|---------|
| `POST` | `/mgmt/shared/file-transfer/uploads/{name}` | Upload cert/key/chain files | All |
| `POST` | `/mgmt/tm/sys/crypto/cert` | Install certificate / chain | All |
| `POST` | `/mgmt/tm/sys/crypto/key` | Install private key | All |
| `PATCH` | `/mgmt/tm/ltm/profile/server-ssl/{name}` | Update Server SSL profile | All |
| `GET` | `/mgmt/tm/ltm/profile/client-ssl/{name}` | Read Client SSL `cert-key-chain` | All |
| `POST` | `/mgmt/tm/util/bash` | `tmsh modify` of the Client SSL profile (1/2), upload cleanup (3) | All |
| `PATCH` | `/mgmt/tm/ltm/profile/client-ssl/~Common~{name}` | Update Client SSL `certKeyChain` | 3 |
| `GET` / `DELETE` | `/mgmt/tm/sys/crypto/{cert,key}[/~Common~{name}]` | List and prune old objects | 3 |
| `POST` | `/mgmt/tm/sys/config` | Save running configuration | 3 |

## Security considerations

- **Credentials** arrive in the AWR argument payload and are never written to the logs in cleartext.
- **Bash script and the process list.** It passes credentials to `curl -u` on the command line, so they are briefly visible in `ps` to other local users on the agent host. Restrict shell access on that host.
- **Management TLS verification is disabled** (`-k`, `SkipCertificateCheck`, or a trust-all callback on PowerShell 5.1) so that self-signed management certificates work. In production, put a trusted certificate on the BIG-IP management interface.
- **`/mgmt/tm/util/bash` runs as root on the BIG-IP.** Only the certificate name, profile name and file paths from your configuration are interpolated into that command. Keep them under administrative control and never source them from untrusted input.
- **Least privilege.** Use a **dedicated service account** rather than a shared `admin` login. Use the lowest role from [Practical minimum](#practical-minimum) that your workflow allows.
- **Legal notice.** `LEGAL_NOTICE_ACCEPT` must be `"true"` before a script will run. Scripts 1/2 ship with `"false"`, script 3 ships with `"true"`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Script exits immediately | `LEGAL_NOTICE_ACCEPT` not `"true"` | Edit the variable at the top of the script |
| No log file at all (Linux) | `LOGFILE` directory missing or not writable | Create the directory and grant the agent's account write access |
| `DC1_POST_SCRIPT_DATA` not set | Script not run by the TLM Agent AWR | Check the post-enrollment script path in the TLM Agent config |
| `grep: invalid option -- 'P'` | Non-GNU `grep` without PCRE | Install GNU grep, or run on a glibc/coreutils Linux host |
| Cert/key "not found" in log | The profile does not write separate PEM `.crt`/`.key` files. For script 3, the file names do not equal Argument 3 | Change the TLM certificate profile output, or align Argument 3 with the file name |
| Upload succeeds but install fails | Name conflict on BIG-IP | Check for an existing cert or key with that name |
| HTTP 401 | Invalid credentials, or (Bash) a password containing a comma or space | Check that `Argument 1` is `username:password`. See [password character constraints](#password-character-constraints-bash-script-only) |
| HTTP 403 on upload or `util/bash` | Role too low, or terminal access is not advanced shell | See [BIG-IP account permissions](#big-ip-account-permissions) |
| `util/bash` rejected on an admin account | BIG-IP is in **Appliance Mode** | Set `UPDATE_CLIENT_SSL_PROFILE="false"` (scripts 1/2), or use a device not in Appliance Mode |
| Client SSL update fails | No `cert-key-chain` entry on the profile | Add at least one entry to the profile |
| Profile update skipped with a warning | Profile name not set | Set `SERVER_SSL_PROFILE_NAME` / `CLIENT_SSL_PROFILE_NAME` |
| Profile reverts after reboot (scripts 1/2) | Running config never saved | Run `tmsh save sys config` after deployment, or use script 3 with `$SAVE_SYS_CONFIG="true"` |
| Only one HA device updated | No config-sync in any script | Run `tmsh run cm config-sync to-group <group>` from the active device |
| Every step logs `SUCCESS` but nothing changed | Profile is not in `/Common` | Move the profile to `/Common`, or adapt the hard-coded partition |
| Exit code 0 despite errors (scripts 1/2) | By design, failed steps are logged and execution continues | Search the log for `ERROR` |
| Second `cert-key-chain` entry disappeared (script 3) | The PATCH replaces the list with one entry | Use a separate profile per key type, or re-add the entry |
| Client SSL chain still shows the old intermediate (script 3) | An existing chain binding is deliberately kept | Update the profile's chain manually |
| `[IIS] ERROR: Unable to import certificate` | Running on Windows PowerShell 5.1 with no OpenSSL found | Run under `pwsh` 7+, or install OpenSSL for Windows and put it on `PATH` |
| `WebAdministration module not available` | IIS management tools not installed | Install the IIS Management Scripts and Tools feature |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.
