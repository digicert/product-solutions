# Azure Key Vault Automation Plugin — subscription scope

A custom plugin built on **DigiCert Trust Lifecycle Manager (TLM) extensibility** that maps **one
connector to one Azure subscription**. It enumerates every Key Vault in the subscription through
Azure Resource Manager, discovers the certificate objects in each vault into the TLM automation
inventory, generates CSRs inside Key Vault (**the private key never leaves Azure**) and merges the
CA-signed certificate back in as a new version of the same object — in whichever vault it lives.

It is a sibling of the single-vault plugin in
[`../azure-keyvault-certificate-automation/`](../azure-keyvault-certificate-automation/), which maps
one connector to one vault by URL. The lifecycle logic, authentication path, PAM support and
packaging are the same; this variant adds a control-plane step and a vault-aware asset identity.
The single-vault plugin is untouched and both can be installed side by side (different plugin names
and artifact ids).

| | Single-vault plugin | This plugin |
|---|---|---|
| Connector unique key | Key Vault URL | **Subscription ID** |
| Vaults per connector | 1 | every vault in the subscription (optionally filtered) |
| Azure control plane | not used | **ARM** `Microsoft.KeyVault/vaults` list (Reader role) |
| Asset identity round-tripped by TLM | `<alias>` = certificate name | `<partition>/<alias>` = **`<vault>/<certificate>`** |
| Plugin / artifact | `AzureKeyvaultAutomationPlugin` / `azurekeyvault-automation-plugin` | `AzureKeyvaultSubscriptionAutomationPlugin` / `azurekeyvault-subscription-automation-plugin` |

> The folder is named `…-multi-tenant` as requested; technically the scope is **one subscription in
> one Azure AD tenant**. A second subscription (same or another tenant) is a second connector.

## Lifecycle operations

| Operation | What happens |
|---|---|
| `testConnection` | ARM lists the vaults of the subscription (proves the Reader role), then the first page of certificates is read from **every** listed vault. Vaults this principal cannot read are logged and skipped (see *Which vaults are discovered*); the test fails only if ARM fails or no vault at all is readable. |
| `refreshConfiguration` | ARM vault list → per readable vault `listPropertiesOfCertificates` + `getCertificate` per object. Unreadable vaults are skipped and logged; the rest are still discovered. |
| `generateCsr` | Resolves the target vault + certificate name (see below) → `beginCreateCertificate(name, policy)` with the **`Unknown`** issuer in that vault → CSR. The chosen target is also recorded per flow on the sensor. |
| `installCertificate` | Signed chain → DER → `mergeCertificate` into the pending version in the same vault. |
| `validateCertificate` | `getCertificate` from that vault → active certificate as PEM. |

## Architecture

```
TLM ──JSON──► AzureKeyvaultSubscriptionAutomationPlugin   (SDK entry point: 5 lifecycle methods,
                      │                                     (vault, certificate) target resolution)
                      ▼
              AzureKeyVaultSubscriptionAdapter            (all vault logic; one cached
                      │                  │                  CertificateClient per vault URI)
                      ▼                  ▼
   AzureResourceManagerClient     CertificateClient (per vault)
   GET management.azure.com       https://<vault>.vault.azure.net
   /subscriptions/{id}/providers/
   Microsoft.KeyVault/vaults
```

- **Control plane via plain REST.** The ARM listing is two GET calls on the azure-core
  `HttpPipeline` (Netty client, bearer-token policy with scope `https://management.azure.com/.default`,
  retry). No `azure-resourcemanager-*` library is added, so the shaded jar contains the same
  dependency set as the single-vault plugin (verified: 0 unresolvable classes in the fat-jar scan).
- **Same credential for both planes.** One Azure AD client-secret credential is used for ARM and
  for every vault's data plane.
- **Proxy / TLS.** As in the single-vault plugin: explicit Netty client, JVM proxy properties
  honoured, insecure trust manager for TLS-inspecting egress.

## Which vaults are discovered

Two different permissions are involved, and it is normal for them to cover different sets of vaults:

| Plane | Call | Permission | Effect |
|---|---|---|---|
| Control plane | ARM `Microsoft.KeyVault/vaults` list | **Reader** on the subscription (or the filtered resource groups) | Decides which vaults are **listed**. Reader sees every vault in scope, including vaults whose certificates are managed by *other* service principals / connectors. |
| Data plane | `listPropertiesOfCertificates`, `getCertificate`, … | certificate **get / list / create** on the individual vault (RBAC or access policy) | Decides which listed vaults are actually **read and managed**. |

So a vault that is bound to a different app registration will appear in the ARM listing but, as long
as this connector's principal has no certificate permission on it, its certificates are never read:
discovery skips it (logged with the reason) and Test Connection reports it as skipped. Only if the
principal *does* hold a data-plane role there — for example **Key Vault Certificates Officer** or
**Key Vault Administrator** assigned **at subscription scope**, which covers every RBAC-enabled vault
beneath it — will its certificates be discovered too. (Key Vault Administrator at subscription scope
is what the lab provisioning script grants, which is why a connector with any of the lab's app
registrations sees and manages every lab vault; it also covers the ARM listing, so no separate Reader
role is needed in that setup.) If that is not wanted, either scope the data-plane role to the intended vaults or
resource groups, or use the connector's resource-group / vault-name / tag filters to keep the ARM
listing itself to the vaults this connector should own.

## Asset identity across vaults

TLM's automation inventory is endpoint-centric and keys endpoints by `dataIp:port`. The plugin
synthesises one endpoint per certificate, `<certName>.<vaultHost>:443`
(e.g. `web-01.kv-prod.vault.azure.net:443`), which is unique across vaults because the vault FQDN
is part of it. Each endpoint carries

- **partition** = the vault's short name (`kv-prod`),
- **alias** = the certificate object name (`web-01`).

TLM round-trips the selected asset as `virtualServerName = "<partition>/<alias>"`, i.e.
`kv-prod/web-01`, which is how a renewal request finds both the vault and the object. The
`AutomationInfo` of the connector reports the subscription (display name when readable) as the host,
and lists all vault names in `partitions`.

### Target resolution (`generateCsr` / `installCertificate` / `validateCertificate`)

This connector **only renews or replaces certificates that already exist in a vault** (typically
switching a self-signed or third-party object to a DigiCert-issued one as a new version). It never
invents a name for a brand-new object, so there is no naming convention and no "default vault".

Certificate name, in priority order — both used **verbatim** so the new version lands on the
existing object:

1. explicit `certificateName` on the request, optionally written as `<vault>/<name>`;
2. the alias from `virtualServerName` (the discovered asset);
3. neither present → the request fails with `CERTIFICATE_NOT_TARGETED`.

Vault, in priority order:

1. explicit `vaultName` on the request;
2. the `<vault>/` prefix of `certificateName`;
3. the partition of `virtualServerName`;
4. for install/validate only: the target recorded by `generateCsr` for the same flow id
   (`<tmp>/AzureKeyvaultSubscriptionAutomationPlugin/<flowId>/target.txt`);
5. the **single** readable vault in the subscription that holds a certificate of that name — an
   ambiguous name (`AMBIGUOUS_TARGET`) or no hit (`VAULT_NOT_FOUND`) is an error, never a guess.

Vault names are resolved against the ARM listing (refreshed on a miss). Only if ARM is unreachable
does the plugin fall back to the public-cloud form `https://<name>.vault.azure.net/`.

## Connector configuration (TLM)

Defined in `configuration.json`:

| Field | Type | Notes |
|---|---|---|
| Managing Sensor | select | Dynamic TLM list (`options_provider: Sensors`) |
| Azure Tenant ID | input | Azure AD directory (tenant) ID |
| Azure Client ID (App Registration) | input | Application (client) ID of the service principal |
| Authentication method | select | *Direct input* (default) or *Secrets manager* (PAM) — identical to the single-vault plugin |
| Azure Client Secret / PAM vault reference | password / input | One of the two is shown depending on the method |
| Secrets manager connector | select | PAM mode only (`options_provider: PamConnectors`) |
| **Azure Subscription ID** | input | **Connector unique key.** The subscription whose vaults are managed |
| Resource groups (optional) | input | Comma-separated. Limits discovery to those groups; Reader is then only needed on them |
| Vault name pattern (optional) | input | Case-insensitive regex a vault name must match, e.g. `^prod-.*` |
| Vault tag filter (optional) | input | `key=value` (or `key` for presence) a vault must carry, e.g. `tlm-managed=true` |
| Exclude expired / disabled certificates | checkbox | Discovery trimming, default off, as in the single-vault plugin |

The three filters are applied to the ARM listing before any data-plane call. They are the
recommended way to keep a large subscription's inventory (and the principal's blast radius) in check.

## Azure prerequisites

- An **Azure AD app registration / service principal** (tenant ID, client ID, client secret — typed
  into TLM or held in a PAM vault).
- **Control plane:** the **Reader** role (it carries `Microsoft.KeyVault/vaults/read`) on the
  subscription, or on each resource group named in the filter. Reader on the subscription also lets
  the plugin show the subscription's display name; without it the ID is shown.
- **Data plane, on every vault to be managed:** certificate **get / list / create** (`create` also
  authorises `mergeCertificate`). Either model works per vault:
  - RBAC: **Key Vault Certificates Officer** assigned once at **subscription** or **resource-group**
    scope covers every RBAC-enabled vault beneath it; or
  - an **access policy** with those three certificate permissions on each access-policy vault.
- No secrets permission, no Contributor role, no Resource Manager write access.
- Egress to `login.microsoftonline.com`, `management.azure.com` and `*.vault.azure.net`.

A vault that ARM lists but the principal cannot read is skipped by `testConnection` and by
discovery (logged by name). That is the expected state for vaults that belong to other principals or
connectors; grant the data-plane permission only where this connector should manage certificates.

## Building

Same toolchain as the single-vault plugin: Java 17+, Maven 3.6+, access to the TLM Plugin SDK on
GitHub Packages (`com.digicert.tlm:plugin-sdk:1.1`).

```bash
export GITHUB_ACTOR=<your-github-username>
export GITHUB_TOKEN=<token-with-read:packages>
./build.sh           # or: mvn clean package -s settings.xml -U
```

Artifacts:
- `target/azurekeyvault-subscription-automation-plugin-1.0.0.jar` — fat (shaded) JAR
- `plugin-dist/azurekeyvault-subscription-automation-plugin-1.0.0.zip` — TLM distribution package
  (the JAR plus `plugin-meta.json`)
- `plugin-dist/checksums` — SHA-256 of the ZIP

Upload the ZIP together with `configuration.json` to TLM, then add a connector of the new type.

The fat-jar packaging notes from the single-vault README apply unchanged (Shade with
`ServicesResourceTransformer`, optional-integration classes stripped for the SDK's eager class scan).
After any Azure SDK / Netty / Reactor bump, re-run the unresolvable-supertype scan.

## Project structure

```
src/main/java/com/example/automation/
├── AzureKeyvaultSubscriptionAutomationPlugin.java        # 5 lifecycle methods + (vault, cert) target resolution
├── AzureKeyvaultSubscriptionAutomationPluginRunner.java  # main() runner
├── adapter/
│   ├── AdapterConfig.java                                # tenant / client / secret / subscription / filters
│   ├── AzureCredentialsProvider.java                     # ClientSecretCredential + Netty HttpClient (unchanged)
│   ├── AzureResourceManagerClient.java                   # ARM: list vaults (paged, filtered), subscription name
│   └── AzureKeyVaultSubscriptionAdapter.java             # per-vault CertificateClient cache + all lifecycle logic
├── helper/                                               # unchanged: DN parsing, artifact download / ZIP / chain split
├── model/                                                # Result, ErrorCode (+ VAULT_NOT_FOUND, AMBIGUOUS_TARGET,
│                                                         #   CERTIFICATE_NOT_TARGETED, SUBSCRIPTION_NOT_FOUND), KeyVaultInfo, …
└── extended/                                             # TLM config + request DTOs (now carry vaultName)
```

## Notes & limitations

- **One subscription per connector.** Cross-subscription or management-group scope would need a
  different unique key and ARM's `/subscriptions` enumeration; not implemented.
- **Azure public cloud endpoints.** `management.azure.com` and `login.microsoftonline.com` are
  fixed. Sovereign clouds (China, US Government) would need the ARM endpoint, token scope and
  authority host made configurable.
- **Discovery cost scales with the estate.** Every vault is listed and every certificate fetched
  once per refresh, sequentially. Use the filters on large subscriptions; the sensor's
  `PROCESS_TIMEOUT` (30 min in `plugin-meta.json`) bounds a single run.
- **Existing certificates only.** The connector has no "create new certificate" path: a request
  that names no existing object fails with `CERTIFICATE_NOT_TARGETED`. Use the single-vault plugin
  or the native TLM Key Vault connector to deliver brand-new certificates into a vault.
- **Partition round-trip.** The vault travels in the endpoint partition. If a TLM request ever
  arrives without it, the plugin falls back to the flow's recorded target, then to an unambiguous
  subscription-wide lookup by certificate name, and otherwise fails rather than guessing.
- **Same certificate name in several vaults** is fully supported — the endpoints differ by vault
  FQDN — but such a name can no longer be targeted *without* its vault (`AMBIGUOUS_TARGET`).
- Runtime log noise (SLF4J "multiple providers", Netty version INFO) is the same benign output as
  the single-vault plugin.
