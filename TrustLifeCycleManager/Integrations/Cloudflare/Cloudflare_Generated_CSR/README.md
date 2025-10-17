# Cloudflare Certificate Automation with DigiCert

Automated certificate provisioning and renewal script that integrates DigiCert certificate issuance with Cloudflare custom certificate deployment.

## 📋 Overview

This bash script automates the complete certificate lifecycle:
1. Creates a Certificate Signing Request (CSR) in Cloudflare
2. Submits the CSR to DigiCert for certificate issuance
3. Retrieves the issued certificate from DigiCert
4. Uploads the certificate to Cloudflare
5. Manages certificate and CSR cleanup based on retention policies

## ✨ Features

- **Fully Automated Workflow**: End-to-end certificate provisioning without manual intervention
- **Interactive & Renewal Modes**: Run manually with prompts or schedule for automatic renewal
- **Smart Certificate Management**: Three deletion strategies for existing certificates
- **CSR Retention Policy**: Configurable cleanup of old Certificate Signing Requests
- **Comprehensive Logging**: Detailed logs for auditing and troubleshooting
- **Secure Credential Handling**: Masks sensitive tokens in logs (unless debug mode enabled)
- **Cron-Ready**: Built for scheduled execution with detailed scheduling examples

## 🔧 Prerequisites

### Required Tools
- `bash` (v4.0+)
- `curl`
- `jq` (JSON processor)
- `openssl` (for certificate parsing)

### Required Credentials
1. **Cloudflare**:
   - Zone ID (32-character alphanumeric)
   - API Token with permissions:
     - Zone.SSL and Certificates: Edit
     - Zone.Zone: Read

2. **DigiCert**:
   - API Key with certificate issuance permissions
   - Profile ID for certificate template

## 📥 Installation

1. Clone or download the script:
```bash
wget https://your-repo/csr_in_cloudflare-api.sh
chmod +x csr_in_cloudflare-api.sh
```

2. Review and accept the legal notice by ensuring this line is set:
```bash
LEGAL_NOTICE_ACCEPT="true"
```

## ⚙️ Configuration

The script uses default values that can be overridden during runtime:

```bash
DEFAULT_ZONE_ID="your-cloudflare-zone-id"
DEFAULT_AUTH_TOKEN="your-cloudflare-api-token"
DEFAULT_DIGICERT_API_KEY="your-digicert-api-key"
DEFAULT_PROFILE_ID="your-digicert-profile-id"
DEFAULT_LOG_FILE="./digicert_cert_automation_$(date +%Y%m%d_%H%M%S).log"
DEFAULT_CSR_RETENTION="5"
DEFAULT_CERT_DELETE_MODE="matching"
```

### Certificate Deletion Modes

| Mode | Behavior | Use Case |
|------|----------|----------|
| `none` | Keep all existing certificates | Multiple certificates for different purposes |
| `matching` | Delete only certificates covering the same hostnames | **Recommended** - Clean certificate replacement |
| `all` | Delete ALL existing certificates | Clean slate deployment |

### CSR Retention Policy

Controls how many historical CSRs to retain:
- `0` - Delete all old CSRs (keep only current)
- `5` - Keep 5 most recent CSRs (default)
- `10+` - Keep more for audit trail

## 🚀 Usage

### Interactive Mode

Run the script with prompts for all configuration:

```bash
./csr_in_cloudflare-api.sh
```

You'll be prompted for:
- Cloudflare Zone ID
- Cloudflare Auth Token
- DigiCert API Key
- DigiCert Profile ID
- Log file location
- CSR retention count
- Certificate deletion mode

Press Enter to accept default values shown in brackets.

### Renewal Mode (Automated)

Run with `--renewal` flag to use all default values without prompts:

```bash
./csr_in_cloudflare-api.sh --renewal
```

Perfect for cron jobs and scheduled automation.

### Help

Display usage information:

```bash
./csr_in_cloudflare-api.sh --help
```

## 📊 Workflow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│ Step 0: Fetch Zone Details                                   │
│ → Retrieve domain name from Cloudflare Zone ID              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 1: Check Existing Certificates                          │
│ → List all custom certificates                              │
│ → Apply deletion strategy (none/all/matching)               │
│ → Delete selected certificates                              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 2: Create CSR at Cloudflare                            │
│ → Generate CSR with domain + www.domain SANs                │
│ → Store CSR ID for later reference                          │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 3: Extract CSR                                          │
│ → Remove PEM headers/footers                                │
│ → Format for DigiCert API submission                        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 4: Submit to DigiCert                                   │
│ → Send CSR with profile and seat information                │
│ → Receive signed certificate                                │
│ → Validate certificate issuance                             │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 5: Upload to Cloudflare                                │
│ → Format certificate for Cloudflare API                     │
│ → Upload with bundle_method: force                          │
│ → Link to original CSR ID                                   │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 6: Display Certificate Details                          │
│ → Show certificate ID, status, expiration                   │
│ → Verify SANs (Subject Alternative Names)                   │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Step 7: CSR Cleanup                                          │
│ → Count total CSRs for domain                               │
│ → Apply retention policy                                    │
│ → Delete oldest CSRs beyond retention limit                 │
└─────────────────────────────────────────────────────────────┘
```

## 🔄 Automation & Scheduling

### Cron Examples

**Daily at 2:00 AM** (Recommended for active renewals):
```bash
0 2 * * * /path/to/csr_in_cloudflare-api.sh --renewal >> /var/log/cert_renewal.log 2>&1
```

**Weekly on Sundays at 2:00 AM**:
```bash
0 2 * * 0 /path/to/csr_in_cloudflare-api.sh --renewal >> /var/log/cert_renewal.log 2>&1
```

**Monthly on the 1st at 2:00 AM**:
```bash
0 2 1 * * /path/to/csr_in_cloudflare-api.sh --renewal >> /var/log/cert_renewal.log 2>&1
```

### Monitor Logs

```bash
# View real-time logs
tail -f /var/log/cert_renewal.log

# Search for errors
grep -i error /var/log/cert_renewal.log

# View last execution
tail -n 100 /var/log/cert_renewal.log
```

## 📝 Output Files

When you choose to save certificate files:

| File | Description |
|------|-------------|
| `{domain}_cert_{timestamp}.pem` | The issued certificate in PEM format |
| `{domain}_info_{timestamp}.txt` | Certificate metadata and configuration details |
| `digicert_cert_automation_{timestamp}.log` | Detailed execution log |

## 🔍 Certificate Deletion Mode Details

### Mode: `none`
```
Before: [Cert A] [Cert B] [Cert C]
After:  [Cert A] [Cert B] [Cert C] [NEW CERT]
```
**Use when:** You need multiple certificates active simultaneously.

### Mode: `matching` (Recommended)
```
Before: [example.com + www] [other.com] [api.example.com]
After:  [other.com] [api.example.com] [NEW example.com + www]
```
**Use when:** Replacing a certificate for the same domain(s).

### Mode: `all`
```
Before: [Cert A] [Cert B] [Cert C]
After:  [NEW CERT]
```
**Use when:** Cleaning up all certificates before fresh deployment.

## 🔐 Security Considerations

1. **Credential Storage**: 
   - Store API keys and tokens securely
   - Consider using environment variables or secret management systems
   - Never commit credentials to version control

2. **Log Files**:
   - Logs mask sensitive tokens by default
   - Set `DEBUG_MODE="false"` in production
   - Restrict log file permissions: `chmod 600 logfile.log`

3. **Script Permissions**:
   ```bash
   chmod 700 csr_in_cloudflare-api.sh
   ```

4. **API Token Permissions**:
   - Use Cloudflare API tokens (not Global API Key)
   - Grant minimum required permissions
   - Rotate tokens regularly

## 🐛 Troubleshooting

### Common Issues

**"Could not fetch zone details"**
- Verify Zone ID is correct
- Check API token has Zone:Read permission
- Ensure token hasn't expired

**"No certificate received from DigiCert"**
- Validate DigiCert API key
- Check Profile ID is active
- Verify seat_id quota isn't exceeded

**"Error uploading certificate to Cloudflare"**
- Confirm custom certificate quota
- Check certificate format
- Verify CSR ID exists

**CSR Deletion Failures**
- Old CSRs may be in use by active certificates
- Check retention policy allows deletion
- Review CSR cleanup logs

### Debug Mode

Enable detailed logging (development only):
```bash
# In the script, change:
DEBUG_MODE="true"
```

This logs full API responses and token values. **Never use in production.**

## 📊 Example Execution Output

```
============================================================================
Starting certificate automation process...
Log file: ./digicert_cert_automation_20251017_143022.log
============================================================================

Step 0: Fetching zone details from Cloudflare...
✓ Zone found:
  Domain: example.com
  Status: active

Step 1: Checking for existing certificates for domain: example.com...
  Certificate deletion mode: matching
  Found 2 existing certificate(s)
  Mode 'matching': Will only delete certificates covering example.com or www.example.com
  Looking for certificates matching: example.com, www.example.com
    Found matching certificate ID abc123 covering: example.com, www.example.com
  Found 1 matching certificate(s) to delete
    Deleting certificate ID: abc123
      ✓ Successfully deleted certificate
  Certificate deletion summary: 1 deleted, 0 failed

Step 2: Creating CSR at Cloudflare for example.com...
✓ CSR created successfully at Cloudflare
  CSR ID: csr_xyz789
  SANs: ["example.com","www.example.com"]

Step 3: Extracting CSR...
✓ CSR extracted (1245 characters)

Step 4: Submitting CSR to DigiCert for certificate issuance...
  Requesting certificate for: example.com
  Including DNS names: example.com, www.example.com
✓ Certificate issued successfully!
  Serial Number: 0F3A7B8C...

Step 5: Uploading new certificate to Cloudflare...
  Creating new certificate...
✓ Certificate uploaded successfully to Cloudflare!

Cloudflare Certificate Details:
  Certificate ID: cert_new123
  Status: active
  Hosts: ["example.com","www.example.com"]
  Expires: 2026-01-17T14:30:22Z
  Custom CSR ID: csr_xyz789
  Deletion Mode Used: matching

Step 7: CSR Cleanup...
  Found 6 total CSRs for example.com
  Retention policy: Keep 5 old CSRs
  Cleaning up old CSRs...
  Will delete 1 old CSRs, keeping the 5 most recent
    Deleting CSR: csr_old123
  ✓ Deleted 1 old CSRs

✅ Process complete!
```

## 📚 Additional Resources

- [Cloudflare API Documentation](https://developers.cloudflare.com/api/)
- [DigiCert API Documentation](https://docs.digicert.com/)
- [Custom Certificates on Cloudflare](https://developers.cloudflare.com/ssl/edge-certificates/custom-certificates/)

## 📄 License

Copyright © 2024 DigiCert. All rights reserved.

See the legal notice in the script header for full terms and conditions.

## 🤝 Contributing

This script is maintained by DigiCert. For issues or feature requests, please contact your DigiCert representative.

---

**Note**: This script requires active Cloudflare and DigiCert accounts with appropriate permissions and quotas.
