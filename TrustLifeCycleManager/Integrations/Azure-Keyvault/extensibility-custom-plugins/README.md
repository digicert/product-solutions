# Extensibility Custom Plugins – Azure Key Vault

This folder contains a **custom plugin built on DigiCert Trust Lifecycle Manager (TLM) extensibility**.

TLM extensibility lets you add support for a target platform that TLM does not integrate with natively. Rather than scripting around the product, you implement the plugin SDK's lifecycle contract in Java, package the result as a distribution ZIP, and upload it to TLM. TLM then treats the platform as a first-class **automation connector** — it appears in the connector UI, discovers certificates into the automation inventory, and participates in scheduled and on-demand renewal exactly like a built-in integration. The plugin runs on a TLM **sensor**, so all traffic to the target platform originates from your own network.

## Contents

| Path | What it is |
|---|---|
| [`automation-plugins/azure-keyvault-certificate-automation/`](automation-plugins/azure-keyvault-certificate-automation/) | Azure Key Vault certificate automation plugin — source, Maven build, TLM connector definition, and prebuilt distribution ZIP |

## What the plugin does

The plugin makes a single **Azure Key Vault** a fully managed automation target in TLM. It extends the SDK's `AbstractAutomationWorkflow` and implements the five lifecycle operations TLM calls:

| Operation | What happens in Azure Key Vault |
|---|---|
| `testConnection` | Lists certificate properties to confirm credentials and list permission |
| `refreshConfiguration` | Discovers every certificate object in the vault, with subject, thumbprint, expiry and enabled state |
| `generateCsr` | Starts a certificate operation with the `Unknown` issuer, so Azure generates the key pair and returns a PKCS#10 CSR |
| `installCertificate` | Merges the DigiCert-signed chain back into the pending version, completing it |
| `validateCertificate` | Reads back the active certificate to confirm the result |

Three properties are worth calling out:

- **The private key never leaves Azure.** Because the certificate is created with the `Unknown` issuer, Key Vault generates and retains the key pair internally and hands out only a CSR. The plugin handles public material exclusively — no key is ever transmitted or written to disk outside Azure.
- **Renewal happens in place, as a new version.** Azure treats a create against an existing certificate name as a new *version* of that certificate. The plugin round-trips each discovered certificate's Azure name so a renewal lands on the existing object instead of creating a duplicate. Nothing needs unbinding or rebinding.
- **Data plane only.** The connector addresses a vault by URL using an Azure AD client-secret credential. It does not use Azure Resource Manager, so no subscription ID is required and it works across subscriptions and tenants. One connector manages one vault.

## Upload artifacts

Two artifacts are uploaded to TLM when the custom integration is registered. Both are produced by the
build (`./build.sh`) and both are committed here, so the plugin can be uploaded without building from
source.

| Artifact | Location | Role |
|---|---|---|
| **Distribution ZIP** | [`plugin-dist/azurekeyvault-automation-plugin-1.0.0.zip`](automation-plugins/azure-keyvault-certificate-automation/plugin-dist/) | The executable payload TLM distributes to the sensor |
| **Connector definition** | [`configuration.json`](automation-plugins/azure-keyvault-certificate-automation/configuration.json) | Declares the connector's UI form, field types, validation and credential handling |
| **Checksums** | [`plugin-dist/checksums`](automation-plugins/azure-keyvault-certificate-automation/plugin-dist/) | SHA-256 of the ZIP, for integrity verification before upload |

### Distribution ZIP

A flat archive containing exactly two entries — no directory structure:

| Entry | Purpose |
|---|---|
| `azurekeyvault-automation-plugin-1.0.0.jar` | Shaded (fat) JAR: plugin classes, the TLM Plugin SDK and the Azure SDK in a single self-contained jar |
| `plugin-meta.json` | Execution manifest: tells the sensor how to launch the plugin on Windows and Linux (`java -jar <jar>`), which environment to set (`JAVA_HOME`, `PATH`) and the runtime limits `MAX_CHUNK` and `PROCESS_TIMEOUT` |

The plugin name and version in `plugin-meta.json` must match the JAR filename inside the ZIP. Both are
generated from the Maven coordinates, so a version bump in `pom.xml` keeps them aligned automatically.

### Connector definition (`configuration.json`)

Uploaded alongside the ZIP and rendered directly as the connector form in TLM. It defines three groups:

- **`core_settings`** — the Managing Sensor selector, populated dynamically by TLM (`options_provider: Sensors`).
- **`config_settings`** — Azure Tenant ID, Client ID, Client Secret, Key Vault URL, and the two optional
  discovery filters (exclude expired / exclude disabled certificates).
- **`credential_sets`** — declares `config_attributes.clientSecret` as **sensitive** (stored encrypted,
  never returned to the UI) and `config_attributes.keyVaultUrl` as the connector's **unique** key, which
  is what enforces one connector per vault.

Changing a field label, adding a setting or adjusting validation is a `configuration.json` change only —
it does not require rebuilding or re-uploading the JAR, provided the plugin code does not need to read a
new attribute.

## Native TLM connector vs. this custom plugin

TLM ships a **built-in Azure Key Vault connector**. It is an *Admin Web Request* delivery connector: TLM
delivers an issued certificate into the vault, naming it after the certificate's common name with dots
replaced by hyphens (`example.com` → `example-com`), and can either create a uniquely named object per
issuance (a random suffix is appended) or add each renewal as a new **version** of the existing object.
It also discovers certificates already held in the vault.

The custom plugin in this folder is an **automation connector**: it runs on a TLM sensor inside your own
network and drives the full lifecycle against the vault's data plane.

| | Native Key Vault connector | Custom automation plugin (this folder) |
|---|---|---|
| **Connector type** | Admin Web Request — certificate *delivery* | Automation connector — full lifecycle (test, discover, CSR, install, validate) |
| **Scope of one connector** | **Subscription ↔ connector** — one connector corresponds to a single Azure subscription and covers the vaults within it; multiple subscriptions require multiple connectors | **Key Vault ↔ connector** — one connector maps to a single vault, addressed by URL; manage multiple vaults with one connector each |
| **Key generation and custody** | Key pair is generated **inside Key Vault** ; only the CSR and the signed chain cross the wire | Key pair is generated **inside Key Vault** ; only the CSR and the signed chain cross the wire |
| **Certificate naming** | Derived from the common name, dots replaced by hyphens (`example-com`) | Uses the discovered certificate's **existing Azure name verbatim**, an explicit `certificateName` override, or a derived name for brand-new certificates |
| **Renewal model** | Unique object per issuance (random suffix) *or* new version of the CN-derived name | New **version** of the targeted certificate, in place — no duplicate object, no rebinding |
| **Discovery** | Yes | Yes — including expired, disabled and self-signed objects, with optional filters to trim the inventory |
| **Replacing a discovered certificate** | Constrained by the CN-derived naming scheme | **Any** discovered certificate can be selected and replaced with a DigiCert Trust Lifecycle Manager or CertCentral certificate, regardless of how it was originally named |
| **Connector inputs** | Tenant ID, Client ID, Client Secret, and Subscription ID (required where the tenant has more than one subscription) | Tenant ID, Client ID, Client Secret, and the Key Vault URL — no subscription ID |
| **Azure permissions required** | Two Azure RBAC roles on the app registration: **Key Vault Certificates Officer** *and* **Key Vault Secrets User**, assigned at resource-group scope (the documented minimum) or subscription scope. Vaults must be configured for **Azure role-based access control**, not access policies | Certificate **get / list / create** on the one vault (`create` also authorises the merge). No secrets permission and no Azure Resource Manager role. Works with either permission model — a vault **access policy**, or an RBAC role such as **Key Vault Certificates Officer** scoped to that single vault |
| **Setup** | Add connector from the Integrations page | Upload plugin (ZIP + `configuration.json`) and add new connector from the Integrations page |
| **Support model** | Supported DigiCert product feature | Customer-deployed extensibility plugin, maintained alongside the source in this repository |

The native connector's prerequisites are documented in
[Link to Azure Key Vault](https://docs.digicert.com/en/trust-lifecycle-manager/build-your-inventory-and-ecosystem/connectors/vaults/link-to-azure-key-vault.html#azure-prerequisites).

**Choosing between them.** The native connector is the right choice when certificates are issued through
TLM and simply need to land in a vault, and where the CN-derived naming convention is acceptable. This
plugin is the better fit when the private key must never leave Azure, when vault traffic has to originate
from your own network, or when you need to take over certificates that already exist in the vault —
including self-signed, third-party or arbitrarily named objects — and renew them in place under their
existing names.

The trade-off is administrative granularity versus blast radius. The native connector covers a whole
subscription in one definition, at the cost of a service principal holding certificate *and* secret
permissions across every vault in the assignment scope. This plugin is deliberately scoped to one vault:
it needs no subscription ID, no Azure Resource Manager permissions and no access to secrets, works
across subscriptions and tenants, and leaves the vault free to use access policies or RBAC — but it
requires one connector per vault. The two are not mutually exclusive: they can be used side by side
against different vaults, or against different certificate populations in the same estate.

## Getting started

The plugin folder ships a prebuilt distribution ZIP under `plugin-dist/`, so you can upload it to TLM without building from source. To build it yourself you need Java 17+, Maven 3.6+, and access to the DigiCert TLM Plugin SDK on GitHub Packages.

Full detail — architecture, certificate-name resolution, discovery and endpoint model, CSR subject handling, connector fields, Azure prerequisites, build instructions and known limitations — is in the [plugin README](automation-plugins/azure-keyvault-certificate-automation/README.md).
