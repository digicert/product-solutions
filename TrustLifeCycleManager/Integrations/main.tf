# ============================================================================
# DigiCert TLM - Automation Admin Web Request
# Enroll certificate with AWS ACM delivery via API
# Destroy: revoke in TLM → optionally delete from ACM
# ============================================================================

terraform {
  required_version = ">= 1.4"
}

# ============================================================================
# Variables
# ============================================================================

variable "digicert_api_key" {
  description = "DigiCert TLM API key"
  type        = string
  sensitive   = true
}

variable "cn" {
  description = "Common Name for the certificate"
  type        = string
}

variable "profile_id" {
  description = "DigiCert certificate profile ID"
  type        = string
}

variable "key_size" {
  description = "Key algorithm and size (e.g. RSA 2048, RSA 4096, ECC 256)"
  type        = string
  default     = "RSA 4096"
}

variable "delete_from_acm" {
  description = "Whether to also delete the certificate from AWS ACM on destroy"
  type        = bool
  default     = true
}

variable "aws_region" {
  description = "AWS region where the certificate is imported"
  type        = string
  default     = "us-east-2"
}

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
variable "revocation_reason" {
  description = "Reason for revoking the certificate on destroy"
  type        = string
  default     = "key_compromise"

  validation {
    condition = contains([
      "unspecified",
      "key_compromise",
      "affiliation_changed",
      "superseded",
      "cessation_of_operation",
      "privilege_withdrawn",
      "ca_compromise",
      "certificate_hold"
    ], var.revocation_reason)
    error_message = "Must be one of: unspecified, key_compromise, affiliation_changed, superseded, cessation_of_operation, privilege_withdrawn, ca_compromise, certificate_hold."
  }
}

# ============================================================================
# Locals
# ============================================================================

locals {
  base_url      = "https://demo.one.digicert.com"
  account_id    = "c2fecb4c-0b91-4a19-987f-170d79f43ae8"
  connector_id  = "46fa0817-7ac8-4e22-b446-30fd98af6737"
  aws_account   = "060236094678"
  response_file = "${path.module}/digicert_response.json"
  state_file    = "${path.module}/digicert_state.json"

  payload = jsonencode({
    cn                             = var.cn
    profile_id                     = var.profile_id
    account_id                     = local.account_id
    key_size                       = var.key_size
    certificate_services_agreement = true
    issue_duplicate_cert           = false

    auto_renew_settings = {
      auto_renew_certificate_and_order = false
      before_expiration                = false
    }

    additional_order_options = {}
    owner_ids                = []
    custom_attributes_field  = []

    cert_delivery_settings = [
      {
        delivery_method = "awsacm"
        connector_id    = local.connector_id
        aws_targets = [
          {
            aws_regions                              = []
            aws_account_id                           = [local.aws_account]
            aws_reimport_arns                        = ["arn:aws:acm:${var.aws_region}:${local.aws_account}:certificate/"]
            create_new_import_on_reimport_arn_failure = true
          }
        ]
      }
    ]
  })
}

# ============================================================================
# Resource - Enroll / Revoke+Delete lifecycle
# ============================================================================

resource "terraform_data" "cert_enrollment" {

  input = {
    cn                = var.cn
    profile_id        = var.profile_id
    key_size          = var.key_size
    api_key           = var.digicert_api_key
    delete_from_acm   = var.delete_from_acm
    aws_region        = var.aws_region
    revocation_reason = var.revocation_reason
  }

  # ------------------------------------------------------------------
  # CREATE: Enroll the certificate and save state for destroy
  # ------------------------------------------------------------------
  provisioner "local-exec" {
    command = <<-EOT
      set -e

      echo "=== Enrolling certificate: ${var.cn} ==="

      HTTP_CODE=$(curl -s -o "${local.response_file}" -w "%%{http_code}" \
        --location '${local.base_url}/mpki/api/v1/automation/admin-web-request' \
        --header 'Content-Type: application/json' \
        --header "x-api-key: $DIGICERT_API_KEY" \
        --data '${local.payload}')

      if [ "$HTTP_CODE" -ne 200 ]; then
        echo "ERROR: Enrollment failed with HTTP $HTTP_CODE"
        cat "${local.response_file}"
        rm -f "${local.response_file}"
        exit 1
      fi

      echo "=== Enrollment successful ==="
      cat "${local.response_file}"
      echo ""

      SEAT_ID=$(jq -r '.[0].seat_identifier // empty' "${local.response_file}")
      INVENTORY_ID=$(jq -r '.[0].inventory_id // empty' "${local.response_file}")

      if [ -z "$SEAT_ID" ]; then
        echo "WARNING: Could not extract seat_identifier from response"
      else
        echo "Seat Identifier: $SEAT_ID"
        echo "Inventory ID:    $INVENTORY_ID"
      fi

      jq -n \
        --arg cn "${var.cn}" \
        --arg seat "$SEAT_ID" \
        --arg inv "$INVENTORY_ID" \
        --arg acct "${local.account_id}" \
        '{cn: $cn, seat_identifier: $seat, inventory_id: $inv, account_id: $acct}' \
        > "${local.state_file}"

      echo "=== State saved for destroy lifecycle ==="
    EOT

    environment = {
      DIGICERT_API_KEY = var.digicert_api_key
    }
  }

  # ------------------------------------------------------------------
  # DESTROY: Revoke in TLM → optionally delete from ACM
  # ------------------------------------------------------------------
  provisioner "local-exec" {
    when = destroy

    command = <<-EOT
      set -e

      STATE_FILE="${path.module}/digicert_state.json"
      BASE_URL="https://demo.one.digicert.com"
      ACCOUNT_ID="c2fecb4c-0b91-4a19-987f-170d79f43ae8"
      DELETE_FROM_ACM="${self.input.delete_from_acm}"
      AWS_REGION="${self.input.aws_region}"
      REVOCATION_REASON="${self.input.revocation_reason}"
      TMPFILE=$(mktemp)

      if [ ! -f "$STATE_FILE" ]; then
        echo "WARNING: No state file found at $STATE_FILE - nothing to revoke"
        exit 0
      fi

      CN=$(jq -r '.cn' "$STATE_FILE")
      SEAT_ID=$(jq -r '.seat_identifier' "$STATE_FILE")

      if [ -z "$SEAT_ID" ] || [ "$SEAT_ID" = "null" ]; then
        echo "WARNING: No seat_identifier in state file - nothing to revoke"
        exit 0
      fi

      echo "============================================"
      echo "  Destroying certificate: $CN"
      echo "============================================"
      echo "Seat Identifier:    $SEAT_ID"
      echo "Revocation Reason:  $REVOCATION_REASON"
      echo "Delete from ACM:    $DELETE_FROM_ACM"
      echo ""

      # -------------------------------------------------------
      # Step 1: Search TLM for the certificate serial number
      # -------------------------------------------------------
      echo "--- Step 1: Looking up serial number in TLM ---"

      SEARCH_CODE=$(curl -s -o "$TMPFILE" -w "%%{http_code}" \
        -X GET "$BASE_URL/mpki/api/v1/certificate-search?seat_id=$SEAT_ID&common_name=$CN&status=issued" \
        -H 'accept: application/json' \
        -H "x-api-key: $DIGICERT_API_KEY")

      if [ "$SEARCH_CODE" -ne 200 ]; then
        echo "ERROR: Certificate search failed with HTTP $SEARCH_CODE"
        cat "$TMPFILE"
        rm -f "$TMPFILE"
        exit 1
      fi

      SERIAL=$(jq -r '.items[0].serial_number // empty' "$TMPFILE")
      rm -f "$TMPFILE"

      if [ -z "$SERIAL" ]; then
        echo "WARNING: No issued certificate found for seat_id=$SEAT_ID - may already be revoked"
        rm -f "$STATE_FILE" "${path.module}/digicert_response.json"
        exit 0
      fi

      echo "Serial Number:   $SERIAL"
      echo ""

      # -------------------------------------------------------
      # Step 2: Revoke the certificate in TLM
      # -------------------------------------------------------
      echo "--- Step 2: Revoking certificate in TLM (reason: $REVOCATION_REASON) ---"

      REVOKE_CODE=$(curl -s -o /dev/null -w "%%{http_code}" \
        -X PUT "$BASE_URL/mpki/api/v1/certificate/$SERIAL/revoke?account_id=$ACCOUNT_ID" \
        -H 'accept: */*' \
        -H "x-api-key: $DIGICERT_API_KEY" \
        -H 'Content-Type: application/json' \
        -d "{\"revocation_reason\": \"$REVOCATION_REASON\"}")

      if [ "$REVOKE_CODE" -ne 200 ] && [ "$REVOKE_CODE" -ne 204 ]; then
        echo "ERROR: TLM revoke failed with HTTP $REVOKE_CODE"
        exit 1
      fi

      echo "Certificate $SERIAL revoked in TLM"
      echo ""

      # -------------------------------------------------------
      # Step 3: Delete from AWS ACM (if enabled)
      # -------------------------------------------------------
      if [ "$DELETE_FROM_ACM" = "true" ]; then
        echo "--- Step 3: Deleting certificate from AWS ACM ($AWS_REGION) ---"

        # Convert DigiCert serial to ACM format (lowercase, colon-separated)
        SERIAL_ACM=$(echo "$SERIAL" | sed 's/../&:/g' | sed 's/:$//' | tr '[:upper:]' '[:lower:]')
        echo "ACM Serial:      $SERIAL_ACM"

        # Find the ARN by matching serial number
        ARN=$(aws acm list-certificates --region "$AWS_REGION" \
          --includes keyTypes=RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1 \
          --output json | \
          jq -r '.CertificateSummaryList[].CertificateArn' | \
          while read arn; do
            S=$(aws acm describe-certificate --certificate-arn "$arn" --region "$AWS_REGION" \
              --query 'Certificate.Serial' --output text)
            if [ "$S" = "$SERIAL_ACM" ]; then
              echo "$arn"
              break
            fi
          done)

        if [ -z "$ARN" ]; then
          echo "WARNING: Certificate not found in ACM - may already be deleted"
        else
          echo "ACM ARN:         $ARN"
          aws acm delete-certificate --certificate-arn "$ARN" --region "$AWS_REGION"
          echo "Certificate deleted from ACM"
        fi
      else
        echo "--- Step 3: Skipping ACM deletion (delete_from_acm = false) ---"
      fi

      # Clean up state files
      rm -f "$STATE_FILE" "${path.module}/digicert_response.json"

      echo ""
      echo "============================================"
      echo "  Destroy complete"
      echo "============================================"
    EOT

    environment = {
      DIGICERT_API_KEY = self.input.api_key
    }
  }
}

# ============================================================================
# Read the enrollment response
# ============================================================================

data "local_file" "api_response" {
  filename   = local.response_file
  depends_on = [terraform_data.cert_enrollment]
}

# ============================================================================
# Outputs
# ============================================================================

output "digicert_response" {
  description = "Full API response from DigiCert TLM"
  value       = jsondecode(data.local_file.api_response.content)
}

output "inventory_id" {
  description = "Inventory ID of the enrolled certificate"
  value       = try(jsondecode(data.local_file.api_response.content)[0].inventory_id, "not returned")
}

output "seat_identifier" {
  description = "Seat identifier of the enrolled certificate"
  value       = try(jsondecode(data.local_file.api_response.content)[0].seat_identifier, "not returned")
}
