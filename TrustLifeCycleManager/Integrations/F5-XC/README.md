# F5 Distributed Cloud (XC) Integrations for DigiCert Trust Lifecycle Manager

Two independent ways to get DigiCert Trust Lifecycle Manager (TLM) certificates onto **F5 Distributed Cloud** (F5 XC, formerly Volterra). Each lives in its own subfolder with its own documentation.

| Folder | Integration type | Summary |
|---|---|---|
| [`admin-webrequest-post-script/`](admin-webrequest-post-script/) | TLM Agent post-enrollment scripting | A bash script that pushes a freshly enrolled or renewed certificate into an F5 XC namespace |
| [`extensibility-custom-plugins/`](extensibility-custom-plugins/) | TLM extensibility custom plugin | A Java plugin that makes an F5 XC tenant namespace a managed automation connector in TLM |

## `admin-webrequest-post-script/`

**Admin Web Request (AWR) post script.** An AWR post script is a script the DigiCert TLM Agent executes immediately *after* it enrols or renews a certificate. The agent hands the script the freshly issued certificate material through the `DC1_POST_SCRIPT_DATA` environment variable, and the script is responsible for installing that material wherever it needs to go.

This particular script takes the issued PEM certificate and private key, Base64-encodes them, and creates or replaces a named **certificate object** in an F5 XC namespace over the F5 XC Configuration API. It authenticates with an F5 XC API token and needs nothing beyond `curl` and standard GNU tools on the agent host. The tenant, namespace, object name and API token are supplied as AWR arguments from the TLM certificate profile, so one script serves any number of profiles.

The certificate is enrolled by TLM in the normal way; the script simply distributes the result to F5 XC. See the [AWR post script README](admin-webrequest-post-script/README.md) for configuration, prerequisites, logging and troubleshooting.

## `extensibility-custom-plugins/`

**A custom plugin built on TLM extensibility.** TLM extensibility lets you add support for a platform TLM does not integrate with natively by implementing the plugin SDK in Java and uploading the packaged result. Once installed, the platform behaves like a first-class automation connector in TLM. There is currently no native F5 XC connector in TLM, so this plugin is the only way to bring F5 XC into TLM's automation inventory.

The F5 XC plugin makes one tenant namespace a managed automation target. It discovers every certificate object in the namespace into TLM's inventory as its own endpoint, generates the key pair and CSR on the TLM sensor, and uploads the DigiCert-signed chain together with that key as a create or in-place replace of the named certificate object. The API token can be typed into TLM or resolved at run time from a Secrets Manager (PAM) connector.

See the [extensibility README](extensibility-custom-plugins/README.md) for an overview, or the [plugin README](extensibility-custom-plugins/tlm-plugin-f5-xc-automation/README.md) for full technical detail.

## Choosing between them

| | AWR post script | Extensibility plugin |
|---|---|---|
| Certificate lifecycle driven by | TLM Agent on a host | TLM automation, via a sensor |
| Private key generated | On the agent host, delivered as a PEM key file | On the TLM sensor during CSR generation, held locally until install |
| Existing F5 XC certificate objects | Not discovered | Discovered into the TLM inventory, one endpoint per object |
| Target object name | Fixed per profile, passed as an AWR argument | The discovered object's existing name, replaced in place |
| API token storage | Passed as an AWR argument in the certificate profile | Encrypted in TLM, or resolved from a PAM vault at run time |
| Setup effort | Accept the legal notice, set the log path, configure four AWR arguments | Upload a plugin package, configure a connector |

Use the **AWR post script** when a TLM Agent already enrols the certificate on a host and F5 XC is one more place the result needs to land. Use the **extensibility plugin** when F5 XC is the system of record and you want TLM to discover and renew the certificate objects that already live there.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.
