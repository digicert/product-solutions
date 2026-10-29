# F5 BIG-IP automation plugin

One plugin lives here: `F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles-MultiAuth`
(artifactId `f5-automation-plugin-multiauth`, version 1.1.0). It extends `AbstractAutomationWorkflow`
from plugin-sdk 1.1, runs every lifecycle operation over SSH by streaming a bundled Python script to
`python -` on the BIG-IP, and uses iControl REST only in `testConnection`. `README_DEV.md` explains the
design, the credential routing and the 1.1.0 changes.

History: until Oct 2026 a single-credential sibling (`f5-automation-plugin` 1.0.0, one account for REST
and SSH, Advanced shell required, HA sync always on) lived next to this one. It was removed on
2026-10-29; MultiAuth in `shared` mode replaces it. Connectors created with it keep working because a
blank `authMode` resolves to `shared`. The "legacy" argument forms described below exist because of it.

## Status (Oct 2026)

- The device-side scripts were exercised against BIG-IP 17.5.1.9 from TLM (discovery, CSR, install in
  both profile modes, validate) through the removed single-credential build, which shared them.
- MultiAuth 1.1.0 builds and passes 76 unit, 7 integration and 50 script tests, but has NOT been run
  against a live BIG-IP. Unverified on hardware: the three auth modes, SSH port, tmsh wrapping, HA sync
  toggle on a real pair, the PAM credential source (and whether TLM resolves the `sshPassword` vault
  reference), and the connector form with optional inputs and conditional PAM fields.
- `F5AutomationPlugin.refreshConfiguration` logs the raw `JsonNode`, not
  `objectMapper.writeValueAsString(refreshRequest)`; the latter throws on the empty `MyRefreshRequest`
  bean and fails every refresh. Keep it that way (see the root `CLAUDE.md`).

## Device-side scripts

`src/main/resources/ssh-scripts/{generate-csr,install-certificate,validate-certificate,get-configuration-info}.py`.
Keep them Python 2.7 compatible (BIG-IP interpreter): no f-strings, no `print` statements, no 3-only
syntax, and use `\\` escapes in non-raw strings so Python 3.12+ stays warning-free.

Argument contracts:

- `generate-csr.py`: 8 positional arguments plus optional 9th `groupSyncEnabled`. The plugin always
  sends it. Absent means the legacy behaviour (sync whenever HA is configured).
- `install-certificate.py`: preferred form is one base64 JSON document (keys in
  `F5SshAdapter.buildInstallPayload`; `groupSyncEnabled` defaults to false, `updateServerSslProfile` to
  true when a key is missing). Legacy form is 8 positional arguments plus optional 9th
  `updateServerSslProfile` (default true) and 10th `groupSyncEnabled` (default true, legacy behaviour).
  `parse_input()` handles both; the tests cover both.
- `validate-certificate.py`: `virtualServerName keyName`.
- HA sync in both scripts goes through `sync_ha_if_enabled(flag)` and returns an `info` message.

## Testing

Follow the repo-wide rules in the root `CLAUDE.md`. This plugin is the reference layout:

- Java: `src/test/java` with `*Test` (surefire) and `*IT` (failsafe, `@Tag("integration")`, WireMock on
  a dynamic HTTPS port with `jdk.internal.httpclient.disableHostnameVerification=true` set in `@BeforeAll`).
  Adapters and the plugin have package-private constructors for injection.
- Scripts: `src/test/python` with `script_loader.py` (`load_script`, `FakeShell`, `run_main`) and one
  `test_<script>.py` per script. Run with `python3 -m unittest discover -s src/test/python`. The tmsh
  fixtures are synthesised from the one-line format, not captured from a device; replace with real
  captures when one is available and keep the structure.
- `build.sh` runs the script tests, then `mvn clean verify`, then regenerates `plugin-dist/checksums`.
- `target/` is ignored by `.gitignore` and must not be tracked. Only `plugin-dist/` carries build output.

## Device-side behaviour to keep in mind

- The SSH probe is `python -c "print('python-ok')" && tmsh show sys version`. If the exec channel lands
  in tmsh, `SSHClient` detects it with `run /util bash -c 'echo %0'` and wraps every command.
- Passwords arrive base64-encoded from TLM; both password fields are decoded, plain text is tolerated.
- `managementPort` is the REST port (443, or 8443 on single-NIC); SSH port is separate (`sshPort`,
  default 22).
- F5 object names are capped at 255 characters including the partition path; `CertificateAttributesUtil.getObjectName`
  derives `CN_flowDate_flowIdPrefix` deterministically so CSR, install and validate agree.
- TLM has no UI for the per-request `updateSameSslProfile` flag on custom plugins; the connector setting
  `clientSslProfileMode` is authoritative.
