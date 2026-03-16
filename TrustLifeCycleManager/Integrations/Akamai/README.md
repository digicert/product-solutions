# Akamai CPS Certificate Management Scripts

Automated certificate lifecycle management for Akamai CDN using the [Certificate Provisioning System (CPS) API](https://techdocs.akamai.com/cps/reference/api) and [DigiCert Trust Lifecycle Manager (TLM)](https://www.digicert.com/trust-lifecycle-manager).

These scripts handle end-to-end certificate provisioning — from creating CPS enrollments and issuing certificates through DigiCert, to uploading and deploying them across Akamai's staging and production networks. Two variants are provided to cover public and private certificate use cases.

## Scripts

| Script | Certificate Type | Use Case |
|--------|-----------------|----------|
| `issue-cert-akamai-public.sh` | Public (DV) | Publicly trusted certificates for internet-facing properties |
| `issue-cert-akamai-private.sh` | Private (OV/IV) | Privately trusted certificates requiring full organizational subject details |

## Key Difference

The only functional difference between the two scripts is the CSR subject attributes sent to DigiCert TLM during certificate issuance.

**Public script** — includes only the Common Name:

```json
"subject": {
  "common_name": "$CSR_CN"
}
```

**Private script** — includes the full organizational subject:

```json
"subject": {
  "common_name": "$CSR_CN",
  "country": "$CSR_C",
  "organization_name": "$CSR_O",
  "locality": "$CSR_L",
  "state": "$CSR_ST",
  "organization_units": [
    "$CSR_OU"
  ]
}
```

This reflects the validation requirements: public/DV certificates only need a Common Name, while private certificates require the complete organizational identity (Country, Organization, Locality, State, and OU) to be embedded in the certificate subject.

## Features

### Operational Modes

- **`--init`** — Create a new CPS enrollment, issue a certificate, and deploy it (default mode)
- **`--renew <CN>`** — Renew an existing certificate by Common Name
- **`--renew-config <file>`** — Renew using a saved configuration file
- **`--discover`** — List existing CPS enrollments for a contract
- **`--auto`** — Fully automated mode (no interactive prompts) for use with cron jobs and CI/CD pipelines

### Workflow Steps

1. **Prerequisite installation** — Automatically installs Python 3, pip, pipx, HTTPie, httpie-edgegrid, and jq if not already present
2. **EdgeGrid configuration** — Sets up `~/.edgerc` with Akamai API credentials for authenticated API access
3. **Storage configuration** — Configures a local directory for certificate files and enrollment configs
4. **Contract selection** — Configures the Akamai contract ID for the enrollment
5. **Enrollment creation** — Builds and submits a CPS enrollment via the Akamai API (supports SAN entries, network settings, admin/tech contacts, and organization details)
6. **CSR retrieval** — Polls the CPS API for the generated CSR from the pending enrollment change
7. **DigiCert TLM issuance** — Submits the CSR to DigiCert TLM via REST API using a configured certificate profile (RSA or ECDSA) and retrieves the signed certificate with full CA chain
8. **Intermediate CA processing** — Extracts and orders the certificate chain correctly for Akamai upload
9. **Certificate upload** — Uploads the signed certificate and trust chain to the CPS enrollment
10. **Post-deployment validation** — Polls for and acknowledges any deployment warnings
11. **Production deployment** — Deploys the certificate to Akamai's production network (with optional staging-only mode and monitoring)

### Additional Capabilities

- **Configuration persistence** — Saves enrollment details, DigiCert settings, and automation preferences to a JSON config file for seamless renewals
- **Renewal workflow** — Detects pending renewal changes in CPS and re-issues certificates using saved configuration
- **Certificate type selection** — Supports both RSA and ECDSA certificate profiles
- **SAN management** — Add multiple Subject Alternative Names during enrollment creation
- **Staging deployment monitoring** — Polls staging deployment status before promoting to production
- **Colour-coded output** — Clear visual feedback throughout the workflow

## Prerequisites

The scripts will attempt to install missing dependencies automatically (requires `sudo` for `apt`):

- **Python 3** and **pip3**
- **pipx**
- **[HTTPie](https://httpie.io/)** with the **httpie-edgegrid** plugin (for Akamai EdgeGrid-signed API requests)
- **jq** (JSON parsing)

## Configuration

### Akamai Credentials

You will need an Akamai API client with CPS read/write permissions. Configure the following in the default values section at the top of the script or provide them interactively at runtime:

| Variable | Description |
|----------|-------------|
| `DEFAULT_HOST` | Akamai EdgeGrid API hostname |
| `DEFAULT_CLIENT_SECRET` | API client secret |
| `DEFAULT_ACCESS_TOKEN` | API access token |
| `DEFAULT_CLIENT_TOKEN` | API client token |
| `DEFAULT_CONTRACT_ID` | Akamai contract ID |

### DigiCert TLM Credentials

| Variable | Description |
|----------|-------------|
| `DEFAULT_DIGICERT_API_KEY` | DigiCert ONE / TLM API key |
| `DEFAULT_RSA_PROFILE_ID` | Certificate profile ID for RSA certificates |
| `DEFAULT_ECDSA_PROFILE_ID` | Certificate profile ID for ECDSA certificates |
| `DEFAULT_SEAT_ID` | Seat ID (defaults to Common Name if empty) |

### CSR Subject Defaults

| Variable | Description | Used In |
|----------|-------------|---------|
| `DEFAULT_CSR_CN` | Common Name | Both |
| `DEFAULT_CSR_C` | Country | Private only |
| `DEFAULT_CSR_ST` | State / Province | Private only |
| `DEFAULT_CSR_L` | Locality / City | Private only |
| `DEFAULT_CSR_O` | Organization Name | Private only |
| `DEFAULT_CSR_OU` | Organizational Unit | Private only |

## Usage

### Legal Notice

Before first use, review the legal notice at the top of the script and set:

```bash
LEGAL_NOTICE_ACCEPT="true"
```

### New Enrollment

```bash
# Interactive mode — prompts for all values
./issue-cert-akamai-public.sh --init

# Or simply (--init is the default)
./issue-cert-akamai-public.sh
```

### Certificate Renewal

```bash
# Renew by Common Name (interactive)
./issue-cert-akamai-public.sh --renew example.com

# Renew by Common Name (fully automated)
./issue-cert-akamai-public.sh --renew example.com --auto

# Renew using a saved config file (fully automated)
./issue-cert-akamai-public.sh --renew-config ~/akamai-certs/example.com-config.json --auto
```

> **Note:** Renewals require a pending renewal change in Akamai CPS. Initiate the renewal from the Akamai Control Center before running the script.

### Discover Existing Enrollments

```bash
./issue-cert-akamai-public.sh --discover
```

## Saved Configuration

After a successful enrollment, the script saves a JSON configuration file containing all enrollment details, DigiCert settings, and automation preferences. This file is used by the renewal workflow to re-issue certificates without re-entering configuration. The config file is stored in the configured certificate directory (default: `~/akamai-certs/`).

## License

Copyright © 2024 DigiCert, Inc. All rights reserved. See the legal notice in each script for full terms.