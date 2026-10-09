# FortiWeb — Admin Web Request post-enrollment script

This folder contains the DigiCert TLM FortiWeb certificate automation script and a companion inspection helper. For the plugin-based alternative see [../extensibility-custom-plugins/README.md](../extensibility-custom-plugins/README.md).

| File | Runs where | Purpose |
|------|-----------|---------|
| [`fortiweb-awr.sh`](fortiweb-awr.sh) | **TLM Agent** (automation) | Uploads a renewed certificate under a unique name and rotates every reference (policy / SNI / multi-cert group) to it, then deletes the old cert. Full behaviour in [`fortiweb-awr.sh`](#fortiweb-awrsh) below. |
| [`fortiweb-discovery.sh`](fortiweb-discovery.sh) | **Your workstation** (manual) | Read-only inspection of a FortiWeb appliance's certificate, server-policy, SNI and multi-cert configuration. |

> **Only `fortiweb-awr.sh` is executed by TLM.** TLM automation can carry a single script, and `fortiweb-awr.sh` is fully self-contained. `fortiweb-discovery.sh` is **never** uploaded to or run by TLM — it exists purely to help a human set up, verify and debug a FortiWeb environment.

---

## `fortiweb-awr.sh`

### Overview

Uploads a certificate and private key to FortiWeb using its REST API and safely handles renewal by **rotating**, not overwriting. It runs as a **post-enrollment automation script** inside the DigiCert TLM Agent after a certificate is issued or renewed.

FortiWeb has two hard limitations that a naive "delete then re-import under the same name" approach cannot satisfy:

1. Importing a certificate under a name that already exists fails with a **duplicate** error.
2. A certificate that is **bound to any object cannot be deleted** while it is in use.

To work around both, the script:

1. **Uploads the new certificate under a unique name**: `<sanitised-CN>_<serial-suffix>` (FortiWeb derives the stored name from the uploaded file name, so the file is staged under this name). A duplicate error can therefore never occur.
2. **Identifies the previous certificate(s) for this domain** by reading each existing cert's real **subject CN from the API** (not by trusting the stored name), constrained to the **same key algorithm** (`pkey_type`). An RSA renewal never touches an ECC certificate of the same CN, and vice versa.
3. **Repoints every reference** from the old cert to the new one across all three ways FortiWeb can reference a local certificate (see below).
4. **Deletes the old certificate** only after every reference has been cleared **and** FortiWeb reports `can_delete: true` for it (a safety gate against reference types the script does not scan).

The result is a zero-downtime rotation: the new certificate is in place and bound before the old one is removed, and nothing is deleted while still in use.

### Prerequisites

- **DigiCert TLM Agent** installed and configured with post-enrollment script execution enabled
- Network access from the TLM Agent host to the FortiWeb REST API port
- **Bash** 4.0 or later, **curl** in `PATH`
- **python3** for subject-CN / key-algorithm matching and reference discovery (degrades gracefully to a name-convention fallback if absent)
- **openssl** CLI to extract the certificate Common Name, serial and key algorithm

### How it is triggered

The TLM Agent writes the cert + key to disk, sets `DC1_POST_SCRIPT_DATA` (Base64-encoded JSON with `certfolder`, `files` and `args`) and executes the script. See the [FortiGate script README](../../FortiGATE/admin-webrequest-post-script/README.md#how-it-is-triggered) for the payload structure, which is identical for every AWR script.

### Reference types handled

A FortiWeb local certificate can be referenced in three ways; the script scans and repoints all of them:

| # | Where the reference lives | Field repointed |
|---|---------------------------|-----------------|
| 1 | Server policy (direct / SSL fallback) | `server-policy/policy` → `certificate` |
| 2 | SNI configuration member (per-domain) | `system/certificate.sni` → member `local-cert` |
| 3 | Multi-certificate group (dual RSA/ECC/DSA on one hostname) | `system/certificate.multi-local` → `rsa-cert` / `ecc-cert` / `dsa-cert` |

### Script configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to allow execution |
| `LOGFILE` | `/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log` | Path to the script log file |

### Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

| Position | Variable | Required | Description |
|----------|----------|----------|-------------|
| 1 | `FORTIWEB_URL` | Yes | FortiWeb FQDN or IP. A bare host is preferred, but the script normalizes the input: a scheme (`https://`/`http://`), trailing slash/path, or `:port` are all stripped automatically. |
| 2 | `FORTIWEB_PORT` | No | FortiWeb REST API port. Defaults to **443** if left blank (or if a non-numeric value is supplied). |
| 3 | `AUTH_TOKEN` | Yes | FortiWeb authorization token |

No further arguments are required: the script auto-discovers every policy, SNI object and multi-cert group referencing the old certificate.

### Flow

```
1. Validate legal notice acceptance and DC1_POST_SCRIPT_DATA
2. Decode JSON, extract file paths and arguments
   (the auth token is identified here and redacted from all subsequent logging)
3. Extract the new cert's CN, serial and key algorithm using openssl
4. Stage the cert/key under a unique name (<sanitised-CN>_<serial>) in a temp dir
5. Snapshot the existing certificate list
6. POST /api/v2.0/system/certificate.local.import_certificate (multipart/form-data)
   - certificateFile = .crt, keyFile = .key, type = certificate
   - the staged private key is securely removed immediately after upload
7. Confirm the name FortiWeb assigned (list diff), then select previous certs
   for this domain by subject CN AND matching pkey_type
8. For each previous cert:
   a. Repoint any SNI member local-cert -> new name
   b. Repoint any multi-cert group rsa/ecc/dsa-cert -> new name
   c. Repoint any server policy certificate -> new name
   d. Re-check can_delete; if true, DELETE the old cert, else skip for manual review
9. Log result and exit
```

### FortiWeb API permissions required

The API token must have read/write access to these endpoints on the configured API port (Argument 2, default **443**):

- `GET  /api/v2.0/system/certificate.local`
- `POST /api/v2.0/system/certificate.local.import_certificate`
- `DELETE /api/v2.0/cmdb/system/certificate.local`
- `GET/PUT /api/v2.0/cmdb/server-policy/policy`
- `GET/PUT /api/v2.0/cmdb/system/certificate.sni` (and its `members` child table)
- `GET/PUT /api/v2.0/cmdb/system/certificate.multi-local`

### Notes

- **Unique naming:** the new cert is stored as `<sanitised-CN>_<serial>` (non-alphanumerics in the CN become `_`). The old certificate keeps whatever name it had; matching is by subject CN, so off-convention names (e.g. a cert manually stored as `tls`) are still found and rotated.
- **Algorithm scoping:** RSA (`pkey_type 1`) and ECDSA (`pkey_type 3`) certs sharing a CN are treated independently. The value is read from the freshly-uploaded cert's own list entry, so no algorithm codes are hardcoded.
- **Safety gate:** if a previous cert is still referenced by something the script does not scan, its `can_delete` stays `false`; the script logs the skip and leaves the cert in place for manual review rather than firing a delete that would fail.
- **Token redaction:** the `AUTH_TOKEN` (which base64-decodes to admin credentials) is masked as `***REDACTED***` in every log line, including the raw JSON dump.
- **Graceful degradation:** if `python3` is unavailable, CN/algorithm matching falls back to a cert-name convention and SNI/multi-cert members are detected but not auto-repointed (the safety gate still prevents unsafe deletion).

### Log file

`/opt/digicert/tlm_agent_3.1.9_linux64/log/fortiweb.log`

### Troubleshooting

| Symptom | Likely cause |
|---------|-------------|
| Script exits immediately with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is still `"false"` in the script |
| `DC1_POST_SCRIPT_DATA environment variable is not set` | Script was not triggered via the TLM Agent post-enrollment hook |
| HTTP 401 / 403 | Token incorrect, expired, or lacking permissions |
| HTTP 404 | Appliance URL or port is wrong, or the API path differs on this firmware (see version compatibility below) |
| Old cert skipped with `can_delete=false` | The old cert is still referenced by an object the script does not scan; repoint or unassign it manually, then it can be removed |
| "New cert uploaded but not bound" | On an initial import the cert is stored but not attached to any policy/SNI/group; bind it in FortiWeb, renewals then rotate it automatically |
| Certificate file not found | TLM Agent did not write the cert files before the script ran, or `certfolder` path is incorrect |

---

## Version compatibility

**Validated end-to-end against FortiWeb 8.0.5.** Every API call the rotation makes was confirmed against that version on real hardware.

It is **not inherently 8.x-only** — the API surface it uses is considerably older (per Fortinet's own CLI/REST documentation):

| Feature used | Available since |
|--------------|-----------------|
| `/api/v2.0/` REST API | FortiWeb 6.3 |
| `certificate.local` + `import_certificate` | 6.x |
| `system certificate sni` (+ `members` child table) | 5.3 / 6.x |
| `system certificate multi-local` (RSA/ECC/DSA groups) | 6.1 / 6.3 |
| `server-policy/policy` `certificate` field | 6.x |

So **7.x is expected to work largely as-is**, and possibly 6.4+, but only 8.0.5 is verified.

### What could differ on other versions

These behaviors were confirmed empirically on 8.0.5 and should be re-checked before trusting the script elsewhere:

1. **`pkey_type` codes** — observed RSA = `1`, ECDSA = `3`. The script reads the value from the new cert's own list entry (nothing hardcoded), but assumes the field is present and consistent within one appliance.
2. **`can_delete` field** — the pre-delete safety gate relies on it being present and meaning "in use."
3. **Filename-derived certificate naming** — that the stored name comes from the uploaded file name.
4. **Child-table addressing** (`certificate.sni/members?mkey=…&sub_mkey=…`) and the `{"data":{…}}` PUT body shape.
5. **JSON field names** (`local-cert`, `rsa-cert` / `ecc-cert`, `certificate`) — stable across versions in the CLI, but worth a glance.

### It fails safe

If any of the above differs on an older version, the script does **not** do damage: repoints return non-200 (logged), and the `can_delete` gate blocks deletion of anything still referenced. The worst case is a logged failed rotation — never a deleted or orphaned in-use certificate.

### Pre-flight for a new version

Run `fortiweb-discovery.sh` against the target appliance first. The `GET` outputs immediately reveal whether the paths, `pkey_type`, `can_delete` and field names match 8.0.5, and `sni-put-test` confirms the PUT body shape works — a few minutes of read-only checks before relying on the automation.

---

## `fortiweb-discovery.sh`

### What it's for

When configuring or troubleshooting the rotation, you often need to see the appliance's current state — what certificates exist, which policies/SNI members/multi-cert groups reference them, and the exact JSON field names the API returns. This script wraps the relevant `GET` calls (and one reversible `PUT` test) so you don't have to hand-craft `curl` commands or re-paste them.

It answers questions like:

- What name did FortiWeb store my certificate under, and is it in use (`can_delete`)?
- Which SNI member / multi-cert group references a given certificate?
- What are the member id and field names the rotation script needs to address?
- Does a certificate repoint (`PUT`) actually succeed on this firmware?

### Setup

```bash
export FWB="your-fortiweb-host"     # hostname or IP, no scheme, no port
export PORT="443"                  # optional; defaults to 443
export TOKEN="your-auth-token"      # same value TLM passes as Argument_3
chmod +x fortiweb-discovery.sh
```

All calls target `https://$FWB:$PORT/api/v2.0/...` (PORT defaults to 443) and use `-k` (self-signed appliance certs are expected).

### Commands

| Command | API call | Shows |
|---------|----------|-------|
| `certs` | `GET /system/certificate.local` | All local certs: `name`, `subject`, `pkey_type`, `can_delete`, validity |
| `policies` | `GET /cmdb/server-policy/policy` | All server policies |
| `policy <name>` | `GET /cmdb/server-policy/policy?mkey=<name>` | One policy in full (`certificate`, `sni-certificate`, `multi-certificate`, …) |
| `sni` | `GET /cmdb/system/certificate.sni` | SNI configuration objects |
| `sni-members <sni>` | `GET /cmdb/system/certificate.sni/members?mkey=<sni>` | Members of one SNI object: `id`, `domain`, `local-cert` |
| `multi-local` | `GET /cmdb/system/certificate.multi-local` | Multi-certificate (RSA/ECC/DSA) groups |
| `multi-local-obj <name>` | `GET /cmdb/system/certificate.multi-local?mkey=<name>` | One multi-cert group: `rsa-cert`, `ecc-cert`, `dsa-cert` |
| `all` | — | `certs` + `policies` + `sni` in one run |
| `sni-put-test <sni> <sub_mkey> <new-cert> <orig-cert>` | `PUT` then revert | Validates the SNI member repoint body format (reversible — see below) |

JSON output is pretty-printed when `python3` is available, otherwise passed through raw. The `GET <url>` line is printed to stderr so you can see exactly what was called.

### Examples

```bash
# What's on the box, and what's in use?
./fortiweb-discovery.sh certs

# Which cert does this SNI member point at, and what's its member id?
./fortiweb-discovery.sh sni-members test-sni

# Inspect a dual-algorithm (RSA + ECC) group
./fortiweb-discovery.sh multi-local-obj dual-multi

# Everything at once
./fortiweb-discovery.sh all
```

### The `sni-put-test` command

This is the **only** command that writes to the appliance, and it is reversible: it repoints an SNI member's `local-cert` to `<new-cert>`, prints the result, then immediately repoints it back to `<orig-cert>`. Use it to confirm the `{"data":{"local-cert":"..."}}` PUT shape works on your firmware before relying on the rotation script.

```bash
# Temporarily point member 1 of "test-sni" at another cert, then revert
./fortiweb-discovery.sh sni-put-test test-sni 1 some-other-cert original-cert
```

Both PUTs print their HTTP status; expect `HTTP:200` on each.

### Security

- `TOKEN` is read from the environment and used **only** in the `Authorization` header — it is never logged or echoed.
- The token base64-decodes to **admin credentials** — treat it as a password. Prefer a dedicated, least-privilege API admin.
- While `curl` runs, the token is briefly visible in the process list (`ps`) on a shared host. Avoid pasting captured output or shell history into shared channels.

---

## Setting up a test environment

To exercise the rotation script's paths against self-signed material, a typical setup is:

1. **Certificates** — upload one or more certs (RSA and/or ECC) for a test CN.
2. **SNI** — create a `system certificate sni` object with a member whose `local-cert` points at a cert.
3. **Multi-cert (optional)** — create a `system certificate multi-local` group with `rsa-cert` + `ecc-cert`, and point an SNI member at it via `multi-local-cert enable` / `multi-local-cert-group`.
4. **Server policy (optional)** — a Reverse-Proxy HTTPS policy that sets `certificate` (direct) or `sni enable` + `sni-certificate`.

Then renew via TLM and watch `fortiweb-awr.sh` rotate the references. Use the discovery commands above to confirm the before/after state (e.g. `sni-members`, `multi-local-obj`, `certs` to see the old cert removed).

---

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice embedded in each script for full terms.
