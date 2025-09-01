terraform {
  required_providers {
    digicert = {
      source  = "digicert/digicert"
      version = "~> 0.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

# Configure DigiCert provider
provider "digicert" {
  api_key = var.digicert_api_key
  url     = var.digicert_url
}

# Generate private key
resource "tls_private_key" "server_key" {
  algorithm = var.private_key_algorithm
  rsa_bits  = var.private_key_rsa_bits
}

# Generate CSR
resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem

  subject {
    common_name  = var.common_name
    organization = var.organization
    country      = var.country
  }

  dns_names = var.dns_names
}

# Request certificate from DigiCert
resource "digicert_certificate" "server_cert" {
  profile_id  = var.digicert_profile_id
  common_name = var.common_name
  csr         = tls_cert_request.server_csr.cert_request_pem
}

# Save files locally
resource "local_file" "private_key" {
  content         = tls_private_key.server_key.private_key_pem
  filename        = var.private_key_filename
  file_permission = var.private_key_file_permission
}

resource "local_file" "certificate" {
  content         = digicert_certificate.server_cert.certificate
  filename        = var.certificate_filename
  file_permission = var.certificate_file_permission
}

# Outputs
output "certificate_serial_number" {
  value = digicert_certificate.server_cert.serial_number
}

output "files_created" {
  value = {
    private_key = var.private_key_filename
    certificate = var.certificate_filename
  }
}