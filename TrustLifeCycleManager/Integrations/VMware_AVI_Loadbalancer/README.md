# VMware AVI (NSX ALB) Certificate Upload Script

Automated SSL/TLS certificate deployment to VMware AVI Load Balancer (NSX Advanced Load Balancer) via REST API.

## Overview

This script automates the upload and management of SSL/TLS certificates to VMware AVI Controllers. It handles both new certificate uploads and updates to existing certificates, using the certificate's Common Name (CN) as the identifier within AVI.

## Features

- **Automated Certificate Upload** - Deploys SSL/TLS certificates and private keys to AVI Controllers
- **Intelligent Update Handling** - Automatically detects existing certificates and performs updates rather than failing on duplicates
- **CN-Based Naming** - Extracts the certificate Common Name for consistent naming in AVI
- **Session Management** - Handles authentication and CSRF token management for secure API communication
- **Comprehensive Logging** - Detailed logging of all operations for troubleshooting

## Prerequisites

- `curl` - HTTP client for API communication
- `jq` - JSON processing
- `openssl` - Certificate parsing

## AVI Configuration

| Parameter | Description |
|-----------|-------------|
| Controller | AVI Controller hostname or IP address |
| Username | AVI administrator username |
| Password | AVI administrator password |
| API Version | AVI API version (default: 22.1.3) |

## API Operations

### Authentication

The script authenticates to the AVI Controller and obtains a CSRF token required for subsequent API calls:

```
POST https://<controller>/login
```

### Certificate Upload

New certificates are uploaded via:

```
POST https://<controller>/api/sslkeyandcertificate
```

Payload structure:
```json
{
    "name": "<certificate-cn>",
    "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
    "certificate": {
        "certificate": "<pem-encoded-certificate>"
    },
    "key": "<pem-encoded-private-key>"
}
```

### Certificate Update

Existing certificates are updated via:

```
PUT https://<controller>/api/sslkeyandcertificate/<uuid>
```

The script first queries for the existing certificate UUID using:

```
GET https://<controller>/api/sslkeyandcertificate?name=<certificate-cn>
```

## Certificate Requirements

- Certificate file in PEM format (`.crt`)
- Private key file in PEM format (`.key`)
- Certificate must contain a valid Common Name (CN) in the subject

## Logging

All operations are logged with timestamps for audit and troubleshooting purposes. Log entries include:

- Authentication status
- Certificate details (subject, validity dates, chain length)
- Upload/update results
- Error conditions with response details

## AVI Console Location

Once uploaded, certificates can be found in the AVI Console at:

**Templates → Security → SSL/TLS Certificates**

## Error Handling

The script handles common error scenarios:

- Authentication failures
- Missing CSRF tokens
- Certificate file not found
- Duplicate certificate detection (triggers update flow)
- API response validation

## Related Documentation

- [VMware AVI REST API Guide](https://avinetworks.com/docs/latest/api-guide/)
- [AVI SSL/TLS Certificates](https://avinetworks.com/docs/latest/ssl-certificates/)

## License

Copyright © 2024 DigiCert. All rights reserved.

This software is provided by DigiCert under proprietary license terms. See the embedded legal notice in the script for complete licensing information.