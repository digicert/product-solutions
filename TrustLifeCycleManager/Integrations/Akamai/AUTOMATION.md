# Akamai Certificate Renewal - Automated Mode

## Overview

The Akamai certificate renewal script now supports **fully automated, non-interactive execution** via the `--auto` flag. This makes it perfect for cron jobs and automated certificate renewal workflows.

## Problem Solved

Previously, the renewal workflow had multiple interactive prompts that prevented automated execution:
- RSA/ECDSA certificate type choice
- Submit to DigiCert confirmation (y/n)
- ICA certificate file location prompt
- Upload certificate to Akamai confirmation (y/n)
- Acknowledge post-verification warnings (y/n)
- Deploy to production confirmation (y/n)

These prompts made it impossible to run the script as a cron job.

## Solution: Automation Configuration

All interactive decisions are now stored in the configuration file and can be used when running with the `--auto` flag.

### Configuration Structure

The configuration file includes an `automation` section:

```json
{
  "automation": {
    "certificate_type": "RSA",
    "auto_submit_digicert": true,
    "auto_upload_cert": true,
    "auto_acknowledge_warnings": true,
    "auto_deploy_production": true
  },
  "storage": {
    "cert_dir": "/home/user/akamai-certs",
    "ica_file": "/home/user/akamai-certs/intermediate-ca.pem"
  }
}
```

### Automation Settings

| Setting | Values | Description |
|---------|--------|-------------|
| `certificate_type` | `"RSA"` or `"ECDSA"` | Which certificate type to issue |
| `auto_submit_digicert` | `true` or `false` | Automatically submit certificate request to DigiCert |
| `auto_upload_cert` | `true` or `false` | Automatically upload certificate to Akamai |
| `auto_acknowledge_warnings` | `true` or `false` | Automatically acknowledge post-verification warnings |
| `auto_deploy_production` | `true` or `false` | Automatically deploy certificate to production |

### ICA File Configuration

The ICA (Intermediate Certificate Authority) file location is stored in the `storage` section:

```json
{
  "storage": {
    "cert_dir": "/home/user/akamai-certs",
    "ica_file": "/home/user/akamai-certs/intermediate-ca.pem"
  }
}
```

## Usage

### Interactive Mode (Default)

Run without the `--auto` flag for interactive prompts:

```bash
./issue-cert-akamai-renewal.sh --renew example.com
```

### Automated Mode

Run with the `--auto` flag for fully automated execution:

```bash
./issue-cert-akamai-renewal.sh --renew example.com --auto
```

Or using a specific configuration file:

```bash
./issue-cert-akamai-renewal.sh --renew-config /path/to/config.json --auto
```

## Cron Job Setup

### Example: Monthly Renewal Check

Add this to your crontab to check for certificate renewal on the 1st of each month at 2 AM:

```bash
0 2 1 * * /path/to/issue-cert-akamai-renewal.sh --renew example.com --auto >> /var/log/akamai-cert-renewal.log 2>&1
```

### Example: Renewal 30 Days Before Expiration

For more sophisticated scheduling, you can create a wrapper script that checks the certificate expiration date:

```bash
#!/bin/bash
# renewal-check.sh

CERT_CN="example.com"
CONFIG_DIR="$HOME/.akamai-cps/configs"
SCRIPT="/path/to/issue-cert-akamai-renewal.sh"

# Check certificate expiration (implement your logic here)
# If cert expires in < 30 days, run renewal:

$SCRIPT --renew "$CERT_CN" --auto
```

Then schedule the wrapper:

```bash
0 2 * * * /path/to/renewal-check.sh >> /var/log/akamai-renewal-check.log 2>&1
```

## Configuration File Location

Configurations are saved in: `~/.akamai-cps/configs/`

After initial setup, you can find your configuration at:
- By common name: `~/.akamai-cps/configs/example.com.json`
- By enrollment ID: `~/.akamai-cps/configs/example.com_enrollment_12345_*.json`

## Example Configuration

See [config.json.example](./config.json.example) for a complete sample configuration file.

## Workflow Steps (Automated Mode)

When running with `--auto`, the script will:

1. Load configuration from saved file
2. Check for pending renewal in Akamai
3. Retrieve CSR from Akamai (auto-generated during renewal)
4. **Automatically** select certificate type (RSA/ECDSA) from config
5. **Automatically** submit to DigiCert if enabled
6. **Automatically** use ICA file from config
7. **Automatically** upload certificate to Akamai if enabled
8. **Automatically** acknowledge warnings if enabled
9. **Automatically** deploy to production if enabled
10. Update configuration with renewal timestamp

## Prerequisites for Automated Renewal

Before setting up automated renewal, ensure:

1. **Initial enrollment exists** - Run `--init` mode first to create the enrollment
2. **Configuration is saved** - The config file is in `~/.akamai-cps/configs/`
3. **ICA file exists** - The intermediate CA certificate is at the configured location
4. **Renewal initiated** - Start the renewal in Akamai Control Center (this still needs to be done manually or via API)
5. **Credentials valid** - EdgeGrid and DigiCert API credentials are current

## Monitoring and Logging

### Log Output

Redirect output to a log file for monitoring:

```bash
./issue-cert-akamai-renewal.sh --renew example.com --auto >> /var/log/akamai-renewal.log 2>&1
```

### Email Notifications

Combine with mail command for notifications:

```bash
./issue-cert-akamai-renewal.sh --renew example.com --auto 2>&1 | mail -s "Akamai Cert Renewal: example.com" admin@example.com
```

## Troubleshooting

### Script Still Prompts for Input

Check:
- Are you using the `--auto` flag?
- Does the configuration file exist and contain the `automation` section?
- Is the ICA file location specified in the config?

### Configuration Not Found

List available configurations:

```bash
./issue-cert-akamai-renewal.sh --list
```

### Test Configuration

Run once in interactive mode to verify configuration:

```bash
./issue-cert-akamai-renewal.sh --renew example.com
```

Then test automated mode:

```bash
./issue-cert-akamai-renewal.sh --renew example.com --auto
```

## Security Considerations

1. **Protect Configuration Files** - They contain API credentials
   - Configs are saved with `chmod 600` (owner read/write only)

2. **Secure Log Files** - May contain sensitive information
   - Use appropriate permissions on log directories

3. **API Key Rotation** - Update configuration when rotating keys
   ```bash
   # Edit config file
   vi ~/.akamai-cps/configs/example.com.json
   ```

4. **Audit Trail** - Log all automated renewals for compliance

## Advanced: Updating Existing Configurations

To add automation settings to an existing configuration file:

```bash
# Edit your config file
vi ~/.akamai-cps/configs/example.com.json

# Add the automation section:
{
  ...existing config...
  "automation": {
    "certificate_type": "RSA",
    "auto_submit_digicert": true,
    "auto_upload_cert": true,
    "auto_acknowledge_warnings": true,
    "auto_deploy_production": true
  }
}
```

## Support

For issues or questions:
- Check script help: `./issue-cert-akamai-renewal.sh --help`
- Review script logs
- Verify Akamai Control Center status
