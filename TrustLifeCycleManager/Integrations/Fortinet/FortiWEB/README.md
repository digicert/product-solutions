# FortiWeb Integration — Scripts

This folder contains the DigiCert TLM FortiWeb certificate automation and a companion inspection helper.

| File | Runs where | Purpose |
|------|-----------|---------|
| [`fortiweb-awr.sh`](fortiweb-awr.sh) | **TLM Agent** (automation) | Uploads a renewed certificate under a unique name and rotates every reference (policy / SNI / multi-cert group) to it, then deletes the old cert. See the [Fortinet README](../README.md#fortiweb-fortiweb-awrsh) for the full rotation behavior. |
| [`fortiweb-discovery.sh`](fortiweb-discovery.sh) | **Your workstation** (manual) | Read-only inspection of a FortiWeb appliance's certificate, server-policy, SNI and multi-cert configuration. |

> **Only `fortiweb-awr.sh` is executed by TLM.** TLM automation can carry a single script, and `fortiweb-awr.sh` is fully self-contained. `fortiweb-discovery.sh` is **never** uploaded to or run by TLM — it exists purely to help a human set up, verify and debug a FortiWeb environment.

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
export TOKEN="your-auth-token"      # same value TLM passes as Argument_2
chmod +x fortiweb-discovery.sh
```

All calls target `https://$FWB:8443/api/v2.0/...` and use `-k` (self-signed appliance certs are expected).

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
