# ============================================================================
# DigiCert TLM - Automation Admin Web Request
# Copy to terraform.tfvars and fill in values
# ============================================================================

digicert_api_key = "REMOVED_SECRET"
cn               = "tls.guru"
profile_id       = "d8cf5f11-8d91-4daf-b6c2-edde1942ce53"
key_size         = "RSA 4096"

# Destroy behaviour
delete_from_acm   = true         # Set to false to only revoke in TLM, leave cert in ACM
aws_region        = "us-east-2"
revocation_reason = "key_compromise"

# Revocation reason used when destroying the certificate.
# Valid values:
#   key_compromise          - Private key has been compromised (default)
#   unspecified             - No specific reason
#   affiliation_changed     - Subject's affiliation has changed
#   superseded              - Certificate has been replaced
#   cessation_of_operation  - Certificate is no longer needed
#   privilege_withdrawn     - Privileges have been revoked
#   ca_compromise           - CA private key has been compromised
#   certificate_hold        - Temporarily suspend the certificate (added to CRL
#                             until it expires or is resumed via the
#                             Resume Suspended Certificate API endpoint)