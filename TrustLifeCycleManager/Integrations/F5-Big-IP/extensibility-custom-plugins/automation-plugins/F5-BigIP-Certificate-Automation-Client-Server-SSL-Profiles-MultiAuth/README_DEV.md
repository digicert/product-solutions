# f5-automation-plugin-multiauth - Developer Guide

User-facing documentation is in `README.md`. This plugin was derived from the DigiCert plugin-sdk
example template and supersedes the earlier single-credential build (`f5-automation-plugin` 1.0.0), which
was removed from the repository in October 2026.

## Prerequisites

- Java 17, Maven 3.6+
- Python 3 on the workstation (device script tests only; the scripts themselves run under the BIG-IP's
  Python 2.7 and must stay 2/3 compatible)
- Access to the DigiCert `tlm-plugins-sdk` GitHub package registry (`GITHUB_ACTOR`, `GITHUB_TOKEN` with
  `read:packages`) for `settings.xml`

## Key dependencies

| Dependency | Version | Purpose |
|---|---|---|
| `com.digicert.tlm:plugin-sdk` | 1.1 | TLM plugin framework (`commons-logging` excluded, see pom comment) |
| `org.apache.sshd:sshd-core` | 2.13.1 | SSH client used to stream the scripts to the BIG-IP |
| `net.i2p.crypto:eddsa` | 0.3.0 | Required on the classpath by the SDK's constructor scan of sshd-core |
| `org.bouncycastle:bcpkix-jdk18on` | 1.86 (`bouncycastle.version`) | Pulls bcprov and bcutil at the same version |
| `com.fasterxml.jackson.core:jackson-databind` | 2.18.2 | Declared explicitly; not exposed transitively by the SDK |
| `org.projectlombok:lombok` | 1.18.30 | Boilerplate |
| `org.slf4j:slf4j-simple` | 2.0.9 | Logging |
| `org.junit.jupiter:junit-jupiter` | 5.10.1 | Tests |
| `org.mockito:mockito-core`, `mockito-junit-jupiter` | 5.8.0 | Mocks for transports |
| `org.wiremock:wiremock` | 3.3.1 | HTTPS stubs for integration tests |

## Project structure

```text
F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles-MultiAuth/
├── src/main/java/com/example/automation/
│   ├── F5AutomationPlugin.java                 # five SDK actions; thin, delegates to adapters
│   ├── F5AutomationPluginRunner.java           # SDK bootstrap (disables JDK HttpClient hostname check)
│   ├── adapter/
│   │   ├── AdapterConfig.java                  # host/port/sshPort/username/password per transport
│   │   ├── TransportCredentials.java           # authMode -> one AdapterConfig per transport + validation errors
│   │   ├── F5SshAdapter.java                   # ships the scripts, builds arguments/JSON payload, parses JSON
│   │   └── F5iControlRestAdapter.java          # GET /mgmt/tm/sys/version for Test Connection
│   ├── extended/configuration/
│   │   ├── AuthMode.java                       # shared / separate / ssh_only parsing
│   │   └── MyPluginConfiguration.java          # connector fields (see configuration.json)
│   ├── extended/request/*.java                 # device-specific request fields (flat JSON, @JsonUnwrapped)
│   ├── helper/
│   │   ├── CertificateAttributesUtil.java      # DN parsing, deterministic object names (255-char limit)
│   │   └── F5AutomationPluginHelper.java       # artifact download, ZIP and inline-chain handling
│   ├── model/                                  # Result<T>, script response models, F5ConfigurationData
│   └── util/ssh/SSHClient.java                 # MINA SSHD wrapper with tmsh login-shell detection
├── src/main/resources/
│   ├── plugin-meta.json                        # tokens replaced at build time
│   └── ssh-scripts/                            # device-side Python, streamed to `python -` over SSH
│       ├── generate-csr.py
│       ├── install-certificate.py
│       ├── validate-certificate.py
│       └── get-configuration-info.py
├── src/test/java/...                           # unit tests (*Test) and WireMock integration tests (*IT)
├── src/test/python/                            # device script tests (unittest), script_loader.py helper
├── configuration.json                          # connector form
├── plugin-fat-jar.xml, zip.xml                 # assembly descriptors
├── build.sh                                    # script tests, mvn verify, checksums
├── pom.xml, settings.xml
└── plugin-dist/                                # <artifactId>-<version>.zip and checksums (committed)
```

## Building

```bash
# Everything build.sh does, without the token check:
python3 -m unittest discover -s src/test/python -p 'test_*.py'
mvn clean verify -s settings.xml

# Or:
./build.sh        # needs GITHUB_TOKEN and GITHUB_ACTOR; regenerates plugin-dist/checksums
```

Outputs:

- `target/f5-automation-plugin-multiauth-<version>.jar` (fat jar, main class `F5AutomationPluginRunner`)
- `plugin-dist/f5-automation-plugin-multiauth-<version>.zip` (jar + plugin-meta.json)

After any dependency change, smoke-test the assembled jar, not the IDE classpath:

```bash
java -cp target/f5-automation-plugin-multiauth-<version>.jar \
  -e 'new org.bouncycastle.jce.provider.BouncyCastleProvider()'   # or a one-line Smoke.java
unzip -l target/*.jar | grep ServletContextCleaner   # must print nothing
```

Remove the previous version's zip from `plugin-dist/` and regenerate `checksums` in the same change as a
version bump. Never commit `target/`.

## Testing

| Layer | Location | Runs on | Count (1.1.0) |
|---|---|---|---|
| Pure logic: AuthMode, MyPluginConfiguration, TransportCredentials, CertificateAttributesUtil, helper | `src/test/java/**/*Test.java` | `mvn test` | 44 |
| F5SshAdapter with a mocked SSHClient (argument and JSON payload contract) | `adapter/F5SshAdapterTest.java` | `mvn test` | 15 |
| F5AutomationPlugin with mocked adapters, real SDK request conversion | `F5AutomationPluginTest.java` | `mvn test` | 17 |
| REST adapter and artifact download against WireMock HTTPS | `**/*IT.java` | `mvn verify` | 7 |
| Device scripts with `run_command` replaced by canned tmsh output | `src/test/python/test_*.py` | `python3 -m unittest discover -s src/test/python` | 50 |

Conventions:

- Flat `@Test` methods with `@DisplayName`, section-separator comments, no `@Nested`.
- `*IT` classes carry `@Tag("integration")`; surefire excludes them, failsafe runs them.
- Transports are injected through package-private constructors (`F5SshAdapter(AdapterConfig, SSHClient)`,
  `F5AutomationPlugin(MyPluginConfiguration, F5iControlRestAdapter, F5SshAdapter)`); no reflection.
- Request JSON in plugin tests goes through `PluginUtils.convertWrappedObject`, so the flat TLM payload
  to `extendedRequest` mapping is exercised.
- Integration tests set `jdk.internal.httpclient.disableHostnameVerification=true` in `@BeforeAll`,
  exactly as the runner does, so WireMock's self-signed certificate is accepted.
- Script tests load each script by path (`script_loader.load_script`) and answer tmsh commands through
  `FakeShell`, an ordered list of regex to output rules. Unmatched commands fail the test. The tmsh
  fixtures are synthesised from the one-line format the parsers expect; they were not captured from a
  live BIG-IP. Replace them with real captures when available.

Run one class:

```bash
mvn test -Dtest=F5SshAdapterTest -s settings.xml
mvn verify -Dit.test=F5iControlRestAdapterIT -s settings.xml
python3 -m unittest test_install_certificate -v   # from src/test/python
```

## Script contract

`generate-csr.py` and `validate-certificate.py` take positional arguments. `install-certificate.py` takes
one base64-encoded JSON document with the keys `virtualServerName`, `currentCertificateThumbprint`,
`keyName`, `updateSameSslProfile`, `useCommonIca`, `icaSerialNum`, `endEntityCertificate`,
`icaCertificate`, `updateServerSslProfile` (default true) and `groupSyncEnabled` (default false). The
script still accepts the legacy positional form that the removed single-credential build sent, and the
script tests cover both forms.

Keep the four scripts Python 2.7 compatible (no f-strings, no `print` statements, no 3-only syntax).

## Logging

- Startup: plugin version (from plugin-meta.json), resolved identities (`describe()`, no secrets), raw
  and parsed connector flags.
- Each action logs its request and response JSON at INFO.
- Script `warnings` are logged at WARN, `info` messages at INFO.

## CI

`.github/workflows/f5-bigip-multiauth-plugin.yml` at the repository root runs the script tests,
`mvn verify` and `build.sh` on pushes that touch this plugin and on manual dispatch, then uploads
`plugin-dist/` as a workflow artifact. Reading the plugin-sdk package requires a token with
`read:packages` on `digicert/tlm-plugins-sdk`; if the default `GITHUB_TOKEN` cannot read it, add a
`PLUGIN_SDK_TOKEN` secret and the workflow will use it.

## Version history

| Version | Notes |
|---|---|
| 1.1.0 | Secrets manager source, tmsh shell support, HA sync toggle, JSON install payload, test suite, BC 1.86, refresh logging fix |
| 1.0.0 | Initial multi-auth variant |
