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
