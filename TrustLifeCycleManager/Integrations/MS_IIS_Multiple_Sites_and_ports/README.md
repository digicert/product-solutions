# DigiCert TLM Agent — IIS Multi-Site / Multi-Port Certificate Replacement (AWR Post-Enrollment Script)

A PowerShell post-enrollment script for **DigiCert Trust Lifecycle Manager (TLM) Agent** that re-points **every https binding across multiple IIS sites** at a newly enrolled certificate. Triggered via the TLM Agent's Admin Web Request (AWR) workflow, the script imports the delivered PFX into `LocalMachine\My`, then updates **both** places IIS stores an SSL binding — `applicationHost.config` *and* the `http.sys` SSL registration — before verifying the result three independent ways.

It is built for the case where several sites share one certificate and differ only by port, with each site carrying that certificate on both an SNI binding and a dedicated-IP binding:

| Site | Binding 1 (host name, SNI) | Binding 2 (dedicated IP) |
|---|---|---|
| `ws1-digicert-demo` | `*:9001:iis-01.digicert-demo.com` | `10.160.52.84:9001:` |
| `ws2-digicert-demo` | `*:9090:iis-01.digicert-demo.com` | `10.160.52.84:9090:` |
| `ws3-digicert-demo` | `*:9080:iis-01.digicert-demo.com` | `10.160.52.84:9080:` |
| `ws4-digicert-demo` | `*:9070:iis-01.digicert-demo.com` | `10.160.52.84:9070:` |

Both stores are updated **on purpose**: writing `applicationHost.config` alone leaves IIS Manager and `http.sys` disagreeing about which certificate is live, while `netsh` alone is silently reverted the next time IIS commits a configuration change. A pre-change snapshot and a ready-to-run rollback script are written before anything is modified.

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
    │
    ├── 1. Pre-flight ......... PFX present? load Microsoft.Web.Administration
    ├── 2. Import ............. PFX -> LocalMachine\My, chain -> LocalMachine\CA
    │                           expiry check + subject-CN safety check
    ├── 3. Enumerate .......... https bindings of the target sites
    │                           parse bindingInformation (IP:Port:Hostname) + sslFlags
    ├── 4. Snapshot ........... read current http.sys registrations
    │                           write snapshot-<stamp>.json + rollback-<stamp>.cmd
    ├── 5. Config ............. applicationHost.config: certificateHash /
    │                           certificateStoreName -> CommitChanges()
    ├── 6. http.sys ........... netsh http delete/add sslcert per selector
    │                           hostnameport=<host>:<port>  (SNI bindings)
    │                           ipport=<ip>:<port>          (IP bindings)
    ├── 7. Verify ............. re-read config + re-read http.sys + live TLS handshake
    └── 8. Retire ............. (optional) delete the replaced certificate
```

## Prerequisites

- **DigiCert TLM Agent** installed and configured with an AWR enrollment profile producing **PFX** output
- **IIS** installed on the target host — the script loads `%windir%\system32\inetsrv\Microsoft.Web.Administration.dll`
- The TLM Agent service must run as an account with **local administrator rights**. Writing `applicationHost.config` and modifying `http.sys` SSL bindings both require elevation
- **Windows PowerShell 5.1 or PowerShell 7** — see [PowerShell Compatibility](#powershell-compatibility)
- The target sites must already have their https bindings created. This script **re-points existing bindings**; it does not create them

## Configuration

All settings live in one block at the **top of the script**, directly under the logging configuration. The only exception is the AWR parameter override block, which necessarily sits further down — see [AWR Parameters](#awr-parameters).

### Legal Notice

The legal notice is accepted via a **string** value (must be the literal `"true"`):

```powershell
$LEGAL_NOTICE_ACCEPT = "true"   # Set to "true" to accept the legal notice and allow execution.
```

If this is not `"true"`, the script logs the reason and exits `1`.

### Settings

| Variable | Default | Description |
|---|---|---|
| `$IIS_TARGET_SITES` | 4 sites | Sites whose https bindings are re-pointed. Used when discovery mode is `List` |
| `$IIS_SITE_DISCOVERY_MODE` | `'List'` | `'List'` = only the sites above. `'AllHttps'` = every IIS site with at least one https binding |
| `$IIS_EXPECTED_SUBJECT_CN` | `'iis-01.digicert-demo.com'` | Safety net — abort before touching anything if the new certificate does not carry this CN. Set to `''` to disable |
| `$IIS_CERT_STORE_NAME` | `'My'` | Store under `LocalMachine` that receives the leaf certificate |
| `$IIS_IMPORT_CHAIN` | `$true` | Install intermediates found in the PFX into `LocalMachine\CA` |
| `$IIS_IMPORT_ROOT_CA` | `$false` | Also install a self-signed root found in the PFX into `LocalMachine\Root`. Off by default — silently altering the machine trust store should be a deliberate act |
| `$IIS_REMOVE_REPLACED_CERTS` | `$false` | Delete the certificate that was replaced, once nothing else references it |
| `$IIS_VERIFY_TLS_HANDSHAKE` | `$true` | Perform a live TLS probe of every endpoint after the change |
| `$IIS_DEFAULT_APPID` | `{4dc3e181-…}` | IIS's well-known `http.sys` appid. **Fallback only** — an existing binding's appid is always read back and preserved. See [Application ID](#application-id) |
| `$IIS_ROLLBACK_DIR` | `C:\ProgramData\DigiCert\iis-cert-rollback` | Destination for the pre-change snapshot and rollback script |

### AWR Parameters

Three settings can be overridden per job from the AWR profile, without editing the script:

| Parameter | Effect |
|---|---|
| **Parameter 1** | Comma-separated site list (e.g. `ws1-digicert-demo,ws2-digicert-demo`), or `ALL` / `*` to switch to `AllHttps` discovery |
| **Parameter 2** | Expected subject CN, or `NONE` to disable the CN safety check |
| **Parameter 3** | `REMOVEOLD` to delete the certificate that was replaced |

Arguments are whitespace-stripped during extraction, so **site names containing spaces** (e.g. `Default Web Site`) cannot be passed this way — leave those in `$IIS_TARGET_SITES`.

> **Why this block is not at the top of the file with everything else:** it reads `$ARGUMENT_1` … `$ARGUMENT_3`, which do not exist until `DC1_POST_SCRIPT_DATA` has been Base64-decoded and parsed. Hoisted to the top, the overrides would silently never fire. The block therefore stays immediately after argument extraction, with a pointer comment back to the configuration block.

### Log File

```
C:\Program Files\DigiCert\TLM Agent\log\awr-template-logfile.log
```

The **log directory is created automatically** on the first log call if it does not exist, so a fresh agent install still produces a log. If the directory cannot be created, or the file cannot be written, the script emits a PowerShell warning and continues rather than failing the deployment.

### Application ID

The `http.sys` appid is a GUID tag identifying the application that registered an SSL binding. It is not validated against a running process, but IIS Manager treats it as an ownership marker — which is why the script **reads the existing appid back and reuses it** rather than stamping one value everywhere.

`$IIS_DEFAULT_APPID` is used only when a selector has no prior `http.sys` registration at all. To confirm what your server uses:

```powershell
netsh http show sslcert
```

Or list the distinct appids in use, matching the GUID by shape so it also works on localised Windows builds:

```powershell
[regex]::Matches((netsh http show sslcert | Out-String),
  '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}'
) | ForEach-Object { $_.Value } | Sort-Object -Unique
```

## DC1_POST_SCRIPT_DATA Format

The TLM Agent sets the `DC1_POST_SCRIPT_DATA` environment variable as a **Base64-encoded JSON string**:

```json
{
  "certfolder": "C:\\path\\to\\certs",
  "files": ["certificate.pfx"],
  "password": "pfx-password",
  "args": ["arg1", "arg2", "arg3"]
}
```

The script extracts:

- **`certfolder`** + the first `.pfx`/`.p12` entry in **`files`** — full path to the PFX file
- **`password`** — PFX import password. These field names are also accepted as fallbacks: `pfx_password`, `keystore_password`, `passphrase`
- **`args`** — up to 15 optional arguments (`$ARGUMENT_1` … `$ARGUMENT_15`); the first three are consumed as described in [AWR Parameters](#awr-parameters)

**The chain comes only from the PFX.** Whatever DigiCert TLM bundled into the PKCS#12 is what gets installed — the script does not read the `.cer`/`.crt`/`.pem` files that may sit alongside it in `certfolder`. If the PFX is leaf-only, no chain certificates are installed and the run still succeeds.

## What the Script Does

### 1. Pre-flight

Confirms a PFX was delivered and exists on disk, then loads `Microsoft.Web.Administration` from `%windir%\system32\inetsrv\`, falling back to `Assembly::LoadFrom` if `Add-Type` fails. A missing DLL is reported as "IIS does not appear to be installed".

### 2. Import the New Certificate

Loads **every** certBag from the PFX into an `X509Certificate2Collection` using `MachineKeySet | PersistKeySet | Exportable`, then selects the newest certificate that has a private key as the leaf. Logs subject, CN, SAN, issuer, serial, thumbprint and validity window.

Three gates before anything is modified:

- **Expired certificate** → abort, nothing touched
- **Not-yet-valid certificate** → warning only, continues
- **Subject CN mismatch** against `$IIS_EXPECTED_SUBJECT_CN` → abort, nothing touched

The leaf goes to `LocalMachine\$IIS_CERT_STORE_NAME`. Chain certificates are sorted by comparing Subject to Issuer: a self-signed cert is treated as a root and **skipped** unless `$IIS_IMPORT_ROOT_CA` is `$true`; everything else goes to `LocalMachine\CA`. The store copy is then re-read to confirm it really carries a usable private key — an import that lands without one would leave IIS unable to serve it.

### 3. Enumerate the https Bindings

Reads the sites via `Microsoft.Web.Administration`, parsing each binding's `bindingInformation` (`IP:Port:Hostname`) and `sslFlags`. An empty or `*` IP is normalised to `0.0.0.0`.

The `sslFlags` value determines the `http.sys` selector:

- **SNI** (`sslFlags & 1`) with a host name → `hostnameport=<host>:<port>`
- otherwise → `ipport=<ip>:<port>`
- SNI enabled but **no** host name → treated as an IP:port binding, with a note in the log
- **Central Certificate Store** (`sslFlags & 2`) → **skipped**, with an explanatory log line. A CCS binding takes its certificate from the CCS file share, so the certificate must be published there instead

### 4. Snapshot and Rollback Artefacts

Reads the current `http.sys` registration for every unique selector, then writes two files to `$IIS_ROLLBACK_DIR`:

| File | Contents |
|---|---|
| `snapshot-<stamp>.json` | Every binding's site, `bindingInformation`, IP, port, host name, `sslFlags`, selector, previous config hash and store, previous `http.sys` hash, and appid |
| `rollback-<stamp>.cmd` | Runnable batch script: `netsh http delete/add sslcert` per selector restoring the previous hash, appid and store, plus `appcmd` commands restoring `certificateHash` / `certificateStoreName` in `applicationHost.config` |

A failure to write these is a **warning**, not a hard stop.

`netsh` output is parsed **by value** — 40 hex characters for the hash, a GUID for the appid — rather than by label, so registration reading also works on localised Windows builds where `netsh` translates its field names.

### 5. Update applicationHost.config

Sets `CertificateHash` and `CertificateStoreName` on every queued binding, then calls `CommitChanges()` **once**. Bindings already pointing at the new certificate in the right store are skipped. If nothing needed changing, nothing is committed. A failed commit aborts the run before `http.sys` is touched.

### 6. Update the http.sys SSL Registrations

Per unique selector, `netsh http delete sslcert` followed by `netsh http add sslcert`. Two behaviours worth knowing:

- If `http.sys` **already serves the new thumbprint** for a selector, the delete/add is skipped entirely — avoiding a needless handshake gap on a binding that is already correct
- On a failed `add`, the script immediately attempts to **restore the previous registration**. If that also fails, the log says explicitly that the selector now has no certificate and the rollback script should be run

### 7. Verification

Three independent checks, because each can pass while another fails:

1. **Config** — `applicationHost.config` is re-read through a *fresh* `ServerManager` and each binding's hash compared to the new thumbprint → `CONFIG OK` / `CONFIG FAIL`
2. **http.sys** — every selector re-queried via `netsh` → `HTTP.SYS OK` / `HTTP.SYS FAIL`
3. **Live TLS handshake** (when `$IIS_VERIFY_TLS_HANDSHAKE` is `$true`) — opens a real TLS connection and compares the served certificate's thumbprint → `TLS OK` / `TLS FAIL` / `TLS SKIPPED`

For the TLS probe, `0.0.0.0` / `*` is dialled as `127.0.0.1`. SNI bindings are probed with the binding's host name; IP bindings are probed using the IP literal as the SNI name, which suppresses the SNI extension so `http.sys` answers from the `ipport` registration — exactly the one under test.

**`TLS SKIPPED` is not counted as an error.** A stopped site or a firewall makes the endpoint unreachable without saying anything about the certificate; the config and `http.sys` checks are authoritative.

### 8. Retire the Replaced Certificate (Optional)

Only when `$IIS_REMOVE_REPLACED_CERTS` is `$true` **and zero errors were recorded**. Each previously bound thumbprint is checked against the full `netsh http show sslcert` output first and **kept** if it is still registered on any other endpoint. Removal failures are warnings.

## Logging

All operations are logged with timestamps in the format `[yyyy-MM-dd HH:mm:ss] message`:

```
[2026-08-03 10:30:01] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)
[2026-08-03 10:30:01] Legal notice accepted, proceeding with script execution.
[2026-08-03 10:30:02] IIS certificate replacement - START
[2026-08-03 10:30:02]   Site discovery mode : List
[2026-08-03 10:30:02]   Target sites        : ws1-digicert-demo, ws2-digicert-demo, ws3-digicert-demo, ws4-digicert-demo
[2026-08-03 10:30:02]   Expected subject CN : iis-01.digicert-demo.com
[2026-08-03 10:30:02]   Microsoft.Web.Administration is available
[2026-08-03 10:30:03]   PFX contains 3 certificate(s)
[2026-08-03 10:30:03]   Thumbprint   : AAAA1111BBBB2222CCCC3333DDDD4444EEEE5555
[2026-08-03 10:30:03]   CN safety check passed (iis-01.digicert-demo.com)
[2026-08-03 10:30:03]   Added AAAA1111... to LocalMachine\My (CN=iis-01.digicert-demo.com)
[2026-08-03 10:30:03]   Skipped self-signed root (set $IIS_IMPORT_ROOT_CA = $true to trust it): CN=DigiCert Global Root G2
[2026-08-03 10:30:03]   Verified in LocalMachine\My: private key present
[2026-08-03 10:30:04]   Site 'ws1-digicert-demo' (id 1, state Started)
[2026-08-03 10:30:04]     *:9001:iis-01.digicert-demo.com  sslFlags=1 (SNI)          current cert=9999888877776666555544443333222211110000
[2026-08-03 10:30:04]     10.160.52.84:9001:               sslFlags=0 (IP:port)      current cert=9999888877776666555544443333222211110000
[2026-08-03 10:30:04]   8 https binding(s) queued across 4 site(s)
[2026-08-03 10:30:05]   hostnameport=iis-01.digicert-demo.com:9001     cert=99998888... appid={4dc3e181-e14b-4a21-b022-59fc669b0914} store=My
[2026-08-03 10:30:05]   Pre-change snapshot written to C:\ProgramData\DigiCert\iis-cert-rollback\snapshot-20260803-103005.json
[2026-08-03 10:30:05]   Rollback script written to C:\ProgramData\DigiCert\iis-cert-rollback\rollback-20260803-103005.cmd
[2026-08-03 10:30:06]   ws1-digicert-demo / *:9001:iis-01.digicert-demo.com: 99998888... -> AAAA1111...
[2026-08-03 10:30:06]   Committed 8 binding change(s) to applicationHost.config
[2026-08-03 10:30:07]       netsh http delete sslcert hostnameport=iis-01.digicert-demo.com:9001 -> exit 0
[2026-08-03 10:30:07]       netsh http add sslcert hostnameport=iis-01.digicert-demo.com:9001 certhash=AAAA1111... appid={4dc3e181-...} certstorename=MY -> OK
[2026-08-03 10:30:08]   CONFIG OK   ws1-digicert-demo / *:9001:iis-01.digicert-demo.com
[2026-08-03 10:30:08]   HTTP.SYS OK   hostnameport=iis-01.digicert-demo.com:9001
[2026-08-03 10:30:09]   TLS OK        ws1-digicert-demo 127.0.0.1:9001 (SNI 'iis-01.digicert-demo.com')
[2026-08-03 10:30:10] IIS certificate replacement - END
[2026-08-03 10:30:10]   Errors           : 0
[2026-08-03 10:30:10] IIS certificate replacement completed successfully
[2026-08-03 10:30:10] Script execution completed (exit code 0)
```

## Error Handling

### Exit Code 1 (Hard Stops, Before Any Change)

- `$LEGAL_NOTICE_ACCEPT` is not `"true"`
- `DC1_POST_SCRIPT_DATA` is not set
- Base64 decode or JSON parse fails

### Aborts With Nothing Modified

These increment the error count and return before any binding is touched:

- No `.pfx`/`.p12` in the payload, or the file does not exist
- `Microsoft.Web.Administration.dll` missing or unloadable
- PFX unreadable — wrong password or corrupt file
- PFX contains no certificate with a private key
- Certificate has **expired**
- Subject CN does not match `$IIS_EXPECTED_SUBJECT_CN`
- Leaf certificate failed to import, or landed in the store **without** a private key
- No usable https bindings found across the target sites
- `applicationHost.config` commit failed

### Recorded Failures (Non-Zero Exit at the End)

The run continues and reports the true outcome:

- A named site in `$IIS_TARGET_SITES` does not exist on the server
- A binding's `bindingInformation` could not be parsed
- Staging a binding's certificate change threw
- `netsh http add sslcert` failed for a selector
- `CONFIG FAIL` / `HTTP.SYS FAIL` / `TLS FAIL` at verification
- A binding disappeared during the update

### Graceful Skips (Not Failures)

- A site has no https bindings — warning, skipped
- A binding uses the **Central Certificate Store** — skipped with an explanation
- A binding or selector is already serving the new certificate — skipped as a no-op
- `TLS SKIPPED` — endpoint unreachable (site stopped or firewalled)
- No chain certificates in the PFX, or a self-signed root skipped by policy
- Rollback artefacts could not be written — warning only

## Rollback

Every run writes a rollback script before making changes. To revert, run from an **elevated** command prompt:

```
C:\ProgramData\DigiCert\iis-cert-rollback\rollback-<stamp>.cmd
```

It restores the previous `http.sys` registrations (hash, appid and store) and the previous `applicationHost.config` values via `appcmd`. Selectors that had no registration before the change are deleted rather than restored. The matching `snapshot-<stamp>.json` records the same state in a readable form.

## PowerShell Compatibility

The script targets **Windows PowerShell 5.1 and PowerShell 7**, and deliberately avoids anything version-specific: no ternary `? :`, no `??`, no `?.`, no `&&` / `||` pipeline chains, no `class` / `enum` / `using`, and no PowerShell 7-only cmdlets or parameters. It also avoids the `WebAdministration` module entirely — that module needs `-SkipEditionCheck` under PowerShell 7 — and calls `Microsoft.Web.Administration` directly instead.

**One item to verify on the target server before standardising on PowerShell 7:** `Microsoft.Web.Administration.dll` is a .NET Framework assembly wrapping the AHADMIN COM interfaces. It loads natively under 5.1. Under PowerShell 7 (.NET Core) it normally loads too, but `ServerManager.CommitChanges()` has a history of edge-case failures on .NET Core. If it misbehaves, run the script via `powershell.exe -File` (5.1) instead of `pwsh.exe` — **no code change is required**.

Minor, no action needed: `-Encoding UTF8` writes a BOM under 5.1 and no BOM under 7, so a log appended to by both hosts may carry one stray BOM.

The script file itself is saved **UTF-8 with BOM**, matching the other AWR templates in this repository. Windows PowerShell 5.1 reads a BOM-less `.ps1` as Windows-1252, which would mangle the non-ASCII characters in the legal notice.

## Common Configuration Examples

### The four documented sites, full safety checks (default)

```powershell
$IIS_TARGET_SITES        = @('ws1-digicert-demo','ws2-digicert-demo','ws3-digicert-demo','ws4-digicert-demo')
$IIS_SITE_DISCOVERY_MODE = 'List'
$IIS_EXPECTED_SUBJECT_CN = 'iis-01.digicert-demo.com'
$IIS_REMOVE_REPLACED_CERTS = $false
```

### Every https site on the server, wildcard or multi-SAN certificate

```powershell
$IIS_SITE_DISCOVERY_MODE = 'AllHttps'
$IIS_EXPECTED_SUBJECT_CN = ''          # a wildcard CN will not match a specific host name
```

Or per job, without editing the script: **AWR Parameter 1** = `ALL`, **Parameter 2** = `NONE`.

### Replace and clean up the old certificate

```powershell
$IIS_REMOVE_REPLACED_CERTS = $true
```

Or per job: **AWR Parameter 3** = `REMOVEOLD`. Removal only runs if the whole run recorded zero errors.

### Config-only run, no live probing

```powershell
$IIS_VERIFY_TLS_HANDSHAKE = $false
```

Useful when the sites are stopped or firewalled and the `TLS SKIPPED` lines are just noise.

## Important Notes

- **Elevation is mandatory.** Both `applicationHost.config` and `http.sys` require it. Without it the run fails at the commit step, after the certificate has been imported but before any binding changed
- **Brief handshake gap.** Updating an `http.sys` registration is a delete followed by an add. Connections arriving in that window fail. Selectors already serving the new certificate are skipped, so a re-run is effectively free
- **Shared selectors are updated once.** Sites sharing a host name and port share one `http.sys` selector; the script deduplicates, so the delete/add happens once no matter how many sites reference it
- **Bindings must already exist.** Sites are re-pointed, never created. A site with no https binding is logged and skipped
- **CCS bindings need a different workflow.** Certificates for Central Certificate Store bindings must be published to the CCS file share
- **The CN safety check is the main guard against a mis-issued or wrong-profile certificate.** Disabling it (`''` or Parameter 2 = `NONE`) is correct for wildcard and multi-SAN certificates, but you lose that protection
- **Root certificates are not trusted silently.** A self-signed root inside the PFX is skipped unless `$IIS_IMPORT_ROOT_CA` is explicitly `$true`
- **The decoded JSON payload and a masked PFX password are written to the log.** Restrict access to the log directory accordingly

## Troubleshooting

| Symptom | Cause / Action |
|---|---|
| No log file at all | The log directory is created automatically; if that fails the script warns on the PowerShell warning stream. Check the agent service account's rights on `C:\Program Files\DigiCert\TLM Agent\log` |
| `ERROR: … Microsoft.Web.Administration.dll not found` | IIS is not installed on this host, or the script is running on the wrong server |
| `ERROR: Unable to load Microsoft.Web.Administration` | Most likely PowerShell 7 on .NET Core. Run via `powershell.exe` (5.1) — see [PowerShell Compatibility](#powershell-compatibility) |
| `ERROR: Safety check failed - expected CN …` | The enrolled certificate's CN differs from `$IIS_EXPECTED_SUBJECT_CN`. Nothing was modified. Fix the expected CN, or set Parameter 2 to `NONE` for a wildcard/multi-SAN certificate |
| `ERROR: Failed to commit applicationHost.config` | Not elevated, or another process holds the file. Confirm the agent service account is a local administrator |
| `CONFIG OK` but `HTTP.SYS FAIL` | The `netsh add` failed — check the exit code and message logged just above. This is the case the rollback script exists for |
| `HTTP.SYS OK` but `TLS FAIL` | Something else is answering on that IP and port, or the site is bound to a different certificate at another layer |
| `TLS SKIPPED` on every binding | Sites stopped, or a firewall is blocking the loopback probe. Not an error — the config and `http.sys` checks are authoritative. Set `$IIS_VERIFY_TLS_HANDSHAKE = $false` to silence |
| `ERROR: IIS site '…' does not exist` | Site name mismatch. Matching is case-insensitive but otherwise exact — no trimming beyond the whitespace stripping applied to AWR arguments, which is also why names containing spaces cannot be passed via AWR Parameter 1 |
| Bindings revert after a later IIS change | Indicates only `http.sys` was updated, not `applicationHost.config`. Both are written here — check the log for a commit failure |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice within the script for full terms.
