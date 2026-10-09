# FortiWeb Automation Plugin — Manual Test Runbook

This runbook reproduces, with `curl` and `openssl`, **every API call the plugin makes**, in the
order TLM would trigger them. Work through it against the target appliance **before uploading the
plugin to Trust Lifecycle Manager**: it confirms the endpoints, JSON field names and FortiWeb
behaviours the plugin relies on, and it leaves you with a clear before/after picture of the
certificate you want to replace.

The companion script [`runbook/fortiweb-runbook.sh`](runbook/fortiweb-runbook.sh) wraps each step
as a sub-command (`./runbook/fortiweb-runbook.sh <step>`), so you can run the whole procedure without
hand-crafting the calls. The raw `curl` is shown here so you can see exactly what happens.

| Runbook step | Plugin operation | What it proves |
|---|---|---|
| [0. Prepare](#0-prepare) | constructor (`AdapterConfig`) | token format, host/port |
| [1. Test connection](#1-test-connection) | `testConnection` | auth + certificate list access |
| [2. Discover](#2-discover-certificates-and-references) | `refreshConfiguration` | list fields, reference scan, PEM via SSH CLI |
| [3. Generate CSR](#3-generate-key--csr-sensor-side) | `generateCsr` | key/CSR format TLM will sign |
| [4. Import](#4-import-the-signed-certificate-under-a-unique-name) | `installCertificate` (identify target + import) | which certificate is replaced, multipart body, filename → name, list diff |
| [5. Rotate](#5-rotate-references-and-delete-the-old-certificate) | `installCertificate` (repoint + delete) | PUT bodies, `can_delete` gate, DELETE |
| [6. Validate](#6-validate) | `validateCertificate` | status / serial check |
| [7. Clean up](#7-clean-up-after-a-dry-run) | — | leave the appliance as you found it |

> **Scenario used throughout:** the appliance holds one self-signed local certificate named `cer`
> (CN `tlsguru.com`, `q_ref: 0`, `can_delete: true`) that is to be discovered and replaced with a
> TLM-issued certificate. Substitute your own names where they differ.

---

## 0. Prepare

You need the FortiWeb management host, REST API port, SSH port, an administrator account
(Read-Write on *System → Certificates* and *Server Policy*, CLI access allowed), and the ADOM
(`root` unless ADOMs are in use).

```bash
export FWB="ec2-18-117-71-27.us-east-2.compute.amazonaws.com"   # host only – no scheme, no port
export PORT="8443"                                              # 443 on a default appliance
export SSH_PORT="22"                                            # for step 2c
export FWB_USER="admin"
export FWB_PASS='********'
export VDOM="root"
```

**Build the API token exactly as the plugin does** (`AdapterConfig.authorizationToken()`): the base64
of the credential JSON, sent as the raw `Authorization` header value (no `Bearer`):

```bash
export TOKEN=$(printf '{"username":"%s","password":"%s","vdom":"%s"}' "$FWB_USER" "$FWB_PASS" "$VDOM" | base64 | tr -d '\n')
export BASE="https://${FWB}:${PORT}/api/v2.0"
alias fwb='curl -k -sS -H "Authorization: $TOKEN" -H "Accept: application/json"'
```

The token base64-decodes to admin credentials — treat it as a password, and prefer a dedicated
least-privilege account. `-k` mirrors the plugin's trust-all TLS (the appliance's management
certificate is self-signed). The same `TOKEN` also works with the existing `fortiweb-discovery.sh`.
The one-liner above does not JSON-escape quotes or backslashes in the password; if yours contains
any, use the helper script below, which escapes them the way the plugin does.

Or with the helper script (it builds the token from `FWB_USER`/`FWB_PASS`/`VDOM`, or uses `TOKEN` if set):

```bash
chmod +x runbook/fortiweb-runbook.sh
./runbook/fortiweb-runbook.sh token      # prints the decoded token JSON (password masked) and the base URL
```

## 1. Test connection

Plugin: `FortiWebAdapter.testConnection()` → `GET /system/certificate.local`.

```bash
fwb -w '\nHTTP:%{http_code}\n' "$BASE/system/certificate.local"
# helper: ./runbook/fortiweb-runbook.sh test
```

| Result | Meaning / plugin behaviour |
|---|---|
| `HTTP:200` with `{"results":[…]}` | OK — Test Connection in TLM will show **active** |
| `HTTP:401` / `403` | Wrong credentials or missing profile permission → `UNAUTHORIZED` |
| `HTTP:200` but body contains `"errcode": -N` | FortiWeb reports an error inside a 200 — the plugin treats this as failure (`FORTIWEB_API_ERROR`) |
| `curl: (6) Could not resolve host` / timeout | Host/port/network problem; check that `FWB` has no scheme and `PORT` is the management port |

## 2. Discover certificates and references

Plugin: `FortiWebAdapter.getConfigurationData()` — list (2a), reference scan (2b), certificate
bodies over SSH (2c); 2d covers the fallbacks the plugin tries when SSH yields nothing.

### 2a. Local certificate list

```bash
fwb "$BASE/system/certificate.local" | python3 -m json.tool
# helper: ./runbook/fortiweb-runbook.sh certs
```

Confirm each field the plugin reads (`FortiWebAdapter.parseCertificates`):

| Field | Used for | Example |
|---|---|---|
| `name` / `_id` / `mkey` | the certificate identity (alias round-tripped to TLM; `mkey` for PUT/DELETE) | `cer` |
| `subject` → `CN = …` | asset domain name; stable endpoint (`<cn>-<keytype>.<host>`); CN/SAN fallback when identifying the certificate to replace | `tlsguru.com` |
| `issuer` | self-signed detection (issuer == subject) | |
| `validFrom` / `validTo` | logged; `validTo` decides which of several same-CN certificates owns the canonical endpoint | `2027-09-21 10:24:42  GMT` |
| `serialNumber` | cross-check against the uploaded/issued leaf and against a PEM before it is trusted | `00 ` (self-signed) |
| `pkey_type` | key-type label in the endpoint (`rsa`/`ecc`); algorithm guard for multi-cert groups and CN/SAN matching (RSA = 1, ECDSA = 3 observed) | `1` |
| `q_ref` | number of objects referencing the cert | `0` = unused |
| `can_delete` | **pre-delete safety gate** | `true` |
| `status` | must be `OK` for validate | `OK` |

Expected for the scenario: one entry `cer`, self-signed, `q_ref: 0`, `can_delete: true`. The plugin
will report it with alias `cer` on the synthetic endpoint `tlsguru-com-rsa.<host>:443` (CN + key
type, so the endpoint survives the rename a renewal causes), domain `tlsguru.com`.

### 2b. Reference scan (who uses which certificate)

```bash
# server policies → "certificate" (direct binding); also note certificate-type / sni-certificate / multi-certificate
fwb "$BASE/cmdb/server-policy/policy" | python3 -m json.tool
for P in $(fwb "$BASE/cmdb/server-policy/policy" | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u); do
  echo "== policy $P"; fwb "$BASE/cmdb/server-policy/policy?mkey=$P" | grep -oP '"(certificate|certificate-type|sni-certificate|multi-certificate|vserver|https-service)"\s*:\s*"[^"]*"'
done

# SNI objects → members → "local-cert"
for S in $(fwb "$BASE/cmdb/system/certificate.sni" | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u); do
  echo "== sni $S"; fwb "$BASE/cmdb/system/certificate.sni/members?mkey=$S" | python3 -m json.tool
done

# multi-cert groups → rsa-cert / ecc-cert / dsa-cert
for G in $(fwb "$BASE/cmdb/system/certificate.multi-local" | grep -oP '"(?:mkey|name)"\s*:\s*"\K[^"]+' | sort -u); do
  echo "== multi-local $G"; fwb "$BASE/cmdb/system/certificate.multi-local?mkey=$G" | grep -oP '"(rsa|ecc|dsa)-cert"\s*:\s*"[^"]*"'
done
# helper: ./runbook/fortiweb-runbook.sh refs [certName]
```

Write down every reference to the certificate you will replace — step 5 must repoint each of them.
For the scenario (`q_ref: 0`) the expected result is **no references**; the plugin then skips the
repoint phase and only deletes `cer` after the import.

Check that the JSON field names match: `certificate` (policy), `id` + `local-cert` (SNI member),
`rsa-cert`/`ecc-cert`/`dsa-cert` (multi-local). If your firmware names them differently, the plugin's
scan will simply find nothing — and the `can_delete` gate will then block deletion — so this is the
moment to notice.

### 2c. Certificate body over SSH (required for the certificate to appear in TLM)

FortiWeb's REST list never contains the PEM, and TLM only inventories a certificate when it
receives one — without it you get the endpoint but nothing to select. The CLI
prints the body, so the plugin runs **one read-only command over SSH** with the same credentials:

```bash
ssh -p 22 "$FWB_USER@$FWB" "show system certificate local"
# helper: ./runbook/fortiweb-runbook.sh cli-certs        (needs SSH_PORT, default 22; prompts for the password)
```

Expected (verified on 8.0.5): one `edit "<name>"` block per certificate, containing
`set certificate "-----BEGIN CERTIFICATE-----…-----END CERTIFICATE-----"`. The private key follows
as `-----BEGIN ENCRYPTED PRIVATE KEY-----` and is ignored by the plugin. If the command works
non-interactively like this (no `--More--` pager, output ends with `end`), the plugin's exec-channel
path works; if the appliance only serves an interactive shell, the plugin falls back to one
automatically (after a 30 s exec timeout). Each PEM is only used when its serial matches the REST
list entry of the same name. The plugin log shows
`CLI 'show system certificate local' over SSH returned N certificate bod(y/ies): [...]`; the
`AcceptAllServerKeyVerifier … presented unverified EdDSA key` warning next to it is expected.

If SSH is disabled on the interface, enable it under *System → Network → Interface →
Administrative Access* or accept metadata-only discovery (set *FortiWeb SSH port* to `0`). A blank
or missing field means port 22, so a connector created before the field existed still uses SSH.

### 2d. Other ways to read the body (optional, informational)

The plugin also tries these before giving up; on 8.0.5 they do not work for imported certificates:

```bash
# (1) management API download/view candidates – on 8.0.5 they answer HTTP 500 with errcode -20007 / -20001
fwb -w '\nHTTP:%{http_code}\n' "$BASE/system/certificate.local.download?mkey=cer" | head -c 600; echo
fwb -w '\nHTTP:%{http_code}\n' "$BASE/system/certificate.local.view?mkey=cer" | head -c 600; echo

# (2) TLS handshake against the server policy VIP (only for a cert bound to a policy)
openssl s_client -connect <VIP>:<https-port> -servername tlsguru.com </dev/null 2>/dev/null | openssl x509 -noout -subject -serial
# helper: ./runbook/fortiweb-runbook.sh download-test cer ;  ./runbook/fortiweb-runbook.sh tls <VIP> <port> tlsguru.com
```

Both return `errcode -20007` / `-20001` on 8.0.5 (`./runbook/fortiweb-runbook.sh download-probe cer`
brute-forces the argument shape if you want to re-check on other firmware). Without SSH and without
a policy binding, the asset is surfaced **metadata-only**: TLM shows the endpoint but no certificate.

## 3. Generate key + CSR (sensor side)

Plugin: `FortiWebAutomationPluginHelper.generateCsrAndStoreKey()` — **no FortiWeb call**. The plugin
generates an RSA (default 2048) or EC key with the JDK and a PKCS#10 CSR (subject DN + SAN from TLM),
storing the PKCS#8 key at `<tmpdir>/FortiWebAutomationPlugin/<flowId>/request.key` (mode 600).
Reproduce with OpenSSL:

```bash
mkdir -p work && cd work
openssl req -new -newkey rsa:2048 -nodes -keyout request.key -out request.csr \
  -subj "/CN=tlsguru.com/O=Digicert/L=Lehi/ST=Utah/C=US" \
  -addext "subjectAltName=DNS:tlsguru.com,DNS:www.tlsguru.com"
openssl req -in request.csr -noout -verify -subject -text | grep -E "Subject:|DNS:|Public Key Algorithm"
# helper: ./runbook/fortiweb-runbook.sh csr tlsguru.com tlsguru.com,www.tlsguru.com
```

Then obtain the signed certificate:

- **Real run:** submit `request.csr` to TLM/DigiCert and save the issued leaf as `signed.crt` (and
  the intermediate as `ica.crt`). Import the DigiCert intermediate once under *System →
  Certificates → Intermediate CA* — the plugin does not manage intermediates.
- **Dry run (import mechanics only):** self-sign the CSR so you have a certificate + matching key to
  push through the API without spending an order:

  ```bash
  openssl x509 -req -in request.csr -signkey request.key -days 30 -out signed.crt \
    -copy_extensions copyall 2>/dev/null || openssl x509 -req -in request.csr -signkey request.key -days 30 -out signed.crt
  # helper: ./runbook/fortiweb-runbook.sh selfsign
  ```

## 4. Import the signed certificate under a unique name

Plugin: `ReplacementResolver.resolve()` (4a) and `FortiWebAdapter.installCertificate()` steps 1–2
(4b–4d).

### 4a. Identify the certificate being replaced

The install request from TLM carries three identifiers for the certificate being renewed, and they
are not always consistent: the alias `virtualServerName` (`<partition>/<name>`), the SHA-256
`currentCertificateThumbprint`, and the endpoint `ipAddress`. The alias can be **stale** — TLM keeps
the alias it first discovered while every FortiWeb renewal creates a new object name — so the plugin
resolves the target through a chain and accepts only names that exist on the appliance:

| Order | Rule | Manual equivalent |
|---|---|---|
| 1 | explicit `certificateName` override | — |
| 2 | alias from `virtualServerName` | is that name in the step 2a list? |
| 3 | `currentCertificateThumbprint` vs the SHA-256 of each body from step 2c | see below |
| 4 | certificate whose stable endpoint equals the request's `ipAddress` | `<cn>-<keytype>.<host>` from step 2a |
| 5 | certificates whose CN equals the new leaf's CN or one of its SAN DNS names, same key algorithm | compare `subject` CNs with `openssl x509 -in signed.crt -noout -subject -ext subjectAltName` |

To reproduce rule 3 by hand, fingerprint the bodies from the CLI output and compare with the
thumbprint TLM logged (`Current certificate thumbprint reported by TLM: …`):

```bash
ssh -p "$SSH_PORT" "$FWB_USER@$FWB" "show system certificate local" \
  | awk '/edit "/{name=$2} /BEGIN CERTIFICATE/,/END CERTIFICATE/{print > ("cli_" name ".pem")}'
for f in cli_*.pem; do echo "$f: $(openssl x509 -in "$f" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)"; done
```

The install log states the outcome as `Installing certificate '…' … replacing [<names>] - selected
by: <rule>`. If it says `replacing <nothing - initial import>` together with a `WARN`, none of the
rules matched: the new certificate is imported but nothing is repointed or deleted.

### 4b. Compute the unique name

`CertificateAttributesUtil.buildUniqueName`: sanitised CN (`[^A-Za-z0-9_]` → `_`) + `_` + the **last
12 hex digits of the serial**, truncated so the whole name is ≤ 35 characters.

```bash
CN=$(openssl x509 -in signed.crt -noout -subject | sed -n 's/.*CN\s*=\s*//p' | sed 's/[,/].*//; s/\s*$//')
SERIAL=$(openssl x509 -in signed.crt -noout -serial | cut -d= -f2 | tr 'A-F' 'a-f')
NEW_NAME="$(echo "$CN" | sed 's/[^A-Za-z0-9]/_/g')_$(echo "$SERIAL" | tail -c 13)"
echo "New certificate name: $NEW_NAME"     # e.g. tlsguru_com_0a1b2c3d4e5f
# helper: ./runbook/fortiweb-runbook.sh name signed.crt
```

Check it is not already in the list from step 2a (the plugin appends `_2`, `_3`… if it is).

### 4c. Stage the files under that name and upload

FortiWeb derives the stored object name from the **uploaded file name**, so the staged file names matter.

```bash
cp signed.crt "$NEW_NAME.crt"; cp request.key "$NEW_NAME.key"; chmod 600 "$NEW_NAME.key"
curl -k -sS -X POST "$BASE/system/certificate.local.import_certificate" \
  -H "Authorization: $TOKEN" -H "Accept: application/json" \
  -F "certificateFile=@$NEW_NAME.crt" -F "keyFile=@$NEW_NAME.key" \
  -F "type=certificate" -F "hsm=undefined" -F "password=undefined" \
  -w '\nHTTP:%{http_code}\n'
# helper: ./runbook/fortiweb-runbook.sh import signed.crt request.key "$NEW_NAME"
```

| Result | Plugin behaviour |
|---|---|
| `HTTP:200`, body `{ "_id": "<name>" }` (observed on 8.0.5) | import accepted → continue |
| `HTTP:400` | cert/key invalid or mismatched, **or the name already exists** → `CERTIFICATE_IMPORT_ERROR` |
| `HTTP:401` | token rejected → check step 1 |
| 2xx with `"errcode": -N` (number or string) | treated as failure (message surfaced to TLM) |

On a TLM retry the plugin recognises its own earlier import (same name, same serial), skips the
upload and only re-runs the rotation.

### 4d. Confirm the stored name and serial

```bash
sleep 1
fwb "$BASE/system/certificate.local" | python3 -m json.tool | grep -E '"(name|serialNumber|pkey_type|status|can_delete|q_ref)"'
# helper: ./runbook/fortiweb-runbook.sh confirm "$NEW_NAME"
```

Expected: a new entry whose `name` equals `$NEW_NAME`, `status: OK`, `serialNumber` equal to the
leaf's serial (compare numerically — FortiWeb may print spaces/leading zeros), `pkey_type` `1` for
RSA. The plugin identifies the new certificate by **list diff** (names present now that were absent
before), so also confirm nothing else changed.

## 5. Rotate references and delete the old certificate

Plugin: `FortiWebAdapter.installCertificate()` step 3–4. `OLD` is the certificate identified in 4a
(`cer` in the scenario), `NEW=$NEW_NAME`.

### 5a. Repoint every reference found in step 2b

The PUT body shape is always `{"data":{"<field>":"<new cert>"}}`; expect `HTTP:200` on each.

```bash
# server policy bound directly to the cert
curl -k -sS -X PUT "$BASE/cmdb/server-policy/policy?mkey=<policy>" -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" --data "{\"data\":{\"certificate\":\"$NEW_NAME\"}}" -w '\nHTTP:%{http_code}\n'

# SNI member (id from step 2b)
curl -k -sS -X PUT "$BASE/cmdb/system/certificate.sni/members?mkey=<sni>&sub_mkey=<id>" -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" --data "{\"data\":{\"local-cert\":\"$NEW_NAME\"}}" -w '\nHTTP:%{http_code}\n'

# multi-cert group slot – ONLY the slot matching the new cert's algorithm (rsa-cert for RSA)
curl -k -sS -X PUT "$BASE/cmdb/system/certificate.multi-local?mkey=<group>" -H "Authorization: $TOKEN" \
  -H "Content-Type: application/json" --data "{\"data\":{\"rsa-cert\":\"$NEW_NAME\"}}" -w '\nHTTP:%{http_code}\n'
# helper (finds and repoints all references of OLD): ./runbook/fortiweb-runbook.sh repoint cer "$NEW_NAME"
```

For the scenario there are none — skip to 5b. If a PUT fails, the plugin leaves the old certificate
in place and reports the install as failed; fix the cause (usually profile permissions or a field
name) and re-run.

Re-verify with step 2b that nothing points at `OLD` any more. Wait ~2 seconds (the plugin does).

### 5b. Safety gate, then delete

```bash
fwb "$BASE/system/certificate.local" | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(n, "can_delete=",c.get("can_delete"), "q_ref=",c.get("q_ref"))' cer
# helper: ./runbook/fortiweb-runbook.sh candelete cer
```

Only if `can_delete=true` (the plugin also accepts `q_ref=0` when `can_delete` is absent):

```bash
curl -k -sS -X DELETE "$BASE/cmdb/system/certificate.local?mkey=cer" -H "Authorization: $TOKEN" -w '\nHTTP:%{http_code}\n'
fwb "$BASE/system/certificate.local" | grep -c '"name": *"cer"'   # expect 0
# helper: ./runbook/fortiweb-runbook.sh delete cer
```

If `can_delete` is still `false` after your repoints, some object the plugin does not scan references
the certificate. Find it in the GUI (*System → Certificates → Local Certificate → reference column*)
— the plugin would leave the certificate in place with a `SKIP delete` warning in the log, and the
install still succeeds. Tick *Keep the replaced certificate* on the connector if you never want
automatic deletion.

## 6. Validate

Plugin: `FortiWebAdapter.validateCertificate()` → the new certificate must be listed with
`status: OK` and (when comparable) the serial must equal the issued leaf's serial. The name to check
comes from the flow record written at install (`flow.json`); if that is missing, from
`certificateName` / `virtualServerName`, or by matching TLM's `certificateSerialNumber` against the
list. The PEM returned to TLM is the leaf recorded at install, else the body read over SSH.

```bash
fwb "$BASE/system/certificate.local" | python3 -c '
import sys,json; n=sys.argv[1]
for c in json.load(sys.stdin).get("results",[]):
    if c.get("name")==n: print(json.dumps({k:c.get(k) for k in ("name","status","serialNumber","validFrom","validTo","pkey_type","q_ref","can_delete")}, indent=2))' "$NEW_NAME"
openssl x509 -in signed.crt -noout -serial -enddate
# helper: ./runbook/fortiweb-runbook.sh validate "$NEW_NAME" signed.crt
```

If the certificate is bound to a policy, also confirm what the data plane serves:

```bash
openssl s_client -connect <VIP>:<https-port> -servername tlsguru.com </dev/null 2>/dev/null | openssl x509 -noout -serial -subject
```

## 7. Clean up after a dry run

If you used a self-signed `signed.crt` in step 3, remove the test certificate and restore any
references you repointed (the reverse PUTs from 5a), then delete the local key material:

```bash
curl -k -sS -X DELETE "$BASE/cmdb/system/certificate.local?mkey=$NEW_NAME" -H "Authorization: $TOKEN" -w '\nHTTP:%{http_code}\n'
cd .. && rm -rf work
```

---

## Running the real thing in TLM

1. Build (`./build.sh`) and upload `plugin-dist/fortiweb-automation-plugin-1.0.0.zip` as a custom
   automation plugin in TLM; select `configuration.json` for the connector UI. Re-upload both
   whenever either changes.
2. Create the connector (host, REST port, username, password / PAM, ADOM, SSH port — blank means
   22, `0` disables SSH) and run **Test Connection** (= step 1). The first log line
   `Loaded extended configuration: host=… port=… sshPort=… username=…` confirms every field arrived;
   a `null` there means the UI field is not reaching the plugin.
3. Run **Refresh / discovery** on the connector and check *Inventory → Endpoints*: expect one
   endpoint per FortiWeb certificate, e.g. `tlsguru-com-rsa.<host>:443` with common name
   `tlsguru.com` and alias `cer`, and the certificate itself listed under it (= step 2). The plugin
   log should show
   `Certificate body for 'cer' read from the CLI over SSH` and `pem=yes` on the discovery line; if
   it shows `pem=no`, check the SSH warning just above it.
4. Select the discovered `cer` asset, request a certificate. TLM calls `generateCsr` (= step 3),
   issues the certificate, calls `installCertificate` (= steps 4–5) and `validateCertificate`
   (= step 6). In the install log expect `replacing [cer] - selected by: asset alias …`, the
   repoint `PUT`s for any references, the `can_delete` check and `SUCCESS: old certificate 'cer'
   deleted`. Re-run discovery: the same `tlsguru-com-rsa.<host>:443` endpoint now carries the new
   certificate with alias `tlsguru_com_…`; `cer` is gone.
5. Later renewals: keep the **same CN** so the endpoint stays stable. TLM may still round-trip the
   previous alias; the plugin then reports `selected by: SHA-256 thumbprint reported by TLM` (or the
   endpoint / subject rule) and rotates the right certificate anyway. Re-run discovery after each
   renewal so TLM refreshes the alias.

### Where to look when something fails

- **Plugin log on the sensor** — every API call is logged as `VERB /path -> HTTP status`, plus the
  reference scan, the name FortiWeb stored, each repoint and the `can_delete` check. The password /
  token is never logged.
- **Flow directory** `<java.io.tmpdir>/FortiWebAutomationPlugin/<flowId>/`: `request.csr`,
  `request.key` (present only between CSR and a successful install) and `flow.json` (what install
  recorded for validate).
- **Install imported the new certificate but the policy still serves the old one** → look for
  `Installing certificate '…' … replacing [...] - selected by: <rule>`. If it says `replacing
  <nothing>` with a `WARN` that no certificate could be identified, TLM sent a stale alias and
  neither the thumbprint (needs SSH), the endpoint nor the CN/SAN matched. Re-run discovery so TLM
  refreshes the alias, or set `certificateName` explicitly, then renew again.
- **`FortiWeb username is empty` right after `Loaded extended configuration: … username=null`** →
  the connector UI field is not reaching the plugin. TLM only delivers the account as
  `config_attributes.userName` (camelCase); check `configuration.json` was re-uploaded after any
  change and that the connector was saved with a value in that field.
- **Discovery shows `pem=no`** → the line above it says why: `SSH disabled on the connector` (SSH
  port set to `0`), or `Could not read certificate bodies from the FortiWeb CLI over SSH (...)` with
  the SSH error (port closed, SSH not enabled on the interface, wrong credentials). Without a PEM the
  endpoint appears in TLM but no certificate can be selected.
- **Expected noise:** the SLF4J "multiple providers" warning, SSHD's `presented unverified EdDSA
  key` warning, and `HTTP 500 … errcode -20007` from the REST download attempts during discovery.
- **Common causes:** `401` → account/profile; `400` on import → cert/key mismatch or name collision;
  `Could not resolve host` → scheme typed into the host field (the plugin strips it, curl does not);
  `can_delete=false` → an unscanned object still references the old certificate.

---

## Appendix A — a minimal test policy to exercise the repoint

To test a replacement of a certificate that is **in use**, bind it to a reverse-proxy server policy.
FortiWeb terminates TLS itself, so the backend does not need to be reachable for the handshake test.
On AWS use the interface's own IP for the virtual server ("Use Interface IP") to avoid adding a
secondary private IP; allow inbound 443 in the security group for your `openssl` test host.

```
config server-policy vserver
  edit "tlm-test-vs"
    config vip-list
      edit 1
        set interface port1
        set use-interface-ip enable
      next
    end
  next
end
config server-policy server-pool
  edit "tlm-test-pool"
    set type reverse-proxy
    set server-balance disable
    config pserver-list
      edit 1
        set ip 10.0.0.10
        set port 80
      next
    end
  next
end
config server-policy policy
  edit "tlm-test-policy"
    set deployment-mode server-pool
    set vserver "tlm-test-vs"
    set server-pool "tlm-test-pool"
    set service "HTTP"
    set https-service "HTTPS"
    set certificate "cer"
  next
end
```

GUI equivalents: *Server Objects → Server → Virtual Server*, *Server Objects → Server → Server Pool*,
*Policy → Server Policy* (Deployment Mode *Single Server/Server Pool*, Certificate Type *Single*,
no web protection profile needed). Use `?` at the CLI if a keyword differs on your firmware.

Then confirm the binding the way the plugin sees it, run the replacement, and verify:

```bash
./runbook/fortiweb-runbook.sh refs cer        # POLICY tlm-test-policy cer ; certs: q_ref=1 can_delete=false
openssl s_client -connect <port1-ip>:443 -servername tlsguru.com </dev/null 2>/dev/null | openssl x509 -noout -subject -serial
# ... request the certificate in TLM for the tlsguru-com-rsa.<host>:443 asset (keep CN tlsguru.com);
#     install log: "replacing [cer] - selected by: ...", "Repointing policy 'tlm-test-policy' ... PUT",
#     "Policy 'tlm-test-policy' successfully repointed", "SUCCESS: old certificate 'cer' deleted" ...
./runbook/fortiweb-runbook.sh refs            # POLICY tlm-test-policy tlsguru_com_<serial>
./runbook/fortiweb-runbook.sh certs           # only the new certificate remains
openssl s_client -connect <port1-ip>:443 -servername tlsguru.com </dev/null 2>/dev/null | openssl x509 -noout -issuer -serial
```

Cleanup: delete `tlm-test-policy`, then `tlm-test-pool` and `tlm-test-vs`.
