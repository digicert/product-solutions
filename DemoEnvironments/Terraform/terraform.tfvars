# DigiCert Configuration
digicert_api_key = "REMOVED_SECRET"
digicert_url     = "https://demo.one.digicert.com"
digicert_profile_id = "f1887d29-ee87-48f7-a873-1a0254dc99a9"

# Certificate Details
common_name  = "tlsguru.io"
organization = "Digicert"
country      = "US"
dns_names    = [
  "tlsguru.io",
  "www.tlsguru.io"
]

# Private Key Configuration
private_key_algorithm = "RSA"
private_key_rsa_bits  = 2048

# Output Files
private_key_filename = "tlsguru.io.key"
certificate_filename = "tlsguru.io.crt"
private_key_file_permission = "0600"
certificate_file_permission = "0644"