# DigiCert TLM — F5 BIG-IP Custom Automation Plugin

A Trust Lifecycle Manager (TLM) **automation plugin** for F5 BIG-IP, built on the DigiCert TLM Plugin SDK. Once it is uploaded to TLM and assigned to a sensor, TLM can manage BIG-IP virtual servers as automation targets:

- discover them
- generate the private key and CSR **on the BIG-IP**
- install the issued certificate into the Client SSL profile, and into any matching Server SSL profile
- validate the result
- renew

| | |
|---|---|
| Project | [automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles/](automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles/) |
| Artifact | `plugin-dist/f5-automation-plugin-1.0.0.zip` (contains `f5-automation-plugin-1.0.0.jar` + `plugin-meta.json`) |
| Checksum | `plugin-dist/checksums` (SHA-256 of the ZIP) |
| Workflow entry point | `F5AutomationPlugin` (`com.example.automation`) |
| Language / runtime | Java 17 on the sensor. The device-side scripts run on the BIG-IP's Python |
| Tested with | BIG-IP 17.5.1.9 Build 0.174.12, single-NIC VE in AWS, standalone (2026-10-02 to 2026-10-05) |

- [Architecture](#architecture)
- [Lifecycle operations](#lifecycle-operations)
- [Install behaviour in detail](#install-behaviour-in-detail)
- [Requirements](#requirements)
- [Connector configuration](#connector-configuration)
- [Building](#building)
- [Deploying to TLM](#deploying-to-tlm)
- [Project layout](#project-layout)
- [Objects created on the BIG-IP](#objects-created-on-the-big-ip)
- [Limitations and known issues](#limitations-and-known-issues)
- [Security considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)

## Architecture

```
┌──────────────────────┐   job (JSON)   ┌───────────────────────────────────────────┐
│  DigiCert TLM        │ ─────────────▶ │  DigiCert sensor                          │
│  connector config    │                │  java -jar f5-automation-plugin-1.0.0.jar │
│  automation flows    │ ◀───────────── │                                           │
└──────────────────────┘   response     │  F5AutomationPlugin (SDK workflow)        │
                                        │   ├── F5iControlRestAdapter ──────────────┼──▶ HTTPS :managementPort
                                        │   │     GET /mgmt/tm/sys/version          │    (test connection only)
                                        │   └── F5SshAdapter ───────────────────────┼──▶ SSH :22
                                        │         SSHClient (Apache MINA SSHD)      │    "python - <args>"
                                        │         streams embedded *.py on stdin    │    script piped on stdin
                                        └───────────────────────────────────────────┘
                                                                                         │
                                                                                         ▼
                                        ┌───────────────────────────────────────────┐
                                        │  F5 BIG-IP                                │
                                        │  python runs tmsh: sys crypto key/cert,   │
                                        │  ltm profile client-ssl / server-ssl,     │
                                        │  ltm virtual, save sys config,            │
                                        │  cm config-sync                           │
                                        │  → prints JSON result / {error, code}     │
                                        └───────────────────────────────────────────┘
```

### Design

- **Thin Java, smart device scripts.** The SDK calls one of five lifecycle methods on `F5AutomationPlugin`. The plugin unwraps the request, builds a deterministic object name, and hands off to an adapter. All tmsh parsing and configuration changes are done by four Python scripts that are embedded in the JAR (`src/main/resources/ssh-scripts/`). They are streamed over SSH to `python -` on the BIG-IP, so **nothing is copied to or left installed on the device**, apart from short-lived temp files in `/var/tmp`.
- **Two transports.**
  - **iControl REST** checks the credentials cheaply during *Test connection*. A wrong password fails fast with `UNAUTHORIZED`.
  - **SSH** carries every lifecycle operation, because multi-step tmsh transactions and config-sync are only reliable from the shell.
- **Typed results.**
  - Each script prints JSON on stdout. On success that is a payload. On failure it is `{"error": "...", "code": "..."}` with a non-zero exit code.
  - The adapter turns this into `Result<T>`, and the plugin maps it onto the SDK response, so failures appear as `PluginError` entries in TLM.
- **One connector per BIG-IP.** `managementIp` is the connector's unique key. The sensor connects to that address on SSH port 22 and on `managementPort` for REST.

## Lifecycle operations

| TLM operation | Java method | Device script | What happens on the BIG-IP |
|---------------|-------------|---------------|----------------------------|
| **Test connection** | `testConnection` | *(inline)* | 1. REST `GET /mgmt/tm/sys/version` with basic auth.<br>2. SSH `tmsh -a list auth user <user>`.<br>Active only if both succeed. |
| **Refresh configuration** | `refreshConfiguration` | `get-configuration-info.py` | Inventory: hostname, product and version, virtual servers (IP, port, partition, SSL state), certificates bound through Client SSL profiles (with SNI flag and cipher/protocol discovery), HA peers with failover state, and partitions. Mapped to the SDK's `AutomationInfo`, `DataIpInfo` and `Certificate` shapes. |
| **Generate CSR** | `generateCsr` | `generate-csr.py` | 1. `tmsh create sys crypto key <partition>/<keyName>.key … gen-csr` in the virtual server's partition, with CN, SANs (`DNS:` list) and subject fields (O, OU, C, ST, L, email).<br>2. Saves the config and config-syncs if the device is in HA.<br>The key never leaves the BIG-IP. |
| **Install certificate** | `installCertificate` | `install-certificate.py` | Installs the end-entity cert and ICA, then updates or creates the Client SSL profile and repoints matching Server SSL profiles, all in one tmsh CLI transaction. Then saves the config and config-syncs. See [Install behaviour](#install-behaviour-in-detail). |
| **Validate certificate** | `validateCertificate` | `validate-certificate.py` | 1. Finds the cert on the virtual server's Client SSL profiles, falling back to its Server SSL profiles.<br>2. Returns the cert and chain PEM from the BIG-IP filestore so TLM can compare it with what was issued. |

### Key and CSR parameters

| TLM input | Mapping |
|-----------|---------|
| Key algorithm | `RSA*` → `rsa-private` with `key-size <n>`, anything else → `ec-private` (no key-size flag) |
| Key storage (`keyStorage` in the extended request) | `normal` (default) or `fips`. FIPS falls back to `normal`, with a warning, if `tmsh show sys crypto fips` shows FIPS is not enabled. See [known issues](#limitations-and-known-issues) for netHSM |
| Subject DN | CN is extracted with `LdapName`. `O`, `OU`, `C`, `ST`, `L` and `EMAILADDRESS` map to the tmsh flags `organization`, `ou`, `country`, `state`, `city` and `email-address` |
| SANs | The comma-separated `dnsNames` become `subject-alternative-name "DNS:a,DNS:b"` |

### Object naming

Each flow uses the same key, certificate and profile name, built by `CertificateAttributesUtil.getObjectName`:

```
<CN>_<flowStartDate, alphanumerics only>_<first 8 alphanumerics of flowId>
```

Characters outside `[0-9A-Za-z._-]` are removed. The name is truncated so that `<partition path>/<name>` stays within the F5 limit of 255 characters. Because the generate, install and validate steps all derive the same name from the flow, the installed certificate pairs with the key created at CSR time.

## Install behaviour in detail

```
installCertificate
 │  cert source: inline certificateChain (split into end-entity + first ICA)
 │               or certificateLink (download ZIP → *_ica.cer / end-entity .cer)
 ▼
install-certificate.py <vip> <currentThumbprint|null> <keyName> <updateSame> <useCommonIca>
                       <icaSerial> "<EE PEM>" "<ICA PEM>" <updateServerSsl>
 │
 ├─ write /var/tmp/<keyName>.crt and /var/tmp/ica_<keyName>.crt
 ├─ useCommonIca? → install shared ICA as ica-digicert-<serial>.crt
 │
 ├─ currentThumbprint == null  (unsecured virtual server)
 │     └─ one transaction: install cert + ICA, create client-ssl <partition>/<keyName>
 │        with cert-key-chain, add it to the VIP (context clientside)
 │
 └─ currentThumbprint set  (renewal / replacement)
       ├─ find the client-ssl profile on the VIP whose cert SHA-256 = currentThumbprint
       │     not found → CLIENT_SSL_PROFILE_NOT_FOUND
       ├─ updateServerSslProfile? → find server-ssl profiles (serverside) on the VIP
       │                            whose cert SHA-256 = currentThumbprint
       ├─ mode "update" (default)
       │     └─ one transaction: install cert + ICA,
       │        modify client-ssl <profile> cert-key-chain replace-all-with {…},
       │        modify server-ssl <each match> cert/key/chain
       └─ mode "create"
             ├─ copy the profile to <partition>/<keyName> (list | sed | load merge, F5 K51888238)
             ├─ one transaction: install cert + ICA, replace cert-key-chain on the copy,
             │  repoint matching server-ssl profiles
             └─ one transaction: remove the original profile from the VIP, add the copy
 │
 ├─ remove temp files
 ├─ tmsh save sys config
 └─ HA mode? → tmsh run cm config-sync to-group <first sync-failover device group>
```

- **Atomicity.** On TMOS 14 and later, the cert installs and profile changes run inside a `create cli transaction` / `submit cli transaction` block, so the Client SSL and Server SSL sides switch together or not at all. On TMOS 13 and earlier ([F5 bug ID468505](https://cdn.f5.com/product/bugtracker/ID468505.html)), the cert installs run as separate tmsh commands. In `update` mode the profile changes also run individually. On the unsecured-VIP and `create` paths, the profile create, bind and unbind steps are still grouped in one transaction.
- **Server SSL scope.** Only Server SSL profiles **attached to the same virtual server**, in serverside context, whose current cert fingerprint equals the thumbprint being replaced are changed. Server SSL profiles carrying any other certificate are never touched. Certificates that exist **only** on a Server SSL profile are not managed by this plugin.
- **Who decides the Client SSL mode.** TLM sends a per-request `updateSameSslProfile` flag for its built-in F5 integration but has no UI for it on custom plugins. The connector setting `clientSslProfileMode` is therefore authoritative, and the request flag is only logged.

## Requirements

### DigiCert TLM and sensor

- A TLM tenant with custom automation plugins enabled, and permission to upload plugins.
- A **DigiCert sensor** that can reach the BIG-IP. The connector's `sensor_id` selects it.
- **Java 17+** on the sensor host, exposed to the plugin as `TG_JAVA_HOME`. `plugin-meta.json` sets `JAVA_HOME=${TG_JAVA_HOME}`, `MAX_CHUNK=15` and `PROCESS_TIMEOUT=30m` for both Windows and Linux sensors.
- Outbound access from the sensor to TLM, to download the certificate artifact when TLM sends a `certificateLink` instead of an inline chain.

### Network

| From | To | Port | Purpose |
|------|----|------|---------|
| Sensor | BIG-IP management IP | `managementPort` (443, or 8443 on single-NIC VE) | iControl REST, test connection |
| Sensor | BIG-IP management IP | **22** (fixed in `SSHClient`) | All lifecycle operations |

### BIG-IP

- **SSH enabled** on the management interface, and the sensor's address allowed under *System → Platform → SSH IP Allow*.
- **Python available on the BIG-IP shell** (`python` on `PATH`), as it is on standard TMOS builds.
- **Not in Appliance Mode.** Appliance Mode removes bash, and the plugin cannot work without it.
- For HA pairs, a **sync-failover device group** in place. Config-sync is run from the device the connector points at, so point the connector at the device you treat as the source of truth (normally the active unit).

### BIG-IP account

The plugin streams scripts to `python -`, so the account must have **Terminal Access = Advanced shell (bash)**. On BIG-IP only the **Administrator** and **Resource Administrator** roles can have advanced shell.

| Setting | Value |
|---------|-------|
| Role | **Administrator** (recommended) or Resource Administrator |
| Terminal access | **Advanced shell (bash)** |
| Partition access | `All`, or every partition that holds managed virtual servers |
| Authentication | Local account preferred. A remote account takes its shell from `auth remote-user remote-console-access` |

```bash
tmsh create auth user digicert-tlm \
    password '<password>' \
    partition-access add { all-partitions { role admin } } \
    shell bash
tmsh save sys config
```

The account runs key generation, cert install, profile and virtual server changes, `save sys config` and `run cm config-sync`. Only an Administrator account was used in testing.

## Connector configuration

The connector form is defined in `configuration.json` and maps onto `MyPluginConfiguration`.

| Field (`config_attributes.*`) | UI label | Required | Default | Description |
|-------------------------------|----------|----------|---------|-------------|
| `core_attributes.sensor_id` | sensor_id | Yes | — | Sensor that runs the plugin and reaches the BIG-IP |
| `userName` | username | Yes | — | BIG-IP account with advanced shell |
| `password` | password | Yes | — | Stored as a sensitive credential. TLM delivers it Base64-encoded, and `decodePassword()` decodes it. A value that is not valid Base64 is used as-is |
| `managementIp` | managementIp | Yes | — | BIG-IP management IP or hostname, used for REST and SSH. Unique per connector |
| `managementPort` | managementPort | Yes | — | iControl REST port (443, or 8443 on single-NIC VE). Not used for SSH |
| `clientSslProfileMode` | Client-ssl profile handling | Yes | `update` | `update`: replace cert/key/chain inside the profile already bound to the virtual server, keeping names and settings. `create`: copy the bound profile to a new profile named after the new key, bind the copy and unbind the original |
| `updateServerSslProfile` | Update server-ssl profiles | Yes | `true` | `true`: also repoint Server SSL profiles on the same virtual server that present the certificate being replaced. `false`: leave all Server SSL profiles untouched |

Connectors saved before the two select fields existed have them blank. Blank is treated as `update` / `true`. The selects are declared non-optional with a default value because optional selects break the connector add/edit form.

### Per-request fields sent by TLM

The extended request DTOs in `extended/request/` carry F5-specific context that TLM sends with each job.

| DTO | Fields used |
|-----|-------------|
| `MyGenerateCertificateRequest` | `virtualServerName` (full path, e.g. `/Common/vs_www`), `flowStartDate`, `keyStorage` |
| `MyInstallCertificateRequest` | `virtualServerName`, `flowStartDate`, `subjectDn`, `useCommonIca`, `updateSameSslProfile` (logged only), `ipAddress`/`port` (logging) |
| `MyValidateRequest` | `virtualServerName`, `flowStartDate`, `subjectDn` |

`useCommonIca=true` installs the issuing CA once as `ica-digicert-<serial hex>.crt` and shares it across virtual servers. With `false`, each flow gets its own `ica_<keyName>.crt`.

## Building

Prerequisites: JDK 17, Maven 3.6+, and a GitHub token with `read:packages` access to `digicert/tlm-plugins-sdk`. The SDK (`com.digicert.tlm:plugin-sdk:1.1`) is resolved from GitHub Packages through `settings.xml`.

```bash
cd automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles
export GITHUB_TOKEN=<token with read:packages>
export GITHUB_ACTOR=<github username>      # or GITHUB_USER
./build.sh
```

`build.sh` does the following:

1. Validates the token scopes.
2. Runs `mvn clean package -s settings.xml -U`, which produces a fat JAR (main class `F5AutomationPluginRunner`) and `plugin-dist/f5-automation-plugin-1.0.0.zip`.
3. Writes the SHA-256 of the ZIP to `plugin-dist/checksums`, using `sha256sum` or, on macOS, `shasum -a 256`.

Build notes:

- **`commons-logging` is excluded from `plugin-sdk`.** Its `ServletContextListener` breaks the SDK's classpath scan at startup (`NoClassDefFoundError: javax/servlet/ServletContextListener`). `jcl-over-slf4j` from `sshd-core` bridges it instead.
- Main dependencies: `sshd-core 2.13.1`, `eddsa 0.3.0`, `bcpkix-jdk18on 1.78.1`, `jackson-databind 2.18.2`, `lombok 1.18.30`, `slf4j-simple 2.0.9`.
- To change the version, edit `<version>` in `pom.xml`. The artifact name and `plugin-meta.json` are filled in from it at build time.

## Deploying to TLM

1. **Upload the plugin.** In TLM, add a custom automation plugin and upload `plugin-dist/f5-automation-plugin-1.0.0.zip`. Use `plugin-dist/checksums` to check the file.
2. **Create a connector** for each BIG-IP (or each HA unit you target). Choose the sensor and enter the fields from [Connector configuration](#connector-configuration).
3. **Test connection.** Both the REST and SSH checks must pass. A failure lists an error for each transport.
4. **Refresh configuration** to import the virtual servers, their SSL state and the certificates currently bound.
5. **Run an automation** against a virtual server. TLM calls *Generate CSR* (key created on the BIG-IP), issues the certificate, then calls *Install* and *Validate*. Renewals repeat the same sequence and replace the certificate identified by its current thumbprint.

The plugin logs every request and response through SLF4J on the sensor. Device-side failures include the script's `code`.

## Project layout

```
F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles/
├── pom.xml, settings.xml, zip.xml, plugin-fat-jar.xml, build.sh
├── configuration.json                     # TLM connector UI definition
├── PLUGIN-DELTA-CONFLUENCE.md             # how this plugin was derived from the SDK template
├── plugin-dist/                           # built ZIP + checksums
└── src/main/
    ├── java/com/example/automation/
    │   ├── F5AutomationPlugin.java        # @WorkflowEntryPoint, 5 SDK lifecycle methods
    │   ├── F5AutomationPluginRunner.java  # main(): SdkRuntime, disables JDK hostname verification
    │   ├── adapter/
    │   │   ├── AdapterConfig.java         # host / port / username / password
    │   │   ├── F5iControlRestAdapter.java # REST credential check
    │   │   └── F5SshAdapter.java          # runs the Python scripts, parses JSON into models
    │   ├── extended/
    │   │   ├── configuration/MyPluginConfiguration.java   # connector fields + defaults
    │   │   ├── request/My{GenerateCertificate,InstallCertificate,Validate,Refresh}Request.java
    │   │   └── response/MyRefreshResponse.java
    │   ├── helper/
    │   │   ├── CertificateAttributesUtil.java   # CN/SAN/DN parsing, F5 object naming
    │   │   └── F5AutomationPluginHelper.java    # cert ZIP download, PEM chain split
    │   ├── model/                         # Result<T>, F5Error, F5GeneratedCsr, F5ConfigurationData, …
    │   └── util/ssh/                      # SSHClient (MINA SSHD), SshResponse
    └── resources/
        ├── plugin-meta.json               # sensor execution definition (java -jar …)
        └── ssh-scripts/
            ├── generate-csr.py
            ├── install-certificate.py
            ├── validate-certificate.py
            └── get-configuration-info.py
```

To change device behaviour, edit the Python scripts. To change what TLM sends or shows, edit `configuration.json` together with `MyPluginConfiguration` and the request DTOs. `PLUGIN-DELTA-CONFLUENCE.md` explains how to build a plugin for another device from the same template.

## Objects created on the BIG-IP

| Object | Name | Created by |
|--------|------|------------|
| Private key + CSR | `<partition>/<keyName>.key` | Generate CSR |
| Certificate | `<partition>/<keyName>.crt` | Install |
| ICA (per flow) | `<partition>/ica_<keyName>.crt` | Install (`useCommonIca=false`) |
| ICA (shared) | `<partition>/ica-digicert-<serial>.crt` | Install (`useCommonIca=true`) |
| Client SSL profile | `<partition>/<keyName>` | Install on an unsecured VIP, or in `create` mode |
| Temp files | `/var/tmp/<keyName>.crt`, `/var/tmp/ica_<keyName>.crt`, `/var/tmp/<profile>.conf` | Install, removed on success |

Old keys, certificates and profiles from previous flows are **not** deleted.

## Limitations and known issues

- **Multi-certificate Client SSL profiles.** Only the **first** `cert-key-chain` entry is compared with the current thumbprint, and the update uses `cert-key-chain replace-all-with`. A profile with several entries (for example RSA plus ECDSA) is left with only the new entry.
- **netHSM key storage is not applied.** Java maps `nethsm` / `net_hsm` / `hsm` to the script value `nethsm`, but `generate-csr.py` only recognises `fips` and `hsm`. netHSM requests therefore create a **normal** key, and no warning is raised. FIPS works as documented.
- **Only one intermediate is installed.** When TLM sends the chain inline, `splitChainPem` keeps the first non-leaf certificate as the ICA and drops the rest. Chains with more than one intermediate are incomplete on the BIG-IP.
- **Server SSL-only certificates** are not discovered or managed. Server SSL profiles are updated only alongside a matching Client SSL profile on the same virtual server.
- **HA has not been tested on a live pair.** It is supported by design: generate and install both config-sync to the first `sync-failover` device group. If you have several sync-failover groups, the first one listed is used.
- **SSH port 22 is fixed.** `managementPort` applies only to REST.
- **No cleanup of superseded objects.** Expect old keys, certs and (in `create` mode) profiles to accumulate. Remove them according to your change process.
- **Error-path temp files.** If install fails after the temp files are written, they stay in `/var/tmp` until removed.

## Security considerations

- **Credentials.**
  - The password is stored by TLM as a sensitive credential set and delivered Base64-encoded to the plugin.
  - It is used for REST basic auth and SSH password authentication.
  - It is not written to the plugin log. The constructor logs host, port, user and the two select values only.
- **TLS and host verification.**
  - The REST adapter and the certificate download use a trust-all `HttpClient`, and the runner disables JDK hostname verification, so that self-signed management certificates work.
  - The SSH client uses the MINA SSHD default server key handling and does not pin the BIG-IP host key.
  - Restrict the sensor's network path to the BIG-IP management network.
- **Root-equivalent access.** Advanced shell on Administrator or Resource Administrator is effectively root on the BIG-IP. Use a dedicated local service account, limit *SSH IP Allow* to the sensor, and audit its use.
- **Inputs passed to the shell.**
  - Virtual server names, object names and PEM blocks are passed to the scripts as command-line arguments and interpolated into tmsh and shell commands.
  - They come from TLM and from the BIG-IP's own inventory.
  - Object names are sanitised to `[0-9A-Za-z._-]`.
- **Keys stay on the device.** Private keys are generated on the BIG-IP and never sent to the sensor or to TLM.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Test connection: `UNAUTHORIZED` | Wrong username or password on REST | Check the credentials. Make sure the password was entered as plain text in the connector |
| Test connection: REST OK, SSH `INTERNAL_ERROR` | SSH blocked or not allowed from the sensor, or the account has no shell | Open port 22, add the sensor to *SSH IP Allow*, set terminal access to **Advanced shell** |
| Test connection: REST timeout | Wrong `managementPort` | Use 8443 on single-NIC VE. Check with `tmsh list sys httpd ssl-port` |
| `python: command not found` or `SHELL_COMMAND_ERROR` on every call | Account lands in `tmsh` instead of bash, or Appliance Mode is on | Set `shell bash` on the user. Disable Appliance Mode |
| `NoClassDefFoundError: javax/servlet/ServletContextListener` at plugin start | Rebuilt without the `commons-logging` exclusion | Restore the exclusion in `pom.xml` |
| `CSR_GENERATION_ERROR` | Key name already exists, or an invalid DN/SAN value | Check `tmsh list sys crypto key` for a clash and look at the tmsh message in the error |
| `CLIENT_SSL_PROFILE_NOT_FOUND` | No Client SSL profile on the VIP has the current thumbprint as its **first** cert-key-chain entry. It may have been changed outside TLM | Run *Refresh configuration* so TLM sees the current cert, then retry |
| `CERTIFICATE_INSTALLATION_ERROR … transaction failed` | tmsh rejected part of the transaction (missing key for the cert name, profile in use, permissions) | The transaction was rolled back. Read the tmsh error in the message, fix it, and retry |
| `HA_SYNC_ERROR` | No sync-failover device group, or the sync failed | Check `tmsh show cm sync-status`. The change is saved locally, so sync manually |
| Server SSL side still presents the old cert | `updateServerSslProfile=false`, the profile is on a different VIP, or it carried a different cert | Check the connector setting and the profile's current cert fingerprint |
| Validation fails after a successful install | Cert not found by the derived name, for example when the VIP has changed | Run *Refresh configuration* and check the VIP's profiles on the device |
| Clients report an incomplete chain | Inline chain had more than one intermediate | Install the missing intermediates and attach them as the profile chain. See [known issues](#limitations-and-known-issues) |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.
