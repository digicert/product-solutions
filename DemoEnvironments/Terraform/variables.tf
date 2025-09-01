variable "digicert_api_key" {
  description = "DigiCert API key for authentication"
  type        = string
  sensitive   = true
}

variable "digicert_url" {
  description = "DigiCert API URL"
  type        = string
}

variable "digicert_profile_id" {
  description = "DigiCert profile ID for certificate requests"
  type        = string
}

variable "common_name" {
  description = "Common name for the certificate"
  type        = string
}

variable "organization" {
  description = "Organization name for the certificate"
  type        = string
}

variable "country" {
  description = "Country code for the certificate"
  type        = string
}

variable "dns_names" {
  description = "List of DNS names for the certificate"
  type        = list(string)
}

variable "private_key_algorithm" {
  description = "Algorithm for private key generation"
  type        = string
}

variable "private_key_rsa_bits" {
  description = "Number of bits for RSA private key"
  type        = number
}

variable "private_key_filename" {
  description = "Filename for the private key file"
  type        = string
}

variable "certificate_filename" {
  description = "Filename for the certificate file"
  type        = string
}

variable "private_key_file_permission" {
  description = "File permissions for the private key file"
  type        = string
}

variable "certificate_file_permission" {
  description = "File permissions for the certificate file"
  type        = string
}