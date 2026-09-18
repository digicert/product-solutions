# Extensibility Custom Plugins – F5 Distributed Cloud (XC)

This folder contains a **custom plugin built on DigiCert Trust Lifecycle Manager (TLM) extensibility**.

TLM extensibility lets you add support for a target platform that TLM does not integrate with natively. Rather than scripting around the product, you implement the plugin SDK's lifecycle contract in Java, package the result as a distribution ZIP, and upload it to TLM. TLM then treats the platform as a first-class **automation connector**: it appears in the connector UI, discovers certificates into the automation inventory, and participates in scheduled and on-demand renewal exactly like a built-in integration. The plugin runs on a TLM **sensor**, so all traffic to the target platform originates from your own network.

TLM has no native F5 Distributed Cloud connector, so this plugin is a standalone integration rather than an alternative to a built-in one.

## Contents

| Path | What it is |
|---|---|
| [`tlm-plugin-f5-xc-automation/`](tlm-plugin-f5-xc-automation/) | F5 XC certificate automation plugin: source, Maven build, TLM connector definition and unit tests |

## What the plugin does

The plugin makes one **F5 XC tenant namespace** a fully managed automation target in TLM. It extends the SDK's `AbstractAutomationWorkflow` and implements the five lifecycle operations TLM calls:

| Operation | What happens against F5 XC |
|---|---|
| `testConnection` | Lists certificate objects in the namespace to confirm the API token and namespace |
| `refreshConfiguration` | Discovers every certificate object in the namespace, reporting each as its own TLM endpoint |
| `generateCsr` | Generates the key pair and PKCS#10 CSR on the sensor and retains the private key locally under the TLM flow ID |
| `installCertificate` | Downloads the issued chain, pairs it with the retained key, and creates or replaces the named certificate object |
| `validateCertificate` | Reads the object back and compares the leaf certificate's serial number numerically, with retry |

Four properties are worth calling out:

- **Decentralized, sensor-side key generation.** F5 XC certificate objects carry the private key inline, so the key has to exist somewhere before upload. The plugin generates it on the sensor during `generateCsr` and reads it back during `installCertificate`. Both steps must therefore run on the **same sensor**, and the TLM certificate profile must use CSR-based (decentralized) enrollment.
- **Renewal replaces the object in place.** Install checks whether the object exists and issues a `PUT` if it does or a `POST` if it does not. The object keeps its name, so anything referencing it in F5 XC, such as an HTTP load balancer, keeps working without rebinding.
- **One endpoint per certificate object.** F5 XC objects have no per-object IP, so discovery uses the object name as the endpoint key rather than a load-balancer VIP. Objects that share a common name or sit behind the same VIP still appear as distinct endpoints. The reasoning is in the plugin README under *Endpoint identity*.
- **Secrets Manager (PAM) support.** The API token can be typed into TLM or held in BeyondTrust, CyberArk or Delinea and resolved by a TLM PAM connector at run time. The plugin fails closed if the resolved token is empty and never logs the token or the vault reference.

## Upload artifacts

Two artifacts are uploaded to TLM when the custom integration is registered. Both come out of the build (`./build.sh`).

| Artifact | Location | Role |
|---|---|---|
| **Distribution ZIP** | `plugin-dist/tlm-plugin-f5-xc-automation-1.0.0.zip` | The executable payload TLM distributes to the sensor |
| **Connector definition** | [`configuration.json`](tlm-plugin-f5-xc-automation/configuration.json) | Declares the connector's UI form, field types, validation and credential handling |
| **Checksums** | `plugin-dist/checksums` | SHA-256 of the ZIP, for integrity verification before upload |

Unlike some sibling integrations in this repository, the `plugin-dist/` folder is **not committed** here (it is listed in the plugin's `.gitignore`), so the ZIP has to be built from source. See *Getting started* below.

### Distribution ZIP

A flat archive containing exactly two entries and no directory structure:

| Entry | Purpose |
|---|---|
| `tlm-plugin-f5-xc-automation-1.0.0.jar` | Shaded (fat) JAR: plugin classes, the TLM Plugin SDK and all dependencies in a single self-contained jar |
| `plugin-meta.json` | Execution manifest: tells the sensor how to launch the plugin on Windows and Linux (`java -jar <jar>`), which environment to set (`JAVA_HOME`, `PATH`) and the runtime limits `MAX_CHUNK` and `PROCESS_TIMEOUT` |

The plugin name and version in `plugin-meta.json` must match the JAR filename inside the ZIP. Both are generated from the Maven coordinates, so a version bump in `pom.xml` keeps them aligned automatically.

### Connector definition (`configuration.json`)

Uploaded alongside the ZIP and rendered directly as the connector form in TLM. It defines three groups:

- **`core_settings`**: the Managing Sensor selector, populated dynamically by TLM (`options_provider: Sensors`).
- **`config_settings`**: F5 XC Tenant, F5 XC Namespace, an **Authentication method** selector, the API token, and the PAM connector selector. The API token field is declared twice with a `conditional_group` so exactly one version is shown: a `password` field labelled *F5 XC API Token* in direct-input mode, or a plain `input` labelled *F5 XC API Token (PAM vault reference)* in secrets-manager mode. In secrets-manager mode a **Secrets manager connector** dropdown (`options_provider: PamConnectors`) also appears, with a per-provider banner showing the expected reference format. See the plugin README's *Secrets Manager (PAM) authentication* section.
- **`credential_sets`**: declares `config_attributes.apiToken` as **sensitive** (stored encrypted, never returned to the UI) and `config_attributes.tenant` as the connector's **unique** key. Note that uniqueness is on the tenant, not the tenant plus namespace, so TLM allows one connector per F5 XC tenant.

Changing a field label, adding a setting or adjusting validation is a `configuration.json` change only. It does not require rebuilding or re-uploading the JAR, provided the plugin code does not need to read a new attribute.

## Getting started

You need Java 17+, Maven 3.6+, and a GitHub personal access token with `read:packages` scope so Maven can pull the DigiCert TLM Plugin SDK from GitHub Packages.

```bash
cd tlm-plugin-f5-xc-automation
export GITHUB_TOKEN=<token>
export GITHUB_ACTOR=<github-username>
./build.sh
```

The script verifies the token, runs `mvn clean package -s settings.xml -U`, and writes the ZIP and a `checksums` file to `plugin-dist/`. Upload the ZIP and `configuration.json` to TLM, add a new connector from the Integrations page, select a sensor, and enter the tenant, namespace and API token.

Full detail, including architecture, the identifier convention, endpoint identity, each workflow operation, PAM behaviour, assumptions to verify and testing conventions, is in the [plugin README](tlm-plugin-f5-xc-automation/README.md).
