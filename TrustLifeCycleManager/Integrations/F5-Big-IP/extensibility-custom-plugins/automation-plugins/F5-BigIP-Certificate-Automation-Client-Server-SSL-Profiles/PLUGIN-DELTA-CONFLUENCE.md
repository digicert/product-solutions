# Building a TLM Automation Plugin: From Template to Working F5 BIG-IP Plugin

This page documents the **delta** — the concrete set of changes — needed to transform the generic automation plugin template (`tlm-plugin-example-automation`) into a working device-specific plugin, using the **F5 BIG-IP** automation plugin as the worked example.

It is the companion to the discovery-plugin delta page, but covers the *lifecycle* operations (generate CSR, install certificate, validate, refresh) instead of inventory.

**Reference paths**

| Role | Location |
|---|---|
| Template | `Engineering-Templates/tlm-plugin-example-automation` |
| Working plugin | `F5-BigIP-Plugins/Automation-Plugin-Development/F5-BigIP` |

---

## 1. High-level summary of the delta

The template ships as a runnable skeleton that fakes every lifecycle operation — `generateCsr` produces a CSR locally with BouncyCastle, `installCertificate` writes the cert to a temp directory, `validateCertificate` reads it back, and `refreshConfiguration` returns hardcoded JSON. To turn it into a real plugin you replace each mock with calls into a **transport adapter** that drives the actual device.

The F5 implementation introduces a **dual-adapter** pattern: a REST adapter for fast credential validation and an SSH adapter for the heavy lifecycle work. The SSH adapter executes **Python scripts shipped inside the plugin JAR** on the device, returning structured JSON.

| Layer | Template | F5 BIG-IP plugin |
|---|---|---|
| Maven artifactId | `tlm-plugin-example-automation` | F5 automation artifact (renamed) |
| Java target | 9 | 17 |
| Transports | none (mock) | iControl REST + SSH |
| CSR generation | local BouncyCastle | F5-device-side via `generate-csr.py` |
| Cert install | TODO placeholder | F5 tmsh + clientssl-profile binding via `install-certificate.py` |
| Validation | reads back cached cert | F5-device query via `validate-certificate.py` |
| Refresh | hardcoded mock JSON | live F5 inventory via `get-configuration-info.py` |
| Helper packages | `helper/` only | + `adapter/`, `model/`, `util/ssh/` |
| Device scripts | none | 4 embedded Python scripts |

---

## 2. Maven & build changes (`pom.xml`, `build.sh`)

### 2.1 `pom.xml`

Update `artifactId`, `version`, and the runner `mainClass`. Bump Java to 17. The dependency additions are the same SSH + JSON stack as the discovery plugin, plus one important exclusion.

**Add the SSH + crypto stack** (required for shipping Python scripts to the device):

```xml
<dependency>
    <groupId>org.apache.sshd</groupId>
    <artifactId>sshd-core</artifactId>
    <version>2.13.1</version>
</dependency>
<dependency>
    <groupId>net.i2p.crypto</groupId>
    <artifactId>eddsa</artifactId>
    <version>0.3.0</version>
</dependency>
<dependency>
    <groupId>org.bouncycastle</groupId>
    <artifactId>bcpkix-jdk18on</artifactId>
    <version>1.78.1</version>
</dependency>
```

**Declare Jackson explicitly** (the SDK ships it transitively, but the adapters use it directly):

```xml
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
    <version>2.18.2</version>
</dependency>
```

**Exclude `commons-logging` from the plugin SDK** — important and easy to miss. The SDK's transitive `unirest-java` pulls `commons-logging 1.2`, which contains a `javax.servlet.ServletContextListener`. The SDK's Guava `ClassPath` scanner trips on it at startup with `NoClassDefFoundError: javax/servlet/ServletContextListener`. `sshd-core` brings `jcl-over-slf4j`, which bridges the commons-logging API safely.

```xml
<dependency>
    <groupId>com.digicert.tlm</groupId>
    <artifactId>plugin-sdk</artifactId>
    <version>1.1</version>
    <exclusions>
        <exclusion>
            <groupId>commons-logging</groupId>
            <artifactId>commons-logging</artifactId>
        </exclusion>
    </exclusions>
</dependency>
```

### 2.2 `build.sh`

Same macOS/Linux platform-detection tweak as the discovery plugin: detect `sha256sum` vs `shasum -a 256`. Otherwise unchanged.

---

## 3. Plugin metadata & UI configuration

### 3.1 `src/main/resources/plugin-meta.json`

Unchanged — Maven substitutes `${project.artifactId}` and `${project.version}` at build time.

### 3.2 `configuration.json`

**Almost identical.** Unlike the discovery template (which ships with only username/password), the automation template **already includes all four connection fields** (`userName`, `password`, `managementIp`, `managementPort`). The only diff is a one-character typo fix on the `managementPort` input size (`"1"` → `"l"`).

So unless your device needs additional UI fields, `configuration.json` is a no-op for you. Update only the labels and descriptions to your device-specific wording before publishing.

---

## 4. The main plugin Java classes

The template's package layout is preserved 1:1 in the F5 plugin:

```
src/main/java/com/example/automation/
├── F5AutomationPlugin.java                    ← rewritten (was MyAutomationPlugin)
├── F5AutomationPluginRunner.java              ← renamed + 1-line addition
├── helper/
│   └── F5AutomationPluginHelper.java          ← rewritten (was MyAutomationPluginHelper)
└── extended/
    ├── configuration/MyPluginConfiguration.java  ← UNCHANGED
    ├── request/MyGenerateCertificateRequest.java ← added F5 fields
    ├── request/MyInstallCertificateRequest.java  ← added F5 fields
    ├── request/MyValidateRequest.java            ← added F5 fields
    ├── request/MyRefreshRequest.java             ← UNCHANGED
    └── response/MyRefreshResponse.java           ← UNCHANGED
```

### 4.1 `extended/configuration/MyPluginConfiguration.java` — UNCHANGED

The template already declares `userName`, `password`, `managementIp`, `managementPort`. Use as-is.

Two fields were added on top of the template. `config_attributes.clientSslProfileMode` is a required select (`update` default / `create`) that decides whether install modifies the bound client-ssl profile in place or copies it to a new profile and re-binds; it overrides the per-request `updateSameSslProfile` flag because TLM has no UI for that flag on custom plugins. `config_attributes.updateServerSslProfile` a required select (`true` default / `false`) that controls whether an install also repoints server-ssl profiles carrying the replaced certificate. It is declared `optional: false` with a `requiredRule` and a default `value` because optional selects break the connector add/edit form. `MyPluginConfiguration.isUpdateServerSslProfileEnabled()` treats null/blank (connectors saved before the field existed) as `true`.

> **Note:** `password` arrives **Base64-encoded** (TLM encrypts secrets at rest). Decode it before passing it to the adapter — the F5 plugin does this in `F5AutomationPlugin.decodePassword()`.

### 4.2 `extended/request/*.java` — ADD device-specific fields

These three request DTOs receive *extra* JSON fields that TLM passes alongside the standard wrapper (`GenerateCsrRequest`, `InstallCertificateRequest`, `ValidateCertificateRequest`). The template ships them empty. Add a field for every device-specific flag your operations need.

**`MyGenerateCertificateRequest`** — add F5 key-namespace fields:

```java
@Data
public class MyGenerateCertificateRequest {
    /** Full F5 virtual-server path, e.g. partition1/alias1. */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the generated key/CSR. */
    private String flowStartDate;

    /** normal, fips, or nethsm. */
    private String keyStorage;
}
```

**`MyInstallCertificateRequest`** — add F5 install-time options:

```java
@Data
public class MyInstallCertificateRequest {
    private String virtualServerName;
    private String flowStartDate;
    private String subjectDn;
    private String ipAddress;             // for logging only
    private String port;                  // for logging only
    private boolean updateSameSslProfile; // reuse existing client-ssl profile?
    private boolean useCommonIca;         // share ICA across VIPs?
}
```

**`MyValidateRequest`** — enough context to find the cert again:

```java
@Data
public class MyValidateRequest {
    private String virtualServerName;
    private String flowStartDate;
    private String subjectDn;
}
```

> **Pattern:** these DTOs are how you add device-specific behaviour to a standard SDK request without modifying the SDK. Use them whenever your device needs information beyond what TLM's generic request type carries.

### 4.3 `extended/request/MyRefreshRequest.java` and `extended/response/MyRefreshResponse.java` — UNCHANGED

The template ships these as empty scaffolds and the F5 plugin doesn't extend them. The refresh path uses the SDK's standard response shape.

### 4.4 `F5AutomationPluginRunner.java`

Identical to the template runner apart from the class name and the F5-specific hostname-verification bypass (lab F5s use self-signed certs with no SAN):

```java
public class F5AutomationPluginRunner {
    public static void main(String[] args) throws IOException {
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
        SdkRuntime runtime = new SdkRuntime(
            F5AutomationPluginRunner.class.getPackageName().toLowerCase());
        SdkContext context = new SdkContext();
        runtime.execute("F5AutomationPlugin", context);
    }
}
```

Update the `mainClass` in `pom.xml` and the `@WorkflowEntryPoint(name=...)` annotation to match.

### 4.5 `F5AutomationPlugin.java` — the substantive rewrite

The template hardcodes every method. The F5 version:

1. Builds an `AdapterConfig` in the constructor and instantiates **both adapters** (REST + SSH).
2. Implements five SDK methods: `testConnection`, `generateCsr`, `installCertificate`, `validateCertificate`, `refreshConfiguration`.
3. Each method delegates to the appropriate adapter, unwraps the `Result<T>`, and maps device payloads back into SDK DTOs.

**Constructor — wire up both adapters:**

```java
@WorkflowEntryPoint(name = "F5AutomationPlugin")
public class F5AutomationPlugin extends AbstractAutomationWorkflow {

    private final F5iControlRestAdapter restAdapter;
    private final F5SshAdapter sshAdapter;
    private final MyPluginConfiguration extendedConfig;

    public F5AutomationPlugin(SdkContext context,
                              PluginConfiguration<MyPluginConfiguration> config) {
        this.extendedConfig = Objects.requireNonNull(config.getExtendedConfig(),
            "Plugin extended configuration is required");

        var adapterConfig = AdapterConfig.builder()
            .host(extendedConfig.getManagementIp())
            .port(extendedConfig.getManagementPort())
            .username(extendedConfig.getUserName())
            .password(decodePassword(extendedConfig.getPassword()))
            .build();

        this.restAdapter = new F5iControlRestAdapter(adapterConfig);
        this.sshAdapter  = new F5SshAdapter(adapterConfig);
    }
}
```

**`testConnection()` — run both checks, surface both errors:**

```java
var rest = restAdapter.testConnection();
var ssh  = sshAdapter.testConnection();
var response = new TestConnectionResponse<JsonNode>();
response.setActive(rest.isSuccess() && ssh.isSuccess()
    && rest.getValue().isActive() && ssh.getValue().isActive());

var errors = new ArrayList<PluginError>();
if (!rest.isSuccess()) errors.add(new PluginError(rest.getErrorCode(), rest.getErrorMessage()));
if (!ssh.isSuccess())  errors.add(new PluginError(ssh.getErrorCode(),  ssh.getErrorMessage()));
if (!errors.isEmpty()) response.setErrors(errors);
return response;
```

**`generateCsr()` — unwrap, normalize, delegate to SSH:**

```java
var csrRequest = PluginUtils.convertWrappedObject(
    request, GenerateCsrRequest.class, MyGenerateCertificateRequest.class);
var extended = csrRequest.getExtended();

var commonName     = CertificateAttributesUtil.getCommonName(csrRequest.getSubjectDn());
var dnsNames       = CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames());
var subjectFields  = CertificateAttributesUtil.getSubjectDnFields(csrRequest.getSubjectDn());
var keyName        = CertificateAttributesUtil.getObjectName(
                       commonName, csrRequest.getFlowId(),
                       extended.getFlowStartDate(), extended.getVirtualServerName());

var generated = sshAdapter.generateCsr(
    extended.getVirtualServerName(), commonName, dnsNames, keyName,
    csrRequest.getKeySize(), csrRequest.getKeyAlgorithm(),
    extended.getKeyStorage(), subjectFields);

if (generated.isSuccess()) {
    response.setCsr(generated.getValue().getCsr());
} else {
    response.setErrors(List.of(new PluginError(
        generated.getErrorCode(), generated.getErrorMessage())));
}
```

**`installCertificate()` — resolve chain (inline PEM *or* downloaded ZIP), then delegate:**

```java
Map<String, String> certificates;
if (installRequest.getCertificateChain() != null && !installRequest.getCertificateChain().isBlank()) {
    certificates = F5AutomationPluginHelper.splitChainPem(installRequest.getCertificateChain());
} else {
    var downloaded = F5AutomationPluginHelper.downloadFileToDirectory(
        installRequest.getCertificateLink(), tempDir);
    certificates = F5AutomationPluginHelper.extractCertificatesFromZip(downloaded);
}
if (!certificates.containsKey("end_entity.cer")) {
    throw new WorkflowExecutionException("End-entity certificate not found", null);
}

var installResult = sshAdapter.installCertificate(
    keyName, extended.getVirtualServerName(), certificates,
    installRequest.getCurrentCertificateThumbprint(),
    extended.isUpdateSameSslProfile(),
    extended.isUseCommonIca());
```

**`validateCertificate()` and `refreshConfiguration()`** follow the same shape: unwrap the request, call the SSH adapter, map `Result<T>` into the SDK response. Refresh additionally flattens an `F5ConfigurationData` into the SDK's `AutomationInfo` / `DataIpInfo` / `Certificate` shapes (see the `populateRefreshResponse(...)` helper in the F5 source).

### 4.6 `helper/F5AutomationPluginHelper.java` — rewritten

The template helper is a **crypto utility class** (BouncyCastle CSR generation, self-signed cert factory, file download via `java.net.URL`). The F5 plugin doesn't generate certs locally — the F5 does it — so the helper is repurposed for **chain handling and downloads**:

| Method | Purpose |
|---|---|
| `downloadFileToDirectory(url, dir)` | Trust-all `java.net.http.HttpClient` with 2-minute timeout for fetching the cert ZIP from TLM. |
| `extractCertificatesFromZip(zip)` | Returns a `Map<String,String>` keyed `end_entity.cer` / `ica.cer` from the downloaded archive. |
| `splitChainPem(pem)` | Splits a single concatenated PEM string into end-entity and ICA when TLM sends the chain inline rather than as a URL. |
| `parseCommonNameFromCert(pem)` | X.509 → subject DN, used for logging. |
| `buildHttpClient()` | Builds the trust-all `HttpClient` used by `downloadFileToDirectory`. |

### 4.7 `helper/CertificateAttributesUtil.java` — new

A second helper, F5-specific, that normalises certificate attributes into F5-friendly shapes:

- `getCommonName(subjectDn)` — uses `javax.naming.ldap.LdapName` to extract `CN`.
- `getDnsNames(commaSeparated)` — splits the comma-list TLM passes.
- `getSubjectDnFields(subjectDn)` — maps X.500 attribute names (`O`, `OU`, `C`, `ST`, `L`, `EMAILADDRESS`) to tmsh flag names (`organization`, `ou`, `country`, `state`, `city`, `email-address`).
- `getObjectName(cn, flowId, flowStartDate, vipName)` — builds an F5 object name that fits inside F5's **255-character limit** while remaining unique across flows.

You will need an analogous class for any device with a name-length limit or its own DN-field naming.

---

## 5. New adapter package — and why there are *two* adapters

```
adapter/
├── AdapterConfig.java           (shared @Data @Builder DTO)
├── F5iControlRestAdapter.java   (HTTPS — credential check only)
└── F5SshAdapter.java            (SSH — everything else)
```

**Why split transports?** F5 BIG-IP exposes two control planes:

1. **iControl REST** over HTTPS — good for cheap auth checks (`GET /mgmt/tm/sys/version`). The REST adapter is used **only by `testConnection`** so a bad password fails fast, before the plugin ever opens an SSH session.
2. **SSH** — the only reliable way to run multi-step tmsh sequences and ship/execute Python scripts on the device. All four lifecycle operations go through SSH.

The same split is useful on any device that has both a REST control plane and a CLI: use REST for connectivity probes, use the CLI for the work.

**`AdapterConfig`** is identical to the discovery plugin's version — a small Lombok `@Data @Builder` DTO with `host`, `port`, `username`, `password`.

**`F5iControlRestAdapter`** builds a trust-all `HttpClient` once at construction, disables hostname verification via `SSLParameters.setEndpointIdentificationAlgorithm(null)`, and returns `Result<Connection>` from `testConnection()`. `401` maps to `ErrorCode.UNAUTHORIZED`.

**`F5SshAdapter`** exposes five methods, each of which loads a script from the classpath, calls `SSHClient.executePythonScript(...)`, and parses the JSON response into a typed model:

| Method | Script | Returns |
|---|---|---|
| `testConnection()` | inline `tmsh -a list auth user <username>` | `Result<Connection>` |
| `generateCsr(...)` | `/ssh-scripts/generate-csr.py` | `Result<F5GeneratedCsr>` |
| `installCertificate(...)` | `/ssh-scripts/install-certificate.py` | `Result<Void>` |
| `validateCertificate(...)` | `/ssh-scripts/validate-certificate.py` | `Result<F5InstalledCertificate>` |
| `getVirtualServersInfo()` | `/ssh-scripts/get-configuration-info.py` | `Result<F5ConfigurationData>` |

Every method follows the same pattern:

```java
var response = sshClient.executePythonScript("/ssh-scripts/install-certificate.py", argsString);
if (!response.isSuccess()) {
    var err = tryParseError(response.getOutput());
    return Result.failure(err.getMessage(), err.getCode());
}
return Result.success();
```

---

## 6. New `model/` package

The same `Result<T>` / `Connection` / `ErrorCode` / `BaseScriptResponse` / `F5Error` types as the discovery plugin, plus three automation-specific payloads:

| Class | Purpose |
|---|---|
| `F5GeneratedCsr extends BaseScriptResponse` | `{ "csr": "<PEM>", "warnings": [...] }` from `generate-csr.py`. |
| `F5InstalledCertificate extends BaseScriptResponse` | `{ "certificate": "<PEM>", "warnings": [...] }` from `validate-certificate.py`. |
| `F5ConfigurationData` | Same shape as the discovery plugin's version: system info, vips, certificates, peers, partitions. Reused for `refreshConfiguration`. |

If you are also writing a discovery plugin for the same device, factor these model classes into a shared module — the F5 plugins currently duplicate them.

---

## 7. New `util/ssh/` package

Identical to the discovery plugin:

- **`SSHClient`** — Apache MINA SSHD wrapper with auth/session timeouts, retry-with-backoff on initial connect, stderr merged into stdout. Methods:
  - `SshResponse executeRemoteCommand(String command)`
  - `SshResponse executePythonScript(String classpathResource, String args)` — streams the script to `python - <args>` on the device.
- **`SshResponse`** — `output`, `exitStatus`, `isSuccess()` (true when exit status is 0).

---

## 8. Embedded device scripts (`src/main/resources/ssh-scripts/`)

Four Python scripts, all shipped inside the plugin JAR and streamed to the F5 at runtime. They emit JSON on stdout — success payloads or `{ "error": "...", "code": "..." }`.

| Script | Run by | What it does on the F5 |
|---|---|---|
| `generate-csr.py` | `generateCsr` | `tmsh create sys crypto key … gen-csr …` against the chosen `keyStorage` (normal / FIPS / netHSM), echoing the resulting CSR. |
| `install-certificate.py` | `installCertificate` | Uploads end-entity + ICA, creates/updates `sys/crypto/cert`, creates/updates a `ltm/profile/client-ssl`, and binds the profile to the target virtual server. Honours `updateSameSslProfile` and `useCommonIca`. When the connector setting `updateServerSslProfile` is `true` (default) it also repoints any `ltm/profile/server-ssl` on the same virtual server whose `cert` fingerprint matches the thumbprint being replaced, inside the same CLI transaction (flat `cert`/`key`/`chain` properties). Fails with `CLIENT_SSL_PROFILE_NOT_FOUND` if no client-ssl profile carries the current certificate. |
| `validate-certificate.py` | `validateCertificate` | Resolves the cert object on the F5 and returns the live PEM for TLM to compare. Looks at client-ssl profiles first, then falls back to server-ssl profiles in serverside context. |
| `get-configuration-info.py` | `refreshConfiguration` | Walks tmsh to inventory system info, virtual servers, certificates (with `cipher-discovery` + SNI flag), peers, partitions. Same script as the discovery plugin — keep them in sync. |

> **Pattern to copy:** keep every device-specific text-parsing and tmsh-fiddling step in the device-side script. The Java code should only ever receive typed JSON. This keeps the Java side small and the device-side logic editable without rebuilding the JAR for parsing tweaks.

---

## 9. README

The README is template boilerplate; **update the title, prerequisites, build steps, and config-field documentation** to your device before publishing. There is no structural difference between the template and F5 versions worth describing here.

---

## 10. Step-by-step checklist for a new automation plugin

1. **Clone the template.**
2. **`pom.xml`** — set `artifactId`, `version`, `mainClass`; bump to Java 17; add `sshd-core` / `eddsa` / `bcpkix` / `jackson-databind`; **exclude `commons-logging` from `plugin-sdk`** (this bites every time it's missed).
3. **`configuration.json`** — likely no change unless your device needs extra fields. Update labels/descriptions to your device wording.
4. **`extended/configuration/MyPluginConfiguration.java`** — leave alone unless you added UI fields.
5. **`extended/request/My*Request.java`** — add device-specific fields per request type (virtual-server name, profile flags, key storage class, etc.). Switch the class to Lombok `@Data` if it isn't already.
6. **Rename the runner** (`*Runner.java`) and the workflow class; update `@WorkflowEntryPoint(name=...)` and `pom.xml`'s `mainClass`. Add the hostname-verification system property if your device uses self-signed TLS.
7. **Create the helper packages** — `adapter/`, `model/`, `util/<transport>/`. Copy `Result<T>` and `BaseScriptResponse` patterns.
8. **Decide on transports.** A device with a quick REST auth endpoint plus a CLI maps naturally to the F5's dual-adapter pattern. A REST-only device collapses to a single adapter.
9. **Write four device-side operations** (CSR, install, validate, refresh) as scripts or REST sequences under `src/main/resources/`. Emit JSON; emit `{error,code}` on failure.
10. **Implement the adapter methods** — each wraps the device call in a `Result<T>` so the plugin class never needs a try/catch around the transport.
11. **Implement the five SDK methods** in the renamed plugin class: `testConnection`, `generateCsr`, `installCertificate`, `validateCertificate`, `refreshConfiguration`. Each one: unwrap the request → call adapter → map `Result<T>` into the SDK response.
12. **Build with `build.sh`** and install into a TLM dev tenant. Exercise the full flow: *Test Connection*, then a real *Enroll* (CSR → install → validate → refresh).

---

## 11. Pointers

- Working source: [F5-BigIP-Plugins/Automation-Plugin-Development/F5-BigIP](../) (this repo)
- Template source: [Engineering-Templates/tlm-plugin-example-automation](../../../Engineering-Templates/tlm-plugin-example-automation)
- Companion page: **Discovery plugin delta** (see `Discovery-Plugin-Development/F5-BigIP/PLUGIN-DELTA-CONFLUENCE.md`)
- Key files to read in order:
  1. `pom.xml`
  2. `src/main/java/com/example/automation/F5AutomationPlugin.java`
  3. `src/main/java/com/example/automation/adapter/F5SshAdapter.java`
  4. `src/main/java/com/example/automation/helper/CertificateAttributesUtil.java`
  5. `src/main/resources/ssh-scripts/install-certificate.py`
