# DigiCert TLM Agent — Oracle Cloud Infrastructure AWR Post-Delivery Scripts

## Overview

This guide documents the OCI compartment certificate-delivery and OCI Load Balancer certificate-delivery AWR scripts.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| `oci_compartment_cert_delivery.ps1` | Windows | PowerShell 5.1+ |
| `oci_lb_cert_delivery.ps1` | Windows | PowerShell 5.1+ |

### OCI Compartment delivery

PowerShell automation script that imports or updates TLS certificates in the Oracle Cloud Infrastructure (OCI) Certificates Management compartment provided in the arguments.

1. Certificate is imported with name same as common name ( for wildcard certificate, * replaced with star )
2. When a certificate with such name already exist in the commpartment, new delivered certificate is uploaded as Renewed certificate into same certificate object and marked it as Current

## Requirements

- **PowerShell 5.1 or later**
- Network access to `https://certificatesmanagement.<region>.oci.oraclecloud.com`.
- An OCI user with an API signing key pair and a policy that allows `manage certificates` in the target compartment.

## Permissions

The OCI user identified by ARGUMENT_2 (User OCID) must be able to list, create, and update certificates in the compartment identified by ARGUMENT_5 (Compartment OCID). The script calls the following Certificates Management endpoints:

| Operation | HTTP | Endpoint | Required permission |
|-----------|------|----------|---------------------|
| List existing certificates | `GET`  | `/20210224/certificates?compartmentId={id}` | `CERTIFICATE_READ` / `CERTIFICATE_INSPECT` |
| Import a new certificate   | `POST` | `/20210224/certificates`                    | `CERTIFICATE_CREATE` |
| Add a new version to an existing certificate | `PUT` | `/20210224/certificates/{id}` | `CERTIFICATE_UPDATE` |

The simplest policy that covers all three is `manage certificate-family`. Example IAM policy, scoped to a single compartment:

```
Allow group <group-name> to manage certificate-family in compartment <compartment-name>
```

For a least-privilege setup, replace `manage certificate-family` with the specific verbs above. The user also needs an API signing key pair uploaded to their OCI profile, and the public key's fingerprint must match ARGUMENT_3.

## Region

The target OCI region is set to `eu-frankfurt-1` per request (see `$Region` near the top of the script). Change this constant if a different region is needed.

## Modes

### Production Mode

#### Argument Reference

| # | Name | Required | Description |
|---|------|----------|-------------|
| ARGUMENT_1 | Tenancy OCID | Yes | `ocid1.tenancy.oc1..…` |
| ARGUMENT_2 | User OCID | Yes | `ocid1.user.oc1..…` of the API caller |
| ARGUMENT_3 | Key fingerprint | Yes | Fingerprint of the API signing key registered for the user |
| ARGUMENT_4 | Signing key | Yes | Unencrypted PEM-encoded RSA private key. Literal `\n` sequences are converted to newlines. |
| ARGUMENT_5 | Compartment OCID | Yes | Target compartment for the certificate |
| ARGUMENT_6 | Description | No | Free-form description attached to the certificate resource |
| ARGUMENT_7 | Input source | No | `AWRProduction` (default) executes calls; `AWRDryRun` logs the requests without invoking them |

#### Production Execution Steps

1. Step 1: Upload script to DigiCert ONE Portal.
    1. Go to Discovery & Automation tools > Scripts.
    2. Click "Add script for" > DigiCert Agents (top right corner).
    3. Enter script name and set:
        - Operating System: Windows
        - Script type: Admin request post-delivery
    4. Click "Add and verify script".

2. Step 2: Configure Admin Web Request (AWR).
    1. Go to Inventory > Admin web request.
    2. In STEP 1, fill in the parameters.
    3. In STEP 2:
        - Click "Add"
        - Select Agent
        - Click "Apply"

3. Step 3: Set certificate delivery.
    1. Under "DigiCert Agents", select the appropriate Agent.
    2. Under "Destination 1", configure:
        - Format: `.crt`
        - Target path: Certificate folder path
    3. Enable "Run post delivery Scripts".
    4. Select the uploaded script.
    5. Fill the arguments as listed in Argument Reference.

4. Step 4: Complete request.
    1. Proceed with the remaining configuration steps.

Note: The TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script. The arguments listed above are the values to provide in the AWR setup.

### LocalMachineValidateOnly

For local testing, fill in the `$Arguments` array and `$AdditionalInputs.CertFolder` near the top of the script, then add the string `"LocalMachineValidateOnly"` to `$Arguments`. The script builds `DC1_POST_SCRIPT_DATA` from those values before running.

### AWRDryRun

Pass `AWRDryRun` as argument 7. All OCI calls are logged but not executed; useful for verifying the signing string and request payload.

## Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and validate inputs.
2. Extract the Common Name from the leaf certificate.
3. Lists certificates in the target compartment.
4. Match by Common Name, accounting for wildcard variants (`*.example.com` matches resources named `example.com`, `star.example.com`, or `wildcard.example.com`).
5. If a match exists, `PUT /certificates/{id}` adds a new version. Otherwise, `POST /certificates` creates a new IMPORTED certificate. New wildcard imports are named `star.<domain>`.
6. Each version is tagged with a timestamp-based `versionName`.

## Logging

Both `$LOG_PATH` and `$API_CALLS_LOG_PATH` are commented out by default. Uncomment and set them at the top of the script to persist logs to disk. Without those paths, INFO/WARN/ERROR/SUCCESS messages still go to the console; DEBUG messages are dropped.

The default paths used by the TLM Agent install are:

- `C:\Program Files\DigiCert\TLM Agent\log\oci-compartment-cert-delivery.log`
- `C:\Program Files\DigiCert\TLM Agent\log\oci-compartment-cert-delivery-api-calls.log`

## Exit codes

- `0` — certificate imported or updated successfully.
- `1` — legal notice not accepted, or an unrecoverable error (logged with stack trace).

## Legal

See the header comment block in [oci_compartment_cert_delivery.ps1](Windows/oci_compartment_cert_delivery.ps1) for the full DigiCert legal notice. `$LEGAL_NOTICE_ACCEPT` must be `"true"` for the script to run.

## Compartment script version

Script version is tracked in the `$SCRIPT_VERSION` constant (currently `1.0.0`).

## OCI Load Balancer certificate delivery

### Overview

The Load Balancer script uploads a delivered TLS certificate to an OCI Load Balancer and can optionally bind the certificate to a specified listener.

1. The script reads the delivered leaf certificate, intermediate chain, and private key from the TLM Agent certificate folder.
2. The certificate is uploaded to the target OCI Load Balancer certificate store with the name `<CommonName>_<YYYYMMDD>`.
3. When a listener name is provided, the listener is updated so its `sslConfiguration.certificateName` points to the new certificate.

### Requirements

- Network access to `https://iaas.<region>.oraclecloud.com`.
- An OCI user with an API signing key pair and permission to manage the target Load Balancer.
- PowerShell 5.1 or later.
- A target listener that already exists on the specified Load Balancer when listener binding is required.
- Permission to write logs under `C:\Program Files\DigiCert\TLM Agent\log\`, or an updated `$LOG_PATH` and `$API_CALLS_LOG_PATH`.

### Permissions

The OCI user identified by ARGUMENT_2 must be able to read and update the Load Balancer identified by ARGUMENT_5. The script calls these endpoints:

| Operation | HTTP | Endpoint | Purpose |
|-----------|------|----------|---------|
| Upload certificate | `POST` | `/20170115/loadBalancers/{loadBalancerId}/certificates` | Creates a certificate entry on the Load Balancer. |
| Read Load Balancer configuration | `GET` | `/20170115/loadBalancers/{loadBalancerId}` | Reads listener details before an update. |
| Bind certificate to listener | `PUT` | `/20170115/loadBalancers/{loadBalancerId}/listeners/{listenerName}` | Updates `sslConfiguration.certificateName`. |

Example policy:

```text
Allow group <group-name> to manage load-balancers in compartment <compartment-name>
```

The API signing key must be uploaded to the OCI user profile, and its fingerprint must match ARGUMENT_3.

### Region

The target region is set to `eu-frankfurt-1` in the Load Balancer script. Change the `$Region` value when another OCI region is required.

### Argument reference

| Argument | Name | Required | Description |
|----------|------|----------|-------------|
| ARGUMENT_1 | Tenancy OCID | Yes | OCI tenancy OCID. |
| ARGUMENT_2 | User OCID | Yes | OCI user OCID of the API caller. |
| ARGUMENT_3 | Key fingerprint | Yes | Fingerprint of the registered API signing key. |
| ARGUMENT_4 | Signing key | Yes | Unencrypted PEM RSA private key. Literal `\n` sequences are converted to newlines. |
| ARGUMENT_5 | Load Balancer OCID | Yes | Target OCI Load Balancer. |
| ARGUMENT_6 | Listener name | No | Existing listener to receive the uploaded certificate. If omitted, the script stops after upload. |
| ARGUMENT_7 | Input source | No | `AWRProduction` executes calls; `AWRDryRun` logs requests without invoking them. |

### Execution steps

1. Upload `oci_lb_cert_delivery.ps1` in **Discovery & Automation tools > Scripts** as a Windows Admin request post-delivery script.
2. Create or select the Admin Web Request in **Inventory > Admin web request**.
3. Add the appropriate DigiCert Agent delivery target.
4. Configure certificate delivery in `.crt` format and select the certificate folder path.
5. Enable **Run post delivery Scripts**, select the uploaded script, and provide ARGUMENT_1 through ARGUMENT_7.
6. Submit the request.

The TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script.

### AWRDryRun

Pass `AWRDryRun` as ARGUMENT_7. Requests are prepared and logged but not executed, allowing payload, signing, and listener inputs to be checked safely.

### Behavior

1. Decode `DC1_POST_SCRIPT_DATA` and validate required inputs.
2. Resolve the delivered certificate and key files.
3. Parse the PEM material into the leaf certificate and intermediate chain.
4. Extract the Common Name and create a name such as `<CommonName>_<YYYYMMDD>`. Wildcard names are normalized to `star.<domain>_<YYYYMMDD>`.
5. Upload the certificate, private key, and optional CA chain to the OCI Load Balancer certificate store.
6. When a listener name is provided, read its current configuration and update only `sslConfiguration.certificateName`, preserving the other listener properties.

### Logging

The script writes INFO, WARN, ERROR, and SUCCESS messages to the console and attempts to append API-call logs under:

```text
C:\Program Files\DigiCert\TLM Agent\log\oci-lb-cert-delivery.log
C:\Program Files\DigiCert\TLM Agent\log\oci-lb-cert-delivery-api-calls.log
```

Sensitive values such as private keys and full argument values are not logged.

### Exit codes

- `0`: Certificate upload completed successfully, with listener binding updated when requested.
- `1`: Legal notice was not accepted or an unrecoverable error occurred.

### Legal

See the header comment block in [oci_lb_cert_delivery.ps1](Windows/oci_lb_cert_delivery.ps1) for the full DigiCert legal notice. The legal notice acceptance flag must be enabled before execution.

## Load Balancer script version

Script version is tracked in the `$SCRIPT_VERSION` constant (currently `1.0.0`).