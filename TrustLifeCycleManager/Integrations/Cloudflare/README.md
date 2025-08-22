# Cloudflare SSL Certificate Upload Script

[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%3E%3D4.0-blue.svg)](https://www.gnu.org/software/bash/)
[![Cloudflare API](https://img.shields.io/badge/Cloudflare%20API-v4-orange.svg)](https://developers.cloudflare.com/api/)

A robust Bash script for automating SSL certificate uploads to Cloudflare via their API v4, designed for integration with DigiCert TLM Agent Admin Web Request Post Script workflows.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Environment Variables](#environment-variables)
- [Logging](#logging)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Legal Notice](#legal-notice)
- [Support](#support)

## 🎯 Overview

This Admin Web Request Post Script automates the process of uploading SSL certificates to Cloudflare zones using the Cloudflare API. It's specifically designed to work as a post-processing script within the DigiCert Trust Lifecycle Manager (TLM) Agent environment, handling certificate renewal and deployment workflows seamlessly.

### Key Capabilities

- Automated SSL certificate and private key upload to Cloudflare
- Integration with DigiCert TLM Agent post-script workflows
- Comprehensive logging with configurable debug mode
- Support for different certificate bundle methods
- Built-in validation and error handling

## ✨ Features

- **Automated Certificate Management**: Seamlessly upload SSL certificates and private keys to Cloudflare zones
- **Flexible Bundle Methods**: Support for `ubiquitous`, `optimal`, and `force` certificate bundling strategies
- **Comprehensive Logging**: Detailed logging with timestamps and configurable debug mode
- **Security-First Design**: Sensitive data masking in logs, secure token handling
- **Error Handling**: Robust validation and error reporting for troubleshooting
- **DigiCert TLM Integration**: Native support for DigiCert TLM Agent post-script data format

## 📦 Prerequisites

### System Requirements

- **Operating System**: Linux (tested on Ubuntu)
- **Bash Version**: 4.0 or higher
- **Required Tools**:
  - `curl` - For API communications
  - `base64` - For decoding certificate data
  - `grep` with PCRE support
  - `awk` - For text processing

### API Requirements

- Active Cloudflare account with API access
- Cloudflare API Token with the following permissions:
  - `Zone:SSL and Certificates:Edit`
  - Access to the target zone
- Valid SSL certificate and private key files

## 🚀 Installation

1. **Download the Script**
   ```bash
   wget https://raw.githubusercontent.com/your-org/cloudflare-cert-uploader/main/cloudflare-awr.sh
   # or
   curl -O https://raw.githubusercontent.com/your-org/cloudflare-cert-uploader/main/cloudflare-awr.sh
   ```

2. **Set Executable Permissions**
   ```bash
   chmod +x cloudflare-awr.sh
   ```

3. **Configure Log Directory**
   ```bash
   mkdir -p /home/ubuntu/tlm_agent_3.0.15_linux64/log
   ```

4. **Verify Prerequisites**
   ```bash
   # Check Bash version
   bash --version
   
   # Verify required commands
   which curl base64 grep awk
   ```

## ⚙️ Configuration

### Script Configuration

Edit the script to configure the following parameters:

```bash
# Legal notice acceptance (required)
LEGAL_NOTICE_ACCEPT="true"

# Log file location
LOGFILE="/home/ubuntu/tlm_agent_3.0.15_linux64/log/cloudflare-awr.log"

# Default bundle method
BUNDLE_METHOD="force"  # Options: "ubiquitous", "optimal", "force"

# Debug mode (use only in development)
DEBUG_MODE="false"  # Set to "true" for verbose logging
```

### DigiCert TLM Agent Integration

When used with DigiCert TLM Agent, configure the post-script parameters:

```json
{
  "args": [
    "your_zone_id_here",
    "your_api_token_here",
    "bundle_method_optional"
  ],
  "certfolder": "/path/to/certificates",
  "files": [
    "certificate.crt",
    "private.key"
  ]
}
```

## 📘 Usage

### Standalone Execution

```bash
# Set the required environment variable
export DC1_POST_SCRIPT_DATA=$(echo '{"args":["zone_id","api_token","force"],"certfolder":"/path/to/certs","files":["cert.crt","key.key"]}' | base64)

# Run the script
./cloudflare-awr.sh
```

### Integration with DigiCert TLM Agent

The script is designed to be called automatically by the TLM Agent during certificate lifecycle events. Configure it as a post-installation script in your TLM Agent configuration.

### Bundle Methods

- **`ubiquitous`**: Compatible with all browsers, including older versions
- **`optimal`**: Balance between compatibility and security
- **`force`**: Modern browsers only, smallest bundle size

## 🔧 Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `DC1_POST_SCRIPT_DATA` | Yes | Base64-encoded JSON containing certificate data and Cloudflare credentials |

### DC1_POST_SCRIPT_DATA Structure

The environment variable should contain a Base64-encoded JSON with the following structure:

```json
{
  "args": [
    "cloudflare_zone_id",
    "cloudflare_api_token",
    "bundle_method"  // Optional
  ],
  "certfolder": "/absolute/path/to/certificate/folder",
  "files": [
    "certificate_filename.crt",
    "private_key_filename.key"
  ]
}
```

## 📝 Logging

### Log Location

Default log location: `/home/ubuntu/tlm_agent_3.0.15_linux64/log/cloudflare-awr.log`

### Log Format

```
[2024-01-15 10:30:45] Starting Cloudflare certificate upload script
[2024-01-15 10:30:45] Legal notice accepted, proceeding with script execution
[2024-01-15 10:30:45] Certificate file exists: /path/to/cert.crt
[2024-01-15 10:30:46] SUCCESS: Certificate uploaded successfully
```

### Debug Mode

Enable debug mode for troubleshooting (⚠️ **Development only**):

```bash
DEBUG_MODE="true"
```

Debug mode logs:
- Full decoded JSON strings
- Complete API tokens (security risk!)
- Detailed curl command structures
- Certificate/key content snippets

## 🔒 Security Considerations

### Best Practices

1. **API Token Security**
   - Use scoped API tokens with minimal required permissions
   - Rotate tokens regularly
   - Never commit tokens to version control

2. **File Permissions**
   - Restrict script permissions: `chmod 700 cloudflare-awr.sh`
   - Secure log directory: `chmod 700 /path/to/log/directory`
   - Protect certificate files: `chmod 600 /path/to/*.{crt,key}`

3. **Production Usage**
   - Always keep `DEBUG_MODE="false"` in production
   - Regularly review and rotate logs
   - Monitor for unauthorized access attempts

### Sensitive Data Handling

- API tokens are masked in standard logs (shows only first/last 4 characters)
- Certificate and key contents are never logged in standard mode
- Full sensitive data is only logged when `DEBUG_MODE="true"`

## 🔍 Troubleshooting

### Common Issues

#### Certificate Upload Fails

```bash
# Check HTTP status code in logs
grep "HTTP Status Code" /path/to/cloudflare-awr.log

# Common status codes:
# 400 - Bad request (check certificate format)
# 401 - Authentication failed (verify API token)
# 403 - Permission denied (check token scopes)
# 404 - Zone not found (verify zone ID)
```

#### Environment Variable Not Set

```bash
# Verify the environment variable is set
echo $DC1_POST_SCRIPT_DATA

# Test with a sample payload
export DC1_POST_SCRIPT_DATA=$(echo '{"args":["test","test"],"certfolder":"/tmp","files":["test.crt","test.key"]}' | base64)
```

#### Certificate File Not Found

```bash
# Verify file paths and permissions
ls -la /path/to/certificate/folder/
```

### Log Analysis

```bash
# View recent errors
grep "ERROR" /path/to/cloudflare-awr.log | tail -20

# Check API responses
grep "API Response" /path/to/cloudflare-awr.log

# Monitor in real-time
tail -f /path/to/cloudflare-awr.log
```

## ⚖️ Legal Notice

Copyright © 2024 DigiCert. All rights reserved.

This software is provided by DigiCert and distributed under licenses restricting its use, copying, distribution, and decompilation or reverse engineering. Use of the software is subject to the terms and conditions of your agreement with DigiCert.

THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.

For complete legal terms, please refer to the legal notice in the script header.

## 📞 Support

For issues related to:
- **Script functionality**: Open an issue in this repository
- **DigiCert TLM Agent**: Contact DigiCert Support
- **Cloudflare API**: Refer to [Cloudflare Documentation](https://developers.cloudflare.com/api/)

---

**Version**: 1.0.0  
**Last Updated**: January 2025  
**Maintained By**: Your Organization Name