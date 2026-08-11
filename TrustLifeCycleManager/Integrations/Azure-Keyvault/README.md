# Azure Key Vault Integrations for DigiCert Trust Lifecycle Manager

Two independent ways to get DigiCert Trust Lifecycle Manager (TLM) certificates into **Azure Key Vault**. Each lives in its own subfolder with its own documentation.

| Folder | Integration type | Summary |
|---|---|---|
| [`admin-webrequest-post-script/`](admin-webrequest-post-script/) | TLM Agent post-enrollment scripting | Scripts that push a freshly enrolled or renewed certificate into Key Vault |
| [`extensibility-custom-plugins/`](extensibility-custom-plugins/) | TLM extensibility custom plugin | A Java plugin that makes a Key Vault a managed automation connector in TLM |

## `admin-webrequest-post-script/`

**Admin Web Request (AWR) post scripts.** An AWR post script is a script the DigiCert TLM Agent executes immediately *after* it enrols or renews a certificate. The agent hands the script the freshly issued certificate material through the `DC1_POST_SCRIPT_DATA` environment variable, and the script is responsible for installing that material wherever it needs to go.

These particular scripts take the issued PFX, authenticate to Azure AD using OAuth 2.0 client credentials, and import the certificate into Azure Key Vault over the Key Vault REST API — no Azure CLI or PowerShell modules required. Two functionally identical versions are provided, one bash and one PowerShell, so you can match whichever OS runs your TLM Agent.

The certificate is enrolled by TLM in the normal way; the script simply distributes the result to the vault. See the [AWR post script README](admin-webrequest-post-script/README.md) for configuration, prerequisites, logging and troubleshooting.

## `extensibility-custom-plugins/`

**A custom plugin built on TLM extensibility.** TLM extensibility lets you add support for a platform TLM does not integrate with natively by implementing the plugin SDK in Java and uploading the packaged result. Once installed, the platform behaves like a first-class automation connector in TLM.

The Azure Key Vault plugin makes a single vault a managed automation target. It discovers every certificate object in the vault into TLM's automation inventory, generates the CSR *inside* Key Vault so the private key never leaves Azure, and merges the DigiCert-signed certificate back in as a new version of the same certificate object — renewing in place with no duplicate objects and no rebinding.

See the [extensibility README](extensibility-custom-plugins/README.md) for an overview, or the [plugin README](extensibility-custom-plugins/automation-plugins/azure-keyvault-certificate-automation/README.md) for full technical detail.

## Choosing between them

| | AWR post script | Extensibility plugin |
|---|---|---|
| Certificate lifecycle driven by | TLM Agent on a host | TLM automation, via a sensor |
| Private key generated | On the agent host, delivered as a PFX | Inside Azure Key Vault |
| Existing vault certificates | Not discovered | Discovered into the TLM inventory |
| Renewal behaviour | Imports a certificate under a name derived from the PFX filename | Creates a new version of the existing certificate object |
| Setup effort | Edit five variables at the top of a script | Upload a plugin package, configure a connector |

Use the **AWR post script** when a TLM Agent already enrols the certificate on a host and the vault is one more place the result needs to land. Use the **extensibility plugin** when Key Vault is the system of record and you want TLM to discover and renew the certificates that already live there.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.
