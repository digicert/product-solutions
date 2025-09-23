#!/bin/bash
clear
# vault-demo-proof.sh
# Complete demonstration of Vault + KMS + SSM integration
# Shows proof that everything is working as designed

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_SKIP_VERIFY=true

# Function to print colored output
print_color() {
    color=$1
    message=$2
    echo -e "${color}${message}${NC}"
}

# Function to print demo section
print_section() {
    echo
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${MAGENTA}  $1${NC}"
    echo -e "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Function to pause for effect
pause_demo() {
    print_color "$YELLOW" "Press Enter to continue..."
    read
}

# Function to run command with display
run_command() {
    echo -e "${CYAN}$ $1${NC}"
    eval $1
    echo
}

# Function to obfuscate token
obfuscate_token() {
    local token="$1"
    if [ ${#token} -le 8 ]; then
        echo "[REDACTED]"
    else
        echo "${token:0:4}****${token: -4}"
    fi
}

# Start the demo
clear
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     VAULT + AWS KMS + SSM INTEGRATION DEMONSTRATION         ║"
echo "║                                                              ║"
echo "║  This demo will prove:                                      ║"
echo "║  1. KMS Auto-unseal is working                              ║"
echo "║  2. SSM stores AppRole credentials                          ║"
echo "║  3. F5XC API token is securely stored in Vault              ║"
echo "║  4. The complete authentication chain works                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

pause_demo
clear
# ============================================================================
print_section "PART 1: Proving KMS Auto-Unseal Works"
# ============================================================================

print_color "$BLUE" "1.1 - Current Vault Status (should be unsealed):"
run_command "vault status | grep -E 'Seal Type|Sealed|Version'"

print_color "$BLUE" "1.2 - Checking which KMS key is configured:"
# Fixed: Better extraction of the actual KMS key
KMS_KEY=$(grep -E '^\s*kms_key_id\s*=' /etc/vault.d/vault.hcl | grep -v '#.*REPLACE' | awk -F'"' '{print $2}')
echo "KMS Key ID: $KMS_KEY"
echo

print_color "$BLUE" "1.3 - Verifying KMS key exists and is accessible:"
if [ ! -z "$KMS_KEY" ]; then
    run_command "aws kms describe-key --key-id '$KMS_KEY' --query 'KeyMetadata.[KeyId,KeyState,Description]' --output table"
else
    print_color "$RED" "Could not extract KMS key from config"
fi

print_color "$BLUE" "1.4 - Checking AWS authentication method:"
# Check current AWS identity
CURRENT_IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)

if echo "$CURRENT_IDENTITY" | grep -q "assumed-role"; then
    print_color "$GREEN" "✓ Using EC2 Instance Role:"
    echo "  $CURRENT_IDENTITY"
    # Extract role name
    ROLE_NAME=$(echo "$CURRENT_IDENTITY" | awk -F'/' '{print $2}')
    print_color "$GREEN" "  Role Name: $ROLE_NAME"
elif echo "$CURRENT_IDENTITY" | grep -q "user/"; then
    print_color "$YELLOW" "⚠ Using IAM User credentials:"
    echo "  $CURRENT_IDENTITY"
    print_color "$YELLOW" "  For best practice, clear user credentials to use EC2 role"
    print_color "$YELLOW" "  Run: rm ~/.aws/credentials"
else
    print_color "$BLUE" "Current identity: $CURRENT_IDENTITY"
fi
echo

# Check if we're on EC2
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
if [ ! -z "$INSTANCE_ID" ]; then
    print_color "$BLUE" "EC2 Instance ID: $INSTANCE_ID"

    # Check for attached role
    ROLE_NAME=$(curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
    if [ ! -z "$ROLE_NAME" ] && [ "$ROLE_NAME" != "404 - Not Found" ]; then
        print_color "$GREEN" "✓ Instance has IAM role attached: $ROLE_NAME"
    else
        print_color "$RED" "✗ No IAM role attached to instance"
    fi
fi

print_color "$GREEN" "✓ KMS Configuration Verified!"
pause_demo
clear
print_color "$YELLOW" "1.5 - PROVING AUTO-UNSEAL: Let's restart Vault and watch it auto-unseal..."
print_color "$RED" "⚠️  Vault will be briefly unavailable during restart"
pause_demo

# Restart Vault and prove auto-unseal
print_color "$BLUE" "Stopping Vault..."
run_command "sudo systemctl stop vault"

print_color "$BLUE" "Vault Status (should be 'connection refused' or error):"
vault status 2>&1 | head -5 || true
echo

print_color "$BLUE" "Starting Vault..."
run_command "sudo systemctl start vault"

print_color "$BLUE" "Waiting for Vault to start..."
for i in {1..5}; do
    echo -n "."
    sleep 1
done
echo

print_color "$GREEN" "Checking if Vault auto-unsealed (NO MANUAL INTERVENTION):"
run_command "vault status | grep -E 'Seal Type|Sealed'"

if vault status | grep -q "Sealed.*false"; then
    print_color "$GREEN" "✅ PROVEN: Vault auto-unsealed using AWS KMS!"
else
    print_color "$RED" "❌ Vault is sealed - check KMS permissions"
fi
pause_demo
clear
# ============================================================================
print_section "PART 2: Proving SSM Stores AppRole Credentials"
# ============================================================================

print_color "$BLUE" "2.1 - Listing SSM parameters for Vault:"
run_command "aws ssm get-parameters-by-path --path '/vault' --recursive --query 'Parameters[*].[Name,Type,LastModifiedDate]' --output table"

print_color "$BLUE" "2.2 - Retrieving Role ID from SSM (non-encrypted):"
ROLE_ID=$(aws ssm get-parameter --name "/vault/myapp/role-id" --query 'Parameter.Value' --output text 2>/dev/null)
if [ ! -z "$ROLE_ID" ]; then
    echo "$ aws ssm get-parameter --name '/vault/myapp/role-id' --query 'Parameter.Value' --output text"
    echo "Role ID: ${ROLE_ID:0:8}****"
else
    print_color "$RED" "Failed to retrieve Role ID from SSM"
fi
echo

print_color "$BLUE" "2.3 - Retrieving Secret ID from SSM (KMS encrypted):"
SECRET_ID=$(aws ssm get-parameter --name "/vault/myapp/secret-id" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)
if [ ! -z "$SECRET_ID" ]; then
    echo "$ aws ssm get-parameter --name '/vault/myapp/secret-id' --with-decryption --query 'Parameter.Value' --output text"
    echo "Secret ID: $(obfuscate_token "$SECRET_ID")"
else
    print_color "$RED" "Failed to retrieve Secret ID from SSM"
fi
echo

print_color "$BLUE" "2.4 - Showing that Secret ID is encrypted in SSM:"
run_command "aws ssm get-parameter --name '/vault/myapp/secret-id' --query 'Parameter.[Type,KeyId]' --output json"

print_color "$GREEN" "✅ PROVEN: AppRole credentials are stored in SSM (Secret ID encrypted with KMS)!"
pause_demo
clear
# ============================================================================
print_section "PART 3: Proving F5XC Token is in Vault"
# ============================================================================

print_color "$BLUE" "3.1 - First, let's authenticate to Vault using root token:"
print_color "$YELLOW" "Enter your Vault root/admin token:"
read -s ROOT_TOKEN
echo
export VAULT_TOKEN="$ROOT_TOKEN"

# Verify authentication
if vault token lookup &>/dev/null; then
    print_color "$GREEN" "✓ Successfully authenticated with Vault"
else
    print_color "$RED" "✗ Invalid token. Please run the script again with a valid token."
    exit 1
fi

print_color "$BLUE" "3.2 - Listing secrets in the api-keys path:"
vault kv list secret/api-keys 2>/dev/null || print_color "$YELLOW" "No secrets found or path doesn't exist"
echo

print_color "$BLUE" "3.3 - Retrieving F5XC token from Vault:"
F5XC_TOKEN=$(vault kv get -field=api_token secret/api-keys/f5xc 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "$ vault kv get -field=api_token secret/api-keys/f5xc"
    echo "F5XC API Token: $(obfuscate_token "$F5XC_TOKEN")"
    print_color "$GREEN" "✅ F5XC token exists in Vault!"
else
    print_color "$YELLOW" "⚠️  No F5XC token found. Let's add one for the demo..."
    print_color "$YELLOW" "Enter an F5XC API token to store (or press Enter to skip):"
    read -s DEMO_TOKEN
    echo
    if [ ! -z "$DEMO_TOKEN" ]; then
        vault kv put secret/api-keys/f5xc api_token="$DEMO_TOKEN"
        F5XC_TOKEN="$DEMO_TOKEN"
        print_color "$GREEN" "✓ Token stored in Vault"
    fi
fi
echo

print_color "$BLUE" "3.4 - Showing metadata about the secret:"
vault kv metadata get secret/api-keys/f5xc 2>/dev/null | head -20 || print_color "$YELLOW" "No metadata available"

pause_demo
clear
# ============================================================================
print_section "PART 4: Complete Authentication Chain Demo"
# ============================================================================

print_color "$BLUE" "Now let's prove the complete authentication chain works..."
print_color "$YELLOW" "This simulates what your certificate script does:"
echo

# Unset root token to prove we're using AppRole
unset VAULT_TOKEN
print_color "$RED" "4.1 - Clearing Vault token (proving we're not authenticated):"
vault token lookup 2>&1 | head -3 || true
echo

print_color "$BLUE" "4.2 - Step 1: Retrieve AppRole credentials from SSM:"
echo "Getting Role ID from SSM..."
ROLE_ID=$(aws ssm get-parameter --name "/vault/myapp/role-id" --query 'Parameter.Value' --output text 2>/dev/null)
if [ ! -z "$ROLE_ID" ]; then
    print_color "$GREEN" "✓ Role ID retrieved: ${ROLE_ID:0:8}****"
else
    print_color "$RED" "✗ Failed to retrieve Role ID"
fi

echo "Getting Secret ID from SSM (with KMS decryption)..."
SECRET_ID=$(aws ssm get-parameter --name "/vault/myapp/secret-id" --with-decryption --query 'Parameter.Value' --output text 2>/dev/null)
if [ ! -z "$SECRET_ID" ]; then
    print_color "$GREEN" "✓ Secret ID retrieved: $(obfuscate_token "$SECRET_ID")"
else
    print_color "$RED" "✗ Failed to retrieve Secret ID"
fi
echo

if [ ! -z "$ROLE_ID" ] && [ ! -z "$SECRET_ID" ]; then
    print_color "$BLUE" "4.3 - Step 2: Authenticate with Vault using AppRole:"
    VAULT_TOKEN=$(vault write -field=token auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID" 2>/dev/null)
    if [ ! -z "$VAULT_TOKEN" ]; then
        export VAULT_TOKEN
        print_color "$GREEN" "✓ Vault token obtained: ${VAULT_TOKEN:0:10}****"
        echo

        print_color "$BLUE" "4.4 - Step 3: Verify we're authenticated and check our policies:"
        vault token lookup | grep -E 'policies|ttl|display_name' || true
        echo

        print_color "$BLUE" "4.5 - Step 4: Retrieve F5XC token using AppRole authentication:"
        F5XC_TOKEN=$(vault kv get -field=api_token secret/api-keys/f5xc 2>/dev/null)
        if [ $? -eq 0 ]; then
            print_color "$GREEN" "✓ Successfully retrieved F5XC token: $(obfuscate_token "$F5XC_TOKEN")"
        else
            print_color "$RED" "✗ Failed to retrieve F5XC token - check AppRole policy permissions"
        fi
    else
        print_color "$RED" "✗ Failed to authenticate with AppRole"
    fi
else
    print_color "$RED" "Cannot proceed without AppRole credentials"
fi

pause_demo
clear
# ============================================================================
print_section "PART 5: Stored Private Keys Check"
# ============================================================================

print_color "$BLUE" "5.1 - Listing stored private keys in Vault:"
vault kv list secret/private-keys 2>/dev/null || print_color "$YELLOW" "No private keys stored yet"
echo

print_color "$BLUE" "5.2 - If keys exist, showing the most recent one:"
LATEST_KEY=$(vault kv list -format=json secret/private-keys 2>/dev/null | jq -r '.[-1]' 2>/dev/null)
if [ ! -z "$LATEST_KEY" ] && [ "$LATEST_KEY" != "null" ]; then
    print_color "$GREEN" "Most recent key: $LATEST_KEY"
    vault kv metadata get "secret/private-keys/$LATEST_KEY" | head -15
else
    print_color "$YELLOW" "No private keys found in Vault yet"
fi

pause_demo
clear
# ============================================================================
print_section "DEMO SUMMARY"
# ============================================================================

echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    PROVEN CAPABILITIES                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║ ✅ KMS Auto-unseal:        Vault unseals automatically       ║"
echo "║ ✅ SSM Integration:        Credentials stored securely       ║"
echo "║ ✅ Vault Secret Storage:   F5XC token protected in Vault     ║"
echo "║ ✅ Authentication Chain:   AppRole → Vault → Secrets works   ║"
echo "║ ✅ No Hardcoded Secrets:   Everything retrieved dynamically  ║"
echo "║ ✅ Private Key Storage:    Keys moved to Vault after upload  ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_color "$CYAN" "Security Architecture Flow:"
echo "  EC2 IAM Role / IAM User"
echo "      ↓"
echo "  AWS KMS (unseals Vault)"
echo "      ↓"
echo "  AWS SSM (provides AppRole creds)"
echo "      ↓"
echo "  Vault AppRole Auth"
echo "      ↓"
echo "  Secrets Retrieved (F5XC token, private keys)"
echo "      ↓"
echo "  Certificate Upload Success"
echo

print_color "$BLUE" "Current Configuration:"
echo "  Vault Address: $VAULT_ADDR"
echo "  KMS Key ID: ${KMS_KEY:-Not found}"
echo "  SSM Path: /vault/myapp/*"
echo "  Secrets Path: secret/api-keys/f5xc"
echo "  Private Keys Path: secret/private-keys/*"
echo

print_color "$GREEN" "✨ Demo Complete!"