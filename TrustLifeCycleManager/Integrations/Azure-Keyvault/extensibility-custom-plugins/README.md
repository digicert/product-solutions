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

## Getting started

The plugin folder ships a prebuilt distribution ZIP under `plugin-dist/`, so you can upload it to TLM without building from source. To build it yourself you need Java 17+, Maven 3.6+, and access to the DigiCert TLM Plugin SDK on GitHub Packages.

Full detail — architecture, certificate-name resolution, discovery and endpoint model, CSR subject handling, connector fields, Azure prerequisites, build instructions and known limitations — is in the [plugin README](automation-plugins/azure-keyvault-certificate-automation/README.md).

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.
