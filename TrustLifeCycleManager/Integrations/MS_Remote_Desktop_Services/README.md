# DigiCert TLM Agent — RDP & Remote Desktop Services Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates certificate deployment across the **RDP-Tcp listener**, **RD Connection Broker Publishing**, **RD Web Access**, and **RD SSO / Redirector** roles. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script decodes the `DC1_POST_SCRIPT_DATA` payload, imports the delivered PFX, and applies it to whichever Remote Desktop Services roles are enabled.

In a **high-availability (HA) deployment** the script can run on **both Connection Brokers in a single Agent Job** or on each broker via separate jobs. The work splits into two scopes:

- **Local, per-server** (always run): import the PFX into `LocalMachine\My`, repair private-key permissions, and — optionally — set this server's RDP-Tcp listener certificate. This runs on every host the job targets.
- **Deployment-wide** (run once, by the active broker only): the Publishing / Web Access / SSO(Redirector) role certificates are applied with `Set-RDCertificate`, which imports the PFX into the deployment and **distributes it to the role servers** — so no per-server remoting (PsExec/WinRM) is required. When a single job targets both brokers, the script detects which host is the active RD Management Server and only that host calls `Set-RDCertificate`; the passive broker skips those calls to prevent a duplicate certificate import.

Any enabled step that genuinely fails is recorded and the script exits non-zero, so TLM reflects the true outcome instead of a false "success". A missing deployment (or a role that isn't part of it) is treated as a graceful skip, not a failure.

## How It Works

```
TLM Agent (AWR)
    │
    ▼
Enrollment / Renewal completes
    │
    ▼
DC1_POST_SCRIPT_DATA (Base64-encoded JSON)
    │
    ▼
Post-enrollment script
    ├── Decode JSON, extract PFX path + password + args
    ├── Import PFX into LocalMachine\My store, read thumbprint, save to file   ── always
    ├── Repair private key permissions (certutil -repairstore)                 ── always
    ├── (Optional) Set RDP-Tcp listener certificate via WMI + restart TermService   ── local
    │
    ├── Probe for an RDS deployment (Get-RDCertificate)
    │     └── none found → skip the role steps with a note (not a failure)
    └── If a deployment exists:
          ├── Check if this host is the active RD Management Server (Get-RDServer local probe)
          │     └── not active + local host has the Connection Broker role (tssdis service)
          │           → skip Publishing / Web Access / SSO with a note (passive broker in single-job HA)
          ├── (Optional) Set RD Publishing    via Set-RDCertificate -ImportPath  ─┐
          ├── (Optional) Set RD Web Access    via Set-RDCertificate -ImportPath   │ active broker only
          └── (Optional) Set RD SSO/Redirector via Set-RDCertificate -ImportPath ─┘
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile (PFX output)
- Script runs with administrative privileges
- **For the deployment-wide roles:** the script must run on (or target, via `-ConnectionBroker`) the RD Connection Broker that currently holds the **RD Management Server** role, and the **RemoteDesktop** PowerShell module must be installed. In HA only the active management node answers the RD cmdlets; the management role can be moved between brokers in Server Manager (**Tasks → Select RD Management Server**).
- PFX enrollment output configured in the TLM AWR profile

> **Note:** The script does **not** gate on `Get-RDServer`. The local steps (PFX import + RDP listener) run regardless of node role; only the deployment-wide roles depend on a deployment being reachable.

## Configuration

### Legal Notice

The legal notice is accepted via a **string** value (must be the literal `"true"`):

```powershell
$LEGAL_NOTICE_ACCEPT = "true"   # Set to "true" to accept the legal notice and allow execution.
```

If this is not `"true"`, the script logs the reason and exits `1`.

### Service Role Flags

Enable the roles that should receive the deployed certificate. **All four default to `$true`.**

| Variable | Default | Scope | Description |
|---|---|---|---|
| `$Install_RDP_Listener_Certificate` | `$true` | Local | Set this server's RDP-Tcp listener certificate via WMI (`Win32_TSGeneralSetting`) and restart Terminal Services |
| `$Install_RDS_Publishing_Certificate` | `$true` | Deployment | Set the RD Connection Broker Publishing certificate via `Set-RDCertificate -Role RDPublishing` |
| `$Install_RDS_WebAccess_Certificate` | `$true` | Deployment | Set the RD Web Access certificate via `Set-RDCertificate -Role RDWebAccess` |
| `$Install_RDS_SSO_Certificate` | `$true` | Deployment | Set the RD SSO / Redirector certificate via `Set-RDCertificate -Role RDRedirector` |

The certificate is always imported into `LocalMachine\My`. If a given flag is `$false`, that role is skipped. The deployment-wide roles are additionally skipped (with a note) if no RDS deployment is detected.

> On a broker-only execution, the RDP-Tcp listener step affects **this broker only** — session hosts are not touched by this script. It also restarts `TermService`, dropping active RDP sessions to the broker. Set `$Install_RDP_Listener_Certificate = $false` if you don't want that.

### RDS Connection Broker

Optional. Leave empty to operate against the **local** deployment (i.e. this server is the active management broker). When set, it is passed as `-ConnectionBroker` to the RDS cmdlets.

```powershell
$RDS_Connection_Broker_FQDN = ""   # e.g. "svt-rdsktcnb002.hegele.de"
```

This value can also be supplied at runtime via **AWR Parameter 1** (`$ARGUMENT_1`), which takes precedence when non-empty.

> **Caution:** point this at a *real* Connection Broker FQDN (the active management node). Do not use a host's own FQDN on a non-broker, and be aware that the round-robin HA cluster DNS name resolves to *both* brokers — only the active management node will answer, so an explicit active-broker FQDN is the most predictable choice.

### Active-Broker Resolution (HA failover)

The deployment-wide roles only work against the broker that currently holds the **RD Management Server** role. Normally that's the host the agent runs on, so no configuration is needed. If the management role has **failed over** to another broker, the script probes the entries below and automatically targets whichever broker currently answers.

```powershell
# Most reliable: list the broker FQDNs explicitly
$RDS_Broker_Candidates = @("svt-rdsktcnb001.hegele.de", "svt-rdsktcnb002.hegele.de")

# Or (best effort) let the HA cluster DNS name be resolved + reverse-looked-up into candidates
$RDS_HA_Broker_DNS     = "rdskt-test-cb.hegele.de"
```

Resolution order: an explicitly configured `$RDS_Connection_Broker_FQDN` (if it answers) → the local host → the discovered candidates. The first broker that responds to `Get-RDServer` is used for all subsequent role cmdlets.

If **no** broker can be reached (and none of the above is configured), the deployment-wide roles are skipped with a warning rather than recorded as a failure — so populate `$RDS_Broker_Candidates` (or `$RDS_HA_Broker_DNS`) if you want failover handled automatically without manual intervention.

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\awr-template-logfile.log
```

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string**:

```json
{
  "certfolder": "C:\\path\\to\\certs",
  "files": ["certificate.pfx"],
  "password": "pfx-password",
  "args": ["arg1", "arg2"]
}
```

The script extracts:

- **`certfolder`** + the first `.pfx`/`.p12` entry in **`files`** — full path to the PFX file
- **`password`** — PFX import password. The following field names are also accepted as fallbacks: `pfx_password`, `keystore_password`, `passphrase`
- **`args`** — up to 15 optional custom arguments from the AWR profile (`$ARGUMENT_1` … `$ARGUMENT_15`). `$ARGUMENT_1` is used as an optional Connection Broker FQDN override

## What the Script Does

### Common Steps (Always Run)

1. **Legal notice check** — exits `1` if `$LEGAL_NOTICE_ACCEPT` is not `"true"`
2. **Environment check** — exits `1` if `DC1_POST_SCRIPT_DATA` is not set
3. **Decode & parse** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload (exits `1` on failure)
4. **Extract** — pulls the arguments, `certfolder`, PFX filename, and password from the JSON
5. **Inspect** — if the PFX exists and a password is available, logs subject/issuer/thumbprint/validity/key details

### Local Steps (Run When the PFX + Password Are Present)

6. **Import** — imports the PFX into `Cert:\LocalMachine\My`, captures the thumbprint, and saves it to `certificate_thumbprint.txt` in the certificate folder
7. **Repair permissions** — runs `certutil -repairstore my <thumbprint>` to ensure private key accessibility
8. **RDP listener** (if `$Install_RDP_Listener_Certificate = $true`) — sets `SSLCertificateSHA1Hash` on the `RDP-Tcp` terminal via WMI and restarts `TermService`

### Deployment-Wide Steps (Run When a Deployment Is Detected)

9. **Resolve the active broker** — determines which broker currently holds the RD Management Server role (configured FQDN → local host → discovered candidates) so the role cmdlets are targeted at the node that answers, even after an HA management-role failover. See [Active-Broker Resolution](#active-broker-resolution-ha-failover).
10. **Load module & probe** — imports the `RemoteDesktop` module, runs `Get-RDServer` against the **local host** to record whether this host is the active RD Management Server, and runs a deployment probe (`Get-RDCertificate`) against the resolved broker. If no broker/deployment is reachable, the role steps below are **skipped with a note** (not recorded as failures).
10a. **Passive-broker guard** — if the local host is **not** the active RD Management Server **and** it carries the Connection Broker role (detected by the presence of the `tssdis` service), the deployment-level role steps are **skipped with a note**. This prevents a duplicate certificate import when a single Agent Job targets both HA brokers at the same time: `Set-RDCertificate -ImportPath` always imports the PFX into the target broker's `LocalMachine\My` store, so the passive broker's call (routed to the active broker via `-ConnectionBroker`) would add a second copy on top of the active broker's own import, causing verification to fail. The active broker handles the deployment-level roles via its own job execution. *(Exception: a non-broker host — an RD Session Host or RD Web Access server — that has set `$RDS_Connection_Broker_FQDN` / AWR Parameter 1 is intentionally delegating to a remote broker; the `tssdis` service will not be present on those hosts, so the guard does not fire and `Set-RDCertificate` is called as configured.)*
11. For each enabled role — **RD Publishing / RD Web Access / RD SSO(Redirector)**:
    - Runs `Set-RDCertificate -Role <role> -ImportPath <pfx> -Password <secure> -Force` (adding `-ConnectionBroker <FQDN>` when configured). This imports the PFX into the deployment and distributes it to the role servers.
    - Verifies the result by reading it back with `Get-RDCertificate` and comparing thumbprints.
    - If the deployment reports that the role isn't present (`does not contain` / `does not exist`), that role is skipped with a note rather than failed.
    - Note (Web Access): the IIS HTTPS binding for the RD Web Access site may also need updating separately.

## Logging

All operations are logged with timestamps in the format `[yyyy-MM-dd HH:mm:ss] message`. Example:

```
[2026-07-13 10:30:01] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)
[2026-07-13 10:30:01] Legal notice accepted, proceeding with script execution.
[2026-07-13 10:30:02] PFX file exists: C:\path\to\certs\certificate.pfx
[2026-07-13 10:30:02] Certificate imported to LocalMachine\My. Thumbprint: A1B2C3D4E5...
[2026-07-13 10:30:03] certutil repair command completed
[2026-07-13 10:30:04] Updated RDP listener certificate thumbprint via WMI
[2026-07-13 10:30:05] Restarted Terminal Services (TermService)
[2026-07-13 10:30:06] RDS deployment detected - proceeding with deployment-level role certificates
[2026-07-13 10:30:07] Set-RDCertificate succeeded for role RDPublishing
[2026-07-13 10:30:07] Verified RDPublishing certificate is correctly applied
[2026-07-13 10:30:08] Script execution completed
```

## Error Handling

The script tracks failures in a list (`$RdsFailures`). Instead of stopping at the first problem, it records each failure, attempts the remaining roles, and reports the true outcome at the end.

### Exit Code 1 (Hard Stops)

Emitted immediately:

- `LEGAL_NOTICE_ACCEPT` is not `"true"`
- `DC1_POST_SCRIPT_DATA` is not set
- Base64 decode or JSON parse fails

### Exit Code 1 (Recorded Failures)

Any of the following are recorded and cause a **non-zero exit at the end of the run** (all failures are logged as a summary):

- PFX file not found, or no PFX password available
- Certificate import into `LocalMachine\My` fails
- `certutil -repairstore` returns a non-zero exit code or cannot be launched
- RDP listener WMI update fails, or `TermService` restart fails (when enabled)
- `Set-RDCertificate` fails for a reason other than the role/deployment being absent (when enabled)
- `Get-RDCertificate` verification fails or the applied thumbprint does not match (when enabled)
- The `RemoteDesktop` module is unavailable while a deployment role is enabled

### Graceful Skips (Not Failures)

- No RDS deployment detected — the deployment-wide role steps are skipped with a note; the local steps still count as a success
- No active management broker could be reached (and none configured) — the deployment-wide roles are skipped with a warning. Configure `$RDS_Broker_Candidates` / `$RDS_HA_Broker_DNS` to have failover handled automatically instead
- An enabled role isn't part of the deployment (`does not contain` / `does not exist`) — that role is skipped with a note
- This host is **not the active RD Management Server** and has the Connection Broker role installed (`tssdis` service present) — the deployment-wide role steps (Publishing / Web Access / SSO) are skipped with a note. This is the expected behaviour for the passive broker in a single Agent Job that targets both HA Connection Brokers, regardless of whether `$RDS_Connection_Broker_FQDN` / AWR Parameter 1 is set. The active broker applies these roles via its own execution.

### Clean Exit (Exit Code 0)

- All enabled steps completed (or were gracefully skipped) without recording a failure

## Common Configuration Examples

### Full RDS Deployment (run on the active management broker)

```powershell
$Install_RDP_Listener_Certificate    = $true    # affects this broker only
$Install_RDS_Publishing_Certificate  = $true
$Install_RDS_WebAccess_Certificate   = $true
$Install_RDS_SSO_Certificate         = $true
$RDS_Connection_Broker_FQDN          = ""       # empty = local (this) broker is the active management node
```

### HA Deployment — Single Agent Job Targeting Both Connection Brokers

No special configuration is required. Deploy the TLM Agent on both brokers and point the job at both hosts. The script automatically detects which broker is the active RD Management Server:

- **Active broker**: runs the full sequence (local import → RDP listener → `Set-RDCertificate` for Publishing / Web Access / SSO)
- **Passive broker**: runs the local steps only (local import → RDP listener); skips `Set-RDCertificate` to prevent a duplicate certificate import on the active broker

For HA management-role failover resilience, populate the broker candidates so the script can find the active node after a failover:

```powershell
$RDS_Broker_Candidates = @("rdsktcnb001.example.com", "rdsktcnb002.example.com")
# Or: $RDS_HA_Broker_DNS = "rds-cb.example.com"
```

### Deployment Roles Only (leave the broker's own RDP listener alone)

```powershell
$Install_RDP_Listener_Certificate    = $false
$Install_RDS_Publishing_Certificate  = $true
$Install_RDS_WebAccess_Certificate   = $true
$Install_RDS_SSO_Certificate         = $true
```

### RD Web Access Only

```powershell
$Install_RDP_Listener_Certificate    = $false
$Install_RDS_Publishing_Certificate  = $false
$Install_RDS_WebAccess_Certificate   = $true
$Install_RDS_SSO_Certificate         = $false
```

## Important Notes

- **HA management role**: The deployment-wide roles only succeed against the broker that currently holds the RD Management Server role. The script resolves this automatically (local host, then the configured candidates), so an HA management-role failover is handled without manual intervention **provided** `$RDS_Broker_Candidates` or `$RDS_HA_Broker_DNS` is populated. See [Active-Broker Resolution](#active-broker-resolution-ha-failover).
- **Single Agent Job targeting both HA brokers**: when one TLM job runs on both Connection Brokers simultaneously, the passive broker **automatically skips** the `Set-RDCertificate` deployment-level calls. Without this guard, `Set-RDCertificate -ImportPath` (run from the passive broker, routed to the active broker via `-ConnectionBroker`) would import the same certificate a second time into the active broker's `LocalMachine\My` store. The local PFX import, private-key repair, and RDP listener steps still run on both brokers. If you instead use **separate jobs per broker**, the guard still applies correctly and the behaviour is unchanged.
- **One call, whole deployment**: `Set-RDCertificate` distributes the certificate to the role servers, so the role steps only need to run once against the active broker — no PsExec/WinRM fan-out.
- **Session disruption**: Enabling `$Install_RDP_Listener_Certificate` restarts `TermService`, terminating active RDP sessions on this server. On a broker-only run this affects the broker itself and does not touch session hosts.
- **IIS binding for Web Access**: `Set-RDCertificate -Role RDWebAccess` configures the RDS role but may not update the IIS HTTPS binding. You may need a separate IIS binding update or combine this with the IIS certificate binding script.
- **Group Policy**: If GPO manages RDP certificates, the WMI-set listener value will be overridden on the next policy refresh.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.
