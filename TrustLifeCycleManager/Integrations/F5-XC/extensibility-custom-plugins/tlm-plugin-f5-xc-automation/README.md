# tlm-plugin-f5-xc-automation

A DigiCert Trust Lifecycle Manager (TLM) automation plugin that manages **F5 Distributed Cloud (F5‑XC)** certificate objects.

## Overview

This plugin integrates with DigiCert TLM and automates the certificate lifecycle for F5‑XC
**certificate objects** (`/api/config/namespaces/{namespace}/certificates`). It extends
`AbstractAutomationWorkflow` and authenticates to the F5‑XC REST API with an **API Token**
(`Authorization: APIToken <token>`).

F5‑XC uses a **decentralized (CSR‑based)** enrollment model: the sensor generates the key pair
and CSR during `generateCsr` and retains the private key locally (keyed by the TLM `flowId`); TLM
issues the certificate from that CSR. `installCertificate` then downloads the issued certificate
chain, pairs it with the retained private key, and uploads both as a single named certificate
object — mirroring the deployment performed manually by the reference script `f5_xc-awr.sh`.

## Features

- **Test Connection** – Lists certificate objects in the configured namespace to validate API token + namespace.
- **Generate CSR** – Generates the key pair + PKCS#10 CSR on the sensor (RSA/EC, with SANs from `dnsNames`), retains the private key under the `flowId`, and returns the CSR.
- **Install Certificate** – Downloads the issued certificate chain, reads back the retained private key, then **POSTs** (create) or **PUTs** (replace) the named certificate object.
- **Validate Certificate** – Fetches the certificate object and compares the served certificate's serial number against the expected value **numerically** (with retry).
- **Refresh Configuration** – Enumerates certificate objects in the namespace and returns consolidated automation info, data‑IP info, and certificate details. Each object becomes its own TLM endpoint keyed by object name (see [Endpoint identity](#endpoint-identity-why-location-is-the-certificate-object-name)).

## Configuration

| Field | Type | Description |
|---|---|---|
| `tenant` | `String` | F5‑XC tenant short name. Base URL is derived as `https://<tenant>.console.ves.volterra.io`. A full `https://…` URL is also accepted for custom domains. |
| `namespace` | `String` | F5‑XC namespace that owns the certificate objects (e.g. `default`). |
| `apiToken` | `String` | F5‑XC API Token (sensitive). Sent as `Authorization: APIToken <token>`. |
| `authentication_method` | `select` | *Self-authentication (Direct input)* (default) or *Self-authentication (Secrets manager)* — see [Secrets Manager (PAM) authentication](#secrets-manager-pam-authentication). |
| `pam_connector_id` | `select` | Secrets-manager mode only. Dynamic TLM list of registered PAM connectors (`options_provider: PamConnectors`). |

HTTP timeouts: connect = 30 s, per‑request = 60 s.

In `configuration.json` the `apiToken` field is declared **twice** with a different `type` and a
`conditional_group`: as a `password` (*F5‑XC API Token*) in direct-input mode, and as a plain `input`
(*F5‑XC API Token (PAM vault reference)*) in secrets-manager mode. Exactly one is shown depending on
the selected authentication method.

## Secrets Manager (PAM) authentication

The API token can be kept in an external privileged-access vault instead of in TLM. The connector
then stores only a **vault reference**; at run time TLM asks the selected **Secrets Manager (PAM)
connector** (BeyondTrust Password Safe, CyberArk CCP, or Delinea Secret Server / Platform) to resolve
that reference and injects the real token into the plugin's `apiToken` field. The plugin never talks
to the vault itself and never sees the reference — it only receives the resolved token.

1. **Register the PAM connector first** in TLM and run its **Test Connection**. The
   `Secrets manager connector` dropdown on this plugin is populated from registered PAM connectors.
2. **Add this connector**, set **Authentication method → Self-authentication (Secrets manager)** and
   select the PAM connector.
3. **Enter the vault reference** for the API token (the UI shows a banner per provider):

   | Provider | Reference format | Example |
   |---|---|---|
   | BeyondTrust Password Safe | `SystemName/AccountName` | `F5XC/svc-tlm-api` |
   | CyberArk CCP | object / secret name (the Safe is fixed on the PAM connector) | `F5XCApiToken` |
   | Delinea Secret Server / Platform | `secretId` or `secretId/fieldSlug` (`fieldSlug` defaults to `password`) | `42` or `42/password` |

4. **Run Test Connection** on this connector.

Plugin behaviour in secrets-manager mode:

- **Fail closed.** If the token arrives empty (unknown reference, no permission, PAM connector
  unreachable), `testConnection`, `installCertificate`, `validateCertificate` and
  `refreshConfiguration` fail with a `WorkflowExecutionException` naming the PAM connector instead of
  calling F5‑XC with an empty `Authorization` header. `generateCsr` is local to the sensor and is
  not affected.
- **No caching.** The token is read once per plugin invocation, so rotating it in the vault takes
  effect on the next TLM workflow run.
- **Logging.** The plugin logs the authentication mode, the PAM connector ID and the token's length,
  never the token or the reference.
- `authenticationMethod` / `pamConnectorId` exist on `F5XCPluginConfiguration` for diagnostics only;
  the F5‑XC calls are identical in both modes.

## Identifier convention

The managed asset is a **certificate object**, keyed by name within a namespace. TLM carries it as
`virtualServerName = <namespace>/<certName>`; the trailing segment is the F5‑XC certificate name used
by install/validate. Discovery sets `partition = namespace` and `alias = certName`, and uses the
certificate object name as the endpoint location (see
[Endpoint identity](#endpoint-identity-why-location-is-the-certificate-object-name)).

## Workflow Operations

### testConnection
`GET /api/config/namespaces/{namespace}/certificates` — returns `active: true` on HTTP 2xx.

### generateCsr
Generates an RSA/EC key pair and PKCS#10 CSR (subject from `subjectDn`, SANs from `dnsNames`), writes
the private key to `<java.io.tmpdir>/F5XCAutomationPlugin/<flowId>/request.key`, and returns the CSR.
`installCertificate` reads that key back. **This requires `generateCsr` and `installCertificate` to
run on the same sensor** (they share the local temp directory, correlated by `flowId`).

### installCertificate
1. Downloads the issued certificate artifact from DigiCert One (`certificateLink`).
2. Extracts the certificate **chain** (auto‑detects ZIP‑with‑PEM or a raw PEM). The key is **not** taken
   from the artifact.
3. Reads the private key retained by `generateCsr` for this `flowId`.
4. Base64‑encodes each as `string:///<base64>`.
5. `GET` to check existence, then `POST` (create) or `PUT` (replace) the certificate object:
   ```json
   {
     "metadata": { "name": "<certName>", "namespace": "<namespace>" },
     "spec": {
       "certificate_url": "string:///<b64 cert chain PEM>",
       "private_key": { "clear_secret_info": { "url": "string:///<b64 key PEM>" } }
     }
   }
   ```

### validateCertificate
`GET` the certificate object, decode `spec.certificate_url`, parse the leaf certificate, and compare its
serial number against `certificateSerialNumber`. The comparison is **numeric** (`BigInteger`), so it is
insensitive to hex case and to a leading zero / DER sign‑padding byte. Retries up to 3 times.

### refreshConfiguration
Lists certificate objects, fetches each, decodes the PEM, derives the CN, and returns
`automationInfo` + `dataIpInfo[]` + `certificates[]`. Each certificate object is reported as a distinct
TLM endpoint keyed by the object name — see [Endpoint identity](#endpoint-identity-why-location-is-the-certificate-object-name).

## Endpoint identity (why `Location` is the certificate object name)

TLM models automation around network endpoints and keys each endpoint on **`ipAddress:port`** — the
value shown as **Location** in *Inventory → Endpoints*. F5‑XC, however, is API‑managed: a certificate
object has **no per‑object IP**; it is identified only by its **name within a namespace**.

Discovery therefore reports each certificate object as:

| Field | Value | Purpose |
|---|---|---|
| `ipAddress` / `dataIp` | the **certificate object name** (e.g. `f5-xc-digicert-demo`) | endpoint key |
| `ipAndPort` | `<objectName>:443` | the **Location** shown in the UI |
| `domainName` | the certificate CN | shown under **Common name** |
| `partition` / `alias` | `<namespace>` / `<certName>` | TLM forms `virtualServerName = <namespace>/<certName>`, consumed by install/validate |

This makes **each certificate object its own TLM endpoint**, even when several objects share a common
name or sit behind the same F5‑XC load‑balancer VIP.

### Why not the VIP?
An earlier version resolved each certificate's CN to the F5‑XC load‑balancer VIP and used `<VIP>:443`
as the location. Because every object behind that VIP — and any two objects sharing a CN — produced the
**same** `ipAddress:port`, TLM collapsed them into a **single endpoint**. Symptoms:

- Only one of several certificate objects appears in Inventory (others silently merged).
- A renewal/switch targets the wrong — or a stale, already‑deleted — object name.
- Deleting and recreating the connector is the only way to clear the stale endpoint.

Note that `ipAndPort` is **not** the endpoint key (it is a display/correlation field): changing only
`ipAndPort` did **not** split the endpoints. The key is `ipAddress:port`, which is why `ipAddress`
carries the unique object name.

### Trade‑off
The F5‑XC VIP no longer appears in the `Location`/IP column (the certificate CN is still shown under
**Common name**). This is intentional — the object name is the only value guaranteed unique per
certificate object. TLM accepts a non‑IP value in `ipAddress` (verified in use).

### If this regresses
If certificate objects start collapsing into one endpoint again (one row for several objects, or a
renewal hitting the wrong object), inspect `RefreshConfigurationService.buildCertificatePair`:
`ipAddress`/`dataIp` and `ipAndPort` must be derived from the **object name**, not from a CN‑resolved
IP/VIP. The classic regression is reintroducing `NetworkApiAdapter.getIp(commonName)` as the `dataIp`.
A unit test that feeds two objects with the **same CN** and asserts they produce **distinct**
`ipAddress`/`ipAndPort` values would catch this on the build.

## Building

```bash
mvn clean package -s settings.xml
```

Artifacts land in `target/` and `plugin-dist/`.

## Assumptions to verify

- **Decentralized enrollment.** The TLM certificate profile must use **CSR / decentralized** enrollment
  so the workflow calls `generateCsr`. (A centralized / DigiCert‑generated‑key profile would skip it, and
  `installCertificate` would have no retained key to upload.)
- **Same‑sensor key retention.** `generateCsr` and `installCertificate` exchange the private key through
  the sensor's local temp directory, correlated by `flowId`. If your deployment can dispatch these two
  steps to **different sensors**, the key would not be found at install time.
- **Issued artifact format.** Chain extraction handles a ZIP of PEM certificate(s) or a raw PEM
  (`AutomationPluginHelper.extractCertificateChain`). The private key is **not** read from the artifact —
  it is the key the sensor generated in `generateCsr`.
- **Inline certificate.** Discovery/validate read `spec.certificate_url`. Managed/auto (Let's Encrypt)
  certs without an inline PEM are skipped during discovery.
- **Non‑IP endpoint address.** Discovery puts the certificate object name in `ipAddress` (see
  [Endpoint identity](#endpoint-identity-why-location-is-the-certificate-object-name)). TLM currently
  accepts this; if a future TLM release validates `ipAddress` as a real IP, the endpoint‑locator scheme
  would need revisiting.

## Testing conventions

See `CLAUDE.md` — flat `@Test` methods (no `@Nested`), `@DisplayName` on every test, integration tests
named `*IT.java` (`@Tag("integration")`, WireMock‑stubbed), Mockito only for SDK constructor types.
