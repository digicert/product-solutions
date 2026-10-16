# DigiCert TLM Agent — Microsoft Exchange Server Hybrid Certificate Automation

## Overview

PowerShell post-delivery script that installs a TLM-issued TLS certificate on Microsoft Exchange Server and updates Exchange Hybrid TLS configuration when enabled.

The script is designed to run on the primary Exchange server under the DigiCert TLM Agent service. It reads the delivered PKCS#12 certificate and password from `DC1_POST_SCRIPT_DATA`, validates the certificate and Exchange topology, and then:

1. Imports and enables the certificate for the selected Exchange services on the primary server and, in HA mode, the secondary server.
2. Updates Hybrid send/receive connector TLS settings and the Hybrid Configuration object when hybrid management is enabled and SMTP is selected.
3. Runs Exchange health and HTTPS validation, and attempts coordinated rollback if deployment fails.
4. Removes the previous certificate only when it passes usage and binding checks, unless removal is disabled or report-only mode is selected.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `Windows/ms_exchange_automation_single_ha_support.ps1` | Windows | Windows PowerShell 5.0/5.1 |

## Requirements

- Windows PowerShell 5.0 or 5.1. The script is built and validated for Windows PowerShell 5.x.
- Run on the primary Exchange server specified by `PRIMARY_SERVER`, with the elevated permissions needed to manage Exchange certificates, services, connectors, and Hybrid Configuration.
- Exchange Management Shell cmdlets available on the primary server.
- TLM Agent access to the delivered PKCS#12 (`.pfx` or `.p12`) file and its generated password.
- For HA mode:
	- WinRM connectivity from the primary server to the secondary Exchange server.
	- Remote administrative access to `\\<SecondaryServer>\C$`.
	- Permissions to manage Exchange certificates and services on both nodes.
- Network and name resolution between the managed Exchange nodes.

## AWR Arguments

Pass six positional values in the Admin Web Request. Use `-` for an unused value so later arguments are not shifted. Blank or placeholder values use the script defaults. The server values must be NetBIOS names, not FQDNs.

| Argument | Setting | Mandatory | Values | Default if blank |
|----------|---------|--------------------|--------|------------------|
| ARGUMENT_1 | NodeMode | No | `Single`, `HA` | `HA` |
| ARGUMENT_2 | PrimaryServer | No | Server name | `LV-EXCH1` |
| ARGUMENT_3 | SecondaryServer | No | Server name (HA only) | `BV-EXCH1` |
| ARGUMENT_4 | HybridEnabled | No | `true`, `false` | `true` |
| ARGUMENT_5 | RemoveOldCertificate | No | `true`, `false`, `report` | `true` |
| ARGUMENT_6 | ExchangeServices | No | `POP`, `IMAP`, `IIS`, `SMTP`, `ALL` | All four (`POP,IMAP,IIS,SMTP`) |

## Production Execution Steps


    Step 1: Upload script to DigiCert ONE Portal
        1. Go to Discovery and Automation tools > Scripts
        2. Click Add script for > DigiCert Agents
        3. Enter script name and set:
                - Operating System: Windows
                - Script type: Admin request post-delivery
        4. Click Add and verify script

    Step 2: Configure Admin Web Request (AWR)
        5. Go to Inventory > Admin web request
        6. In STEP 1, fill in the parameters
        7. In STEP 2:
                - Click Add
                - Select Agent
                - Click Apply

    Step 3: Set certificate delivery
        8. Under DigiCert Agents, select the appropriate Agent
        9. Under Destination 1, configure:
                - Format: PKCS12
                - Target path: certificate folder path
                - Provide password
       10. Enable Run post delivery Scripts
       11. Select the uploaded script
       12. Fill the arguments as listed in the Argument reference above

    Step 4: Complete request
       13. Proceed with the remaining configuration steps

## Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and read the six AWR arguments, delivered files, and PFX password. Placeholder values (`-`, `none`, `n/a`, `na`, or `default`) select the script defaults.
2. Require a PKCS#12 file with a certificate that has a private key, validate the target server and topology, and check certificate suitability before making Exchange changes.
3. Archive the PFX and import the certificate on the primary server. In HA mode, validate transport readiness and stage/import the certificate on the secondary server.
4. Enable the certificate for the selected Exchange services. When effective hybrid management is enabled, update the applicable Hybrid TLS connector settings and Hybrid Configuration object.
5. Validate the deployment, including Exchange health and OWA/ECP HTTPS where applicable. On failure, attempt to restore the prior certificate and Hybrid TLS state; inspect the run summary to confirm whether rollback completed.
6. Check old-certificate usage and HTTP.sys bindings before removal. Certificates that are self-signed, used by OAuth/federation/internal transport, assigned to unmanaged services, or still bound are not removed.

`HYBRID_ENABLED=true` does not update Hybrid configuration when SMTP is omitted from `EXCHANGE_SERVICES`. `IIS` controls whether the Front End HTTPS binding is managed; the Exchange Back End binding on port 444 is read-only.

## Logging

Logs are written to:

- `C:\Program Files\DigiCert\TLM Agent\log\ms-exchange-server-hybrid-support.log`

The script writes timestamped progress and a deployment summary to the log and console. Log level is controlled by the `LogLevel` script parameter (`DEBUG` or `INFO`). Logs rotate at 20 MB, retaining up to five rotated files. The PFX password and raw delivery payload are not logged.

## Exit Codes

- `0` — deployment and required final validation completed successfully.
- `1` — initialization, payload, preflight, deployment, or final validation failed. Review the deployment summary and verify rollback status before retrying.

## Security Considerations

- Do not hardcode credentials or PFX passwords. The script obtains the generated PFX password from the TLM runtime payload; do not put secrets in AWR arguments or local test files committed to source control.
- Restrict the TLM Agent service identity to the Exchange and Windows permissions needed for the selected node mode and services.
- Treat the delivered PFX and archived PFX as sensitive private-key material. Restrict access to the delivery and archive paths and follow your certificate retention policy.
- Validate AWR server names and settings before execution. Use NetBIOS names and preserve all six argument positions with `-` placeholders when needed.
- In HA mode, coordinate execution with Exchange operations because deployment and rollback may restart IIS or transport services. A special old-certificate removal path can temporarily stop `MSExchangeTransport`; verify it is running after the run.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `DC1_POST_SCRIPT_DATA` missing or decode failed | Script was not invoked through the expected TLM post-delivery flow, or the payload is invalid | Verify the AWR post-delivery configuration and rerun through the TLM Agent. |
| Arguments appear shifted | An unused argument was left blank and omitted from the payload | Supply all six positions and use `-` for unused values. |
| Wrong-host execution guard fails | `PRIMARY_SERVER` does not match the local server, or an FQDN was supplied | Set ARGUMENT_2 to the local server's NetBIOS name. |
| HA requires a secondary server | `NODE_MODE=HA` but ARGUMENT_3 is empty | Set the secondary Exchange server NetBIOS name, or use `Single` for one node. |
| PFX missing, password empty, or import fails | Delivery format/path is not PKCS12, or the TLM payload did not include a valid password | Configure PKCS12 delivery and verify the TLM certificate destination and password settings. |
| WinRM, admin-share, or remote operation fails | Primary-to-secondary connectivity or permissions are missing | Verify WinRM, name resolution, `\\<SecondaryServer>\C$` access, and the Agent service identity's rights. |
| Hybrid configuration is not updated | Hybrid is disabled, or SMTP is not selected | Set ARGUMENT_4 to `true` and include `SMTP` in ARGUMENT_6. |
| Old certificate remains installed | Removal was disabled/report-only, or safety checks found another usage or binding | Review the old-certificate removal results in the run summary; remove manually only after verifying all Exchange dependencies. |
| Deployment reports rollback failure | One or more restore or post-rollback validation stages failed | Check the log's first failure and rollback errors; verify the active certificate, connectors, Hybrid Configuration, and service health before retrying. |

## Legal

See the header comment block in `Windows/ms_exchange_automation_single_ha_support.ps1` for the full DigiCert legal notice. `$LEGAL_NOTICE_ACCEPT` must be `"true"` for the script to run.

## Version

Script version is tracked in the `$ScriptVersion` constant (currently `9.13`).
