# DigiCert TLM Agent — Microsoft AD FS & Web Application Proxy Certificate Deployment (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that automates SSL certificate deployment to **Active Directory Federation Services (AD FS)** farm members and **Web Application Proxy (WAP)** servers. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script decodes the `DC1_POST_SCRIPT_DATA` payload, imports the delivered PFX into `LocalMachine\My`, grants the AD FS service account read access to the private key, and then applies the certificate to the role the host plays in the federation topology.

The same script is deployed to every server in the topology. A single AWR argument (**Role**) tells it which set of AD FS / WAP cmdlets to run on that host:

| Role | Where it runs | What it configures |
|---|---|---|
| `ADFS_PRIMARY` | The primary AD FS server (WID farm) or any node of a SQL farm | Service Communications certificate (farm-wide) **and** the SSL binding |
| `ADFS_SECONDARY` | Every other AD FS farm member | The local SSL binding only |
| `WAP` | Each Web Application Proxy server in the DMZ | The WAP SSL binding, with optional re-establishment of the proxy trust |

Script: [`adfs_certrenew_awr.ps1`](adfs_certrenew_awr.ps1)

## Architecture

### Typical topology

```
                              Internet / external clients
                                          │
                                          │ 443
                     ┌────────────────────▼────────────────────┐
     DMZ             │  Web Application Proxy server(s)        │
                     │  TLM Agent + script  ── Role: WAP       │
                     │  Set-WebApplicationProxySslCertificate  │
                     └────────────────────┬────────────────────┘
                                          │ 443 (federation passthrough)
  ────────────────────────────────────────┼─────────────────────────────────
                                          │
     Internal        ┌────────────────────▼────────────────────────────────────────┐
     network         │  AD FS farm                                                 │
                     │  ┌────────────────────────┐   ┌────────────────────────┐    │
                     │  │ Primary AD FS node     │   │ Secondary AD FS node   │ …  │
                     │  │ Role: ADFS_PRIMARY     │   │ Role: ADFS_SECONDARY   │    │
                     │  │ Set-AdfsCertificate    │   │ Set-AdfsSslCertificate │    │
                     │  │ Set-AdfsSslCertificate │   │                        │    │
                     │  └───────────┬────────────┘   └────────────────────────┘    │
                     │              │ writes farm configuration                    │
                     │              ▼                                              │
                     │      WID / SQL configuration database                       │
                     └─────────────────────────────────────────────────────────────┘
```

One public TLS certificate is used across the whole topology. Its Subject Alternative Names normally include the federation service name (for example `sts.example.com`), `certauth.sts.example.com` (certificate authentication), and `enterpriseregistration.example.com` (device registration). TLM issues or renews that certificate once and delivers the resulting PFX to every agent host that participates in the job; this script then applies it on each host according to its role.

### How the roles map onto AD FS behaviour

- **Service Communications certificate** is stored in the AD FS configuration database, so it only has to be set once, on a server that can write the configuration. In a WID farm that is the primary server. In a SQL farm any node can write. This is why only `ADFS_PRIMARY` calls `Set-AdfsCertificate -CertificateType Service-Communications`.
- **SSL binding** (`Set-AdfsSslCertificate`) is a per-host HTTP.sys binding. On Windows Server 2016 and later it is a multi-node cmdlet: run on the primary, it pushes the binding to every farm member over WinRM, but it requires the certificate to already be present in each member's `LocalMachine\My` store. The `ADFS_SECONDARY` role covers that requirement by importing the PFX locally, and it also sets the binding itself so that the deployment does not depend on WinRM remoting between nodes and still works on Windows Server 2012 R2, where the cmdlet is strictly local.
- **WAP** keeps its own SSL binding for the federation endpoint and for published applications that share the same certificate. `Set-WebApplicationProxySslCertificate` updates that binding. The proxy trust between WAP and AD FS uses a separate, automatically renewed trust certificate, so renewing the public SSL certificate does **not** normally break the trust. Re-establishing it with `Install-WebApplicationProxy` is optional and is only needed when the trust has already expired or been broken.

### Execution flow on each host

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
    ├── Legal notice check, decode + parse the payload, log the extraction summary
    ├── Locate the PFX (prefers the non-"_legacy" file when TLM delivers both)
    ├── Inspect the PFX with the delivered password (subject, thumbprint, validity)
    ├── Import the PFX into Cert:\LocalMachine\My (exportable), capture the thumbprint
    ├── Grant private-key Read to NT SERVICE\adfssrv and NETWORK SERVICE
    │
    ├── Role = ADFS_PRIMARY
    │     ├── Import-Module ADFS
    │     ├── Set-AdfsCertificate -CertificateType Service-Communications
    │     └── Set-AdfsSslCertificate
    ├── Role = ADFS_SECONDARY
    │     ├── Import-Module ADFS
    │     └── Set-AdfsSslCertificate
    └── Role = WAP
          ├── Import-Module WebApplicationProxy
          ├── Set-WebApplicationProxySslCertificate
          └── (optional) Install-WebApplicationProxy  ── re-establish proxy trust
    │
    ├── (optional) Restart services: adfssrv (AD FS) / apphostsvc + adfssrv (WAP)
    └── Final validation: certificate present in LocalMachine\My with a private key
```

## Use Cases

### Single AD FS server

One AD FS server, no WAP. One Agent job with `ADFS_PRIMARY`. The script sets both the Service Communications certificate and the SSL binding and restarts `adfssrv`.

### AD FS farm with WID (two or more nodes)

Create one Agent job per role, all enrolling the same certificate:

1. **Primary node**: `ADFS_PRIMARY`. Sets the Service Communications certificate in the configuration database and the SSL binding.
2. **Secondary nodes**: `ADFS_SECONDARY`. Imports the PFX locally and sets the local SSL binding. Secondaries pick up the Service Communications change through normal configuration synchronisation.

Run the primary job first. If the Windows Server 2016+ multi-node push over WinRM succeeds, the secondary jobs simply confirm the binding; if WinRM between nodes is blocked, the secondary jobs are what actually update the binding.

### AD FS farm with SQL Server

Same as above. Any node can write the configuration, so `ADFS_PRIMARY` can be assigned to whichever node is convenient. Use `ADFS_SECONDARY` on the rest.

### AD FS farm with Web Application Proxy in the DMZ

Add a third job for the WAP servers with `WAP`. Because the proxy trust is independent of the SSL certificate, leave `ReEstablishWapTrust` at `false`. Order of operations: AD FS primary, AD FS secondaries, then WAP, so that the proxy's backend already presents the new certificate when the proxy starts using it.

### WAP trust repair

If the proxy trust has lapsed (for example after a long outage), run the WAP job with `ReEstablishWapTrust=true` and `FederationServiceName` set. See the note under [Important Notes](#important-notes) about credentials: `Install-WebApplicationProxy` prompts for federation trust credentials, which an unattended Agent job cannot supply.

### Hybrid identity (Microsoft Entra ID / Microsoft 365 federation)

No additional steps are needed. Entra ID federation trust is based on the token-signing certificate, which this script does not touch. Only the SSL and Service Communications certificates are rotated.

## Prerequisites

- **DigiCert TLM Agent** installed on every AD FS and WAP server that should receive the certificate, with an AWR enrollment profile that produces PFX output
- The Agent runs with local administrator rights
- `ADFS_PRIMARY` / `ADFS_SECONDARY`: the **ADFS** PowerShell module (installed with the AD FS role). For `ADFS_PRIMARY` on a WID farm, the host must be the primary server
- `WAP`: the **WebApplicationProxy** PowerShell module (installed with the Remote Access / WAP role)
- The certificate's Subject Alternative Names cover the federation service name and, where used, the `certauth.` and `enterpriseregistration.` names
- If the AD FS service runs under a group Managed Service Account (gMSA) or a custom account, add that account to the private-key ACL list in the script (see [Private key permissions](#private-key-permissions))

## Configuration

### Legal Notice

The legal notice is accepted via a **string** value (must be the literal `"true"`):

```powershell
$LEGAL_NOTICE_ACCEPT = "true"   # Set to "true" to accept the legal notice and allow execution.
```

If this is not `"true"`, the script logs the reason and exits `1`.

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\adfs-wap-awr.log
```

The directory is created if it does not exist.

### AWR Parameters

All runtime behaviour is driven by the AWR arguments configured on the Agent job. No other edits to the script are required.

| Argument | Name | Values | Default | Description |
|---|---|---|---|---|
| `$ARGUMENT_1` | Role | `ADFS_PRIMARY`, `ADFS_SECONDARY`, `WAP` | `ADFS_PRIMARY` | Which cmdlets to run on this host. Case-insensitive |
| `$ARGUMENT_2` | FederationServiceName | FQDN, e.g. `sts.example.com` | empty | Required only when `ReEstablishWapTrust` is `true` |
| `$ARGUMENT_3` | RestartServices | `true` / `false` | `true` | Restart `adfssrv` (AD FS roles) or `apphostsvc` and `adfssrv` (WAP) after the binding change |
| `$ARGUMENT_4` | ReEstablishWapTrust | `true` / `false` | `false` | WAP only. Runs `Install-WebApplicationProxy` to re-create the proxy trust |

Whitespace is stripped from each argument. Boolean arguments that are not `true` or `false` cause the run to fail with a logged error.

### Private key permissions

After import, the script grants **Read** on the private key file to:

```powershell
Grant-PrivateKeyReadAccess -Thumbprint $thumbprint -Accounts @(
    "NT SERVICE\adfssrv",
    "NT AUTHORITY\NETWORK SERVICE"
)
```

Add your gMSA (`DOMAIN\gmsa-adfs$`) or custom service account to this list if AD FS does not run under the default virtual account. ACL failures are logged as warnings and do not abort the run, because `Set-AdfsSslCertificate` sets its own permissions on supported versions.

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string**:

```json
{
  "args": ["ADFS_PRIMARY", "sts.example.com", "true", "false"],
  "certfolder": "C:\\Program Files\\DigiCert\\TLM Agent\\certs\\sts.example.com_pfx_2026_06_04_14_44_10",
  "files": ["sts.example.com.pfx", "sts.example.com_legacy.pfx"],
  "password": "pfx-password"
}
```

The script extracts:

- **`certfolder`** + a `.pfx`/`.p12` entry in **`files`** — full path to the PFX. When TLM delivers both a modern and a `_legacy` PFX, the non-legacy file is preferred. If no listed file is usable, the folder is scanned for any PFX/P12 as a fallback
- **`password`** — PFX import password. The following field names are also accepted as fallbacks: `pfx_password`, `keystore_password`, `passphrase`. If none is present, the `DC1_PFX_PASSWORD` environment variable is used
- **`args`** — the four AWR parameters described above

## What the Script Does

### Common Steps (Always Run)

1. **Legal notice check** — exits `1` if `$LEGAL_NOTICE_ACCEPT` is not `"true"`
2. **Environment check** — exits `1` if `DC1_POST_SCRIPT_DATA` is not set
3. **Decode & parse** — Base64-decodes `DC1_POST_SCRIPT_DATA` and parses the JSON payload (exits `1` on failure). The payload is written to the log with the password masked
4. **Extract** — pulls the arguments, `certfolder`, PFX filename, and password from the JSON and logs an extraction summary
5. **Inspect** — if the PFX exists and a password is available, logs subject, issuer, thumbprint, serial, validity, signature algorithm, and whether a private key is present
6. **Folder listing** — logs every certificate-related file in the delivery folder for troubleshooting

### Deployment Steps

7. **Validate arguments** — normalises the role, applies defaults, and rejects invalid role or boolean values
8. **Locate PFX** — resolves the PFX path (payload entry first, folder scan as fallback)
9. **Import** — `Import-PfxCertificate` into `Cert:\LocalMachine\My` with the key marked exportable; selects the returned certificate that carries the private key and records its thumbprint
10. **Private key ACL** — grants Read on the key file to the configured service accounts (warnings only)
11. **Role-specific configuration**
    - `ADFS_PRIMARY`: `Set-AdfsCertificate -CertificateType Service-Communications`, then `Set-AdfsSslCertificate`; logs `Get-AdfsCertificate` and `Get-AdfsSslCertificate` afterwards
    - `ADFS_SECONDARY`: `Set-AdfsSslCertificate`; logs `Get-AdfsSslCertificate` afterwards
    - `WAP`: `Set-WebApplicationProxySslCertificate`; optionally `Install-WebApplicationProxy -CertificateThumbprint <tp> -FederationServiceName <fqdn>`
12. **Restart services** (if `RestartServices=true`) — `adfssrv` for AD FS roles; `apphostsvc` and `adfssrv` for WAP. A missing service is logged as a warning, not a failure
13. **Final validation** — confirms the certificate is present in `LocalMachine\My` with a private key and logs its details

## Logging

All operations are logged with timestamps in the format `[yyyy-MM-dd HH:mm:ss] message`. Example from an `ADFS_PRIMARY` run:

```
[2026-10-12 12:08:42] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format) - AD FS / WAP
[2026-10-12 12:08:42] Legal notice accepted, proceeding with script execution.
[2026-10-12 12:08:42] Raw JSON content (password masked):
[2026-10-12 12:08:42] {"args":["ADFS_PRIMARY","sts.example.com","true","false"],"certfolder":"...","files":["sts.example.com.pfx","sts.example.com_legacy.pfx"],"password":"********"}
[2026-10-12 12:08:42] ARGUMENT_1 extracted: 'ADFS_PRIMARY'
[2026-10-12 12:08:42] Multiple PFX/P12 files listed in payload: sts.example.com.pfx,sts.example.com_legacy.pfx
[2026-10-12 12:08:42] Extracted PFX_FILE: sts.example.com.pfx
[2026-10-12 12:08:42] Certificate thumbprint: 947761B576C6AA7D39CF3DB2863DA2318367EA40
[2026-10-12 12:08:42] Certificate has private key: Yes
[2026-10-12 12:08:42] Starting custom script section...
[2026-10-12 12:08:42] ========== ADFS/WAP AWR deployment started ==========
[2026-10-12 12:08:42] Role: ADFS_PRIMARY
[2026-10-12 12:08:43] Importing PFX into Cert:\LocalMachine\My: ...\sts.example.com.pfx
[2026-10-12 12:08:43] Imported certificate thumbprint: 947761B576C6AA7D39CF3DB2863DA2318367EA40
[2026-10-12 12:08:43] Granting read permission on private key to NT SERVICE\adfssrv
[2026-10-12 12:08:44] Setting AD FS Service Communications certificate.
[2026-10-12 12:08:45] Setting AD FS SSL certificate.
[2026-10-12 12:08:47] Restarting adfssrv service.
[2026-10-12 12:08:52] Final local certificate check:
[2026-10-12 12:08:52] ========== ADFS/WAP AWR deployment completed successfully ==========
[2026-10-12 12:08:52] Script execution completed
```

The PFX password is never written to the log. Only its length and a masked placeholder appear.

## Error Handling

### Exit Code 1 (Hard Stops)

Emitted immediately, before any change is made:

- `LEGAL_NOTICE_ACCEPT` is not `"true"`
- `DC1_POST_SCRIPT_DATA` is not set
- Base64 decode or JSON parse fails

### Exit Code 1 (Deployment Failures)

Any failure inside the deployment section is caught, logged with an `ERROR:` prefix, and the script exits `1` after writing its closing banners so TLM reports the job as failed:

- Invalid role, or a boolean argument that is not `true`/`false`
- `certfolder` missing or not found, or no PFX/P12 file available
- No PFX password in the payload and `DC1_PFX_PASSWORD` not set
- `Import-PfxCertificate` fails or returns no certificate with a private key
- `Import-Module ADFS` / `Import-Module WebApplicationProxy` fails (role not installed)
- Any `Set-Adfs*`, `Set-WebApplicationProxySslCertificate`, or `Install-WebApplicationProxy` cmdlet throws
- `ReEstablishWapTrust=true` without a `FederationServiceName`
- Final validation cannot find the certificate with a private key in `LocalMachine\My`

### Warnings (Not Failures)

- Private key ACL could not be updated for an account
- A service to restart (`adfssrv`, `apphostsvc`) is not installed on this host
- The PFX could not be inspected with the supplied password during the pre-flight step (the import step will still fail hard if the password is wrong)

### Clean Exit (Exit Code 0)

- All steps for the selected role completed and final validation passed

## Common Configuration Examples

AWR parameters are shown in the order `Role, FederationServiceName, RestartServices, ReEstablishWapTrust`.

### AD FS primary node

```
ADFS_PRIMARY, sts.example.com, true, false
```

### AD FS secondary nodes

```
ADFS_SECONDARY, sts.example.com, true, false
```

### WAP, normal renewal

```
WAP, sts.example.com, true, false
```

### WAP, repair the proxy trust (interactive context only)

```
WAP, sts.example.com, true, true
```

### Apply the certificate but leave services running (restart in a maintenance window)

```
ADFS_PRIMARY, sts.example.com, false, false
```

## Important Notes

- **Job ordering**: run the `ADFS_PRIMARY` job before the `ADFS_SECONDARY` and `WAP` jobs. The Service Communications certificate must be in the configuration database before secondaries sync it, and WAP should switch after the backend already presents the new certificate.
- **One certificate for the whole topology**: all jobs must enroll the same certificate. TLM delivers a separate PFX file to each agent, but the key pair and certificate are identical.
- **`Install-WebApplicationProxy` and credentials**: the cmdlet requires `-FederationServiceTrustCredential` (an account that is a local administrator on the AD FS servers). The script does not pass credentials, so in an unattended Agent job the cmdlet will fail or hang waiting for a prompt. Keep `ReEstablishWapTrust=false` for scheduled renewals. If you need unattended trust repair, extend `Configure-Wap` to build a `PSCredential` from a secure source and pass it explicitly.
- **Service restart impact**: restarting `adfssrv` briefly interrupts sign-in on that node. In a farm behind a load balancer, stagger the jobs or set `RestartServices=false` and restart during a maintenance window. On WAP, `apphostsvc` is also restarted.
- **Windows Server 2012 R2**: `Set-AdfsSslCertificate` is local-only on 2012 R2, so `ADFS_SECONDARY` jobs are mandatory on every secondary node. On 2016 and later they are still recommended because the multi-node push relies on WinRM between farm members.
- **Token-signing and token-decrypting certificates** are not touched. AD FS auto-rolls those by default, and they are not part of the SSL certificate lifecycle.
- **Exportable key**: the PFX is imported with `-Exportable` so that AD FS backup and `Set-AdfsSslCertificate` push scenarios keep working. Remove the flag in `Import-CertificatePfx` if your policy forbids exportable keys and the multi-node push is not used.
- **gMSA accounts**: add the gMSA to the ACL account list, otherwise the AD FS service may fail to start after the restart with a private-key access error (event ID 133 / 102).

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.
