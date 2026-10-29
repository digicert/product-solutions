# F5 BIG-IP Automation Plugin (multi-auth) - User Guide

## Overview

This plugin automates certificate lifecycle operations for F5 BIG-IP virtual servers from DigiCert
Trust Lifecycle Manager (TLM). It is a custom plugin built on the TLM extensibility framework.

Compared with the earlier single-credential build of this plugin (1.0.0, removed in October 2026) it adds:

- Three authentication modes: shared credentials, separate REST and SSH credentials, SSH only.
- Credentials from a connected secrets manager (BeyondTrust, CyberArk, Delinea) as well as direct input.
- Configurable SSH port.
- Support for SSH accounts whose terminal access is `tmsh` rather than Advanced shell (typical for
  AD/LDAP/RADIUS remote-role users). Commands are wrapped transparently.
- Optional HA group sync after CSR generation and certificate installation.
- Server-ssl profiles that present the replaced certificate are repointed in the same transaction as
  the client-ssl profile.

Supported operations:

- Test connection (SSH, plus iControl REST unless the mode is SSH only)
- Refresh configuration (discover BIG-IP system, virtual server and certificate metadata)
- Generate CSR
- Install certificate
- Validate certificate

## Prerequisites

### Access and permissions

- Follow https://docs.digicert.com/en/trust-lifecycle-manager/integration-guides/f5-big-ip-ltm-integration/prerequisites.html
  for the BIG-IP role requirements (Administrator role for the account that runs the lifecycle operations).
- The SSH account's **Terminal Access** can be either **Advanced shell** or **tmsh**. The plugin detects a
  tmsh login shell and wraps every command with `run /util bash -c`.
- Network reachability from the managing sensor to the BIG-IP management address on the SSH port (22
  by default) and, unless the mode is SSH only, on the iControl REST port (443, or 8443 on single-NIC
  deployments).
- RADIUS / TACACS+ / LDAP accounts work as a normal username and password. They need a Remote Role Group
  mapping to Administrator. When a remote auth source is configured, the BIG-IP authenticates only `admin`
  and `root` locally, so either use a remote-auth service account (shared mode) or pair `admin` for REST
  with `root` for SSH (separate mode).
- SSH key authentication is not implemented; SSH is password-only.

### Tested with

| Component | Version | Notes |
|---|---|---|
| F5 BIG-IP | 17.5.1.9 Build 0.174.12 | Single-NIC VE in AWS, standalone. Discovery, CSR generation, install (in-place and copy-profile paths, with and without server-ssl repoint) and validation were driven from TLM on 2026-10-02 to 2026-10-05 **using the earlier single-credential 1.0.0 build**, which ran the same device scripts. |

What has **not** been exercised against a live BIG-IP yet, and must be verified on first deployment:

- The three authentication modes and the SSH port setting on a device (covered by unit tests only).
- The tmsh login-shell wrapping (covered by unit tests only).
- The HA group sync toggle on an HA pair (the scripts' sync logic has not run on a live pair in either plugin).
- The secrets manager (PAM) credential source, including whether TLM resolves the vault reference entered
  in the **SSH password** field the same way it resolves the primary password. The configuration follows
  the pattern validated with BeyondTrust in the ps-solutions F5 plugin.
- The connector form itself with this `configuration.json` (optional inputs, conditional PAM fields).

## Security notes

- Store BIG-IP credentials in a secrets manager where possible.
- Passwords are delivered to the plugin base64-encoded by TLM and decoded in memory only.
- Nothing secret is written to the sensor log; the resolved identities are logged as `user@host:port`.
- Rotate credentials periodically and audit privileged access on the BIG-IP.

## Plugin configuration

Note: some connector UI capabilities of the built-in F5 integration are not available in custom plugins
because of extensibility framework limitations (see below).

### Steps to add the plugin

- Log in to the DigiCert ONE portal.
- Ensure the account has the **Plugins** menu under **Integrations**. If not, ask the Engineering team to
  enable it (customer name, region and account GUID). The uploading user needs the Plugin Developer permission.
- Navigate to **Integrations > Plugins** and click **Add plugin**:
  - Name: F5 BIG-IP (multi-auth), or a business-friendly name
  - Plugin type: Automation
  - Plugin version: 1.1.0
  - Vendor: F5
  - Operating system: Cross platform
  - Plugin file: upload `plugin-dist/f5-automation-plugin-multiauth-1.1.0.zip`
  - Configuration: upload `configuration.json`
- Click **Verify and Create**. Security scanning can take up to 15 minutes before the plugin becomes active.
- Once active, add a connector from **Integrations > Connectors > Add connector** and pick the plugin.

### Steps to update the plugin

- Edit the existing plugin under **Integrations > Plugins**, set the version to 1.1.0, upload the new zip
  and `configuration.json`, click **Verify and Create** and wait for the scan to complete.
- Existing connectors keep working. Connectors saved with version 1.0.0 behave as before: shared
  credentials, direct input, HA group sync off.

### Connector fields

| Field | Description |
|---|---|
| Managing Sensor | Sensor that runs the integration against the BIG-IP. |
| Management IP | BIG-IP management IP or hostname. |
| Management Port (iControl REST) | 443, or 8443 on single-NIC deployments. Still required in SSH only mode; enter 443. |
| Credentials source | **Direct input**: enter username and password. **Secrets manager**: pick a PAM connector, enter the username and the vault reference of the password. Banners show the reference format per provider. |
| Username / Password | Primary account. REST and SSH in shared mode, REST only in separate mode, SSH in SSH only mode unless an SSH username is given. |
| Authentication mode | **Shared credentials** (default), **Separate REST and SSH credentials**, **SSH only (no REST)**. |
| SSH username / SSH password | Required in separate mode. Optional in SSH only mode (falls back to the primary account). Ignored in shared mode. With a secrets manager source, the SSH password is a vault reference. |
| SSH port | Leave blank for 22. |
| Client-ssl profile handling | **Update existing profile** (default) replaces cert, key and chain inside the bound profile. **Create new profile** copies the bound profile to one named after the new key, binds the copy and unbinds the original. |
| Update server-ssl profiles | **Yes** (default) repoints server-ssl profiles on the same virtual server that present the replaced certificate, in the same transaction. **No** leaves them untouched. |
| Enable HA group sync | Off by default. When on, a `config-sync to-group` runs against the sync-failover device group after CSR generation and after certificate install. Ignored on standalone devices. |

### Authentication modes

The plugin talks to two control planes. iControl REST is used only by Test Connection (one basic-auth
`GET /mgmt/tm/sys/version`). SSH carries every lifecycle operation by streaming a Python script to the
device and running it with `python -`, which calls `tmsh`. The SSH identity is therefore the one that
needs real rights; REST is a fast fail-early check.

| Mode | REST identity | SSH identity |
|---|---|---|
| Shared credentials | Username / Password | Username / Password |
| Separate REST and SSH credentials | Username / Password | SSH username / SSH password (required) |
| SSH only | none | SSH username / SSH password when both are set, otherwise Username / Password |

Test Connection always runs the SSH probe (`python -c ... && tmsh show sys version`, which works for local,
root and remote-auth users) and, outside SSH only mode, the REST probe. Error messages are prefixed with
the transport and identity (`SSH (root@10.0.0.1:22): ...`, `REST (admin@10.0.0.1:443): ...`). Missing
required fields are reported as `CONFIGURATION_ERROR` by every operation before any network call.

## Extensibility framework limitations

The following features of the built-in F5 connector are not available in a custom plugin:

- Connector addition: **Additional settings > Recover previous settings**.
- Connector view: partition information and the values of additional settings are not shown.
- Automation request: private key storage location cannot be chosen per request. The plugin honours the
  `keyStorage` value TLM passes (`normal`, `fips`, `nethsm`) and defaults to the BIG-IP filesystem.
- TLM sends an `updateSameSslProfile` flag per request but offers no UI for it on custom plugins. The
  connector setting **Client-ssl profile handling** is authoritative; the request flag is only logged.

## Workflow usage

### 1. Test connection

Validates that the SSH identity can run python and tmsh and, unless SSH only, that the REST identity can
authenticate. Reports active only when every probe succeeds; all failures are listed, not just the first.

### 2. Refresh configuration

Discovers system version, virtual servers (partition, alias, destination IP and port, SSL state),
certificates presented by client-ssl profiles (with cipher discovery and SNI flag), peers and partitions.

### 3. Generate CSR

Inputs: subjectDn, dnsNames, keyAlgorithm, keySize, keyStorage, virtualServerName (for example
`/Common/vs_example`). The key and CSR are created on the BIG-IP in the virtual server's partition with a
deterministic object name derived from the CN, flow start date and flow id. HA sync runs if enabled.

### 4. Install certificate

Inputs: certificateLink (DigiCert ONE artifact URL) or an inline certificateChain, virtualServerName,
currentCertificateThumbprint. The end-entity and ICA certificates are installed, the client-ssl profile is
updated or copied according to the connector setting, matching server-ssl profiles are repointed when
enabled, the configuration is saved and HA sync runs if enabled.

### 5. Validate certificate

Resolves the expected certificate object name from the same inputs as the CSR step and returns the PEM
presented by the client-ssl profile, falling back to server-ssl profiles.

## Error handling

- `CONFIGURATION_ERROR`: a required connector field for the selected mode is missing.
- `UNAUTHORIZED`: the REST identity was rejected (HTTP 401).
- `INTERNAL_ERROR`: transport failure or a script that did not return JSON (for example python missing).
- Script error codes: `CLIENT_SSL_PROFILE_NOT_FOUND`, `CERTIFICATE_INSTALLATION_ERROR`,
  `CERTIFICATE_VALIDATION_ERROR`, `CSR_GENERATION_ERROR`, `HA_SYNC_ERROR`, `HA_INFO_FETCH_ERROR`,
  `TMSH_OUTPUT_PARSE_ERROR`, `SHELL_COMMAND_ERROR`, `INVALID_ARGUMENTS`, `UNKNOWN_ERROR`.
- Informational messages from the device scripts (for example whether HA sync ran) are written to the
  sensor log at INFO level.

## Troubleshooting

### Test connection fails

- Read the prefix of the error: it names the transport and the identity that failed.
- `SSH (...)`: check the SSH port, that the account can log in over SSH, and that `python` and `tmsh` are
  available to it. Both Advanced shell and tmsh terminal access are supported.
- `REST (...)`: check the management port (8443 on single-NIC) and the REST identity, or switch to SSH only
  if the management port is not reachable from the sensor.
- `CONFIGURATION_ERROR`: fill in the SSH username and password for separate mode.

### CSR generation fails

- Verify the virtual server name includes the partition (`/Common/vs_example`).
- Confirm the requested key storage (FIPS, NetHSM) is enabled on the device.
- `HA_SYNC_ERROR`: the device is HA but has no sync-failover device group, or the account cannot run
  `config-sync`. Disable HA group sync or fix the device group.

### Certificate installation fails

- `CLIENT_SSL_PROFILE_NOT_FOUND`: no client-ssl profile on the virtual server presents a certificate with
  the thumbprint TLM sent. The certificate may already have been replaced on the device.
- Verify the artifact URL is reachable from the sensor.
- On HA pairs verify the sync-failover device group state.

### Validation fails

- Confirm the certificate install completed and the virtual server and profile mapping is correct.

### Reading sensor logs

The TLM SDK logs `Workflow executed successfully` and `POST Response Code :: 200` even when an action
failed. Search for `Error in <action>` or `SSH script ... failed` instead.

## Best practices

- Run Test Connection before operational workflows.
- Validate on a non-production virtual server first.
- Enable HA group sync only where HA synchronisation is required.

## Changelog

### 1.1.0

- Credentials source: direct input or secrets manager (PamConnectors) with BeyondTrust, CyberArk and
  Delinea reference hints, for the primary and the SSH password.
- SSH accounts with tmsh terminal access are supported; commands are wrapped with `run /util bash -c`.
- Enable HA group sync connector setting (default off) honoured in CSR generation and install.
- install-certificate.py now takes one base64-encoded JSON document instead of positional arguments
  (the legacy positional form sent by the 1.0.0 build is still accepted).
- Fixed refreshConfiguration failing with a Jackson "no serializer for MyRefreshRequest" error when
  logging the request.
- Fixed validate-certificate.py raising instead of returning not-found when a client-ssl profile has no
  flat `cert` property.
- BouncyCastle 1.86 (CVE fixes), single version property.
- Plugin version logged at startup; process timeout raised to 60 minutes.
- Test suite: 76 Java unit tests, 7 WireMock integration tests, 50 device script tests. See README_DEV.md.

### 1.0.0

- Initial multi-auth variant: authentication modes, SSH port, identity-prefixed errors, configuration
  validation, server-ssl profile handling.
