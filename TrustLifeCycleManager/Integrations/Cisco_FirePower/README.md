# DigiCert TLM — Cisco Firepower Management Center (FMC) Certificate Automation Script

Automated post-enrollment script that deploys certificates issued by **DigiCert Trust Lifecycle Manager (TLM)** into **Cisco Firepower Management Center (FMC)** as an **Internal Certificate object**, using the FMC REST API.

The script runs as an **Admin Web Request (AWR)** automation script on the DigiCert TLM Agent after a certificate is issued or renewed. It receives the certificate data through the `DC1_POST_SCRIPT_DATA` environment variable, authenticates to FMC and creates (or replaces) the certificate object.

> **Scope:** the script creates the certificate **object** in FMC (Objects > Object Management > PKI > Internal Certs). It does **not** assign the certificate to a policy, VPN or device, and it does **not** deploy configuration. Those remain separate steps.

---

## Contents

| Script | Target Product | Purpose |
| --- | --- | --- |
| `Cisco-FirePower_FMC_awr-v2.2.ps1` | Cisco Firepower Management Center | Import a TLM-issued certificate and private key as an Internal Certificate object, with optional replacement of an existing object of the same name |

---

## Prerequisites

- **DigiCert TLM Agent** installed on a Windows host, with post-delivery script execution enabled
- **Windows PowerShell 5.1** (PowerShell 7 also works)
- **TLS 1.2 or later** available on the TLM Agent host (Windows PowerShell 5.1 needs .NET Framework 4.5.2 or later; 4.6.2 or later is recommended)
- Network access from the TLM Agent host to the FMC management interface (HTTPS, default port 443)
- An FMC account with API access and permission to create and delete certificate objects
- In the TLM AWR destination: certificate delivery format **`.pem`** and a **Password for certificate files** set (this is the key passphrase)

---

## How It Works

```
DigiCert TLM issues or renews the certificate
        │
        ▼
TLM Agent writes the PEM file to the target path
        │
        ▼
TLM Agent sets DC1_POST_SCRIPT_DATA (base64-encoded JSON)
        │
        ▼
TLM Agent runs Cisco-FirePower_FMC_awr-v2.2.ps1
        │
        ▼
Script decodes the payload: arguments, certificate folder, files, key passphrase
        │
        ▼
Script reads the PEM, picks the leaf certificate, checks expiry and the private key
        │
        ▼
(DRY_RUN=true stops here, with no FMC calls)
        │
        ▼
Authenticate           POST /api/fmc_platform/v1/auth/generatetoken
        │
        ▼
(NAME_MODE=replace)    GET  .../object/internalcertificates       find an object with the same name
                       DELETE .../internalcertificates/{id}       delete it
        │
        ▼
Create the object      POST .../object/internalcertificates
        │
        ▼
Read it back           GET  .../internalcertificates/{id}
        │
        ▼
Log written. Exit code 0 on success, 1 on failure
```

The `DC1_POST_SCRIPT_DATA` variable contains a base64-encoded JSON object such as:

```json
{
  "certfolder": "C:\\certs\\example.com_pem_2026_10_19",
  "files": ["example.com.pem"],
  "args": ["<base64 username:password>", "fmc01.corp.com", "TLM-FMC-Cert", "NAME_MODE=replace"],
  "password": "key-passphrase"
}
```

---

## Script Configuration

Edit these values at the top of the script before deploying:

| Variable | Default | Description |
| --- | --- | --- |
| `$LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` for the script to run. Review the legal notice at the top of the script first. |
| `$script:LOGFILE` | `C:\Program Files\DigiCert\TLM Agent\log\fmc_awr.log` | Path of the log file. Can also be set with `LOGFILE=` in ARGUMENT_4. |

---

## Arguments

Enter these as separate parameters, in this order, in the post-delivery script settings of the TLM AWR destination.

| Position | Name | Required | Description |
| --- | --- | --- | --- |
| 1 | `FMC_CREDS_B64` | Yes | Base64-encoded `username:password` of the FMC account. No plaintext credentials are entered in TLM. |
| 2 | `FMC_HOST` | Yes | FMC hostname, IP or URL, with an optional `:port`. Examples: `fmc01.corp.com`, `10.0.0.5`, `https://fmc01.corp.com:443` |
| 3 | `CERT_NAME` | Yes | Name of the Internal Certificate object in FMC. See `NAME_MODE`. |
| 4 | `OPTIONS` | No | Optional settings as semicolon-separated `KEY=VALUE` pairs. See below. |

Create the value for ARGUMENT_1 on any machine with PowerShell. Use single quotes so special characters are not interpreted:

```powershell
[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('username:password'))
```

To check a value, decode it:

```powershell
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('<value>'))
```

> Base64 is an encoding, not encryption. It keeps the password out of plain text in the TLM screen, but anyone who can read the AWR settings can decode it. Use a dedicated FMC service account with only the permissions the script needs.

### Options (ARGUMENT_4)

Format: `KEY=VALUE;KEY=VALUE`, with no quotes or spaces. Unknown keys are ignored with a warning in the log.

| Option | Default | Description |
| --- | --- | --- |
| `NAME_MODE` | `timestamp` | How the FMC object is named and how existing objects are handled. See [Naming and renewals](#naming-and-renewals). |
| `SKIP_TLS_VALIDATION` | `false` | `true` accepts any FMC HTTPS certificate. **Lab use only.** With the default, the FMC certificate must be trusted by the TLM Agent host. |
| `DRY_RUN` | `false` | `true` validates the delivery (files, certificate, key, passphrase) and makes **no** FMC calls. Use it for the first test. |
| `DOMAIN_UUID` | from login | FMC domain UUID. By default it is read from the FMC login response. |
| `LOGFILE` | script default | Full path of the log file |

### Example

| Position | Value |
| --- | --- |
| 1 | `<base64 of username:password>` |
| 2 | `fmc01.corp.com` |
| 3 | `TLM-FMC-Cert` |
| 4 | `NAME_MODE=replace` |

For the first run, set ARGUMENT_4 to `DRY_RUN=true`, check the log, then change it for the real run.

---

## Naming and Renewals

FMC does not allow two objects with the same name, and it does not update the certificate of an existing Internal Certificate object through the API (a `PUT` returns success but leaves the certificate unchanged). The script therefore offers three naming modes:

| `NAME_MODE` | Object name | Behavior on renewal |
| --- | --- | --- |
| `timestamp` (default) | `<CERT_NAME>-yyyyMMdd-HHmmss` | Every run creates a **new** object. Nothing is deleted. Policies or devices that use an older object must be pointed at the new one, and old objects removed, separately. |
| `exact` | exactly `CERT_NAME` | Creates the object. If an object with that name already exists, FMC rejects the request and the run fails. |
| `replace` | exactly `CERT_NAME` | Finds the existing object with that name, **deletes it**, then creates a new object with the same name, the new certificate and the new key. If no object exists, it is created. |

### How `replace` behaves

1. **Lookup:** the script lists the Internal Certificate objects (paged) and finds the one with the exact name.
2. **Delete:** it deletes that object. If FMC refuses the delete (for example because the object is in use), the script **stops, changes nothing and creates nothing**. The log shows the FMC response.
3. **Create:** it creates the new object with the same name.
4. **Read back:** it reads the object from FMC and logs its name, subject, issuer and expiry date.

Things to be aware of with `replace`:

- The new object has a **new FMC object ID**. A policy or configuration that referenced the old object is not automatically moved to the new one.
- If the create fails after the delete, FMC has **no object with that name** until the script is run again (or the certificate is imported manually). The script logs this clearly and exits with code 1. The certificate, key and passphrase are checked on the TLM Agent host before anything is deleted, which makes this unlikely.
- `replace` needs delete permission on certificate objects for the FMC account.

---

## Certificate and Key Handling

- The script reads every `.pem`, `.crt`, `.cer` and `.key` file in the TLM delivery. It works with a single combined PEM (certificate and private key together) or with separate certificate and key files.
- If the delivery contains several certificates (a chain), only the **leaf** certificate (the one that is not the issuer of another certificate in the delivery) is sent to FMC. Import the issuing CA chain into FMC separately if FMC does not already trust it.
- If the private key is encrypted, the passphrase from the TLM payload is sent to FMC as `passPhrase`. If the key is encrypted and no passphrase is present, the script stops before contacting FMC.
- If the key is not encrypted, no passphrase is sent.
- The script stops if the certificate has expired, and warns if it is not yet valid.
- The certificate details (subject, issuer, serial, thumbprint, validity, SANs, key algorithm) are written to the log.

---

## TLS and .NET

- The script enables TLS 1.3 and TLS 1.2, falling back to TLS 1.2 only on runtimes that do not support TLS 1.3. It logs the protocols applied and the installed .NET Framework Release key (378389 = 4.5, 394802 = 4.6.2, 528040 = 4.8).
- By default the FMC HTTPS certificate is **validated** against the TLM Agent host's trust store. If FMC uses a self-signed or internal-CA certificate, install that certificate (or its CA) in the host's trusted root store. `SKIP_TLS_VALIDATION=true` is available for lab use only.

---

## FMC API Permissions Required

The FMC account needs API access and permission to:

- `POST /api/fmc_platform/v1/auth/generatetoken` (authenticate)
- `GET /api/fmc_config/v1/domain/{domainUUID}/object/internalcertificates` (list, used by `replace`)
- `DELETE /api/fmc_config/v1/domain/{domainUUID}/object/internalcertificates/{id}` (used by `replace`)
- `POST /api/fmc_config/v1/domain/{domainUUID}/object/internalcertificates` (create)
- `GET /api/fmc_config/v1/domain/{domainUUID}/object/internalcertificates/{id}` (read back)

---

## Log File

`C:\Program Files\DigiCert\TLM Agent\log\fmc_awr.log` (or the path set with `LOGFILE`)

Every step is logged with a timestamp, including the FMC response for each call (errors included). The password, key passphrase and access token are masked.

**Exit code:** `0` on success or a completed dry run, `1` on any failure.

---

## Common Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `Legal notice not accepted` | `$LEGAL_NOTICE_ACCEPT` is still `"false"` in the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | The script was not started by the TLM Agent post-delivery hook |
| `ARGUMENT_1 is not valid base64` | The credentials were entered as plain text. Encode `username:password` as shown above. |
| `Decoded ARGUMENT_1 has no ':' separator` | The base64 value does not decode to `username:password` |
| `No PEM files ... in the TLM delivery` | The delivery format in the AWR destination is not `.pem` |
| `No PEM private key block found` | The delivered files contain no private key. Check the delivery format and destination settings. |
| `private key is encrypted but no passphrase was found` | Set **Password for certificate files** on the TLM AWR destination |
| `Certificate expired` | The delivered certificate has already expired |
| Authentication fails with a TLS or trust error and `HINT: TLS/connection failure` | The FMC HTTPS certificate is not trusted by the TLM Agent host. Trust it on the host, or use `SKIP_TLS_VALIDATION=true` in a lab. |
| Authentication fails with `Could not create SSL/TLS secure channel` | The host cannot negotiate TLS with FMC. Check the `.NET Framework Release key` line in the log. A value below 378389 means TLS 1.2 is not available. Upgrade .NET Framework (4.6.2 or later), enable TLS 1.2 in Windows, or run under PowerShell 7. |
| `HTTP 401` on authentication | Wrong FMC username or password, or the account has no API access |
| `HTTP 401/403` on create or delete | The FMC account lacks permission to create or delete certificate objects |
| `HTTP 400/422` on create | An object with that name already exists (use `timestamp` or `replace`), the key does not match the certificate, or the passphrase is wrong. The FMC response in the log gives the reason. |
| `FMC would not delete the existing object` (`replace`) | FMC refused the delete, usually because the object is in use. Nothing was changed. |
| `previous object ... was already DELETED and the new one could NOT be created` (`replace`) | The create failed after the delete. Fix the cause shown above it in the log and run the script again. |
| Object created but not visible where expected | It is under **Objects > Object Management > PKI > Internal Certs**, not under **Devices > Certificates** |

---

## Notes

- Validated end to end on Windows PowerShell 5.1 against a Cisco FMC 7.7.12 (virtual) test system, including authentication, listing, creating, replacing and reading back the Internal Certificate object. Run `DRY_RUN=true` and then one real run on your own TLM Agent host and FMC before relying on it in production.
- The script does not assign the certificate to a policy, VPN or device and does not deploy configuration.
- FMC access tokens are valid for 30 minutes. A single run takes seconds.

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in the script for the full terms.
