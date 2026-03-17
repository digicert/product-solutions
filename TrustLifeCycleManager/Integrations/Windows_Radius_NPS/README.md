# DigiCert TLM – NPS/RADIUS Certificate Automation

Automated certificate lifecycle management for Windows NPS (Network Policy Server) RADIUS deployments using DigiCert Trust Lifecycle Manager (TLM).

This solution pairs an **AWR post-enrollment script** on the NPS server with a **RADIUS authentication test script** on a Linux client, enabling fully automated certificate replacement, distribution, and validation for PEAP/EAP-TLS wireless and wired 802.1X environments.

## Overview

When the DigiCert TLM Agent renews a certificate on a Windows NPS server, the AWR script automatically:

1. Converts and imports the new certificate into the Windows certificate store
2. Updates the NPS PEAP configuration to reference the new certificate
3. Restarts the NPS service to apply changes
4. Distributes the public certificate chain to a Linux test client via SCP

The test client can then verify the new certificate is being served correctly using the included `eapol_test` wrapper.

```
┌──────────────────────┐         ┌──────────────────────┐
│   DigiCert TLM       │         │                      │
│   ┌────────────────┐ │  SCP    │   Linux Test Client  │
│   │  TLM Agent     │ │───────▶ │   ┌────────────────┐ │
│   │  + AWR Script  │ │  .pem   │   │ radius-cert-   │ │
│   └───────┬────────┘ │         │   │ test.sh         │ │
│           │          │         │   └───────┬────────┘ │
│   ┌───────▼────────┐ │ RADIUS  │           │          │
│   │  Windows NPS   │◀├─────────┤   eapol_test        │
│   │  (PEAP)        │ │         │                      │
│   └────────────────┘ │         └──────────────────────┘
│   Windows Server     │
└──────────────────────┘
```

## Components

### `windows-radius_nps-awr.ps1` — AWR Post-Enrollment Script

PowerShell script triggered by the DigiCert TLM Agent after certificate enrollment or renewal. Runs on the Windows NPS server.

**What it does:**

- Reads certificate and key files delivered by the TLM Agent via `DC1_POST_SCRIPT_DATA`
- Creates a PFX from the PEM certificate and private key using OpenSSL
- Imports the PFX into `Cert:\LocalMachine\My`
- Exports the NPS configuration, locates the old certificate thumbprint in the `msEAPConfiguration` blob, replaces it with the new thumbprint, and re-imports the config
- Restarts the NPS service (`IAS`) to apply the change
- Copies the full certificate chain (PEM) to a remote Linux client via SCP for test validation
- Cleans up temporary files (PFX, DER) while retaining the PEM and NPS config backup

**AWR Arguments (configured in the TLM profile):**

| Argument | Purpose | Example |
|----------|---------|---------|
| 1 | SSH destination for the RADIUS test client | `sysadmin@10.160.115.190` |
| 2 | Remote path for the PEM file | `/home/sysadmin/nps-cert.pem` |

### `radius-cert-test.sh` — RADIUS Certificate Verification Test

Bash wrapper around `eapol_test` that performs a PEAP/MSCHAPv2 authentication against the NPS server and displays a concise summary of the results.

**Usage:**

```bash
./radius-cert-test.sh <radius_ip> <port> <shared_secret> [local_ip] [config_file]
```

**Examples:**

```bash
# Basic test
./radius-cert-test.sh 10.160.184.104 1645 Pwosd2003

# Specify source IP
./radius-cert-test.sh 10.160.184.104 1645 Pwosd2003 10.160.115.190

# Custom eapol_test config
./radius-cert-test.sh 10.160.184.104 1645 Pwosd2003 10.160.115.190 /etc/eapol_test.conf
```

**Output includes:**

- Server certificate details (subject, issuer, serial, validity dates, SAN, hash)
- Full certificate chain with depth indicators
- Certificate verification result (trusted / failed with reason)
- PEAP authentication status (TLS version, MSCHAPv2 result)
- RADIUS Access-Accept / Access-Reject outcome

## Prerequisites

### Windows NPS Server

- Windows Server with the NPS role installed and a PEAP network policy configured
- DigiCert TLM Agent installed and enrolled
- OpenSSL installed (default path: `C:\Program Files\OpenSSL\bin\openssl.exe`)
- OpenSSH client available (built-in on Server 2019+, or install via `Add-WindowsCapability`)
- SSH key-based authentication configured to the Linux test client

### Linux Test Client

- `eapol_test` installed (part of `wpa_supplicant` — build from source or install via package manager)
- An `eapol_test.conf` configuration file (see below)
- The CA certificate chain PEM (distributed automatically by the AWR script)

## Configuration

### eapol_test.conf (Linux Client)

Create a configuration file for PEAP/MSCHAPv2 authentication:

```ini
network={
    ssid="NPS-Test"
    key_mgmt=WPA-EAP
    eap=PEAP
    identity="DOMAIN\\testuser"
    password="TestPassword123"
    phase2="auth=MSCHAPV2"
    ca_cert="/home/sysadmin/nps-cert.pem"
}
```

The `ca_cert` path should match **Argument 2** configured in the TLM AWR profile, so the certificate chain distributed by the AWR script is automatically picked up on the next test run.

### TLM AWR Profile Setup

1. In DigiCert TLM, navigate to the certificate profile used by the NPS server
2. Under **Post-Enrollment Script**, select the `windows-radius_nps-awr.ps1` script
3. Set **Argument 1** to the SSH destination (e.g. `sysadmin@10.160.115.190`)
4. Set **Argument 2** to the remote PEM path (e.g. `/home/sysadmin/nps-cert.pem`)

### SSH Key Setup for SYSTEM Account

The TLM Agent runs as `SYSTEM`, so SSH keys must be accessible to that account. Copy the administrator's SSH key to the SYSTEM profile:

```powershell
mkdir "C:\Windows\System32\config\systemprofile\.ssh"
copy "C:\Users\Administrator\.ssh\id_ed25519" "C:\Windows\System32\config\systemprofile\.ssh\"
copy "C:\Users\Administrator\.ssh\known_hosts" "C:\Windows\System32\config\systemprofile\.ssh\"
```

## Workflow

```
Certificate Renewal Triggered (TLM)
        │
        ▼
TLM Agent delivers .crt + .key files
        │
        ▼
AWR script executes (windows-radius_nps-awr.ps1)
        │
        ├── 1. Validate prerequisites (OpenSSL, SCP, NPS service)
        ├── 2. Backup current NPS config (XML export)
        ├── 3. Create PFX from CRT + KEY via OpenSSL
        ├── 4. Import PFX → Cert:\LocalMachine\My
        ├── 5. Replace thumbprint in NPS config, re-import, restart NPS
        ├── 6. Export certificate chain as PEM
        ├── 7. SCP the PEM to the Linux test client
        └── 8. Clean up temporary files
                │
                ▼
        Verification (radius-cert-test.sh)
                │
                ├── Connects to NPS via eapol_test
                ├── Validates server certificate chain
                ├── Performs PEAP/MSCHAPv2 authentication
                └── Reports Access-Accept / Access-Reject
```

## Logging

The AWR script writes detailed logs to:

```
C:\Program Files\DigiCert\TLM Agent\log\dc1_data.log
```

Each run logs the full extraction summary, certificate details, every step of the replacement process, and a final summary including the new certificate subject, thumbprint, and validity dates.

## Troubleshooting

**NPS config thumbprint not found** — The script searches all certificates in `Cert:\LocalMachine\My` (excluding the newly imported one) and checks whether each thumbprint appears in the NPS XML config. If none match, a manual update is required via the NPS console: *Policies → Network Policies → [policy] → Constraints → PEAP Properties*.

**SCP fails when running as SYSTEM** — Ensure the SSH private key and `known_hosts` file are copied to `C:\Windows\System32\config\systemprofile\.ssh\` as described above.

**eapol_test times out** — Verify network connectivity to the NPS server on the configured RADIUS port. Check that the shared secret matches the NPS RADIUS client configuration. The test script uses a 30-second timeout.

**Certificate verification failed** — If the test reports a verification failure, check that the `ca_cert` in `eapol_test.conf` points to the full chain PEM (not just the leaf certificate). The AWR script distributes the full chain by default.

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in the script headers for full terms.