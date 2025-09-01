# DigiCert Configuration
digicert_api_key = "01e615c60<REDACTED>9a1ff689c7ea5c"
digicert_url     = "https://one.digicert.com"
digicert_profile_id = "f18<REDACTED>254dc99a9"

# Certificate Details
common_name  = "Your Domain"
organization = "Your Organization"
country      = "US"
dns_names    = [
  "DNS1",
  "www.DNS1"
]

# Private Key Configuration
private_key_algorithm = "RSA"
private_key_rsa_bits  = 2048

# Output Files
private_key_filename = "DNS1.key"
certificate_filename = "DNS1.crt"
private_key_file_permission = "0600"
certificate_file_permission = "0644"