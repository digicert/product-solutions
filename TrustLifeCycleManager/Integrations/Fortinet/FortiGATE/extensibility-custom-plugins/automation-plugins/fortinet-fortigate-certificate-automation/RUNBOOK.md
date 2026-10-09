# FortiGate Automation Plugin — Manual Test Runbook

This runbook reproduces, with `curl`, `ssh` and `openssl`, **every API call the plugin makes**, in
the order TLM would trigger them. Work through it against the target FortiGate **before uploading
the plugin to Trust Lifecycle Manager**: it confirms the endpoints, JSON field names and FortiOS
behaviours the plugin relies on, and it leaves you with a clear before/after picture of the
certificate you want to replace.

The companion script [`runbook/fortigate-runbook.sh`](runbook/fortigate-runbook.sh) wraps each step
as a sub-command (`./runbook/fortigate-runbook.sh <step>`). The raw `curl` is shown here so you can
see exactly what happens.

| Runbook step | Plugin operation | What it proves |
|---|---|---|
| [0. Prepare](#0-prepare) | constructor (`AdapterConfig`) | token, host/port, VDOM, scope |
| [1. Test connection](#1-test-connection) | `testConnection` | token + certificate list access |
| [2. Discover](#2-discover-certificates-references-and-bodies) | `refreshConfiguration` | list fields, reference scan, **which path returns the PEM** |
| [3. Generate CSR](#3-generate-key--csr-sensor-side) | `generateCsr` | key/CSR format TLM will sign |
| [4. Import](#4-import-the-signed-certificate-under-a-unique-name) | `installCertificate` (identify target + import) | import payload, stored name, list diff |
| [5. Rotate](#5-rotate-references-and-delete-the-old-certificate) | `installCertificate` (repoint + delete) | PUT bodies, `q_ref` gate, DELETE |
| [6. Validate](#6-validate) | `validateCertificate` | presence / serial check |
| [7. Clean up](#7-clean-up-after-a-dry-run) | — | leave the firewall as you found it |

> **Start with step 2 (`discover`).** It is read-only and answers the one question that decides
> how the connector must be configured: does this firmware hand out certificate bodies over REST,
> or is the SSH fallback needed?

---

## 0. Prepare

You need the FortiGate management host, HTTPS admin port, a **REST API administrator token**
(System → Administrators → Create New → REST API Admin; profile with read-write on System, VPN and
Firewall; trusted hosts covering your workstation and the sensor) and the VDOM (`root` unless VDOMs
are in use). An interactive admin account is optional and only used by the runbook's diagnostic
SSH probe; the plugin itself never uses SSH.

```bash
export FGT="fgt.example.com"      # host only – no scheme, no port
export PORT="443"                 # HTTPS administrative access port
export API_TOKEN="q3fhb0dq6HGN73rNn1z9wQb4y0m8Qx"
export VDOM="root"
export SCOPE="global"             # or vdom
export SSH_PORT="22"; export SSH_USER="admin"; export SSH_PASS='********'   # optional, for the CLI probe
export BASE="https://${FGT}:${PORT}/api/v2"
alias fgt='curl -k -sS -H "Authorization: Bearer $API_TOKEN" -H "Accept: application/json"'
```

`-k` mirrors the plugin's trust-all TLS. The plugin sends `scope=global` (or `vdom=<VDOM>` when the
scope is `vdom`) on every certificate call and `vdom=<VDOM>` on every reference call.

```bash
chmod +x runbook/fortigate-runbook.sh
./runbook/fortigate-runbook.sh info      # base URL, hostname, FortiOS version/build, serial
```

## 1. Test connection

Plugin: `FortiGateAdapter.testConnection()` → `GET /cmdb/vpn.certificate/local?scope=global&with_meta=1`.

```bash
fgt -w '\nHTTP:%{http_code}\n' "$BASE/cmdb/vpn.certificate/local?scope=global&with_meta=1"
# helper: ./runbook/fortigate-runbook.sh test
```

| Result | Meaning / plugin behaviour |
|---|---|
| `HTTP:200` with `"status":"success"` | OK — Test Connection in TLM will show **active** |
| `HTTP:401` / `403` | Token rejected, profile lacks permission, or the caller is not a trusted host → `UNAUTHORIZED` |
| `HTTP:200` but `"status":"error"` | FortiOS reports an error inside a 200 — the plugin treats this as failure (`FORTIGATE_API_ERROR`) |
| `curl: (6)` / timeout | Host/port/network problem; check that `FGT` has no scheme and `PORT` is the admin HTTPS port |

## 2. Discover: certificates, references and bodies

Plugin: `FortiGateAdapter.getConfigurationData()` — list (2a), reference scan (2b), certificate
bodies (2c). **Run the all-in-one probe first:**

```bash
./runbook/fortigate-runbook.sh discover
```

It prints, per certificate, whether the cmdb entry carries the PEM, whether the download endpoint
returns it, and (if SSH_USER is set) how many bodies the CLI would print, then a summary line telling you whether
SSH is needed. Keep that output; the sections below explain each part.

### 2a. Local certificate list

```bash
fgt "$BASE/monitor/system/available-certificates?scope=global" | python3 -m json.tool
fgt "$BASE/cmdb/vpn.certificate/local?scope=global&with_meta=1" | python3 -m json.tool
# helper: ./runbook/fortigate-runbook.sh certs
```

Fields the plugin reads (`FortiGateAdapter.listCertificates` / `applyMonitor`):

| Source | Field | Used for |
|---|---|---|
| cmdb | `name` | the certificate identity (alias round-tripped to TLM; `mkey` for PUT/DELETE) |
| cmdb | `range`, `source` | global/vdom; `factory` = built-in, never deleted |
| cmdb | `q_ref` (needs `with_meta=1`) | reference count — **pre-delete safety gate** |
| cmdb | `certificate` | **the PEM** (when the firmware returns it); X.509 fields are re-derived from it |
| monitor | `subject.CN` / `subject`, `issuer` | asset domain name; stable endpoint; self-signed detection |
| monitor | `key_type`, `key_size` | key-type label in the endpoint; algorithm guard in subject matching |
| monitor | `valid_to`, `valid_to_raw` | which of several same-CN certificates owns the canonical endpoint |
| monitor | `serial_number` | cross-check against the uploaded/issued leaf |
| monitor | `status` | `expired` / `pending` fail validation |
| monitor | `is_built_in`, `is_default_local` | built-in detection |

If your firmware spells a field differently, note it — the parser already tries several spellings
and falls back to the PEM, but the runbook output is the place to see what actually came back.

### 2b. Reference scan (who uses which certificate)

```bash
fgt "$BASE/cmdb/vpn.ssl/settings?vdom=$VDOM"           | grep -o '"servercert": *"[^"]*"'
fgt "$BASE/cmdb/system/global?vdom=$VDOM"              | grep -o '"admin-server-cert": *"[^"]*"'
fgt "$BASE/cmdb/user/setting?vdom=$VDOM"               | grep -o '"auth-cert": *"[^"]*"'
fgt "$BASE/cmdb/system/ftm-push?vdom=$VDOM"            | grep -o '"server-cert": *"[^"]*"'
fgt "$BASE/cmdb/vpn.ipsec/phase1-interface?vdom=$VDOM" | python3 -c 'import sys,json; [print(t["name"], t.get("certificate")) for t in json.load(sys.stdin)["results"]]'
fgt "$BASE/cmdb/vpn.ipsec/phase1?vdom=$VDOM"           | python3 -c 'import sys,json; [print(t["name"], t.get("certificate")) for t in json.load(sys.stdin)["results"]]'
fgt "$BASE/cmdb/firewall/vip?vdom=$VDOM"               | python3 -c 'import sys,json; [print(v["name"], v.get("ssl-certificate")) for v in json.load(sys.stdin)["results"]]'
fgt "$BASE/cmdb/firewall/ssl-ssh-profile?vdom=$VDOM"   | python3 -c 'import sys,json; [print(p["name"], p.get("server-cert")) for p in json.load(sys.stdin)["results"]]'
# helper: ./runbook/fortigate-runbook.sh refs [certName]
```

Write down every reference to the certificate you will replace — step 5 must repoint each of them.
Note whether each list-type attribute (`certificate`, `ssl-certificate`, `server-cert`) is a JSON
list of `{"name": …}` (7.x) or a plain string (older firmware); the plugin handles both.

### 2c. Certificate body (required for the certificate to appear in TLM)

TLM only inventories a certificate when it receives the PEM. The plugin tries (1), (2) and, for a
certificate bound to admin HTTPS or the SSL-VPN portal, a TLS handshake; (3) is a runbook-only
diagnostic that shows why SSH support was left out of this plugin:

```bash
# (1) cmdb attribute – expected to contain "-----BEGIN CERTIFICATE-----" on FortiOS
fgt "$BASE/cmdb/vpn.certificate/local/<name>?scope=global" | python3 -c 'import sys,json; r=json.load(sys.stdin)["results"]; r=r[0] if isinstance(r,list) else r; print(r.get("certificate","")[:120])'
# helper: ./runbook/fortigate-runbook.sh cmdb-cert <name>

# (2) download endpoint (the GUI's Download button)
fgt -w '\nHTTP:%{http_code}\n' "$BASE/monitor/system/certificate/download?mkey=<name>&type=local-cer&scope=global" | head -c 400
# helper: ./runbook/fortigate-runbook.sh download-test <name>

# (3) CLI over SSH - runbook diagnostic only, the plugin never uses SSH (needs SSH_USER/SSH_PASS)
ssh -p "$SSH_PORT" "$SSH_USER@$FGT" "show vpn certificate local"
# helper: ./runbook/fortigate-runbook.sh cli-certs
```

Observed on FortiOS 7.6.7 (2026-09-22, 18 global certificates): the download endpoint returned a
PEM for **18/18**, the single cmdb entry for 15/18 (not for the factory-embedded
`Fortinet_Factory`, `Fortinet_Factory_Backup`, `Fortinet_Wifi`), the cmdb *list* view for none
(`"certificate": ""`), and the CLI listed the entries but printed **0** bodies. That is why the
plugin has no SSH configuration. If on some other firmware neither (1) nor (2) returns a PEM, TLM
shows the endpoint but no selectable certificate — report the `discover` output so the plugin can
be adjusted.

## 3. Generate key + CSR (sensor side)

Plugin: `FortiGateAutomationPluginHelper.generateCsrAndStoreKey()` — **no FortiGate call**.

```bash
./runbook/fortigate-runbook.sh csr vpn.example.com vpn.example.com,www.example.com     # ./work/request.key + request.csr
./runbook/fortigate-runbook.sh selfsign                                                # dry run only: ./work/signed.crt
```

For a real run, submit `work/request.csr` to TLM/DigiCert and save the issued leaf as
`work/signed.crt`. Import the DigiCert intermediate once under *System → Certificates → CA
Certificate* — the plugin does not manage intermediates.

## 4. Import the signed certificate under a unique name

Plugin: `ReplacementResolver.resolve()` (which certificate is replaced — alias → thumbprint →
endpoint → subject, see README) and `FortiGateAdapter.installCertificate()` steps 1–2.

```bash
./runbook/fortigate-runbook.sh name work/signed.crt        # e.g. vpn_example_com_0a1b2c3d4e5f
./runbook/fortigate-runbook.sh import work/signed.crt work/request.key
```

The raw call, as in `fortigate-awr.sh`:

```bash
curl -k -sS -X POST "$BASE/monitor/vpn-certificate/local/import?vdom=$VDOM" \
  -H "Authorization: Bearer $API_TOKEN" -H "Content-Type: application/json" \
  --data "{\"type\":\"regular\",\"scope\":\"$SCOPE\",\"certname\":\"$NEW_NAME\",
           \"file_content\":\"$(base64 -w0 work/signed.crt 2>/dev/null || base64 -i work/signed.crt)\",
           \"key_file_content\":\"$(base64 -w0 work/request.key 2>/dev/null || base64 -i work/request.key)\"}" \
  -w '\nHTTP:%{http_code}\n'
```

Observed on 7.6.7: `HTTP:200` with `{"results":{},"status":"success","action":"import",…}`, and
the certificate appears in the list under exactly the requested `certname` with `q_ref: 0`,
`source: user`, `range: global` and the PEM in its cmdb entry. The VIP repoint
(`{"ssl-certificate":[{"name":"<new>"}]}`) and the delete also answered `status: success`; the
delete envelope carries `revision_changed: true`.

| Result | Plugin behaviour |
|---|---|
| `HTTP:200`, `"status":"success"` | import accepted → continue |
| `HTTP:500`/`400` with `cli_error` | cert/key invalid or mismatched, **or the name already exists** → `CERTIFICATE_IMPORT_ERROR` |
| `HTTP:401`/`403` | token rejected → check step 1 |

Then confirm what FortiOS stored (the plugin identifies the new certificate by **list diff**):

```bash
./runbook/fortigate-runbook.sh confirm "$NEW_NAME"
```

## 5. Rotate references and delete the old certificate

Plugin: `FortiGateAdapter.installCertificate()` steps 3–4. `OLD` is the certificate identified in
step 4, `NEW=$NEW_NAME`.

### 5a. Repoint every reference found in step 2b

```bash
# singleton objects: plain string attribute
curl -k -sS -X PUT "$BASE/cmdb/vpn.ssl/settings?vdom=$VDOM" -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" --data "{\"servercert\":\"$NEW_NAME\"}" -w '\nHTTP:%{http_code}\n'
curl -k -sS -X PUT "$BASE/cmdb/system/global?vdom=$VDOM" -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" --data "{\"admin-server-cert\":\"$NEW_NAME\"}" -w '\nHTTP:%{http_code}\n'

# table entries with a list attribute: the plugin rewrites the list with only the matching member swapped
curl -k -sS -X PUT "$BASE/cmdb/vpn.ipsec/phase1-interface/<tunnel>?vdom=$VDOM" -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" --data "{\"certificate\":[{\"name\":\"$NEW_NAME\"}]}" -w '\nHTTP:%{http_code}\n'
# helper (finds and repoints all references of OLD): ./runbook/fortigate-runbook.sh repoint <OLD> "$NEW_NAME"
```

Expect `HTTP:200` and `"status":"success"` on each. Repointing `admin-server-cert` restarts the
admin HTTPS daemon; your next call may need a second. Re-verify with step 2b that nothing points at
`OLD` any more.

### 5b. Safety gate, then delete

```bash
./runbook/fortigate-runbook.sh candelete <OLD>       # q_ref must be 0 (built-in certificates are never deleted)
./runbook/fortigate-runbook.sh delete <OLD>          # DELETE /cmdb/vpn.certificate/local/<OLD>?scope=global
```

If FortiOS still answers `"status":"error"` with a "used"/"in use" `cli_error`, some object the plugin
does not scan references the certificate. Find it in the GUI (*System → Certificates → Ref.
column*) — the plugin would leave the certificate in place with a `SKIP delete` warning, and the
install still succeeds.

## 6. Validate

```bash
./runbook/fortigate-runbook.sh validate "$NEW_NAME" work/signed.crt
openssl s_client -connect "$FGT:$PORT" </dev/null 2>/dev/null | openssl x509 -noout -serial -subject   # if admin-server-cert was repointed
```

## 7. Clean up after a dry run

If you used a self-signed `work/signed.crt` in step 3, restore any references you repointed (the
reverse PUTs from 5a), delete the test certificate, and remove the local key material:

```bash
./runbook/fortigate-runbook.sh delete "$NEW_NAME"
rm -rf work
```

---

## Running the real thing in TLM

1. Build (`./build.sh`) and upload `plugin-dist/fortigate-automation-plugin-1.0.0.zip` as a custom
   automation plugin in TLM; select `configuration.json` for the connector UI.
2. Create the connector (host, port 443, REST API token / PAM, VDOM, scope, replaced-certificate policy) and run
   **Test Connection**. The first log line `Loaded extended configuration: host=… port=… vdom=…`
   confirms every field arrived; a `null` there means the UI field is not reaching the plugin
   (e.g. `host=null` when `configuration.json` and the plugin disagree on the field name: the host is
   declared `config_attributes.management_ip`).
3. Run **Refresh / discovery** and check *Inventory → Endpoints*: expect one endpoint per
   certificate, e.g. `vpn-example-com-rsa.<host>:443`, with the certificate listed under it. The
   plugin log shows `Certificate body for '<name>' read from the cmdb 'certificate' attribute` (or
   `fetched via …download` / `read from the cmdb entry's 'certificate' attribute`) and `pem=yes` on the discovery line.
4. Select the discovered asset, request a certificate. In the install log expect `replacing [<old>]
   - selected by: …`, the repoint `PUT`s, the `q_ref` check and `SUCCESS: old certificate '<old>'
   deleted` (or the reason it was retained).
5. Later renewals: keep the **same CN** so the endpoint stays stable; re-run discovery after each
   renewal so TLM refreshes the alias.

### Where to look when something fails

- **Plugin log on the sensor** — every API call is logged as `VERB /path -> HTTP status`, plus the
  reference scan, the name FortiOS stored, each repoint and the `q_ref` check. The token is never
  logged.
- **Flow directory** `<java.io.tmpdir>/FortiGateAutomationPlugin/<flowId>/`: `request.csr`,
  `request.key` (present only between CSR and a successful install) and `flow.json`.
- **`UNAUTHORIZED` on Test Connection** → token, admin profile, or **trusted hosts** on the REST API
  admin (the sensor's IP must be listed).
- **Discovery shows `pem=no`** → none of the four body sources worked; run `discover` from the
  sensor's network and compare.
- **Import `status: error`** → `cli_error` says why (duplicate name, key mismatch, scope not
  permitted for this admin).
