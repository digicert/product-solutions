# Fortinet FortiWeb Automation Plugin

A Java-based automation plugin for DigiCert **Trust Lifecycle Manager (TLM)** that manages the
certificate lifecycle on a single **Fortinet FortiWeb** appliance over its REST API
(`/api/v2.0`). It discovers the local certificates held on the appliance, generates the key pair
and CSR on the TLM sensor, uploads the CA-signed certificate + key to FortiWeb under a new unique
name, repoints every server policy / SNI member / multi-cert group that used the previous
certificate, and deletes the previous certificate — all driven by TLM.

It is a port of the Azure Key Vault automation plugin (same SDK skeleton, PAM support and packaging)
onto the FortiWeb API surface proven by the DigiCert `fortiweb-awr.sh` post-enrollment script
(validated end-to-end against FortiWeb 8.0.5).

The plugin extends `AbstractAutomationWorkflow` and implements the five TLM lifecycle operations:

| Operation | FortiWeb REST API action |
|---|---|
| `testConnection` | `GET /system/certificate.local` — exercises auth + network + certificate read access |
| `refreshConfiguration` | `GET /system/certificate.local` + scan of `server-policy/policy`, `certificate.sni/members`, `certificate.multi-local` for references; certificate bodies via SSH `show system certificate local` |
| `generateCsr` | **No FortiWeb call.** Key pair + PKCS#10 CSR are generated on the sensor; the private key is retained in the flow directory |
| `installCertificate` | identify the certificate to replace (alias → thumbprint → endpoint → subject) → `POST /system/certificate.local.import_certificate` (multipart cert + key) → `PUT` repoints on every reference → `DELETE /cmdb/system/certificate.local?mkey=<old>` |
| `validateCertificate` | `GET /system/certificate.local` → new certificate present with `status: OK`, serial cross-checked against the flow record / `certificateSerialNumber`; returns the leaf PEM recorded at install |

> **Before uploading the plugin to TLM**, walk through [RUNBOOK.md](RUNBOOK.md): it reproduces
> every API call the plugin makes with `curl`, so the appliance's field names and behaviour can be
> confirmed by hand first.

## Tested with

| | |
|---|---|
| **Appliance** | FortiWeb virtual appliance on AWS, ADOM `root` |
| **Firmware** | **FortiWeb 8.0.5** |
| **Access** | REST API on port 8443 (base64 credential token in `Authorization`); SSH on port 22 with the same administrator account for the read-only `show system certificate local` |
| **Test date** | 2026-09-21 |
| **How** | Two ways: (1) by hand with [`runbook/fortiweb-runbook.sh`](runbook/fortiweb-runbook.sh), which issues the same REST/SSH calls as the plugin; (2) **end-to-end from TLM** with the packaged plugin running on a Linux sensor (JDK 17) — connector creation, Test Connection, discovery, certificate request, install and validate. |

What was exercised and confirmed:

- **Discovery**: `GET /api/v2.0/system/certificate.local` returns metadata only (`subject`, `issuer`,
  `validFrom`/`validTo`, `serialNumber`, `pkey_type` 1 = RSA / 3 = ECDSA, `q_ref`, `can_delete`) and
  never the PEM; `certificate.local.download` / `.view` refuse imported certificates with
  `errcode -20007` (130 argument variants probed); `errcode` arrives as a string inside HTTP 200 or
  500. The CLI over SSH prints the body per `edit "<name>"` block on an exec channel, and TLM
  inventoried the certificate only once that PEM was supplied.
- **Rotation of a self-signed local certificate** (`cer`, CN `tlsguru.com`), both unreferenced and
  bound to a reverse-proxy server policy (Appendix A of the runbook): multipart import under the
  plugin's unique name (stored name derived from the uploaded file name), `PUT` repoint of the
  policy `certificate`, `can_delete` gate, `DELETE …?mkey=<old>`, followed by a TLS handshake
  against the policy VIP showing the new certificate.
- **TLM behaviour** observed during the same runs: `config_attributes.userName` is the only spelling
  TLM delivers for the account field; TLM keeps the first-discovered alias, so a second renewal
  arrived with a stale `virtualServerName` and was resolved through the thumbprint / endpoint /
  subject chain; the SLF4J, SSHD host-key and `errcode -20007` log lines are benign noise.
- **Offline**: Maven build, the shaded jar loads all of its classes under the TLM `SdkRuntime`
  eager scan.

Not yet exercised: SNI member and multi-certificate-group repoints (no such objects on the test
appliance); a non-`root` ADOM; the Secrets Manager (PAM) path on this plugin (inherited unchanged
from the Azure Key Vault plugin where it was tested); FortiWeb versions other than 8.0.5.

## Architecture

```
TLM  ──JSON──►  FortiWebAutomationPlugin        (SDK entry point: the 5 lifecycle methods)
                        │  builds AdapterConfig, resolves the certificate to replace
                        ▼
                FortiWebAdapter                 (all FortiWeb logic; returns Result<T>)
                   │                     │
                   │ FortiWebRestClient  │ FortiWebSshClient (read-only, one CLI command)
                   ▼                     ▼
       https://<host>:<port>/api/v2.0    ssh <host>:<sshPort>  "show system certificate local"
       list / import / repoint / delete  certificate bodies (PEM) for discovery + validation
```

- **Authentication.** FortiWeb expects `Authorization: <token>` where the token is the base64 of
  `{"username":"…","password":"…","vdom":"…"}`. The plugin builds it from the username / password /
  ADOM entered on the connector, so operators never have to pre-encode anything. The token is never
  logged.
- **TLS to the appliance** is trust-all with hostname verification disabled (appliances run a
  self-signed management certificate and are often addressed by IP) — the same as `curl -k` in the
  shell automation. JVM proxy system properties are honoured. SSH host keys are likewise accepted
  without verification (the fingerprint is logged).
- **FortiWeb error reporting.** FortiWeb returns `errcode` sometimes as a number and sometimes as a
  string (`"-20007"`), and sometimes inside an HTTP 200. `FortiWebRestClient` treats any negative
  `errcode` as a failure regardless of HTTP status.
- **Private key custody.** FortiWeb's import API takes certificate **and** key, so the key pair is
  generated on the sensor (JDK providers; PKCS#10 built with BouncyCastle) and the PKCS#8 key is kept
  owner-readable at `<java.io.tmpdir>/FortiWebAutomationPlugin/<flowId>/request.key` between
  `generateCsr` and `installCertificate` (each plugin call is a fresh JVM). The key is deleted as
  soon as the upload succeeds. `generateCsr` and `installCertificate` must therefore run on the
  **same sensor**.

## The "replace the existing certificate" use case

FortiWeb **cannot overwrite** a local certificate: importing under an existing name fails as a
duplicate, and a certificate that is referenced by any object cannot be deleted. So a renewal is a
**rotation**, never an in-place update:

1. `refreshConfiguration` **discovers every local certificate** (including the factory self-signed
   one) as a selectable asset, carrying its FortiWeb **name** (round-tripped as the asset alias),
   subject CN, issuer, validity, key type, and whether anything references it.
2. The operator selects the discovered certificate in TLM and requests a certificate for it. TLM
   round-trips the asset identity in `virtualServerName` as `<partition>/<name>` (e.g. `null/cer`),
   and on install also sends `currentCertificateThumbprint` and the endpoint `ipAddress`.
3. `generateCsr` generates the key + CSR on the sensor and returns the CSR; TLM has it signed.
4. `installCertificate`:
   0. identifies the certificate to replace (see *Which certificate gets replaced* below);
   1. imports the signed certificate + key under a **new unique name**
      `<sanitised CN>_<last 12 hex digits of the serial>` (e.g. `tlsguru_com_0a1b2c3d4e5f`), which
      can never collide with an existing name;
   2. confirms the name FortiWeb actually stored (list diff);
   3. for the certificate being replaced, finds every reference — `server-policy/policy →
      certificate`, `certificate.sni/members → local-cert`, `certificate.multi-local →
      rsa-cert/ecc-cert/dsa-cert` — and `PUT`s each one to the new name;
   4. re-reads the list and deletes the old certificate **only if** FortiWeb now reports
      `can_delete: true` (`q_ref: 0`). Anything still referenced by an object type the plugin does
      not scan is left in place with a warning.
5. `validateCertificate` confirms the new certificate is listed with `status: OK` and that the serial
   FortiWeb reports matches the certificate TLM issued.

**If a repoint fails**, the new certificate stays imported, the old one is left in place, and the
install is reported as failed with the list of references that could not be moved — never a deleted
in-use certificate. On a TLM retry the plugin recognises its own earlier import (same name, same
serial) and only re-runs the rotation.

### Which certificate gets replaced

TLM identifies the certificate being renewed in several ways that are not always consistent. In
particular the alias it round-trips in `virtualServerName` can be **stale**: TLM keeps the alias it
discovered first, while every FortiWeb renewal creates a new object name, and a CN change moves the
asset to another endpoint. Trusting the alias alone therefore left a previous certificate bound and
undeleted in testing. `ReplacementResolver` picks the certificate(s) to rotate out through a chain,
accepting only names that **exist on the appliance**, and logs which rule matched:

1. an explicit `certificateName` extended-request field (user override), else
2. the `virtualServerName` alias (`<partition>/<name>`), else
3. the **`currentCertificateThumbprint`** TLM sends (SHA-256 of the certificate it last saw), matched
   against the certificate bodies read over SSH — the most reliable identifier, else
4. the **endpoint**: the certificate whose stable discovery endpoint equals the request's
   `ipAddress`, else
5. **subject match**: certificates whose CN equals the new leaf's CN or one of its SAN DNS names,
   with the same key algorithm (an RSA renewal never selects an ECC certificate).

If nothing matches, the new certificate is imported and a `WARN` explains that nothing was repointed
or deleted. Inside the adapter, multi-cert-group slots are only repointed when `pkey_type` matches,
so an RSA renewal never lands in an `ecc-cert` slot.

### Naming and TLM identity

Every renewal produces a new FortiWeb object name, but the TLM **endpoint stays the same**: it is
derived from the subject CN and key algorithm (`tlsguru-com-rsa.<host>:443`), not from the FortiWeb
name (see below). After a rotation the next discovery shows the same endpoint carrying the new name
(`tlsguru_com_…`) as its alias; the deleted certificate simply stops being listed. FortiWeb object
names allow only `[A-Za-z0-9_]` and at most 35 characters; `CertificateAttributesUtil.buildUniqueName`
enforces both (long CNs are truncated to make room for the serial suffix).

## Asset discovery & the endpoint model

TLM's automation inventory is **endpoint-centric** — a certificate renders only when anchored to a
data `IP:port`, and TLM keys endpoints by `dataIp:port`. On FortiWeb a certificate may be bound to
a policy VIP, several certificates may share one VIP (SNI), or — like the factory self-signed
certificate — a certificate may be bound to nothing. So discovery synthesizes an endpoint per
certificate. Because a renewal always imports under a **new FortiWeb name**, the endpoint is built
from what survives a renewal — the subject CN and the key algorithm:

```
<sanitised CN>-<rsa|ecc|dsa>.<fortiwebHost>:443      e.g. tlsguru-com-rsa.fortiweb.example.com:443
```

- **Stable across renewals.** `cer` and its replacement `tlsguru_com_26ec116511e1` both map to
  `tlsguru-com-rsa.<host>:443`, so TLM tracks one endpoint and the renewed certificate lands on it.
- **Duplicates never collapse.** If several certificates share CN and key type (previous certificate
  kept after a rotation, hand-uploaded copies), the one expiring last owns the canonical endpoint and
  the others are reported on `<name>.<fortiwebHost>:443`. A certificate without a readable CN also
  uses the name-based endpoint. RSA and ECC certificates for the same CN are separate endpoints.
- **Keep the CN stable across renewals.** The endpoint is stable only while CN and key type are.
  Renewing with a different CN (e.g. `tlsguru.com` → `01.tlsguru.com`) moves the certificate to a
  new endpoint; the old endpoint then lingers in TLM with a stale alias until it is removed. The
  install still finds the right certificate to replace (via thumbprint / SAN), but the inventory is
  harder to read.
- `alias` / `serverParam` = the FortiWeb certificate name (round-trips as `virtualServerName`), which
  is what the install rotates out.
- `domainName` = the subject CN (falls back to the name).
- `isSni` = true when the certificate is referenced from an SNI member.
- **Certificate body (why SSH is needed).** FortiWeb's REST list returns metadata only (subject,
  issuer, validity, serial, `pkey_type`, `q_ref`, `can_delete`) — never the PEM — and on 8.0.5 the
  `certificate.local.download` endpoint refuses imported certificates (`errcode -20007`). TLM,
  however, only inventories a certificate when it receives the PEM; a metadata-only asset produces
  an endpoint but **no certificate to select**. The CLI does print the body, so the plugin logs in
  over SSH with the same credentials and runs one read-only command:

  ```
  FortiWeb # show system certificate local
  config system certificate local
    edit "cer"
      set certificate "-----BEGIN CERTIFICATE-----
  MIIC7jCC…
  -----END CERTIFICATE-----
  "
      set private-key "-----BEGIN ENCRYPTED PRIVATE KEY-----   ← ignored (encrypted, never read)
  ```

  `FortiWebSshClient` parses the `edit <name>` blocks into name → PEM; each PEM is accepted only if
  its serial matches the REST list entry. Order of attempts per certificate: (1) CLI over SSH,
  (2) REST download endpoints (kept for other firmware), (3) for a policy-bound certificate a TLS
  handshake against the policy VIP with SNI = CN. If all fail the asset is surfaced metadata-only.
  SSH is on by default (port 22; *FortiWeb SSH port* `0` disables it) and is never used to change
  configuration.
- Every certificate is shown — expired, self-signed and unreferenced ones included — because those
  are exactly the certificates an operator wants to replace. `q_ref`/`can_delete` and the reference
  list are written to the plugin log for each discovered certificate.

## Connector configuration (TLM)

Defined in `configuration.json` and surfaced in the TLM connector UI:

| Field | Type | Notes |
|---|---|---|
| Managing sensor | select | Dynamic TLM list (`options_provider: Sensors`) |
| FortiWeb host (FQDN or IP) | input | Bare host; a scheme, path or `:port` is tolerated and stripped. Part of the connector unique key |
| FortiWeb REST API port | input | Optional; blank → 443 (the lab appliance uses 8443). Part of the unique key |
| FortiWeb username | input | Administrator with REST API access (see prerequisites). Declared as `config_attributes.userName` — TLM only delivers the camelCase spelling; a field named `username` arrives as null |
| Authentication method | select | *Self-authentication (Direct input)* (default) or *Self-authentication (Secrets manager)* |
| FortiWeb password | password | Direct-input mode only. Stored by TLM as a sensitive credential |
| Secrets manager connector | select | Secrets-manager mode only. Dynamic TLM list of registered PAM connectors |
| FortiWeb password (PAM vault reference) | input | Secrets-manager mode only. The **vault reference** the PAM connector resolves at runtime |
| FortiWeb ADOM | input | Optional; blank → `root`. Sent as `vdom` in the API token |
| FortiWeb SSH port (certificate discovery) | input | Optional; blank/absent → 22. Same username/password; one read-only CLI command to read certificate bodies. Enter `0` to disable SSH (discovery then metadata-only) |
| Keep the replaced certificate on FortiWeb after rotation | checkbox | Optional; default off (delete the replaced certificate once unreferenced) |

The two `FortiWeb password` rows are the **same** `config_attributes.password` field declared twice
with a different `type` and a `conditional_group`, so exactly one is shown depending on the
authentication method.

### Secrets Manager (PAM) authentication

Identical to the Azure Key Vault plugin: the connector stores only a vault reference; at run time
TLM asks the selected PAM connector (BeyondTrust Password Safe, CyberArk CCP, Delinea Secret Server /
Platform) to resolve it and injects the real password into `password`. The plugin **fails closed**
when no value arrives, base64-decodes the value only when it is valid base64 **and** decodes to
printable text (TLM encodes directly-typed secrets; PAM-injected ones may be plain), reads the secret
once per invocation (no caching), and logs only the authentication mode, PAM connector ID and secret
length. Register the PAM connector and run its Test Connection **before** creating this connector,
otherwise the dropdown is empty.

| Provider | Reference format | Example |
|---|---|---|
| BeyondTrust Password Safe | `SystemName/AccountName` | `FortiWeb-Lab/tlm-api` |
| CyberArk CCP | object / secret name | `FortiWebTLM` |
| Delinea Secret Server / Platform | `secretId` or `secretId/fieldSlug` | `42` or `42/password` |

### FortiWeb prerequisites

- **REST API reachable** from the sensor on the management port (default 443; e.g. 8443), and
  **SSH reachable** on the management interface (default 22) unless you accept metadata-only
  discovery. Enable SSH on the interface under *System → Network → Interface → Administrative Access*.
- An **administrator account** for TLM whose access profile grants **Read-Write** on
  *System → Certificates* (local certificates, SNI, multi-certificate) and *Server Policy*
  (to repoint `certificate`), with CLI access allowed so `show system certificate local` works over
  SSH. Prefer a dedicated least-privilege account: the token base64-decodes to its credentials.
- If ADOMs are enabled, the account's ADOM name in the *FortiWeb ADOM* field.
- Version: validated API surface is **FortiWeb 8.0.5**; 7.x is expected to work (the endpoints date
  back to 6.x). Confirm with the runbook — in particular `pkey_type` codes (RSA = 1, ECDSA = 3
  observed), the `can_delete` flag, and that the stored name is derived from the uploaded file name.
- Intermediate CA certificates are **not** managed by this plugin: configure the DigiCert
  intermediate under *System → Certificates → Intermediate CA* (or a CA group) once; the uploaded
  local certificate file contains only the leaf unless `useCommonIca` is set on the request.

## Prerequisites (build)

- **Java 17+**, **Maven 3.6+**
- Access to the DigiCert TLM Plugin SDK on GitHub Packages (`com.digicert.tlm:plugin-sdk:1.1`) and
  to Maven Central (BouncyCastle, Apache MINA SSHD, EdDSA, Jackson, SLF4J).

## Building

```bash
export GITHUB_ACTOR=<your-github-username>
export GITHUB_TOKEN=<token-with-read:packages>
./build.sh           # or: mvn clean package -s settings.xml -U
```

Artifacts:
- `target/fortiweb-automation-plugin-1.0.0.jar` — fat (shaded) JAR
- `plugin-dist/fortiweb-automation-plugin-1.0.0.zip` — TLM distribution package (jar + `plugin-meta.json`)
- `plugin-dist/checksums` — SHA-256 checksum

The fat JAR is built with the **Maven Shade plugin**; jar signatures are stripped (BouncyCastle ships
signed jars and a shaded jar cannot keep them). The plugin itself uses BC only for PKCS#10 ASN.1;
Apache MINA SSHD additionally registers the BC and EdDSA providers at runtime for the SSH session,
which has been verified to work from the shaded jar on a Linux sensor (JDK 17). The TLM `SdkRuntime`
eagerly loads every class on the classpath at startup; the packaged jar has been verified to load all
of its classes without a `NoClassDefFoundError` (the `eddsa` dependency exists solely for that scan,
as in the Kubernetes plugin). Re-verify after any dependency bump.

## Project structure

```
src/main/java/com/example/automation/
├── FortiWebAutomationPlugin.java          # 5 lifecycle methods (SDK entry point), stable endpoint assignment, SSH port resolution
├── FortiWebAutomationPluginRunner.java    # main() runner
├── adapter/
│   ├── AdapterConfig.java                 # host / port / sshPort / username / password / vdom → API token
│   ├── FortiWebRestClient.java            # JDK HttpClient: GET/PUT/DELETE/multipart, FortiWeb errcode handling
│   ├── FortiWebSshClient.java             # Apache MINA SSHD: read-only "show system certificate local" + parser
│   └── FortiWebAdapter.java               # list, reference scan, import, repoint, delete, validate, PEM fetch
├── helper/
│   ├── CertificateAttributesUtil.java     # CN parsing, FortiWeb-safe unique names, serial comparison
│   ├── ReplacementResolver.java           # which certificate an install replaces: alias → thumbprint → endpoint → subject
│   └── FortiWebAutomationPluginHelper.java# key+CSR generation, flow directory, artifact download/extract
├── model/                                 # Result, ErrorCode, FortiWebCertificate, CertificateReference, FlowRecord, …
└── extended/                              # TLM request/response/config extensions
configuration.json                         # TLM connector UI definition (field names matter: userName, sshPort, …)
runbook/fortiweb-runbook.sh                # curl/ssh helper that performs each RUNBOOK step by hand
RUNBOOK.md                                 # manual test procedure (run before uploading to TLM)
```

## Notes & limitations

- **One appliance per connector.** Host + port form the unique key; configure one connector per
  FortiWeb (or per ADOM).
- **Same sensor for CSR and install.** The private key lives in the sensor's temp directory between
  the two calls (owner-only permissions on Linux; inherited ACLs on Windows) and is deleted after a
  successful import. Flow directories of failed flows are left for diagnosis.
- **Rotation, not overwrite.** The new certificate always gets a new name; the old one is deleted
  only when FortiWeb reports it unreferenced. Tick *Keep the replaced certificate* to skip deletion.
- **Object types scanned** for references: server policy `certificate`, SNI member `local-cert`,
  multi-cert group `rsa-cert`/`ecc-cert`/`dsa-cert`. Other consumers (e.g. an SNI member's
  `multi-local-cert-group`, XML-protection or SAML certificates) are not repointed; FortiWeb's
  `can_delete` gate then keeps the old certificate in place for manual review.
- **Certificate body in discovery** comes from the CLI over SSH (see above). With SSH disabled
  (`0`) or unreachable, TLM shows the endpoint but no selectable certificate, because it never
  received a PEM.
- **SSH is read-only.** The plugin runs exactly one `show` command and never enters `config` mode
  over SSH; all changes go through the REST API. Host keys are accepted without verification, like
  the trust-all TLS towards the REST API.
- **Key types.** RSA (2048/3072/4096) and EC (P-256/384/521, from `keySize`) with SHA-256/384/512
  signatures, as requested by TLM.
- **Stale TLM alias.** TLM keeps the alias it first discovered for an endpoint. After a rotation the
  alias names a certificate that no longer exists; the install copes (thumbprint / endpoint / SAN
  resolution) and the log states which rule matched. Re-running discovery refreshes the alias.
- **Runtime log noise.** Benign lines to expect: the SLF4J "multiple providers" warning at startup
  (the TLM provider is selected), SSHD's `AcceptAllServerKeyVerifier … presented unverified EdDSA
  key` warning (host keys are deliberately not verified), and the REST download attempts logged as
  `HTTP 500 … errcode -20007` during discovery (expected on 8.0.5; the body then comes from SSH).
