terraform {
  required_providers {
    digicert = {
      source  = "digicert/digicert"
      version = "0.1.3"
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
  api_key = "REMOVED_SECRET"
  url     = "https://demo.one.digicert.com"
}

# Generate private key
resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Generate CSR
resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem

  subject {
    common_name  = "tlsguru.io"
    organization = "Your Organization"
    country      = "US"
  }

  dns_names = [
    "tlsguru.io",
    "www.tlsguru.io"
  ]
}

# Request certificate from DigiCert
resource "digicert_certificate" "server_cert" {
  profile_id  = "f1887d29-ee87-48f7-a873-1a0254dc99a9"
  common_name = "tlsguru.io"
  csr         = tls_cert_request.server_csr.cert_request_pem
}

# Save files locally
resource "local_file" "private_key" {
  content         = tls_private_key.server_key.private_key_pem
  filename        = "tlsguru.io.key"
  file_permission = "0600"
}

resource "local_file" "certificate" {
  content         = digicert_certificate.server_cert.certificate
  filename        = "tlsguru.io.crt"
  file_permission = "0644"
}

# Outputs
output "certificate_serial_number" {
  value = digicert_certificate.server_cert.serial_number
}

output "files_created" {
  value = {
    private_key = "tlsguru.io.key"
    certificate = "tlsguru.io.crt"
  }
}