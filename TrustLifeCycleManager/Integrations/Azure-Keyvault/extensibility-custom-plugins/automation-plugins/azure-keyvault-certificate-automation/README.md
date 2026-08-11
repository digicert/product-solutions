# Azure Key Vault Automation Plugin

A custom plugin built on **DigiCert Trust Lifecycle Manager (TLM) extensibility** — a Java automation
plugin, implemented against the TLM Plugin SDK and uploaded to TLM, that manages the certificate
lifecycle in a single **Azure Key Vault**. It discovers the certificate objects held in the vault,
generates CSRs inside Key Vault (**the private key never leaves Azure**), and merges the CA-signed
certificate back in as a new version — all driven by TLM.

The plugin extends `AbstractAutomationWorkflow` and implements the five TLM lifecycle operations:

| Operation | Azure Key Vault action (Certificates SDK) |
|---|---|
| `testConnection` | `listPropertiesOfCertificates` (first page) — exercises auth + list permission |
| `refreshConfiguration` | `listPropertiesOfCertificates`, then `getCertificate` per object for the active PEM / subject / thumbprint / enabled / expiry |
| `generateCsr` | `beginCreateCertificate(name, policy)` with the **`Unknown`** issuer → read `CertificateOperation.getCsr()` (PEM-wrapped) |
| `installCertificate` | Convert the signed chain to DER → `mergeCertificate(name, [DER…])` (completes the pending version) |
| `validateCertificate` | `getCertificate(name)` → active cert as PEM |

## Architecture

```
TLM  ──JSON──►  AzureKeyvaultAutomationPlugin      (SDK entry point: the 5 lifecycle methods)
                        │  builds AdapterConfig, resolves the target certificate name
                        ▼
                AzureKeyVaultAdapter               (all Key Vault logic; returns Result<T>)
                        │  CertificateClient (data plane), explicit Netty HTTP client
                        ▼
                Azure Key Vault  (https://<vault>.vault.azure.net)
```

- **Data plane only.** The plugin talks to the vault by **URL** using an Azure AD **client-secret
  credential** (`AzureCredentialsProvider` → `ClientSecretCredential`). It does **not** use Azure
  Resource Manager, so no subscription ID is needed and it works across subscriptions/tenants — the
  vault URL uniquely identifies one vault. One connector = one vault.
- **Private key custody.** Because the issuer is `"Unknown"`, Azure generates the key pair **inside
  the vault**, returns a PKCS#10 CSR, and holds the certificate *pending* until the signed cert is
  merged. The plugin only ever handles public material (the CSR and the signed chain); the private
  key is never transmitted or written to disk outside Azure.
- **Proxy / TLS.** An explicit Netty HTTP client is passed to every SDK client builder. This keeps
  the plugin proxy-aware (honours JVM proxy system properties), trusts the endpoint via an insecure
  trust manager (supports TLS-inspecting egress proxies), and avoids the Azure SDK's
  `HttpClientProvider` `ServiceLoader` lookup — which is fragile inside a shaded fat jar.

## The "create a new version" use case

Azure Key Vault treats a create against an **existing certificate name** as a **new version** of
that certificate. That is the core flow:

1. `refreshConfiguration` **discovers every certificate object** in the vault as a selectable asset,
   carrying its Azure certificate **name** (round-tripped as the asset alias), subject, thumbprint,
   expiry, enabled state, and a self-signed flag.
2. When a discovered certificate has **no managed TLM certificate yet**, the customer selects it in
   TLM. On the follow-up generate/install request, TLM round-trips that asset's identity in the
   `virtualServerName` field as `<partition>/<name>` (e.g. `null/selfsigned-certificate`).
3. `generateCsr` resolves the target name (see below), calls `beginCreateCertificate` with it → Azure
   starts a **new version** and returns a CSR. `installCertificate` then `mergeCertificate`s the
   CA-signed certificate into that pending version, completing it as the new active version of the
   **same** certificate — no duplicate object is created.

### Certificate-name resolution

`resolveCertName` picks the Key Vault certificate name to target in priority order:

1. an explicit **`certificateName`** extended-request field (user override), else
2. the **`virtualServerName`** round-trip — the discovered asset's name with the `<partition>/`
   prefix stripped, used **verbatim** so the new version lands on the existing object, else
3. a derived **`CN-date-flow`** value for a brand-new certificate.

Derived/override names are sanitized to Azure's rules (`^[0-9a-zA-Z-]+$`, ≤127 chars); a name coming
from an existing discovered asset is used as-is so it matches exactly.

## Asset discovery & the endpoint model

TLM's automation inventory is **endpoint-centric** — a certificate renders only when it is anchored
to a data `IP:port` (the F5/NetScaler "cert in use on a virtual server" model), and TLM keys
endpoints by `dataIp:port`. A Key Vault has no per-certificate data-plane IP:port, so discovery
synthesizes a **unique endpoint per certificate** using its name as the host:
`<certName>.<vaultHost>:443` (e.g. `test-03.myvault.vault.azure.net:443`).

- Uniqueness is essential: a single shared host would collapse every certificate onto one endpoint,
  so TLM would keep only the first alias and every renewal would target that first certificate.
- The alias (and therefore the round-tripped `virtualServerName`) is the bare certificate name, so
  each certificate is inventoried and renewed independently.
- **Disabled certificates**: Azure blocks reading a disabled certificate's material, so those are
  surfaced as name/thumbprint-only assets (no PEM/subject) until re-enabled — they still appear.
- **"In use" detection**: Key Vault has no API to report which external services (Application
  Gateway, Front Door, App Service, …) consume a certificate, so discovery reports certificate
  metadata (enabled / expiry / thumbprint / self-signed) rather than a live binding state. Every
  certificate object is shown so an operator can choose what to renew.

## CSR subject handling

TLM subject DNs are normalized before being sent to Azure (`policy.x509_props.subject`):

- **Email is moved to the SAN.** Azure rejects `emailAddress=` in the subject as an invalid X.500
  name, so `toAzureSubject` strips it and `getEmailAddresses` re-adds it via
  `SubjectAlternativeNames.setEmails`. RDN order and escaping (e.g. `O=Acme\, LLC`) are preserved.
- **CN-only fallback.** If Azure still rejects the subject as an invalid distinguished name,
  `generateCsr` retries once with a `CN=<commonName>` subject and logs a `WARN`. For most DigiCert
  products the issued certificate's subject comes from the TLM order (not the CSR), so this only
  affects the CSR itself and keeps the renewal from hard-failing. The full subject is logged for
  diagnosis.

## Connector configuration (TLM)

Defined in `configuration.json` and surfaced in the TLM connector UI:

| Field | Type | Notes |
|---|---|---|
| Managing Sensor | select | Dynamic TLM list (`options_provider: Sensors`) |
| Azure Tenant ID | input | Azure AD directory (tenant) ID |
| Azure Client ID (App Registration) | input | Application (client) ID of the service principal |
| Azure Client Secret | password | Stored as a sensitive credential |
| Key Vault URL | input | `https://<vault>.vault.azure.net/` — the connector unique key |
| Exclude expired certificates from discovery | checkbox | Optional; default off (show all) |
| Exclude disabled certificates from discovery | checkbox | Optional; default off (show all) |

`Name` and `Business Unit` are TLM connector-level fields managed by TLM itself.

The two **exclude** options trim the discovery inventory (filtered on the cheap list metadata before
any per-certificate fetch; skips are logged). Both default to off so the connector shows every
certificate — including expired, disabled and self-signed ones, which are exactly the certificates an
operator may want to replace. Note TLM also offers a native "Exclude expired certificates" toggle on
its certificate-import screen; the plugin-side flag additionally trims the automation inventory.

### Azure prerequisites

- An **Azure AD app registration / service principal** (Tenant ID, Client ID, Client Secret).
- A **Key Vault access policy** (or Azure RBAC role such as *Key Vault Certificates Officer*)
  granting the service principal certificate **get / list / create / merge** permissions on the vault.
- The **vault URL**, e.g. `https://myvault.vault.azure.net/`.
- Network egress to `login.microsoftonline.com` and the vault endpoint.

## Prerequisites (build)

- **Java 17+**
- **Maven 3.6+**
- Access to the DigiCert TLM Plugin SDK on GitHub Packages
  (`com.digicert.tlm:plugin-sdk:1.1`) and to Maven Central for the Azure SDK BOM.

## Building

```bash
export GITHUB_ACTOR=<your-github-username>
export GITHUB_TOKEN=<token-with-read:packages>
./build.sh           # or: mvn clean package -s settings.xml -U
```

Artifacts:
- `target/azurekeyvault-automation-plugin-1.0.0.jar` — fat (shaded) JAR
- `plugin-dist/azurekeyvault-automation-plugin-1.0.0.zip` — TLM distribution package
- `plugin-dist/checksums` — SHA-256 checksums

### Fat-jar packaging notes (for maintainers)

The fat JAR is built with the **Maven Shade plugin** (not Assembly) because the Azure SDK resolves
providers through `META-INF/services`, and Shade's `ServicesResourceTransformer` merges those entries
across the many `com.azure.*` jars into one uber jar (`minimizeJar` is deliberately **off** — the SDK
loads classes reflectively).

The TLM `SdkRuntime` eagerly loads **every** class on the classpath at startup (Guava
`ClassPath.load`). Netty and Reactor ship "optional integration" glue classes whose
superclass/interface lives in an **optional** dependency we don't bundle (Kotlin, BlockHound,
Micrometer context, Conscrypt/Jetty alternative TLS, JBoss Marshalling, Zstd, Log4j2). Those are
never used here but the eager scan force-loads them and crashes with `NoClassDefFoundError`, so they
are stripped from the jar via `pom.xml` shade `<excludes>`. **After any Azure SDK / Netty / Reactor
version bump, re-verify** there are no classes whose supertype is unresolvable (a new version can
introduce new optional-integration classes).

## Project structure

```
src/main/java/com/example/automation/
├── AzureKeyvaultAutomationPlugin.java              # 5 lifecycle methods (SDK entry point) + name/endpoint resolution
├── AzureKeyvaultAutomationPluginRunner.java        # main() runner
├── adapter/
│   ├── AdapterConfig.java                          # tenant / client / secret / vault URL
│   ├── AzureCredentialsProvider.java               # ClientSecretCredential + Netty HttpClient
│   └── AzureKeyVaultAdapter.java                    # all Key Vault certificate logic
├── helper/
│   ├── CertificateAttributesUtil.java              # subject-DN parsing/normalization + Azure-valid name builder
│   └── AzureKeyvaultAutomationPluginHelper.java     # cert artifact download / ZIP extract / chain split
├── model/                                          # Result, ErrorCode, config/discovery DTOs
└── extended/                                       # TLM request/response/config extensions
```

## Notes & limitations

- **One vault per connector.** The connector addresses a single Key Vault (the URL is the unique
  key). To manage multiple vaults, configure one connector per vault. (Subscription-wide discovery
  via ARM was deliberately not implemented — it needs broader RBAC, a heavier dependency, and
  complicates the per-endpoint identity.)
- **New-version semantics.** Installing renews **in place** by creating a new version of the target
  certificate name — no unbinding or endpoint rebind. `currentCertificateThumbprint` is logged for
  traceability; Azure's versioning makes an explicit swap unnecessary.
- **Chain merge.** The signed end-entity certificate is always merged; the intermediate is included
  in the merge when the request sets `useCommonIca`.
- **Key types.** RSA (with key size) and EC (curve `P-<size>`, default `P-256`) are supported via the
  certificate policy. Keys are software-protected; HSM-backed keys would require a Premium vault and
  switching the policy key type to `RSA-HSM`/`EC-HSM`.
- **Runtime log noise.** Two benign messages appear in the plugin log: the SLF4J "multiple providers"
  warning (the TLM provider is correctly selected) and an Azure `INFO` about Netty version detection
  (a side effect of shading; "can be ignored"). Neither indicates a failure.
