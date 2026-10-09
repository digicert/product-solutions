# Fortinet FortiGate Automation Plugin

A Java-based automation plugin for DigiCert **Trust Lifecycle Manager (TLM)** that manages the
certificate lifecycle on a single **Fortinet FortiGate** (FortiOS) over its REST API (`/api/v2`).
It discovers the local certificates held on the firewall, generates the key pair and CSR on the
TLM sensor, imports the CA-signed certificate + key under a new unique name, repoints every
SSL-VPN / admin-HTTPS / IPsec / VIP / SSL-inspection object that used the previous certificate,
and deletes the previous certificate — all driven by TLM.

It is a port of the FortiWeb automation plugin (same SDK skeleton, PAM support, packaging and
rotation logic) onto the FortiOS API surface used by the DigiCert `fortigate-awr.sh` /
`fortigate-awr.ps1` post-enrollment scripts.

> **Status.** Every API call the plugin makes has been executed by hand against **FortiOS 7.6.7**
> (FortiGate VM64-AWS) with the runbook: discovery (list, metadata, bodies, reference scan) and
> the full rotation (JSON import under a unique name → VIP `ssl-certificate` repoint → `q_ref`
> gate → delete) all succeeded. The remaining step is driving the same sequence from TLM through
> the packaged plugin. Before using it on a new appliance, run
> `./runbook/fortigate-runbook.sh discover` (see [RUNBOOK.md](RUNBOOK.md)).

The plugin extends `AbstractAutomationWorkflow` and implements the five TLM lifecycle operations:

| Operation | FortiOS REST API action |
|---|---|
| `testConnection` | `GET /cmdb/vpn.certificate/local?{scope}&with_meta=1` — exercises token + network + certificate read access; logs hostname/version from `monitor/system/status` |
| `refreshConfiguration` | certificate list (`cmdb/vpn.certificate/local` merged with `monitor/system/available-certificates`) + scan of SSL-VPN settings, `system/global`, `user/setting`, `system/ftm-push`, IPsec phase1(-interface), firewall VIPs and SSL/SSH profiles for references; certificate bodies from the download endpoint, else the single cmdb entry |
| `generateCsr` | **No FortiGate call.** Key pair + PKCS#10 CSR are generated on the sensor; the private key is retained in the flow directory |
| `installCertificate` | identify the certificate to replace (alias → thumbprint → endpoint → subject) → `POST /monitor/vpn-certificate/local/import` (JSON, base64 cert + key) → `PUT` repoints on every reference → `DELETE /cmdb/vpn.certificate/local/<old>?{scope}` |
| `validateCertificate` | certificate present, not `expired`/`pending`, serial cross-checked against the flow record / `certificateSerialNumber`; returns the leaf PEM recorded at install |

`{scope}` is `scope=global` (default) or `vdom=<name>` depending on the connector's *Certificate scope*.

## Tested with

| | |
|---|---|
| **Appliance** | FortiGate VM64-AWS (single VDOM `root`, certificates in the `global` scope) |
| **Firmware** | **FortiOS v7.6.7 build 3704** |
| **Access** | REST API on port 443 with a REST API administrator token (Bearer); an SSH admin was used once, by the runbook only, to prove the CLI is not needed |
| **Test date** | 2026-09-22 |
| **How** | (1) Manually, with [`runbook/fortigate-runbook.sh`](runbook/fortigate-runbook.sh), which issues the same REST calls with the same paths, query strings and bodies as the plugin, in the order TLM triggers them; (2) from TLM with the packaged plugin on a Linux sensor: connector creation, Test Connection and discovery. |

What was exercised and confirmed:

- **Discovery** (`discover`, `certs`, `refs`): 18 local certificates listed from `cmdb/vpn.certificate/local?scope=global&with_meta=1` merged with `monitor/system/available-certificates`; metadata field names as documented above; the certificate body retrievable for **18/18** via `monitor/system/certificate/download?type=local-cer`, for 15/18 via the single cmdb entry, for 0/18 via the CLI over SSH (`show vpn certificate local` lists the entries without bodies on 7.6.7). Reference scan found `system/global admin-server-cert`, `user/setting auth-cert`, `system/ftm-push server-cert` and a firewall VIP `ssl-certificate` list; `vpn.ssl/settings` returned an empty `servercert`.
- **Rotation of a certificate bound to a firewall VIP** (`csr` → `selfsign` → `import` → `repoint` → `candelete` → `delete`): import under the plugin's unique name via `monitor/vpn-certificate/local/import` (JSON, `type=regular`, `scope=global`) answered `status: success` and the entry appeared under the requested name; the VIP `ssl-certificate` list was rewritten to the new certificate; the old certificate then showed `q_ref: 0` and `DELETE …?scope=global` removed it.
- **Offline**: Maven build, 17 smoke checks (FortiOS error envelope, naming, monitor/PEM merge, endpoint assignment, token handling) and an eager class-load of every class in the shaded jar.
- **From TLM** (packaged plugin, Linux sensor): connector saved, Test Connection active, discovery
  populated the inventory. Lessons from that run are baked into `configuration.json`: the REST
  port field is labelled "(not SSH)" and the plugin refuses port 22 with a clear message; every
  field is declared required because optional fields broke add/edit; the SSH credential fields
  were removed altogether because REST covers every certificate body and a mandatory CLI account
  is unacceptable in least-privilege deployments.

Not yet exercised: CSR / issue / install / validate driven from TLM through the sensor (the same REST calls succeeded from the runbook); `certificateScope = vdom` on a multi-VDOM unit; IPsec phase1 / SSL-VPN / SSL-SSH-profile repoints (no such references existed on the test unit); the Secrets Manager (PAM) path; other FortiOS versions.

## Architecture

```
TLM  ──JSON──►  FortiGateAutomationPlugin        (SDK entry point: the 5 lifecycle methods)
                        │  builds AdapterConfig, resolves the certificate to replace
                        ▼
                FortiGateAdapter                 (all FortiOS logic; returns Result<T>)
                        │
                        │ FortiGateRestClient  (Bearer token, trust-all TLS)
                        ▼
       https://<host>:<port>/api/v2/{cmdb,monitor}
       list / bodies / import / repoint / delete
```

The plugin talks to the FortiGate **over the REST API only**. No CLI/SSH account is needed:
FortiOS returns certificate bodies through `monitor/system/certificate/download` and the cmdb entry,
so the SSH fallback the FortiWeb plugin needs was removed from this one (it would have forced
customers to hand TLM a CLI-capable administrator for nothing).

- **Authentication.** REST calls carry `Authorization: Bearer <token>` where the token belongs to a
  FortiGate **REST API administrator** (System → Administrators → Create New → REST API Admin).
  The token is never logged.
- **TLS to the appliance** is trust-all with hostname verification disabled (FortiGates run a
  factory or self-signed management certificate and are often addressed by IP) — the same as
  `curl -k` in the shell automation. JVM proxy system properties are honoured.
- **FortiOS error reporting.** Every FortiOS response is an envelope with `status`
  (`success`/`error`), `http_status`, `error` (negative code) and often `cli_error`; the plugin
  treats `status: error` as a failure even inside an HTTP 200.
- **Private key custody.** The import API takes certificate **and** key, so the key pair is
  generated on the sensor (JDK providers; PKCS#10 built with BouncyCastle) and the PKCS#8 key is kept
  owner-readable at `<java.io.tmpdir>/FortiGateAutomationPlugin/<flowId>/request.key` between
  `generateCsr` and `installCertificate` (each plugin call is a fresh JVM). The key is deleted as
  soon as the import succeeds. `generateCsr` and `installCertificate` must therefore run on the
  **same sensor**.

## The "replace the existing certificate" use case

FortiOS **cannot overwrite** a local certificate: importing under an existing name fails as a
duplicate, and a certificate that is referenced by any object cannot be deleted. So a renewal is a
**rotation**, never an in-place update:

1. `refreshConfiguration` **discovers every local certificate** in the managed scope (factory
   certificates included) as a selectable asset, carrying its FortiOS **name** (round-tripped as
   the asset alias), subject CN, issuer, validity, key type, `q_ref` and where it is referenced.
2. The operator selects the discovered certificate in TLM and requests a certificate for it. TLM
   round-trips the asset identity in `virtualServerName` as `<partition>/<name>`, and on install
   also sends `currentCertificateThumbprint` and the endpoint `ipAddress`.
3. `generateCsr` generates the key + CSR on the sensor and returns the CSR; TLM has it signed.
4. `installCertificate`:
   0. identifies the certificate to replace (see *Which certificate gets replaced* below);
   1. imports the signed certificate + key under a **new unique name**
      `<sanitised CN>_<last 12 hex digits of the serial>` (e.g. `vpn_example_com_0a1b2c3d4e5f`);
   2. confirms the name FortiOS actually stored (list diff);
   3. for the certificate being replaced, finds every reference and `PUT`s each one to the new
      name — string attributes are replaced, list attributes (IPsec `certificate`, VIP
      `ssl-certificate`, SSL/SSH profile `server-cert`) are rewritten with only the matching member
      swapped;
   4. re-reads the entry and deletes the old certificate **only if** it is not a built-in
      certificate and FortiOS no longer reports `q_ref > 0`. FortiOS itself refuses to delete an
      in-use certificate, so nothing referenced by an unscanned object type is ever lost.
5. `validateCertificate` confirms the new certificate is listed and that the serial FortiOS reports
   matches the certificate TLM issued.

**If a repoint fails**, the new certificate stays imported, the old one is left in place, and the
install is reported as failed with the list of references that could not be moved. On a TLM retry
the plugin recognises its own earlier import (same name, same serial) and only re-runs the rotation.

### Which certificate gets replaced

`ReplacementResolver` picks the certificate(s) to rotate out through a chain, accepting only names
that **exist on the appliance**, and logs which rule matched:

1. an explicit `certificateName` extended-request field (user override), else
2. the `virtualServerName` alias (`<partition>/<name>`), else
3. the **`currentCertificateThumbprint`** TLM sends (SHA-256 of the certificate it last saw), matched
   against the SHA-256 fingerprint FortiOS reports, then against every certificate body known, else
4. the **endpoint**: the certificate whose stable discovery endpoint equals the request's
   `ipAddress`, else
5. **subject match**: certificates whose CN equals the new leaf's CN or one of its SAN DNS names,
   with the same key algorithm (an RSA renewal never selects an ECC certificate).

If nothing matches, the new certificate is imported and a `WARN` explains that nothing was repointed
or deleted.

### Naming and TLM identity

Every renewal produces a new FortiOS object name, but the TLM **endpoint stays the same**: it is
derived from the subject CN and key algorithm (`vpn-example-com-rsa.<host>:443`), not from the
FortiOS name. After a rotation the next discovery shows the same endpoint carrying the new name as
its alias; the deleted certificate simply stops being listed. FortiOS object names are capped at
35 characters; `CertificateAttributesUtil.buildUniqueName` restricts them to `[A-Za-z0-9_-]` and
truncates long CNs to make room for the serial suffix.

## Asset discovery & the endpoint model

TLM's automation inventory is **endpoint-centric** — a certificate renders only when anchored to a
data `IP:port`. On a FortiGate a certificate may be bound to the admin GUI, the SSL-VPN portal,
several IPsec tunnels or VIPs, or — like `Fortinet_Factory` — to nothing the plugin scans. So
discovery synthesizes an endpoint per certificate from what survives a renewal:

```
<sanitised CN>-<rsa|ecc|dsa>.<fortigateHost>:443      e.g. vpn-example-com-rsa.fgt.example.com:443
```

- **Stable across renewals**; **duplicates never collapse** (same CN + key type → the one expiring
  last owns the canonical endpoint, the others are reported on `<name>.<fortigateHost>:443`).
- `alias` / `serverParam` = the FortiOS certificate name (round-trips as `virtualServerName`).
- `domainName` = the subject CN (falls back to the name). `isSni` = referenced from a firewall VIP.
- **Certificate body.** TLM only inventories a certificate when it receives the PEM. Unlike
  FortiWeb, FortiOS hands it out over REST. The plugin tries, per certificate:
  (1) `GET /monitor/system/certificate/download?mkey=<name>&type=local-cer&{scope}` (the GUI's
  Download button) — on 7.6.7 this returned **every** local certificate, factory-embedded ones
  included; (2) the single cmdb entry `GET /cmdb/vpn.certificate/local/<name>?{scope}`, whose
  `certificate` attribute carries the PEM for imported certificates (the *list* view returns it
  empty); (3) for a certificate bound to admin HTTPS or the SSL-VPN portal, a TLS handshake against
  that listener. Each candidate is accepted only if its serial matches the entry. (The CLI over SSH
  is deliberately not used: on 7.6.7 `show vpn certificate local` lists the entries but prints no
  bodies, and REST already covers every certificate. The runbook keeps an SSH probe for diagnosis.)
  Once the body is known, subject / issuer / serial / validity / key type are re-derived from it.
- Every server certificate in the scope is shown — expired, factory and unreferenced ones
  included. Entries of type `local-ca` (`Fortinet_CA_SSL`, `Fortinet_CA_Untrusted`) are CA
  certificates for SSL inspection and are skipped.
- **Monitor field names (7.6.7):** `type` is `local-cer`/`local-ca`; `valid_to` is the epoch and
  `valid_to_raw` the printable date; `serial_number` and `fingerprint` (SHA-256) are colon-hex;
  `subject`/`issuer` are objects with `subject_raw`/`issuer_raw` strings; `q_ref` in the monitor
  view is 0 for factory certificates even when referenced, so the cmdb `q_ref` (needs
  `with_meta=1`) is authoritative. The monitor fingerprint lets the install match TLM's
  `currentCertificateThumbprint` without downloading bodies.

## Connector configuration (TLM)

Defined in `configuration.json` and surfaced in the TLM connector UI:

| Field | Type | Notes |
|---|---|---|
| Managing sensor | select | Dynamic TLM list (`options_provider: Sensors`) |
| FortiGate host (FQDN or IP) | input | Declared as `config_attributes.management_ip` (renamed from `host` on DigiCert engineering's advice, 2026-09-23; the plugin accepts both). Bare host; a scheme, path or `:port` is tolerated and stripped. Part of the connector unique key |
| FortiGate HTTPS admin / REST API port (not SSH) | input | Default 443. Part of the unique key |
| Authentication method | select | *Self-authentication (Direct input)* (default) or *Self-authentication (Secrets manager)* |
| FortiGate REST API token | password | Direct-input mode only. Stored by TLM as a sensitive credential (`config_attributes.password`) |
| Secrets manager connector | select | Secrets-manager mode only. Dynamic TLM list of registered PAM connectors |
| FortiGate REST API token (PAM vault reference) | input | Secrets-manager mode only. The **vault reference** the PAM connector resolves at runtime |
| FortiGate VDOM | input | Default `root`. VDOM whose objects are scanned/repointed. Part of the unique key |
| Certificate scope | select | `global` (default) or `vdom` |
| Replaced certificate after rotation | select | `delete` (default) or `keep` |

**Every field is declared required** (`optional: false` + `requiredRule`) with a default value where
one makes sense. This is deliberate: the TLM connector form answered "Server error, see logs for
details" on add *and* edit while fields were declared `optional: true` (first seen with the scope
select, then with the remaining optional fields, 2026-09-22). Required fields with defaults behave
exactly like optional ones for the operator, but save reliably. The two `REST API token` rows are
the **same** `config_attributes.password` field declared twice with a different `type` and a
`conditional_group`, so exactly one is shown depending on the authentication method. Keeping the
token in the `password` field is what makes TLM's sensitive storage and PAM injection work unchanged.

### Secrets Manager (PAM) authentication

Identical to the FortiWeb / Azure Key Vault plugins: the connector stores only a vault reference; at
run time TLM asks the selected PAM connector (BeyondTrust Password Safe, CyberArk CCP, Delinea
Secret Server / Platform) to resolve it and injects the real token into `password`. The plugin
**fails closed** when no value arrives. Directly-typed secrets arrive base64-encoded from TLM and are
decoded only when the decoded bytes are printable text; a raw FortiOS token (alphanumeric, hence
also valid base64) decodes to control bytes and is therefore used as-is — this is covered by the
offline smoke test.

### FortiGate prerequisites

- **REST API reachable** from the sensor on the HTTPS administrative-access port (default 443).
- A **REST API administrator** whose **administrator profile** grants Read/Write on *System*
  (certificates), *VPN* (SSL-VPN settings, IPsec) and *Firewall* (VIPs, SSL/SSH profiles), and whose
  **trusted hosts** include the sensor's address. Token generation happens once in the GUI; the
  token cannot be retrieved again afterwards.
- No SSH / CLI access is required. If `discover` on another firmware ever shows that neither the
  download endpoint nor the cmdb entry returns a PEM, the FortiWeb plugin's SSH client can be
  re-added; on 7.6.7 it is not needed.
- Multi-VDOM units: use a REST API admin with the right VDOM assignment; global certificates are
  addressed with `scope=global`, which the plugin sends whenever *Certificate scope* is `global`.
- Intermediate CA certificates are **not** managed by this plugin: import the DigiCert intermediate
  once under *System → Certificates → Create/Import → CA Certificate*; the uploaded local certificate
  file contains only the leaf unless `useCommonIca` is set on the request.
- Version: written against FortiOS 7.x (`/api/v2` cmdb/monitor; import via
  `monitor/vpn-certificate/local/import` as in `fortigate-awr.sh`). Confirm with the runbook.

## Prerequisites (build)

- **Java 17+**, **Maven 3.6+**
- Access to the DigiCert TLM Plugin SDK on GitHub Packages (`com.digicert.tlm:plugin-sdk:1.1`) and
  to Maven Central (BouncyCastle, Jackson, SLF4J).

## Building

```bash
export GITHUB_ACTOR=<your-github-username>
export GITHUB_TOKEN=<token-with-read:packages>
./build.sh           # or: mvn clean package -s settings.xml -U
```

Artifacts:
- `target/fortigate-automation-plugin-1.0.0.jar` — fat (shaded) JAR
- `plugin-dist/fortigate-automation-plugin-1.0.0.zip` — TLM distribution package (jar + `plugin-meta.json`)
- `plugin-dist/checksums` — SHA-256 checksum

The fat JAR is built with the **Maven Shade plugin**; jar signatures are stripped. The TLM
`SdkRuntime` eagerly loads every class on the classpath at startup; the packaged jar has been
verified to load all of its classes without a `NoClassDefFoundError`. Re-verify after any dependency
bump.

## Project structure

```
src/main/java/com/example/automation/
├── FortiGateAutomationPlugin.java         # 5 lifecycle methods (SDK entry point), stable endpoint assignment
├── FortiGateAutomationPluginRunner.java   # main() runner
├── adapter/
│   ├── AdapterConfig.java                 # host / port / token / vdom / scope → query fragments
│   ├── FortiGateRestClient.java           # JDK HttpClient: Bearer auth, FortiOS envelope error handling
│   └── FortiGateAdapter.java              # list/merge, reference scan, import, repoint, delete, validate, PEM fetch
├── helper/
│   ├── CertificateAttributesUtil.java     # CN parsing, FortiOS-safe unique names, serial comparison
│   ├── ReplacementResolver.java           # which certificate an install replaces: alias → thumbprint → endpoint → subject
│   └── FortiGateAutomationPluginHelper.java # key+CSR generation, flow directory, artifact download/extract
├── model/                                 # Result, ErrorCode, FortiGateCertificate, CertificateReference, FlowRecord, …
└── extended/                              # TLM request/response/config extensions
configuration.json                         # TLM connector UI definition (field names matter: management_ip, password, vdom, certificateScope, …)
runbook/fortigate-runbook.sh               # curl/ssh helper that performs each RUNBOOK step by hand (incl. `discover`)
RUNBOOK.md                                 # manual test procedure (run before uploading to TLM)
```

## Notes & limitations

- **One appliance/VDOM per connector.** Host + port + VDOM form the unique key.
- **Same sensor for CSR and install.** The private key lives in the sensor's temp directory between
  the two calls and is deleted after a successful import.
- **Rotation, not overwrite.** The new certificate always gets a new name; the old one is deleted
  only when it is not built-in and FortiOS reports it unreferenced.
- **Object types scanned** for references: `vpn.ssl/settings.servercert`,
  `system/global.admin-server-cert`, `user/setting.auth-cert`, `system/ftm-push.server-cert`,
  `vpn.ipsec/phase1-interface[].certificate`, `vpn.ipsec/phase1[].certificate`,
  `firewall/vip[].ssl-certificate`, `firewall/ssl-ssh-profile[].server-cert`. Other consumers
  (wireless controller, web-proxy, SAML, LDAP client certs, …) are not repointed; FortiOS's own
  refusal to delete a referenced certificate then keeps the old certificate in place.
- **Built-in certificates** (`Fortinet_Factory`, `Fortinet_SSL`, …) can be replaced as references
  but are never deleted.
- **SSL-VPN on FortiOS 7.6+** is being retired on some models; if `vpn.ssl/settings` is absent the
  scan simply logs it as such.
- **Verified on FortiOS 7.6.7 only.** Runbook-validated there on 2026-09-22: discovery, import
  (`monitor/vpn-certificate/local/import`, `status: success`, stored under the requested name),
  repoint of a list-valued VIP `ssl-certificate`, `q_ref` gate and `DELETE …?scope=global`. On
  other firmware confirm with `discover` / `certs`; the parsers are tolerant (several spellings
  tried, X.509 fields re-derived from the PEM when available).
