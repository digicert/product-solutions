# TLM Agent — Azure Application Gateway Certificate Upload

**Script:** `awr-application-gateway-upload-cert.ps1`

A DigiCert Trust Lifecycle Manager (TLM) AWR Post Script that automatically uploads a newly issued PFX certificate to an Azure Application Gateway SSL certificate store. Does not use Azure Key Vault — the certificate is uploaded directly to the Application Gateway using the native SSL certificate resource.

---

## How It Works

When TLM issues or renews a certificate, the AWR agent triggers this post script and passes certificate details (file paths, password, arguments) via the `DC1_POST_SCRIPT_DATA` environment variable as a Base64-encoded JSON payload.

The script:

1. Decodes and parses `DC1_POST_SCRIPT_DATA` to extract the PFX file path and password
2. Validates that all required AWR parameters and the PFX file are present
3. Authenticates to Azure using a Service Principal or Managed Identity
4. Retrieves the target Application Gateway
5. Adds the certificate if it does not exist, or updates it in place if it does
6. Commits the change with `Set-AzApplicationGateway`, triggering an AGW reconfiguration
7. Logs all steps and outcomes to a local log file

---

## Prerequisites

### On the TLM Agent host (Windows)

- **PowerShell 5.1** or later (PowerShell 7+ recommended)
- **Az PowerShell modules** — `Az.Accounts` and `Az.Network`:

  ```powershell
  Install-Module Az.Accounts, Az.Network -Scope AllUsers -Force
  ```

- **Log directory** — the directory for the log file must exist before the script runs. The default path is `C:\Certs\`. Create it if needed:

  ```powershell
  New-Item -ItemType Directory -Path "C:\Certs" -Force
  ```

- **DigiCert TLM Agent** installed and enrolled

### In Azure

- An Azure Application Gateway (v1 or v2 SKU) already provisioned
- A Service Principal with **Network Contributor** role on the resource group, **or** a Managed Identity assigned to the host VM with the same role

---

## Script Configuration

Two variables at the top of the script must be set before use:

| Variable | Default | Description |
|---|---|---|
| `$LEGAL_NOTICE_ACCEPT` | `"true"` | Must be `"true"` for the script to run |
| `$LOGFILE` | `C:\Certs\agw-logfile.log` | Full path to the log file |

---

## AWR Post Script Parameter Mapping

Configure the following in the TLM AWR **Post Script** parameter fields:

| AWR Parameter | Maps To | Required | Description |
|---|---|---|---|
| Parameter 1 | Azure Tenant ID | No* | Directory (tenant) ID from Microsoft Entra ID |
| Parameter 2 | Service Principal Client ID | No* | Application (client) ID of the Service Principal |
| Parameter 3 | Service Principal Client Secret | No* | Secret value (logged as `***`, never in clear text) |
| Parameter 4 | Azure Subscription ID | **Yes** | Subscription containing the Application Gateway |
| Parameter 5 | Resource Group Name | **Yes** | Resource group containing the Application Gateway |
| Parameter 6 | Application Gateway Name | **Yes** | Name of the Application Gateway resource |
| Parameter 7 | Certificate Name in AGW | **Yes** | Label for the certificate inside the Application Gateway |

*Parameters 1–3 are required when using Service Principal authentication. Leave all three empty to use Managed Identity instead.

---

## Authentication

### Option A — Service Principal (recommended for most environments)

**1. Create the Service Principal via Azure CLI:**

```bash
az ad sp create-for-rbac \
  --name "tlm-appgw-cert-upload" \
  --role "Network Contributor" \
  --scopes "/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/<RESOURCE_GROUP>"
```

The output contains all three values needed for Parameters 1–3:

```json
{
  "appId":    "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",   ← Parameter 2 (Client ID)
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", ← Parameter 3 (Client Secret)
  "tenant":   "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"    ← Parameter 1 (Tenant ID)
}
```

> **Save the `password` immediately.** It cannot be retrieved again after creation.

**2. Create the Service Principal via Azure Portal:**

- **Microsoft Entra ID** → **App registrations** → **New registration** → name it and register
- Copy **Application (client) ID** (Parameter 2) and **Directory (tenant) ID** (Parameter 1)
- Under **Certificates & secrets** → **New client secret** → copy the **Value** (Parameter 3)
- Assign **Network Contributor** to the Service Principal on the target resource group via **IAM**

---

### Option B — Managed Identity

If the TLM Agent host is an Azure VM:

1. Enable a **System-assigned Managed Identity** on the VM (Azure Portal → VM → Identity → On)
2. Assign **Network Contributor** on the resource group to the VM's identity
3. Leave AWR Parameters 1, 2, and 3 **empty** — the script detects this and uses `Connect-AzAccount -Identity`

---

## Certificate Name Behaviour

The **Certificate Name** (Parameter 7) is the label stored inside the Application Gateway. The script checks whether a certificate with that name already exists:

- **Exists** → updates the certificate in place using `Set-AzApplicationGatewaySslCertificate`
- **Does not exist** → creates a new entry using `Add-AzApplicationGatewaySslCertificate`

When a certificate name is updated in place, all HTTPS listeners that reference that name automatically use the new certificate after the gateway reconfigures — no listener changes are required.

> If you change the certificate name (Parameter 7) between renewals, the old certificate entry remains in the gateway orphaned, and existing listeners will still point to the old name. Keep the name consistent across renewals.

---

## Log File

All script activity is written to the path defined in `$LOGFILE` (`C:\Certs\agw-logfile.log` by default). Sensitive values are protected:

- Client Secret (Parameter 3) — logged as `[redacted]`
- PFX password — length only, never the value
- Raw `DC1_POST_SCRIPT_DATA` JSON — logging disabled (contains the PFX password)

Example log output for a successful run:

```
[2026-08-17 10:23:01] ==========================================
[2026-08-17 10:23:01] Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)
[2026-08-17 10:23:01] JSON parsed successfully
[2026-08-17 10:23:01] Authenticating with Service Principal (Client ID: xxxxxxxx-...)
[2026-08-17 10:23:03] Service Principal authentication successful
[2026-08-17 10:23:03] Retrieving Application Gateway 'my-appgw' in resource group 'my-rg'...
[2026-08-17 10:23:04] Application Gateway retrieved — State: Running, Provisioning: Succeeded
[2026-08-17 10:23:04] Certificate 'my-cert' already exists — updating...
[2026-08-17 10:23:05] Committing Application Gateway changes to Azure (may take several minutes)...
[2026-08-17 10:23:47] Application Gateway update committed successfully
[2026-08-17 10:23:47]   Provisioning state : Succeeded
[2026-08-17 10:23:47]   Operational state  : Running
```

---

## Gotchas

**`Set-AzApplicationGateway` takes several minutes**
Committing any change to an Application Gateway triggers a full reconfiguration. Expect 2–10 minutes depending on gateway size. The TLM AWR post script timeout must be set higher than this. The gateway continues serving traffic during this period on v2 SKUs; v1 SKUs may experience a brief interruption.

**Gateway must not already be updating**
If another operation (portal change, another deployment) has the gateway in a `Updating` or `Failed` provisioning state when the script runs, `Set-AzApplicationGateway` will fail. Check the gateway's provisioning state in the portal before scheduling concurrent operations.

**PFX must include the private key**
Application Gateway rejects PFX files that do not contain the private key. TLM-issued PFX files always include it, but verify if the AWR profile is configured for a non-PFX format and converted externally.

**RSA key requirement on older SKUs**
Application Gateway v1 only supports RSA certificates. Application Gateway v2 supports both RSA and ECDSA. If your TLM profile issues ECDSA certificates, confirm you are using a v2 SKU.

**Client Secret expiry**
Service Principal secrets expire (typically 1–2 years). If the secret expires, the script will fail at authentication. Rotate the secret in Microsoft Entra ID and update AWR Parameter 3 before expiry.

**Log directory must exist**
The script will fail silently on the very first `Write-LogMessage` call if `C:\Certs\` does not exist, because `Add-Content` does not create missing directories. Create the directory before the script first runs.

**Az module availability under the TLM Agent service account**
The Az modules must be installed for the Windows account that runs the TLM Agent service, not just the interactive user. Use `-Scope AllUsers` when installing:

```powershell
Install-Module Az.Accounts, Az.Network -Scope AllUsers -Force
```

**Concurrent AWR post scripts**
If TLM triggers renewals for multiple certificates simultaneously and both target the same Application Gateway, the second `Set-AzApplicationGateway` call will fail because the gateway is already updating. The script will log the error and exit with code 1. TLM will surface this as a post-script failure. Stagger renewals or use a single AWR renewal that covers all SANs to avoid this.

---

## Minimum IAM Role

`Network Contributor` scoped to the resource group works for all environments. For least-privilege, a custom role with only these actions is sufficient:

```json
"actions": [
  "Microsoft.Network/applicationGateways/read",
  "Microsoft.Network/applicationGateways/write"
]
```

---

