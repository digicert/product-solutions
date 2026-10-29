# Working in this repo

This repo holds DigiCert Trust Lifecycle Manager (TLM) integrations: custom
automation plugins (Java fat jars run by the TLM sensor) and agent-side
scripts. The rules below exist because of real production failures.

## TLM automation plugins (Java, fat jar via maven-assembly)

### BouncyCastle
- Declare ONE `<bouncycastle.version>` property in the pom and use it for every
  `org.bouncycastle` artifact (bcprov, bcpkix, bcutil). Never pin them to
  different versions. Split versions duplicate classes across jars; the
  assembly fat jar silently keeps one copy and the plugin dies at runtime with
  `NoSuchFieldError` inside `new BouncyCastleProvider()`. Seen Oct 2026 in the
  F5-XC plugin (bcprov 1.85 + bcutil 1.84).
- Prefer declaring only `bcpkix-jdk18on` and letting it pull bcprov and bcutil
  transitively at the same version.
- Check the `plugin-sdk` version in use before choosing a BC version. Most
  plugins use plugin-sdk 1.1 (no BC pin). plugin-sdk 1.2 pins bcprov 1.78.1:
  either match it or exclude BC from the SDK dependency.

### Build and verify
- After ANY dependency change run `mvn clean package`, then smoke-test the
  assembled jar, not the IDE classpath:
  ```java
  // Smoke.java: compile and run with -cp target/<plugin>.jar
  new org.bouncycastle.jce.provider.BouncyCastleProvider();
  ```
  Unit tests do not catch version splits because Maven gives them every jar
  side by side.
- Regenerate `plugin-dist/<plugin>.zip` and `plugin-dist/checksums` (SHA-256 of
  the zip) in the same change as any pom edit. Never ship a zip built from a
  different commit than the pom.
- Keep the plugin's bundled dependencies self-contained. The sensor runs the
  jar with its own JRE and nothing else on the classpath.

### Testing
Most plugins in this repo ship with no `src/test` at all. When adding or
changing a plugin, add tests using the layout below so every plugin runs the
same way. A plugin-level `CLAUDE.md` may add device-specific priorities.

- **Wiring.** Unit tests run under `maven-surefire-plugin` in the `test`
  phase; integration tests are named `*IT.java`, tagged
  `@Tag("integration")`, and run under `maven-failsafe-plugin` on
  `mvn verify`. Surefire must exclude `**/*IT.java`. Consequence: `build.sh`
  (`mvn clean package`) runs unit tests only. CI must call `mvn verify`
  so integration tests gate the release too.
  ```xml
  <!-- test dependencies: all <scope>test</scope> -->
  <dependency><groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId><version>5.10.1</version><scope>test</scope></dependency>
  <dependency><groupId>org.mockito</groupId><artifactId>mockito-core</artifactId><version>5.8.0</version><scope>test</scope></dependency>
  <dependency><groupId>org.mockito</groupId><artifactId>mockito-junit-jupiter</artifactId><version>5.8.0</version><scope>test</scope></dependency>
  <dependency><groupId>org.wiremock</groupId><artifactId>wiremock</artifactId><version>3.3.1</version><scope>test</scope></dependency>

  <!-- build/plugins -->
  <plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-surefire-plugin</artifactId>
    <version>3.2.5</version>
    <configuration><excludes><exclude>**/*IT.java</exclude></excludes></configuration>
  </plugin>
  <plugin>
    <groupId>org.apache.maven.plugins</groupId>
    <artifactId>maven-failsafe-plugin</artifactId>
    <version>3.2.5</version>
    <executions><execution><goals><goal>integration-test</goal><goal>verify</goal></goals></execution></executions>
  </plugin>
  ```
  Run: `mvn test -s settings.xml` (unit), `mvn verify -s settings.xml`
  (unit + integration), `mvn test -Dtest=ClassName -s settings.xml` (one
  class).
- **Style.** JUnit 5, flat `@Test` methods (no `@Nested`), `@DisplayName`
  on each test, section-separator comments to group them. Mockito only for
  SDK/framework dependencies and transports, never for the class under test.
- **Make transports injectable.** Give the plugin class and each adapter a
  package-private constructor that accepts the adapter / HTTP / SSH client,
  so tests do not need reflection to replace private fields. The default
  SDK constructor `(SdkContext, PluginConfiguration<Config>)` must remain.
- **Cover both paths of every SDK action.** For each of `testConnection`,
  `generateCsr`, `installCertificate`, `validateCertificate`,
  `refreshConfiguration`: one success test and one adapter-failure test
  asserting `response.getErrors()` carries the adapter's code and message.
- **Test the device boundary with ArgumentCaptor.** Capture the exact
  command/argument string or JSON payload passed to the SSH or HTTP client
  and assert each field. This is the only place the Java-to-script contract
  is checked; it is where positional-argument and quoting bugs live.
- **Stub HTTP with WireMock in `*IT` tests**, on a dynamic HTTPS port.
  Plugins already run trust-all HTTP clients, so WireMock's self-signed
  certificate is accepted without a trust store. Stub 200, 401 and 500.
- **Use real crypto for fixtures.** Generate throwaway certificates with
  BouncyCastle (known serial, known CN) instead of hand-typed PEM strings
  when the code parses the certificate.
- **Device-side scripts (Python under `src/main/resources/ssh-scripts/`).**
  Test them on the workstation with the standard library `unittest`
  (pytest runs them too, but CI and the sensor hosts need nothing
  installed): load the script by path, replace `run_command` with canned
  CLI output (for tmsh, `list ... one-line` output) and assert the JSON
  the script prints and the exit code. Reference layout:
  `TrustLifeCycleManager/Integrations/F5-Big-IP/extensibility-custom-plugins/automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles-MultiAuth/src/test/python`
  (`script_loader.py` with `load_script`, `FakeShell`, `run_main`). Run
  with `python3 -m unittest discover -s src/test/python` from `build.sh`,
  behind `command -v python3`. Say in the test file whether fixtures were
  captured from a device or synthesised.
- **Template pitfall: never serialise a converted request whose extended
  class is empty.** `objectMapper.writeValueAsString(refreshRequest)` on
  `RefreshConfigurationRequest<MyRefreshRequest>` throws
  `InvalidDefinitionException` (FAIL_ON_EMPTY_BEANS) and turns every
  refresh into a `WorkflowExecutionException`. The example template and
  plugins cloned from it carry this line; log the raw `JsonNode` instead.
  Found by the F5 MultiAuth tests in Oct 2026.
- **Do not count helper tests as coverage.** Before testing a helper class,
  confirm the plugin flow actually calls it.
- **Keep `README.md` truthful.** Its Testing section must name test classes
  that exist and commands that work.

### Dependabot
- GitHub security updates bump ONE artifact at a time to the lowest safe
  version. Do not merge a PR that moves a single `org.bouncycastle` artifact;
  bump the shared property instead and rebuild the dist zip.
- Some plugin directories contain a duplicate copy (for example a `bin/`
  folder). Dependabot bumps both; treat the duplicate as stale.

### Diagnosing sensor plugin logs
- The TPM SDK catches action exceptions and still logs
  `Workflow executed successfully` and `POST Response Code :: 200`. Those
  lines prove nothing. Search the stderr lines for the action's own exception
  (`Error executing action <name>`) before trusting success.
- `testConnection` passing while `refreshConfiguration` returns no
  certificates almost always means an exception inside the refresh action.

## Git in this checkout
- The working tree lives inside OneDrive Files On-Demand. If the OneDrive
  client is not running, git can hang on dataless `.git` placeholders. Wrap
  git calls in a timeout (for example `perl -e 'alarm 30; exec @ARGV' git ...`)
  and check for stale `.git/index.lock` files before retrying.
- Do not commit or push unless asked.
