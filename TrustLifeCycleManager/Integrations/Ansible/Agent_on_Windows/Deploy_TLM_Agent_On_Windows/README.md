# Ansible Playbook: Deploy DigiCert TLM Agent on Windows

Automates the installation, activation, upgrade, and uninstallation of the [DigiCert Trust Lifecycle Manager (TLM)](https://www.digicert.com/trust-lifecycle-manager) Agent across Windows hosts using Ansible and WinRM.

The playbook copies the TLM Agent installer and a companion PowerShell deployment script to each target host, executes the deployment, verifies the result, and optionally cleans up temporary files.

## Prerequisites

- **Ansible** with WinRM connectivity configured to your Windows target hosts
- The Windows inventory group must be named `windows`
- The following files must exist on the Ansible control node:
  - `./files/DigiCert TLM Agent.exe` — the TLM Agent installer
  - `./files/Deploy-TLMAgent.ps1` — the PowerShell deployment wrapper script

## Configuration

### Environment Variables

The playbook reads sensitive values from environment variables on the control node to avoid hardcoding credentials:

| Variable | Description | Default |
|----------|-------------|---------|
| `DC_API_KEY` | DigiCert API key for agent activation | *(empty)* |
| `TLM_BUSINESS_UNIT` | TLM Business Unit ID | *(empty)* |
| `DCONE_HOST` | DigiCert ONE host URL | `one.digicert.com` |

Set these before running:

```bash
export DC_API_KEY="your-api-key"
export TLM_BUSINESS_UNIT="your-bu-id"
```

### Playbook Variables

These can be overridden at the command line with `-e` or in your inventory/group vars:

| Variable | Default | Description |
|----------|---------|-------------|
| `deployment_action` | `InstallAndActivate` | Action to perform (see below) |
| `agent_name` | `{{ inventory_hostname }}` | Name to register the agent under |
| `proxy_url` | *(empty)* | Optional proxy URL |
| `custom_install_dir` | *(empty)* | Custom installation directory |
| `remote_temp_dir` | `C:\Temp` | Temp directory on the remote host |
| `upgrade_installer_path` | *(empty)* | Alternate installer path for upgrades |

### Deployment Actions

The `deployment_action` variable accepts the following values:

| Action | Description |
|--------|-------------|
| `Install` | Install the agent without activating |
| `Activate` | Activate an already-installed agent |
| `InstallAndActivate` | Install and activate in one step *(default)* |
| `Upgrade` | Upgrade an existing installation |
| `Uninstall` | Remove the agent and its data |
| `UninstallPreserveData` | Remove the agent but keep its data |

## What the Playbook Does

1. Creates `C:\Temp` (or the configured temp directory) on each remote host
2. Copies the installer and `Deploy-TLMAgent.ps1` to the remote temp directory
3. Checks whether the TLM Agent service (`DigiCertAdmAgentService`) already exists and reports its status
4. Runs `Deploy-TLMAgent.ps1` with the appropriate parameters based on the configured action, passing in the API key, business unit, agent name, proxy, and host as needed
5. Fails the play if the deployment script exits with a non-zero exit code
6. Verifies the service state after deployment — confirms the service is running for install actions, or confirms it has been removed for uninstall actions
7. Reads and displays the last 30 lines of the deployment log at `%SystemDrive%\tlm_agent_deployment.log`
8. Cleans up the installer and script from the remote temp directory
9. Prints a summary showing the host, action taken, service state, and exit code

## Usage

### Basic Run (Install and Activate)

```bash
export DC_API_KEY="your-api-key"
export TLM_BUSINESS_UNIT="your-bu-id"

ansible-playbook ansible-deploy-tlm-agent.yaml -i inventory.ini
```

### Override the Deployment Action

```bash
ansible-playbook ansible-deploy-tlm-agent.yaml -i inventory.ini \
  -e "deployment_action=Upgrade"
```

### Target a Subset of Hosts

```bash
ansible-playbook ansible-deploy-tlm-agent.yaml -i inventory.ini \
  --limit web-servers
```

### Run Specific Phases Using Tags

| Tag | Description |
|-----|-------------|
| `install` | Copy files and run the deployment script |
| `verify` | Check service status and review deployment log |
| `cleanup` | Remove temporary files from remote hosts |
| `report` | Print the final deployment summary |

```bash
# Only verify (no install)
ansible-playbook ansible-deploy-tlm-agent.yaml -i inventory.ini --tags verify

# Skip cleanup
ansible-playbook ansible-deploy-tlm-agent.yaml -i inventory.ini --skip-tags cleanup
```

## Notes

- `agent_name` defaults to `inventory_hostname`, so each host registers under its own hostname
- API key and business unit ID are only passed to the deployment script when the action involves activation (`Activate`, `InstallAndActivate`)
- The `DcOneHost` parameter is only passed for install-type actions
- For `Upgrade`, you can optionally specify a different installer via `upgrade_installer_path`
- The playbook monitors the Windows service: **DigiCertAdmAgentService**

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.