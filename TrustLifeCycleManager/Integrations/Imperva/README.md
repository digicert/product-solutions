# Imperva Certificate Deployment Script for DigiCert TLM Agent

[![Bash](https://img.shields.io/badge/bash-%3E%3D4.0-green.svg)](https://www.gnu.org/software/bash/)
[![Imperva](https://img.shields.io/badge/Imperva-Cloud%20WAF-blue.svg)](https://www.imperva.com/)
[![DigiCert](https://img.shields.io/badge/DigiCert-TLM%20Agent-orange.svg)](https://www.digicert.com/)
[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)

Automated certificate deployment script for Imperva Cloud WAF, designed to work as a post-processing handler for DigiCert Trust Lifecycle Manager (TLM) Agent. This script handles certificate chain extraction, Base64 encoding, and API deployment to Imperva sites.

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