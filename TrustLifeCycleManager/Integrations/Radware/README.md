# Radware Alteon Certificate Deployment

Post-script hooks for the [DigiCert TLM Agent](https://www.digicert.com/tls-ssl/certificate-lifecycle-management) that automatically deploy renewed certificates and private keys to a Radware Alteon load balancer via its REST API.

Two implementations are provided, both functionally equivalent:

| Script | Platform | TLM Agent host |
| --- | --- | --- |
| [`radware_alteon.sh`](./radware_alteon.sh) | Linux / macOS | bash 4+ |
| [`radware_alteon.ps1`](./radware_alteon.ps1) | Windows | PowerShell 5.1+ |

---

## How it works

The DigiCert TLM Agent invokes a post-script after each successful certificate issuance or renewal. It passes context to the script via:

1. **`DC1_POST_SCRIPT_DATA`** — a Base64-encoded JSON payload (env var) containing the certificate folder, file names, and a user-defined `args` array.
2. **Files on disk** — the certificate (`.crt`) and private key (`.key`) written to `certfolder`.

The script decodes the payload, reads both files, and POSTs them to the Alteon REST API:

```
POST https://{ALTEON_HOST}/config/sslcertimport?renew=1&id={CERT_ID}&type=certificate&src=txt
POST https://{ALTEON_HOST}/config/sslcertimport?renew=1&id={CERT_ID}&type=key&src=txt
```

Both requests use HTTP Basic auth, with the credential pre-encoded as Base64 and supplied via the `args` array.

### Execution flow

```
TLM Agent renewal event
        │
        ▼
DC1_POST_SCRIPT_DATA set, script invoked
        │
        ▼
1. Verify legal-notice acceptance
2. Decode Base64 → parse JSON
3. Extract args[0..2] + cert/key paths
4. Inspect cert (subject, issuer, validity, key type)
        │
        ▼
5. POST certificate PEM → Alteon
6. POST private key PEM → Alteon
        │
        ▼
Log result, exit 0 (success) or 1 (failure)
```

---

## Prerequisites

- DigiCert TLM Agent installed and configured to invoke post-scripts
- Network reachability from the TLM Agent host to the Alteon management interface (default HTTPS / 443)
- A pre-existing certificate entry on the Alteon with a known `id` to overwrite (the `renew=1` flag updates in place rather than creating a new entry)
- Alteon admin credentials Base64-encoded for HTTP Basic auth: `echo -n 'admin:password' | base64`

---

## Configuration

### TLM Agent `args` array

Both scripts read three positional arguments from the JSON `args` array. Configure these in the TLM Agent's post-script settings:

| Index | Variable | Purpose | Example |
| --- | --- | --- | --- |
| `args[0]` | `ARGUMENT_1` | Alteon IP or hostname | `alteon.example.com` |
| `args[1]` | `ARGUMENT_2` | Certificate ID on the Alteon | `web-prod-2026` |
| `args[2]` | `ARGUMENT_3` | Base64-encoded `user:password` for Basic auth | `YWRtaW46czNjcjN0` |

### Script-level settings

Both scripts expose two configuration variables at the top of the file:

| Setting | Bash | PowerShell | Default |
| --- | --- | --- | --- |
| Legal notice acceptance | `LEGAL_NOTICE_ACCEPT` | `$LEGAL_NOTICE_ACCEPT` | `"false"` |
| Log file path | `LOGFILE` | `$LOGFILE` | See below |

Default log paths:

```bash
# Linux
/home/admin/digicert-automation/radware/radware_alteon.log

# Windows
C:\Program Files\DigiCert\TLM Agent\log\radware_alteon.log
```

> **You must set `LEGAL_NOTICE_ACCEPT="true"`** before the script will run. The default `false` causes the script to log an error and exit immediately.

---

## Installation

### Linux

```bash
# Place the script where the TLM Agent expects it
sudo install -m 0750 -o admin -g admin radware_alteon.sh /home/admin/digicert-automation/radware/

# Create the log directory
sudo mkdir -p /home/admin/digicert-automation/radware/
sudo chown admin:admin /home/admin/digicert-automation/radware/

# Edit the script and accept the legal notice
sudo sed -i 's/LEGAL_NOTICE_ACCEPT="false"/LEGAL_NOTICE_ACCEPT="true"/' \
  /home/admin/digicert-automation/radware/radware_alteon.sh
```

### Windows

```powershell
# Copy the script to a fixed location
Copy-Item radware_alteon.ps1 'C:\Program Files\DigiCert\TLM Agent\scripts\'

# Ensure the log directory exists
New-Item -ItemType Directory -Force -Path 'C:\Program Files\DigiCert\TLM Agent\log\'

# Edit the script and set $LEGAL_NOTICE_ACCEPT = "true"
notepad 'C:\Program Files\DigiCert\TLM Agent\scripts\radware_alteon.ps1'
```

If PowerShell execution policy blocks the script, sign it or set the appropriate policy:

```powershell
Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned
```

---

## Logging

Every step writes a timestamped entry to the log file. Sensitive values (the auth token) are obfuscated as `xxx***` so logs can be shared safely.

Example output:

```
[2026-05-21 10:14:02] ==========================================
[2026-05-21 10:14:02] Starting DC1_POST_SCRIPT_DATA extraction script
[2026-05-21 10:14:02] ==========================================
[2026-05-21 10:14:02] Legal notice accepted, proceeding with script execution.
[2026-05-21 10:14:02] DC1_POST_SCRIPT_DATA is set (length: 412 characters)
[2026-05-21 10:14:02] JSON_STRING decoded successfully
[2026-05-21 10:14:02] ARGUMENT_1 (IP Address) extracted: 'alteon.example.com'
[2026-05-21 10:14:02] ARGUMENT_2 (Certificate ID) extracted: 'web-prod-2026'
[2026-05-21 10:14:02] ARGUMENT_3 (Auth Token) extracted: 'YWR***'
[2026-05-21 10:14:02] Total certificates in file: 1
[2026-05-21 10:14:02] Key type: RSA (BEGIN RSA PRIVATE KEY found)
[2026-05-21 10:14:03] Step 1: Importing certificate to Radware Alteon...
[2026-05-21 10:14:03] SUCCESS: Certificate imported successfully.
[2026-05-21 10:14:04] Step 2: Importing private key to Radware Alteon...
[2026-05-21 10:14:04] SUCCESS: Private key imported successfully.
[2026-05-21 10:14:04] Script execution completed
```

The PowerShell version additionally logs parsed certificate metadata (subject, issuer, validity dates, thumbprint, signature algorithm) using the .NET `X509Certificate2` class.

---

## Platform differences

While both scripts produce equivalent results, a few implementation details differ:

| Aspect | Bash | PowerShell |
| --- | --- | --- |
| HTTP client | `curl -k` | `Invoke-RestMethod` |
| SSL bypass | `curl -k` flag | Scoped override of `ServerCertificateValidationCallback`, restored in `finally` |
| JSON parsing | `grep -oP` regex | `ConvertFrom-Json` |
| Certificate inspection | `grep` on PEM markers | `X509Certificate2` with full metadata |
| Success detection | HTTP status code 200/201 | Response body regex (`error\|fail\|denied\|unauthorized`) |

The PowerShell version's scoped SSL callback override is the safer pattern — it restores the original callback in a `finally` block so other code running in the same session isn't affected. The bash version uses curl's per-invocation `-k` flag, which is naturally scoped.

---

## Troubleshooting

**Script exits immediately with "Legal notice not accepted"**
Set `LEGAL_NOTICE_ACCEPT="true"` (bash) or `$LEGAL_NOTICE_ACCEPT = "true"` (PowerShell) at the top of the script.

**`DC1_POST_SCRIPT_DATA environment variable is not set`**
The script is being run outside the TLM Agent context. To test manually, Base64-encode a sample JSON payload and export it:

```bash
export DC1_POST_SCRIPT_DATA=$(echo -n '{"certfolder":"/tmp/certs","files":["server.crt","server.key"],"args":["alteon.example.com","web-prod-2026","YWRtaW46czNjcjN0"]}' | base64 -w 0)
```

**HTTP 401 / `unauthorized` in response**
The `args[2]` token is wrong or doesn't match what the Alteon expects. Regenerate with `echo -n 'username:password' | base64` — make sure there's no trailing newline (the `-n` flag matters).

**HTTP 404**
The certificate ID in `args[1]` doesn't exist on the Alteon. The `renew=1` flag updates an existing entry — it does not create one. Create the certificate slot via the Alteon UI or CLI first, then let the script handle renewals.

**Certificate imports but the Alteon doesn't serve the new cert**
The Alteon caches loaded certificates. After import you may need to `apply` and `save` the configuration, or restart the relevant virtual service. Check your Alteon documentation for the specific apply/save workflow your firmware version requires.

---

## Security notes

- The Base64 auth token in `args[2]` is **not encryption** — it's reversible encoding. Anyone with read access to the TLM Agent config can recover the password. Use a dedicated service account with the minimum privileges needed to import certificates.
- Both scripts disable TLS verification when talking to the Alteon (`curl -k` / `ServerCertificateValidationCallback = {$true}`). This is standard practice for management interfaces using self-signed certs, but it means the script will silently accept a man-in-the-middle if the network between the TLM Agent and the Alteon isn't trusted.
- Private key contents are never written to the log. The auth token is obfuscated. Cert PEM contents are logged at debug levels only.

---

## License

Copyright © 2026 DigiCert. All rights reserved. See the legal notice at the top of each script for full terms.