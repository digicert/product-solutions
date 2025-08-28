# Imperva Certificate Deployment Script for DigiCert TLM Agent

[![Bash](https://img.shields.io/badge/bash-%3E%3D4.0-green.svg)](https://www.gnu.org/software/bash/)
[![Imperva](https://img.shields.io/badge/Imperva-Cloud%20WAF-blue.svg)](https://www.imperva.com/)
[![DigiCert](https://img.shields.io/badge/DigiCert-TLM%20Agent-orange.svg)](https://www.digicert.com/)
[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)

Automated certificate deployment script for Imperva Cloud WAF, designed to work as a post-processing handler for DigiCert Trust Lifecycle Manager (TLM) Agent. This script handles certificate chain extraction, Base64 encoding, and API deployment to Imperva sites.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [API Integration](#api-integration)
- [Certificate Chain Handling](#certificate-chain-handling)
- [Logging](#logging)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Architecture](#architecture)
- [Legal Notice](#legal-notice)

## 🎯 Overview

This script automates the deployment of SSL/TLS certificates from DigiCert TLM Agent to Imperva Cloud WAF sites. It processes certificate chains and private keys, encodes them in Base64 format, and deploys them via Imperva's REST API.

### Workflow

```
DigiCert TLM Agent
     ↓
Certificate Files Generated
     ↓
DC1_POST_SCRIPT_DATA Environment Variable
     ↓
Bash Script Execution
     ↓
Base64 Encoding & Processing
     ↓
Imperva API Call
     ↓
Certificate Deployed to WAF
```

## ✨ Features

### Core Capabilities

- **Automatic Certificate Chain Processing**: Handles full certificate chains including intermediates
- **Base64 Encoding**: Encodes entire certificate chain and private key for API transmission
- **Key Type Detection**: Automatically identifies RSA, ECC, and PKCS#8 key formats
- **Multi-Certificate Support**: Processes certificate bundles with multiple certificates
- **Comprehensive Logging**: Dual logging system for operations and API calls
- **Error Handling**: Detailed error detection and debugging information

### Advanced Features

- **Cross-Platform Compatibility**: Works on Linux and macOS with automatic detection
- **Certificate Validation**: Verifies Base64 encoding and certificate format
- **API Response Analysis**: Interprets Imperva API responses for troubleshooting
- **Security-First Design**: Masks sensitive data in logs while maintaining debuggability

## 📦 Prerequisites

### System Requirements

- **Operating System**: Linux (Ubuntu, RHEL, CentOS) or macOS
- **Shell**: Bash 4.0+
- **Required Tools**:
  ```bash
  base64    # Base64 encoding/decoding
  curl      # API communication
  grep      # Text processing
  awk       # Data extraction
  openssl   # Certificate analysis (optional but recommended)
  ```

### DigiCert TLM Agent

- TLM Agent installed and configured
- Certificate deployment configured with this script as post-processor
- Environment variable `DC1_POST_SCRIPT_DATA` properly set

### Imperva Account

- Active Imperva Cloud WAF account
- Site configured for custom certificate
- API credentials:
  - Site ID
  - API ID
  - API Key

## 🚀 Installation

### 1. Download the Script

```bash
# Download to TLM Agent scripts directory
wget -O /opt/digicert/tlm-agent/scripts/imperva_deploy.sh \
    https://raw.githubusercontent.com/your-org/imperva-deploy/main/imperva_deploy.sh

# Or using curl
curl -o /opt/digicert/tlm-agent/scripts/imperva_deploy.sh \
    https://raw.githubusercontent.com/your-org/imperva-deploy/main/imperva_deploy.sh
```

### 2. Set Permissions

```bash
chmod 750 /opt/digicert/tlm-agent/scripts/imperva_deploy.sh
chown tlm-agent:tlm-agent /opt/digicert/tlm-agent/scripts/imperva_deploy.sh
```

### 3. Accept Legal Notice

Edit the script and modify:
```bash
# Change from:
LEGAL_NOTICE_ACCEPT="false"

# To:
LEGAL_NOTICE_ACCEPT="true"
```

### 4. Configure Logging

```bash
# Create log directory
mkdir -p /home/ubuntu/tlm_agent_3.0.15_linux64/log

# Set appropriate permissions
chmod 755 /home/ubuntu/tlm_agent_3.0.15_linux64/log
```

## ⚙️ Configuration

### Script Configuration

Edit the script to set your paths:

```bash
# Log file locations
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/imperva.log"
API_CALL_LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/imperva-curl-command.log"

# Legal notice acceptance (required)
LEGAL_NOTICE_ACCEPT="true"
```

### TLM Agent Configuration

Configure TLM Agent to pass required arguments:

```json
{
  "post_script": {
    "path": "/opt/digicert/tlm-agent/scripts/imperva_deploy.sh",
    "args": [
      "site_id_here",        // Argument 1: Imperva Site ID
      "api_id_here",         // Argument 2: Imperva API ID
      "api_key_here",        // Argument 3: Imperva API Key
      "",                    // Argument 4: Reserved for future use
      ""                     // Argument 5: Reserved for future use
    ]
  }
}
```

### Imperva Configuration

Ensure your Imperva site is configured to accept custom certificates:

1. Log into Imperva Cloud WAF console
2. Navigate to your site settings
3. Enable custom certificate option
4. Note the Site ID for configuration

## 📘 Usage

### Automatic Execution

The script runs automatically when TLM Agent deploys certificates:

1. TLM Agent generates certificate files
2. Agent sets `DC1_POST_SCRIPT_DATA` environment variable
3. Script executes and processes certificates
4. Certificate chain is deployed to Imperva

### Manual Testing

```bash
# Set test environment variable
export DC1_POST_SCRIPT_DATA=$(echo '{
  "certfolder": "/path/to/certs",
  "files": ["cert.crt", "key.key"],
  "args": ["site_id", "api_id", "api_key", "", ""]
}' | base64)

# Run script
./imperva_deploy.sh
```

### Verification

Check deployment status:

```bash
# View operation log
tail -f /home/ubuntu/tlm_agent_3.0.15_linux64/log/imperva.log

# View API call details
cat /home/ubuntu/tlm_agent_3.0.15_linux64/log/imperva-curl-command.log
```

## 🔗 API Integration

### Imperva API Endpoint

The script uses Imperva's custom certificate API:

```
PUT https://my.imperva.com/api/prov/v2/sites/{site_id}/customCertificate
```

### Request Format

```json
{
  "certificate": "BASE64_ENCODED_CERTIFICATE_CHAIN",
  "private_key": "BASE64_ENCODED_PRIVATE_KEY",
  "auth_type": "RSA" | "ECC"
}
```

### Response Codes

| Code | Status | Description |
|------|--------|-------------|
| 200 | Success | Certificate updated successfully |
| 201 | Success | Certificate created successfully |
| 400 | Error | Invalid certificate or key format |
| 401 | Error | Authentication failed |
| 404 | Error | Site not found |
| 409 | Error | Certificate/key mismatch |

## 🔐 Certificate Chain Handling

### Supported Formats

The script handles various certificate and key formats:

#### Certificate Formats
- Single certificates
- Full certificate chains (server + intermediates + root)
- PEM format with headers/footers

#### Private Key Formats
- RSA private keys
- ECC (Elliptic Curve) private keys
- PKCS#8 format (encrypted or unencrypted)
- Traditional format (BEGIN RSA/EC PRIVATE KEY)

### Certificate Chain Order

Ensure proper certificate chain order:

```
-----BEGIN CERTIFICATE-----
[Server Certificate]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Intermediate Certificate 1]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Intermediate Certificate 2]
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
[Root Certificate (optional)]
-----END CERTIFICATE-----
```

### Base64 Encoding

The script performs Base64 encoding of the entire certificate chain:

```bash
# Linux (with -w 0 for no line wrapping)
cat certificate.crt | base64 -w 0

# macOS (no -w flag needed)
cat certificate.crt | base64
```

## 📝 Logging

### Log Files

| File | Purpose | Content |
|------|---------|---------|
| `imperva.log` | Main operation log | Script execution, validation, results |
| `imperva-curl-command.log` | API call log | Complete curl commands for debugging |

### Log Format

```
[2025-01-15 10:30:00] ==========================================
[2025-01-15 10:30:00] Starting certificate variable extraction script
[2025-01-15 10:30:00] ==========================================
[2025-01-15 10:30:00] Legal notice accepted, proceeding with script execution.
[2025-01-15 10:30:01] Certificate file exists: /path/to/cert.crt
[2025-01-15 10:30:01] Total certificates in file: 3
[2025-01-15 10:30:02] Base64 encoding certificate chain and private key...
[2025-01-15 10:30:02] Certificate chain Base64 encoded successfully
[2025-01-15 10:30:03] Making API call to Imperva with Base64 encoded certificate chain...
[2025-01-15 10:30:04] SUCCESS: Certificate chain uploaded successfully to Imperva
```

### Log Rotation

Implement log rotation to manage file sizes:

```bash
# /etc/logrotate.d/imperva-deploy
/home/ubuntu/tlm_agent_3.0.15_linux64/log/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 644 tlm-agent tlm-agent
}
```

## 🔍 Troubleshooting

### Common Issues

#### Issue: Base64 Encoding Fails

```bash
# Test Base64 encoding
echo "test" | base64 -w 0  # Linux
echo "test" | base64        # macOS

# If -w flag not supported, script auto-detects and adjusts
```

#### Issue: Certificate Chain Validation

```bash
# Verify certificate chain manually
openssl verify -CAfile ca.crt -untrusted intermediate.crt server.crt

# Check certificate details
openssl x509 -in certificate.crt -text -noout
```

#### Issue: Key Type Detection

```bash
# Check key type
openssl rsa -in private.key -check     # For RSA
openssl ec -in private.key -check      # For ECC

# Convert to PKCS#8 if needed
openssl pkcs8 -topk8 -nocrypt -in private.key -out private_pkcs8.key
```

#### Issue: API Authentication

```bash
# Test API credentials
curl -X GET "https://my.imperva.com/api/prov/v2/sites" \
     -H "x-API-Id: YOUR_API_ID" \
     -H "x-API-Key: YOUR_API_KEY"
```

### Debug Mode

Enable verbose logging by modifying the script:

```bash
# Add at the beginning
set -x  # Enable debug output

# Or selectively debug
DEBUG=true
[[ "$DEBUG" == "true" ]] && echo "Debug: Variable=$VARIABLE"
```

### Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `certificate and key do not match` | Mismatched certificate/key pair | Verify certificate and key are from same generation |
| `Invalid certificate format` | Malformed PEM | Check certificate file integrity |
| `Authentication failed` | Invalid API credentials | Verify API ID and Key |
| `Site not found` | Wrong Site ID | Check Site ID in Imperva console |

## 🔒 Security

### Best Practices

1. **File Permissions**
   ```bash
   # Restrict script access
   chmod 750 imperva_deploy.sh
   chown tlm-agent:tlm-agent imperva_deploy.sh
   
   # Protect log files
   chmod 640 /path/to/logs/*.log
   ```

2. **Credential Management**
   - Store API credentials in TLM Agent configuration
   - Never hardcode credentials in scripts
   - Use environment variables or secure vaults
   - Rotate API keys regularly

3. **Log Security**
   - API keys are masked in logs (first 5 characters only)
   - Full API commands logged separately for debugging
   - Implement log retention policies
   - Monitor logs for unauthorized access

4. **Certificate Validation**
   - Verify certificate chain before deployment
   - Ensure certificate matches private key
   - Check certificate expiration dates
   - Validate certificate authority chain

## 🏗️ Architecture

### Component Interaction

```
┌──────────────────────┐
│   DigiCert TLM      │
│      Agent          │
└──────────┬───────────┘
           │
           │ Certificate Files
           ▼
┌──────────────────────┐
│   File System       │
│ • certificate.crt   │
│ • private.key       │
└──────────┬───────────┘
           │
           │ DC1_POST_SCRIPT_DATA
           ▼
┌──────────────────────┐
│  Bash Script        │
│ • Decode JSON       │
│ • Extract files     │
│ • Base64 encode     │
│ • Detect key type   │
└──────────┬───────────┘
           │
           │ HTTPS PUT
           ▼
┌──────────────────────┐
│   Imperva Cloud     │
│       WAF           │
│ • Site protection   │
│ • SSL termination   │
└──────────────────────┘
```

### Data Flow

1. **Input**: Base64-encoded JSON from TLM Agent
2. **Processing**: Decode → Extract → Validate → Encode
3. **Output**: API call to Imperva with encoded certificate chain

## ⚖️ Legal Notice

Copyright © 2024 DigiCert. All rights reserved.

This software is provided by DigiCert under license. Use is subject to the terms and conditions of your agreement with DigiCert. The software is provided "AS IS" without warranties of any kind.

For complete legal terms, see the legal notice in the script header.

## 📞 Support

### Resources
- [Imperva API Documentation](https://docs.imperva.com/bundle/cloud-application-security/page/settings/api.htm)
- [DigiCert TLM Documentation](https://docs.digicert.com/)
- [Script Repository](https://github.com/your-org/imperva-deploy)

### Contact
- Imperva Support: [support.imperva.com](https://support.imperva.com)
- DigiCert Support: [support.digicert.com](https://support.digicert.com)
- Script Issues: [GitHub Issues](https://github.com/your-org/imperva-deploy/issues)

---

**Version**: 1.0.0  
**Last Updated**: January 2025  
**Integration**: DigiCert TLM Agent → Imperva Cloud WAF
