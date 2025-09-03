# DigiCert Terraform Provider

## Table of Contents
- [Requirements](#requirements)
- [Installation](#installation)
- [Provider Configuration](#provider-configuration)
- [Resources](#resources)
- [Certificate Outputs](#certificate-outputs)
- [Certificate Management](#certificate-management)
- [Revoking Certificates](#revoking-certificates)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Contact Us](#contact-us)
- [License](#license)

## Requirements

- HashiCorp Terraform 0.13.x or later.
- DigiCert ONE  API key for a user with permissions for certificate operations (such as request and revoke) and certificate profile management (such as create and edit).

## Provider configuration

Configure the provider with the DigiCert ONE API base URL and your API key:

```hcl
provider "digicert" {
  url     = "<digicert_host_url>" # DigiCert ONE API base URL
  api_key = "<digicert_api_key>"  # API key for authentication
}
```

### Provider arguments

| Name     | Description                                                                           | Type   | Required |
|----------|--------------------------------------------------------------------------------------|--------|----------|
| url      | The URL pointing to the DigiCert ONE platform (for example, "https://stage.one.digicert.com") | String | Yes      |
| api_key  | The API key corresponding to a user’s account for authenticating to the DigiCert ONE platform                           | String | Yes      |

## Resources

### Certificate resource

The `digicert_certificate` resource allows you to issue and manage certificates.

#### Example with CSR

```hcl
resource "digicert_certificate" "[resource_name]" {
  profile_id  = "8e201a92-4b16-412d-aa5c-bbeba3dacdef"
  common_name = "example.com"
  dns_names   = "www.example.com,api.example.com"
  csr         = "-----BEGIN CERTIFICATE REQUEST-----\nMIICjzCCAX/ZvGPbg=\n-----END CERTIFICATE REQUEST-----\n"
}
```

#### Example without CSR

```hcl
resource "digicert_certificate" "[resource_name]" {
  profile_id  = "8e201a92-4b16-412d-aa5c-bbeba3dacdef"
  common_name = "example.com"
  dns_names   = "www.example.com,api.example.com"
  tags        = "production,web-servers"
}
```

### Resource Arguments

| Name         | Description                                                   | Type           | Required |
|--------------|---------------------------------------------------------------|----------------|----------|
| digicert_certificate | Resource type and container for a certificate request in your Terraform plan.| String | Yes |  
| [resource_name] | Placeholder for the name that you assign to the resource.| String | Yes |      
| profile_id   | ID of an existing DigiCert​​®​​ Trust Lifecycle Manager profile to use for the certificate request | String         | Yes      |
| common_name  | Common name of certificate                                | String         | Yes      |
| dns_names    | Additional subject alternative names (SANs) of the certificate.                                | Comma separated list of strings| No       |
| csr          | Certificate signing request (CSR) in PEM format               | String         | No       |
| tags         | Tags to attach to the certificate                             | Comma separated list of strings| No       |

After enrollment, the digicert_certificate resource includes these attributes:

| Name          | Description                                      |
|---------------|--------------------------------------------------|
| id            | Unique identifier for the certificate            |
| serial_number | Serial number of the issued certificate          |
| status        | Current status of the certificate                |
| thumbprint    | SHA-1 thumbprint of the certificate              |
| valid_from    | Certificate validity start date                  |
| valid_to      | Certificate validity end date                    |
| certificate   | Issued certificate in PEM format                 |
| chain_pem     | Certificate chain in PEM format                  |
| request_id    | Unique identifier for the certificate request transaction.         |

## Certificate outputs

Certificate outputs allow you to retrieve and use certificate details in your infrastructure or for verification. When you define outputs, Terraform displays or makes available specific certificate information after creation.

### Output examples

```hcl
output "certificate_pem" {
  value     = digicert_certificate.[resource_name].certificate
  sensitive = true
}

output "certificate_serial" {
  value = digicert_certificate.[resource_name].serial_number
}
```
## Deploying certificates

### Generate a certificate

1. Verify your configuration:
    
    ```
    terraform plan
    ```
    The terraform plan command:

     - Validates the syntax and provider settings.

     - Shows the changes Terraform will make without applying them.

    If there are no errors, continue to the next step.

2. Apply the configuration and generate the certificates:
    To create the certificates, execute:
    ```
    terraform apply
    ```
    Terraform will prompt for confirmation. Type yes and press Enter to proceed.

    Upon successful execution, Terraform will:

    Send a request to the DigiCert​​®​​ Trust Lifecycle Manager API.

    Issue the requested certificates.

    Store the certificate details in the Terraform state.

3. Confirm any prompts to continue

4. Terraform applies your plan and:
    - Sends a request to the DigiCert® Trust Lifecycle Manager API.
    - Issues the requested certificates.
    - Stores the certificate details in the Terraform state

5. View the applied configuration:
    ```
    terraform show
    ```

## Revoking Certificates

Revoke certificates in Terraform individually or all deployed certificates at once. Choose the method that 
best meets your needs.
When revoking certificates deployed in your Terraform plan, Terraform also 
removes the resource from the deployment, from your Terraform state file, 
and from your DigiCert ONE Trust Lifecycle Manager certificate inventory.

**Tip**:   Before you run a destroy command, run terraform plan to verify 
changes.

### Revoke a single certificate as a one-time action

Revoke a specific certificate without altering your configuration file. Use 
this method if you expect to deploy the certificate through your Terraform 
plan at a later time.

```
terraform destroy -target=digicert_certificate.[resource_name]
```

### Revoke one or more certificates and remove them from your plan

Revoke one or more certificates by removing them from your 
configuration file. This automatically detects the removed resource and 
revokes the corresponding certificate. Use this method if you no longer 
expect to deploy the certificates at a later time

1. Remove the specific certificate resource from your Terraform configuration file.
2. Run Terraform plan and apply:
   ```
   terraform plan
   terraform apply
   ```

### Revoke and remove all deployed certificates

Revoke all managed certificates:

```
terraform destroy
```
**Caution**:   The destroy  command destroys all resources defined in your
main.tf  file.

## Security best practices

### Protecting Terraform state files

The Terraform state file contains critical infrastructure information, including sensitive data. 

Recommendations:
- **Secure storage**: Use remote backends with encryption and access controls. For example:
  - HashiCorp Terraform Cloud
  - AWS S3 with proper IAM policies
  - Google Cloud Storage with appropriate permissions
- **Access control**: 
  - Restrict state file access to only necessary individuals or systems
  - Implement least privilege access principles

For comprehensive guidelines, see [Sensitive Data in State](https://www.terraform.io/language/state/sensitive-data).

## Troubleshooting
- Error: API request failed (401 Unauthorized)

  - Ensure the DigiCert ONE API key is valid and has required permissions.

- Error: Validation failed due to unknown attributes

  - Check the DigiCert​​®​​ Trust Lifecycle Manager API documentation for the correct certificate attributes.

- Error: Certificate issuance failed (400 Bad Request)

  - Ensure all required fields are correctly defined in main.tf.

For more help, see the [DigiCert​​®​​ Trust Lifecycle Manager API documentation](https://one.digicert.com/mpki/docs/swagger-ui/index.html#/Inventory) or enable Terraform debugging:
  ```
  TF_LOG=DEBUG terraform apply
  ```

## Contributing

DigiCert Terraform Provider is open-source: you can freely download, use, modify, and distribute it according to the terms of our license. However, this is not an open contribution project.
To maintain code quality, security standards, and alignment with our internal development roadmap, we do not accept direct code contributions from external contributors. Our internal development team is solely responsible for all code changes and enhancements.

## Contact us

If you have any questions, suggestions, or issues regarding this provider, contact us at terraform-provider-support@digicert.com.

## License

Copyright © 2025 DigiCert, Inc. All rights reserved.

This project is licensed under the MIT. See the [LICENSE](./LICENSE) file for more information.
