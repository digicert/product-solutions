# DigiCert ACME Certificate Automation – Azure DevOps Pipeline

Automated certificate issuance and deployment pipeline using DigiCert ONE ACME, AWS Route 53 DNS validation, Azure Key Vault, and Azure Application Gateway.

## Overview

This Azure DevOps pipeline automates the full certificate lifecycle for an Azure Application Gateway by chaining together DigiCert's ACME directory, AWS Route 53 DNS-01 challenge validation, Azure Key Vault storage, and Application Gateway SSL certificate refresh — all on a bi-monthly schedule with zero manual intervention.

## Pipeline Flow

```
┌──────────────────┐     ACME + EAB      ┌──────────────────┐     DNS-01        ┌──────────────────┐
│  Azure DevOps    │ ──────────────────▶  │  DigiCert ONE    │ ──────────────▶   │  AWS Route 53    │
│  Pipeline        │                      │  ACME Directory  │  challenge         │  (DNS Validation)│
│  (Scheduled)     │ ◀────────────────── │                  │ ◀──────────────── │                  │
└────────┬─────────┘    signed cert       └──────────────────┘   validated        └──────────────────┘
         │
         │  PFX import
         ▼
┌──────────────────┐     Secret ID ref    ┌──────────────────┐
│  Azure Key Vault │ ──────────────────▶  │  Azure App       │
│                  │                      │  Gateway          │
└──────────────────┘                      │  (SSL Listener)  │
                                          └──────────────────┘
```

## What Each Step Does

| Step | Description |
|------|-------------|
| **Install Certbot** | Installs Certbot and the Route 53 DNS plugin on the build agent. |
| **Install Azure CLI** | Installs the Azure CLI for Key Vault and Application Gateway operations. |
| **Clear Certbot cached state** | Removes any leftover ACME state from previous runs to ensure a clean issuance. |
| **Issue certificate via Certbot** | Requests a certificate from DigiCert ONE's ACME directory using External Account Binding (EAB) credentials and DNS-01 validation via Route 53. |
| **Convert to PFX** | Packages the issued private key and full chain into a PKCS#12 (.pfx) file for Azure import. |
| **Import certificate to Key Vault** | Uploads the PFX to Azure Key Vault as a managed certificate object. |
| **Refresh Application Gateway SSL** | Retrieves the latest certificate version from Key Vault and updates the Application Gateway SSL listener to reference it. |

## Schedule

The pipeline runs on a **bi-monthly cron schedule** (`0 0 1 */2 *` — midnight UTC on the 1st of every other month) and does not trigger on code pushes. It can also be run manually from the Azure DevOps UI.

## Prerequisites

### Azure

- **Azure Key Vault** with an access policy granting the pipeline service principal `import` permission on certificates and `get`/`list` on secrets.
- **Azure Application Gateway** configured with an HTTPS listener referencing a Key Vault certificate.
- **Azure DevOps Service Connection** (`azure-keyvault-connection`) with contributor access to the resource group.

### DigiCert ONE

- An ACME-enabled certificate profile in DigiCert ONE mPKI.
- **EAB credentials** (Key ID and HMAC key) generated from the DigiCert ONE ACME directory configuration.

### AWS

- **Route 53 hosted zone** for the target domain (used for DNS-01 challenge validation).
- **AWS Service Connection** (`AWS`) in Azure DevOps with permissions to create/delete Route 53 TXT records.

### Build Agent

- A **self-hosted agent** (Linux/Ubuntu) registered in the `Default` pool.
- The `AWSShellScript@1` task extension installed in the Azure DevOps organisation.

## Configuration

### Pipeline Variables

Defined inline in the YAML:

| Variable | Description |
|----------|-------------|
| `domain` | The FQDN to issue the certificate for (e.g. `kv-003.tlsguru.io`). |
| `keyVaultName` | Name of the Azure Key Vault instance. |
| `certName` | Certificate object name within Key Vault. |
| `resourceGroup` | Resource group containing the Application Gateway. |
| `appGatewayName` | Name of the Application Gateway to update. |

### Secret Variables (Variable Group: `certbot-secrets`)

These must be defined in a linked Azure DevOps variable group and marked as secret:

| Variable | Description |
|----------|-------------|
| `EAB_KID` | DigiCert ONE ACME External Account Binding Key ID. |
| `EAB_HMAC_KEY` | DigiCert ONE ACME External Account Binding HMAC key. |
| `PFX_PASSWORD` | Password used to protect the intermediate PFX file. |

## Key Design Decisions

- **DNS-01 validation via Route 53** — avoids exposing HTTP endpoints on the build agent and supports wildcard certificates if needed.
- **DigiCert ONE ACME directory** — uses a trusted public CA rather than Let's Encrypt, with EAB for controlled issuance tied to an organisational mPKI profile.
- **`--force-renew` flag** — ensures a fresh certificate is issued on every pipeline run regardless of existing certificate state.
- **Key Vault as the intermediary** — the Application Gateway references a Key Vault secret ID rather than holding the certificate directly, allowing version rotation without Gateway redeployment.
- **Versioned secret reference** — the final step queries the latest Key Vault certificate version and pins the Application Gateway to that specific version, ensuring deterministic rollout.
- **RSA key type** — explicitly requests RSA keys for broad compatibility with Application Gateway and downstream clients.

## Cleanup

A cleanup step to remove temporary PFX and ACME files is included but currently commented out. Uncomment it for production use to avoid leaving sensitive material on the build agent:

```yaml
- script: |
    sudo rm -rf $(Agent.TempDirectory)/acme
    sudo rm -f $(Agent.TempDirectory)/*.pfx
  displayName: Cleanup sensitive files
  condition: always()
```

## Troubleshooting

| Symptom | Likely Cause |
|---------|--------------|
| `ACME error: unauthorized` | EAB credentials are incorrect or expired. Regenerate from DigiCert ONE. |
| `DNS challenge failed` | The AWS service connection lacks Route 53 permissions, or DNS propagation hasn't completed. |
| `Key Vault import failed` | The service principal is missing certificate import permissions on the vault access policy. |
| `Application Gateway update failed` | The gateway name/resource group is wrong, or the service connection lacks contributor access. |
| `PFX password error` | The `PFX_PASSWORD` variable is not set or has been rotated without updating the variable group. |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved.