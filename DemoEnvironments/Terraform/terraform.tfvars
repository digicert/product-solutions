# DigiCert Configuration
digicert_api_key = "01e615c60f4e874a1a6d0d66dc_87d297ee13fb16ac4bade5b94bb6486043532397c921f665b09a1ff689c7ea5c"
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