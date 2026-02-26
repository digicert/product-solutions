# ============================================================================
# DigiCert TLM - Automation Admin Web Request
# Copy to terraform.tfvars and fill in values
# ============================================================================

digicert_api_key = "<API_KEY>"
cn               = "tls.guru"
profile_id       = "d8cf5f11-8d91-4daf-b6c2-edde1942ce53"
key_size         = "RSA 4096"

# Destroy behaviour
delete_from_acm   = true         # Set to false to only revoke in TLM, leave cert in ACM
aws_region        = "us-east-2"
revocation_reason = "key_compromise"

# Revocation reason used when destroying the certificate.
# Valid values:
#
# Private certificates #
########################

# unspecified
# key_compromise
# affiliation_changed
# superseded
# cessation_of_operation
# privilege_withdrawn
# ca_compromise
# certificate_hold

# Public certificates #
########################

# key_compromise
# affiliation_changed
# superseded
# cessation_of_operation