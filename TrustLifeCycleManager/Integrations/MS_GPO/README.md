# Deploy-TLMAgent.ps1

A PowerShell script that manages the full deployment lifecycle of the **DigiCert Trust Lifecycle Manager (TLM) Agent** on Windows hosts. It wraps the vendor installer and activation tooling behind a single, parameterised entry point so the agent can be installed, activated, upgraded, and removed consistently — whether run interactively or pushed at scale through **Microsoft Group Policy (GPO)**.

## What it does

The script performs one of six actions in a single run, with consistent logging, error handling, and administrator-privilege checks throughout:

| Action | Description |
| --- | --- |
| `Install` | Silently installs the TLM Agent using the bundled installer. |
| `Activate` | Activates an already-installed agent against DigiCert ONE using an API key and (optionally) a business unit, agent name, and proxy. |
| `InstallAndActivate` | **(Default)** Installs and then immediately activates the agent in one pass. |
| `Upgrade` | Upgrades an existing agent to a newer installer version (`ISUPDATE=1`). |
| `Uninstall` | Silently removes the agent and all of its data. |
| `UninstallPreserveData` | Removes the agent but preserves data and certificates for rollback (`PRESERVEDATA=1`). |

Key behaviours:

- **Silent operation** — the installer is always invoked with `/quiet /norestart ACCEPTEULA=yes`, making the script suitable for unattended/GPO deployment.
- **Service-aware activation** — locates the `DigiCertAdmAgentService` via WMI, derives the installation directory from the service executable path, and runs the vendor's `activate-and-start-tlm-agent.bat` from there.
- **Environment-variable fallbacks** — sensitive or per-host values can be supplied via environment variables instead of command-line parameters (see below).
- **Comprehensive logging** — every step is timestamped and written to both the console (colour-coded by severity) and a log file. The API key is masked in the logs.
- **Structured exit codes** — see [Exit codes](#exit-codes).

## Requirements

- Windows with PowerShell.
- **Administrator privileges** — the script aborts if not run elevated.
- The TLM Agent installer (`DigiCert TLM Agent.exe` by default) available on the host — typically placed alongside this script.

## Parameters

| Parameter | Required | Description | Environment fallback |
| --- | --- | --- | --- |
| `-Action` | No | One of the six actions above. Defaults to `InstallAndActivate`. | — |
| `-InstallerPath` | No | Path to the installer `.exe`. Defaults to `DigiCert TLM Agent.exe` in the script directory. | — |
| `-InstallDir` | No | Custom installation directory. Defaults to Program Files. | — |
| `-ApiKey` | For activation | API key used to activate the agent. | `DC_API_KEY` |
| `-BusinessUnitId` | No | Business unit ID for activation. | `TLM_BUSINESS_UNIT` |
| `-AgentName` | No | Friendly agent name. Defaults to the computer name. | `TLM_AGENT_NAME` |
| `-Proxy` | No | Proxy server URL for agent communication. | — |
| `-DcOneHost` | No | DigiCert ONE host to register against. | `DCONE_HOST` |
| `-LogFile` | No | Path to the deployment log. Defaults to `%SystemDrive%\tlm_agent_deployment.log`. | — |

## Usage

Install and activate in one step:

```powershell
.\Deploy-TLMAgent.ps1 -Action InstallAndActivate -ApiKey "your-api-key" -BusinessUnitId "your-bu-id"
```

Install only, to a custom directory:

```powershell
.\Deploy-TLMAgent.ps1 -Action Install -InstallDir "D:\CustomPath\TLMAgent"
```

Activate an existing agent behind a proxy with a custom name:

```powershell
.\Deploy-TLMAgent.ps1 -Action Activate -AgentName "WebServer01" -Proxy "http://proxy.company.com:8080"
```

Upgrade to a newer version:

```powershell
.\Deploy-TLMAgent.ps1 -Action Upgrade -InstallerPath "C:\Temp\NewVersion.exe"
```

Uninstall (optionally preserving data for rollback):

```powershell
.\Deploy-TLMAgent.ps1 -Action Uninstall
.\Deploy-TLMAgent.ps1 -Action UninstallPreserveData
```

## Deploying via Group Policy (GPO)

Because the script runs silently and supports environment-variable fallbacks, it is well suited to GPO-based rollout:

1. Place `Deploy-TLMAgent.ps1` and the installer `.exe` on a share reachable by target machines.
2. Distribute the API key / business unit / DigiCert ONE host via environment variables (`DC_API_KEY`, `TLM_BUSINESS_UNIT`, `DCONE_HOST`) or as script parameters in the startup script definition.
3. Configure a **Computer Configuration → Startup** PowerShell script that invokes `Deploy-TLMAgent.ps1` with the desired `-Action`. Startup scripts run as `SYSTEM`, satisfying the administrator requirement.
4. Review the deployment log (default `%SystemDrive%\tlm_agent_deployment.log`) on target hosts to confirm success.

## Logging

- **Console:** colour-coded — `INFO` (default), `WARNING` (yellow), `ERROR` (red), `SUCCESS` (green).
- **File:** timestamped entries appended to the path given by `-LogFile`.
- **Installer/activation logs:** the vendor installer writes to the same `-LogFile`; activation stdout/stderr are captured to temporary files in `%TEMP%`, echoed into the log, then cleaned up.
- The API key is never written to the logs in clear text.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Deployment completed successfully. |
| `1` | Failure — install, upgrade, uninstall, or activation failed, or a critical error occurred (including missing administrator privileges). |
| `2` | Partial success under `InstallAndActivate` — installation succeeded but activation failed. |

## Notes

- The service the script manages is named `DigiCertAdmAgentService`.
- Activation requires an API key; supply it via `-ApiKey` or the `DC_API_KEY` environment variable, otherwise activation aborts.
- After install/upgrade the script pauses briefly to allow service registration before reporting service status.
