#!/bin/bash
clear
# Akamai EdgeGrid CPS Enrollment Script with Certificate Upload, Production Deployment, and Renewal Support
# This script sets up EdgeGrid authentication, creates a CPS enrollment, 
# retrieves CSRs, issues certificates via DigiCert, uploads them to Akamai,
# deploys to production, and supports certificate renewal workflows

set -e

# Script version
SCRIPT_VERSION="2.2.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# Function to prompt with default value
prompt_with_default() {
    local prompt_message="$1"
    local default_value="$2"
    local user_input
    
    if [ -n "$default_value" ]; then
        read -p "$prompt_message [$default_value]: " user_input
        echo "${user_input:-$default_value}"
    else
        read -p "$prompt_message: " user_input
        echo "$user_input"
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to show usage
show_usage() {
    echo "Akamai CPS Certificate Management Script v$SCRIPT_VERSION"
    echo
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --init                  Initialize a new certificate enrollment (default if no options)"
    echo "  --renew <CN>           Renew certificate for the specified Common Name"
    echo "  --renew-config <file>  Renew certificate using the specified config file"
    echo "  --list                 List all saved certificate configurations"
    echo "  --discover             Discover existing enrollments in Akamai"
    echo "  --no-save              Don't save configuration (for init mode)"
    echo "  --auto                 Run in automated mode (no interactive prompts, uses config values)"
    echo "  --help                 Show this help message"
    echo
    echo "Examples:"
    echo "  $0 --init                                    # Create new enrollment with config saving"
    echo "  $0 --renew digicert-demo.com                # Renew certificate by Common Name (interactive)"
    echo "  $0 --renew digicert-demo.com --auto         # Renew certificate by Common Name (automated)"
    echo "  $0 --renew-config ~/config.json --auto      # Renew using specific config file (automated)"
    echo "  $0 --discover                                # List existing enrollments"
    echo
    echo "Automated Mode:"
    echo "  When using --auto flag, the script will use configuration values for all decisions:"
    echo "  - Certificate type (RSA/ECDSA)"
    echo "  - Submit to DigiCert (yes/no)"
    echo "  - Upload certificate to Akamai (yes/no)"
    echo "  - Acknowledge post-verification warnings (yes/no)"
    echo "  - Deploy to production (yes/no)"
    echo
    echo "  Perfect for cron jobs and automated certificate renewal workflows!"
    echo
}

# Parse command line arguments
MODE="init"
CONFIG_FILE=""
COMMON_NAME=""
SAVE_CONFIG=true
DISCOVER_MODE=false
AUTO_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --init)
            MODE="init"
            shift
            ;;
        --renew)
            MODE="renew"
            COMMON_NAME="$2"
            shift 2
            ;;
        --renew-config)
            MODE="renew"
            CONFIG_FILE="$2"
            shift 2
            ;;
        --list)
            MODE="list"
            shift
            ;;
        --discover)
            DISCOVER_MODE=true
            shift
            ;;
        --no-save)
            SAVE_CONFIG=false
            shift
            ;;
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Configuration directory
CONFIG_DIR="$HOME/.akamai-cps/configs"
mkdir -p "$CONFIG_DIR"

# Function to save configuration
save_configuration() {
    local config_file="$1"
    local enrollment_id="$2"
    local change_id="$3"
    
    print_info "Saving configuration to: $config_file"
    
    # Create configuration JSON
    cat > "$config_file" << EOF
{
  "version": "$SCRIPT_VERSION",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "last_renewed": null,
  "enrollment": {
    "enrollment_id": "$enrollment_id",
    "change_id": "$change_id",
    "contract_id": "$CONTRACT_ID",
    "common_name": "$CSR_CN",
    "certificate_type": "$CERT_TYPE"
  },
  "edgegrid": {
    "host": "$EDGEGRID_HOST",
    "client_secret": "$EDGEGRID_CLIENT_SECRET",
    "access_token": "$EDGEGRID_ACCESS_TOKEN",
    "client_token": "$EDGEGRID_CLIENT_TOKEN"
  },
  "csr_config": {
    "c": "$CSR_C",
    "cn": "$CSR_CN",
    "st": "$CSR_ST",
    "l": "$CSR_L",
    "o": "$CSR_O",
    "ou": "$CSR_OU"
  },
  "network_config": {
    "geography": "$GEOGRAPHY",
    "quic_enabled": $QUIC_ENABLED,
    "secure_network": "$SECURE_NETWORK",
    "sni_only": $SNI_ONLY,
    "must_have_ciphers": "$MUST_HAVE_CIPHERS",
    "ocsp_stapling": "$OCSP_STAPLING",
    "preferred_ciphers": "$PREFERRED_CIPHERS"
  },
  "validation": {
    "ra": "$RA",
    "validation_type": "$VALIDATION_TYPE"
  },
  "contacts": {
    "admin": {
      "email": "$ADMIN_EMAIL",
      "firstName": "$ADMIN_FIRSTNAME",
      "lastName": "$ADMIN_LASTNAME",
      "phone": "$ADMIN_PHONE"
    },
    "tech": {
      "email": "$TECH_EMAIL",
      "firstName": "$TECH_FIRSTNAME",
      "lastName": "$TECH_LASTNAME",
      "phone": "$TECH_PHONE"
    }
  },
  "organization": {
    "name": "$ORG_NAME",
    "addressLineOne": "$ORG_ADDR1",
    "addressLineTwo": "$ORG_ADDR2",
    "city": "$ORG_CITY",
    "country": "$ORG_COUNTRY",
    "phone": "$ORG_PHONE",
    "postalCode": "$ORG_POSTAL",
    "region": "$ORG_REGION"
  },
  "digicert": {
    "seat_id": "$SEAT_ID",
    "api_key": "$DIGICERT_API_KEY",
    "rsa_profile": "f1887d29-ee87-48f7-a873-1a0254dc99a9",
    "ecdsa_profile": "8b566220-8e48-4b44-bf4c-20434f4f95c1"
  },
  "storage": {
    "cert_dir": "$CERT_STORAGE_DIR",
    "ica_file": "${ICA_FILE:-}"
  },
  "third_party": {
    "exclude_sans": $EXCLUDE_SANS
  },
  "change_management": $CHANGE_MGMT,
  "automation": {
    "certificate_type": "${CERT_TYPE_CHOICE:-RSA}",
    "auto_submit_digicert": ${AUTO_SUBMIT_DIGICERT:-true},
    "auto_upload_cert": ${AUTO_UPLOAD_CERT:-true},
    "auto_acknowledge_warnings": ${AUTO_ACK_WARNINGS:-true},
    "auto_deploy_production": ${AUTO_DEPLOY_PROD:-true}
  }
}
EOF
    
    chmod 600 "$config_file"
    print_info "✓ Configuration saved successfully!"
    echo
    
    # Create a symlink for easy access by CN
    local cn_link="$CONFIG_DIR/${CSR_CN}.json"
    if [ -f "$cn_link" ]; then
        print_warning "Configuration for $CSR_CN already exists. Creating backup..."
        mv "$cn_link" "${cn_link}.$(date +%Y%m%d_%H%M%S).bak"
    fi
    ln -sf "$config_file" "$cn_link"
    print_info "Created symlink: $cn_link -> $config_file"
}

# Function to load configuration
load_configuration() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        print_error "Configuration file not found: $config_file"
        return 1
    fi
    
    print_info "Loading configuration from: $config_file"
    
    # Load configuration using jq
    export ENROLLMENT_ID=$(jq -r '.enrollment.enrollment_id' "$config_file")
    export CHANGE_ID=$(jq -r '.enrollment.change_id' "$config_file")
    export CONTRACT_ID=$(jq -r '.enrollment.contract_id' "$config_file")
    export CSR_CN=$(jq -r '.enrollment.common_name' "$config_file")
    export CERT_TYPE=$(jq -r '.enrollment.certificate_type' "$config_file")
    
    export EDGEGRID_HOST=$(jq -r '.edgegrid.host' "$config_file")
    export EDGEGRID_CLIENT_SECRET=$(jq -r '.edgegrid.client_secret' "$config_file")
    export EDGEGRID_ACCESS_TOKEN=$(jq -r '.edgegrid.access_token' "$config_file")
    export EDGEGRID_CLIENT_TOKEN=$(jq -r '.edgegrid.client_token' "$config_file")
    
    export CSR_C=$(jq -r '.csr_config.c' "$config_file")
    export CSR_ST=$(jq -r '.csr_config.st' "$config_file")
    export CSR_L=$(jq -r '.csr_config.l' "$config_file")
    export CSR_O=$(jq -r '.csr_config.o' "$config_file")
    export CSR_OU=$(jq -r '.csr_config.ou' "$config_file")
    
    export GEOGRAPHY=$(jq -r '.network_config.geography' "$config_file")
    export QUIC_ENABLED=$(jq -r '.network_config.quic_enabled' "$config_file")
    export SECURE_NETWORK=$(jq -r '.network_config.secure_network' "$config_file")
    export SNI_ONLY=$(jq -r '.network_config.sni_only' "$config_file")
    export MUST_HAVE_CIPHERS=$(jq -r '.network_config.must_have_ciphers' "$config_file")
    export OCSP_STAPLING=$(jq -r '.network_config.ocsp_stapling' "$config_file")
    export PREFERRED_CIPHERS=$(jq -r '.network_config.preferred_ciphers' "$config_file")
    
    export RA=$(jq -r '.validation.ra' "$config_file")
    export VALIDATION_TYPE=$(jq -r '.validation.validation_type' "$config_file")
    
    export ADMIN_EMAIL=$(jq -r '.contacts.admin.email' "$config_file")
    export ADMIN_FIRSTNAME=$(jq -r '.contacts.admin.firstName' "$config_file")
    export ADMIN_LASTNAME=$(jq -r '.contacts.admin.lastName' "$config_file")
    export ADMIN_PHONE=$(jq -r '.contacts.admin.phone' "$config_file")
    
    export TECH_EMAIL=$(jq -r '.contacts.tech.email' "$config_file")
    export TECH_FIRSTNAME=$(jq -r '.contacts.tech.firstName' "$config_file")
    export TECH_LASTNAME=$(jq -r '.contacts.tech.lastName' "$config_file")
    export TECH_PHONE=$(jq -r '.contacts.tech.phone' "$config_file")
    
    export ORG_NAME=$(jq -r '.organization.name' "$config_file")
    export ORG_ADDR1=$(jq -r '.organization.addressLineOne' "$config_file")
    export ORG_ADDR2=$(jq -r '.organization.addressLineTwo' "$config_file")
    export ORG_CITY=$(jq -r '.organization.city' "$config_file")
    export ORG_COUNTRY=$(jq -r '.organization.country' "$config_file")
    export ORG_PHONE=$(jq -r '.organization.phone' "$config_file")
    export ORG_POSTAL=$(jq -r '.organization.postalCode' "$config_file")
    export ORG_REGION=$(jq -r '.organization.region' "$config_file")
    
    export SEAT_ID=$(jq -r '.digicert.seat_id' "$config_file")
    export DIGICERT_API_KEY=$(jq -r '.digicert.api_key' "$config_file")
    
    export CERT_STORAGE_DIR=$(jq -r '.storage.cert_dir' "$config_file")
    export ICA_FILE=$(jq -r '.storage.ica_file // empty' "$config_file")
    
    export EXCLUDE_SANS=$(jq -r '.third_party.exclude_sans' "$config_file")
    export CHANGE_MGMT=$(jq -r '.change_management' "$config_file")

    # Load automation settings (with defaults if not present)
    export CERT_TYPE_CHOICE=$(jq -r '.automation.certificate_type // "RSA"' "$config_file")
    export AUTO_SUBMIT_DIGICERT=$(jq -r '.automation.auto_submit_digicert // true' "$config_file")
    export AUTO_UPLOAD_CERT=$(jq -r '.automation.auto_upload_cert // true' "$config_file")
    export AUTO_ACK_WARNINGS=$(jq -r '.automation.auto_acknowledge_warnings // true' "$config_file")
    export AUTO_DEPLOY_PROD=$(jq -r '.automation.auto_deploy_production // true' "$config_file")

    # Set global variables
    GLOBAL_ENROLLMENT_ID="$ENROLLMENT_ID"
    GLOBAL_CHANGE_ID="$CHANGE_ID"
    
    print_info "✓ Configuration loaded successfully!"
    echo
    print_info "Enrollment ID: $ENROLLMENT_ID"
    print_info "Common Name: $CSR_CN"
    print_info "Certificate Storage: $CERT_STORAGE_DIR"
    echo
}

# Function to list configurations
list_configurations() {
    print_info "=== Saved Certificate Configurations ==="
    echo
    
    if [ ! -d "$CONFIG_DIR" ] || [ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
        print_warning "No configurations found in $CONFIG_DIR"
        return
    fi
    
    echo "Common Name                     | Enrollment ID | Created            | Config File"
    echo "--------------------------------|---------------|--------------------|---------------------------------"
    
    for config in "$CONFIG_DIR"/*.json; do
        if [ -f "$config" ] && [ ! -L "$config" ]; then  # Skip symlinks
            cn=$(jq -r '.enrollment.common_name // "N/A"' "$config" 2>/dev/null)
            enrollment=$(jq -r '.enrollment.enrollment_id // "N/A"' "$config" 2>/dev/null)
            created=$(jq -r '.created_at // "N/A"' "$config" 2>/dev/null)
            filename=$(basename "$config")
            
            printf "%-31s | %-13s | %-18s | %s\n" "$cn" "$enrollment" "${created:0:19}" "$filename"
        fi
    done
    echo
}

# Function to discover enrollments
discover_enrollments() {
    print_info "=== Discovering Existing Enrollments ==="
    echo
    
    # Check for EdgeGrid configuration
    if [ ! -f "$HOME/.edgerc" ]; then
        print_error ".edgerc file not found. Please run initial setup first."
        return 1
    fi
    
    # Prompt for contract ID if not set
    if [ -z "$CONTRACT_ID" ]; then
        DEFAULT_CONTRACT_ID="M-27UV417"
        CONTRACT_ID=$(prompt_with_default "Enter Contract ID" "$DEFAULT_CONTRACT_ID")
    fi
    
    print_info "Fetching enrollments for Contract ID: $CONTRACT_ID"
    echo
    
    # Fetch enrollments
    DISCOVER_FILE="/tmp/akamai_enrollments_$(date +%s).json"
    
    if http --auth-type edgegrid -a default: GET \
        "https://$(grep host ~/.edgerc | cut -d'=' -f2 | tr -d ' ')/cps/v2/enrollments?contractId=${CONTRACT_ID}" \
        accept:'application/vnd.akamai.cps.enrollments.v12+json' \
        --body > "$DISCOVER_FILE" 2>&1; then
        
        # Parse and display enrollments
        ENROLLMENT_COUNT=$(jq '.enrollments | length' "$DISCOVER_FILE" 2>/dev/null)
        
        if [ "$ENROLLMENT_COUNT" -gt 0 ]; then
            print_info "Found $ENROLLMENT_COUNT enrollment(s):"
            echo
            echo "ID       | Common Name                     | Status      | Type         | Expires"
            echo "---------|--------------------------------|-------------|--------------|--------------------"
            
            for ((i=0; i<$ENROLLMENT_COUNT; i++)); do
                enroll_id=$(jq -r ".enrollments[$i].id" "$DISCOVER_FILE")
                cn=$(jq -r ".enrollments[$i].csr.cn" "$DISCOVER_FILE")
                status=$(jq -r ".enrollments[$i].pendingChanges[0].statusInfo.status // \"active\"" "$DISCOVER_FILE")
                cert_type=$(jq -r ".enrollments[$i].certificateType" "$DISCOVER_FILE")
                expires=$(jq -r ".enrollments[$i].validNotAfter // \"N/A\"" "$DISCOVER_FILE")
                
                printf "%-8s | %-30s | %-11s | %-12s | %s\n" "$enroll_id" "$cn" "$status" "$cert_type" "${expires:0:19}"
            done
            echo
            
            # Save discovery results
            DISCOVER_SAVE="$CONFIG_DIR/discovered_$(date +%Y%m%d_%H%M%S).json"
            cp "$DISCOVER_FILE" "$DISCOVER_SAVE"
            print_info "Discovery results saved to: $DISCOVER_SAVE"
        else
            print_warning "No enrollments found for Contract ID: $CONTRACT_ID"
        fi
    else
        print_error "Failed to fetch enrollments from Akamai"
        if [ -f "$DISCOVER_FILE" ]; then
            cat "$DISCOVER_FILE"
        fi
    fi
    
    rm -f "$DISCOVER_FILE"
}

# Function to get latest pending change for an enrollment
get_latest_pending_change() {
    local enrollment_id="$1"
    local enrollment_info_file="$CERT_STORAGE_DIR/enrollment_${enrollment_id}_info.json"
    
    print_info "Fetching latest enrollment information..." >&2
    
    # Get enrollment details
    if http --auth-type edgegrid -a default: GET \
        "https://${EDGEGRID_HOST}/cps/v2/enrollments/${enrollment_id}" \
        accept:'application/vnd.akamai.cps.enrollment.v12+json' \
        --body > "$enrollment_info_file" 2>&1; then
        
        # Check if there are pending changes
        PENDING_CHANGES=$(jq '.pendingChanges // []' "$enrollment_info_file" 2>/dev/null)
        PENDING_COUNT=$(echo "$PENDING_CHANGES" | jq 'length' 2>/dev/null)
        
        if [ "$PENDING_COUNT" -gt 0 ]; then
            # Get the latest (first) pending change
            LATEST_CHANGE_ID=$(echo "$PENDING_CHANGES" | jq -r '.[0].location' 2>/dev/null | grep -oP '(?<=/changes/)[0-9]+' | head -1)
            LATEST_CHANGE_STATUS=$(echo "$PENDING_CHANGES" | jq -r '.[0].statusInfo.status' 2>/dev/null)
            LATEST_CHANGE_STATE=$(echo "$PENDING_CHANGES" | jq -r '.[0].statusInfo.state' 2>/dev/null)
            
            if [ -n "$LATEST_CHANGE_ID" ]; then
                print_info "✓ Found pending change:" >&2
                print_info "  Change ID: $LATEST_CHANGE_ID" >&2
                print_info "  Status: $LATEST_CHANGE_STATUS" >&2
                print_info "  State: $LATEST_CHANGE_STATE" >&2
                echo >&2
                
                # Return the change ID (to stdout for capture)
                echo "$LATEST_CHANGE_ID"
                return 0
            fi
        fi
        
        print_warning "No pending changes found for enrollment $enrollment_id" >&2
        print_info "Please initiate a renewal in the Akamai Control Center first." >&2
        return 1
    else
        print_error "Failed to fetch enrollment information" >&2
        return 1
    fi
}

# Function for renewal workflow
renewal_workflow() {
    print_info "=== Certificate Renewal Workflow ==="
    echo
    
    print_info "Checking for the latest pending change in Akamai..."
    print_info "Note: A renewal must be initiated in Akamai Control Center before running this script."
    echo
    
    # Get the latest pending change ID
    LATEST_CHANGE=$(get_latest_pending_change "$GLOBAL_ENROLLMENT_ID")
    
    if [ $? -eq 0 ] && [ -n "$LATEST_CHANGE" ]; then
        GLOBAL_CHANGE_ID="$LATEST_CHANGE"
        print_info "✓ Using latest change ID: $GLOBAL_CHANGE_ID"
        print_info "Akamai has automatically generated a CSR for this renewal."
        echo
        
        return 0
    else
        print_error "Could not find a pending renewal change."
        echo
        print_info "To renew this certificate:"
        echo "  1. Log in to Akamai Control Center"
        echo "  2. Navigate to Certificate Provisioning System"
        echo "  3. Find enrollment: $GLOBAL_ENROLLMENT_ID ($CSR_CN)"
        echo "  4. Initiate a renewal"
        echo "  5. Run this script again"
        echo
        
        return 1
    fi
}

# Main script starts here
print_info "Akamai CPS Certificate Management Script v$SCRIPT_VERSION"
echo

# Handle list mode
if [ "$MODE" = "list" ]; then
    list_configurations
    exit 0
fi

# Handle discover mode
if [ "$DISCOVER_MODE" = true ]; then
    discover_enrollments
    exit 0
fi

# ============================================================================
# STEP 1: Check and Install Prerequisites
# ============================================================================

print_info "Checking prerequisites..."

# Check for Python3
if command_exists python3; then
    print_info "Python3 is already installed: $(python3 --version)"
else
    print_warning "Python3 not found. Installing..."
    sudo apt update
    sudo apt install python3 -y
    print_info "Python3 installed successfully"
fi

# Check for pip3
if command_exists pip3; then
    print_info "pip3 is already installed: $(pip3 --version)"
else
    print_warning "pip3 not found. Installing..."
    sudo apt install python3-pip -y
    print_info "pip3 installed successfully"
fi

# Check for pipx (needed for externally-managed Python environments)
if command_exists pipx; then
    print_info "pipx is already installed"
else
    print_warning "pipx not found. Installing..."
    sudo apt install pipx -y
    pipx ensurepath
    export PATH="$PATH:$HOME/.local/bin"
    print_info "pipx installed successfully"
fi

# Check for HTTPie
if command_exists http; then
    print_info "HTTPie is already installed: $(http --version)"
else
    print_warning "HTTPie not found. Installing via pipx..."
    pipx install httpie
    export PATH="$PATH:$HOME/.local/bin"
    print_info "HTTPie installed successfully"
fi

# Check for httpie-edgegrid
if http --version 2>&1 | grep -q edgegrid || pipx list 2>/dev/null | grep -q httpie-edgegrid; then
    print_info "httpie-edgegrid plugin is already installed"
else
    print_warning "httpie-edgegrid plugin not found. Installing..."
    pipx inject httpie httpie-edgegrid
    print_info "httpie-edgegrid plugin installed successfully"
fi

# Ensure pipx bin directory is in PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    export PATH=$PATH:~/.local/bin
    if ! grep -q 'export PATH=$PATH:~/.local/bin' ~/.bashrc; then
        echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
        print_info "Added ~/.local/bin to PATH in .bashrc"
    fi
fi

# Check for jq (needed for JSON parsing)
if command_exists jq; then
    print_info "jq is already installed: $(jq --version)"
else
    print_warning "jq not found. Installing..."
    sudo apt install jq -y
    print_info "jq installed successfully"
fi

echo
print_info "All prerequisites are installed!"
echo

# Variables to store enrollment and change IDs globally
GLOBAL_ENROLLMENT_ID=""
GLOBAL_CHANGE_ID=""

# Initialize automation defaults (can be overridden by config)
CERT_TYPE_CHOICE="${CERT_TYPE_CHOICE:-RSA}"
AUTO_SUBMIT_DIGICERT="${AUTO_SUBMIT_DIGICERT:-true}"
AUTO_UPLOAD_CERT="${AUTO_UPLOAD_CERT:-true}"
AUTO_ACK_WARNINGS="${AUTO_ACK_WARNINGS:-true}"
AUTO_DEPLOY_PROD="${AUTO_DEPLOY_PROD:-true}"

# Handle renewal mode
if [ "$MODE" = "renew" ]; then
    print_info "=== RENEWAL MODE ==="
    echo
    
    # Determine config file
    if [ -n "$CONFIG_FILE" ]; then
        # Use specified config file
        CONFIG_TO_LOAD="$CONFIG_FILE"
    elif [ -n "$COMMON_NAME" ]; then
        # Look for config by common name
        CONFIG_TO_LOAD="$CONFIG_DIR/${COMMON_NAME}.json"
        if [ ! -f "$CONFIG_TO_LOAD" ]; then
            print_error "No configuration found for Common Name: $COMMON_NAME"
            print_info "Available configurations:"
            list_configurations
            exit 1
        fi
    else
        print_error "Please specify either a Common Name (--renew CN) or config file (--renew-config file)"
        exit 1
    fi
    
    # Load configuration
    if ! load_configuration "$CONFIG_TO_LOAD"; then
        exit 1
    fi
    
    # Create .edgerc if it doesn't exist
    EDGERC_PATH="$HOME/.edgerc"
    if [ ! -f "$EDGERC_PATH" ]; then
        print_info "Creating EdgeGrid configuration file..."
        cat > "$EDGERC_PATH" << EOF
[default]
client_secret = $EDGEGRID_CLIENT_SECRET
host = $EDGEGRID_HOST
access_token = $EDGEGRID_ACCESS_TOKEN
client_token = $EDGEGRID_CLIENT_TOKEN
EOF
        chmod 600 "$EDGERC_PATH"
    fi
    
    # Start renewal workflow
    if ! renewal_workflow; then
        print_error "Renewal workflow failed"
        exit 1
    fi
    
    # Skip to CSR retrieval (jump to existing workflow)
    ENROLLMENT_ID="$GLOBAL_ENROLLMENT_ID"
    CHANGE_ID="$GLOBAL_CHANGE_ID"
    
    # The rest of the script continues from here...
    
else
    # INIT MODE - Original workflow
    print_info "=== INITIALIZATION MODE ==="
    echo
    
    # ============================================================================
    # STEP 2: EdgeGrid Configuration
    # ============================================================================
    
    print_info "=== EdgeGrid Authentication Configuration ==="
    echo
    
    # Default values for EdgeGrid configuration
    DEFAULT_HOST="akab-jdvprprib6gsolke-em6xwno5rlxlhjyr.luna.akamaiapis.net"
    DEFAULT_CLIENT_SECRET="lw/S0qsb1wqGK20f9is98aAbqq/9bu0MPWMcQtwfW74="
    DEFAULT_ACCESS_TOKEN="akab-3sh5pqfo25mt5njl-ytywsb6ny7jy2elh"
    DEFAULT_CLIENT_TOKEN="akab-u5cunhz522t4vghi-aym4edz6ygloibvf"
    
    # Prompt for EdgeGrid credentials
    EDGEGRID_HOST=$(prompt_with_default "Enter Akamai API host" "$DEFAULT_HOST")
    EDGEGRID_CLIENT_SECRET=$(prompt_with_default "Enter client_secret" "$DEFAULT_CLIENT_SECRET")
    EDGEGRID_ACCESS_TOKEN=$(prompt_with_default "Enter access_token" "$DEFAULT_ACCESS_TOKEN")
    EDGEGRID_CLIENT_TOKEN=$(prompt_with_default "Enter client_token" "$DEFAULT_CLIENT_TOKEN")
    
    # Create .edgerc file
    EDGERC_PATH="$HOME/.edgerc"
    print_info "Creating EdgeGrid configuration file at $EDGERC_PATH..."
    
    cat > "$EDGERC_PATH" << EOF
[default]
client_secret = $EDGEGRID_CLIENT_SECRET
host = $EDGEGRID_HOST
access_token = $EDGEGRID_ACCESS_TOKEN
client_token = $EDGEGRID_CLIENT_TOKEN
EOF
    
    chmod 600 "$EDGERC_PATH"
    print_info "EdgeGrid configuration file created successfully with secure permissions"
    
    clear
    echo


    # ============================================================================
    # STEP 3: Storage Location Configuration
    # ============================================================================
    
    print_info "=== Storage Location Configuration ==="
    echo
    
    DEFAULT_CERT_DIR="$HOME/akamai-certs"
    
    CERT_STORAGE_DIR=$(prompt_with_default "Enter directory for certificates and CSR storage" "$DEFAULT_CERT_DIR")
    
    # Create storage directory if it doesn't exist
    if [ ! -d "$CERT_STORAGE_DIR" ]; then
        mkdir -p "$CERT_STORAGE_DIR"
        print_info "Created certificate storage directory: $CERT_STORAGE_DIR"
    fi
    
    echo
    
    # ============================================================================
    # STEP 4: Contract ID Configuration
    # ============================================================================
    
    print_info "=== Contract Configuration ==="
    echo
    
    DEFAULT_CONTRACT_ID="M-27UV417"
    CONTRACT_ID=$(prompt_with_default "Enter Contract ID" "$DEFAULT_CONTRACT_ID")
    
    echo
    
    # ============================================================================
    # STEP 5: Enrollment Configuration
    # ============================================================================
    
    print_info "=== CPS Enrollment Configuration ==="
    echo
    
    # Certificate Type
    DEFAULT_CERT_TYPE="third-party"
    CERT_TYPE=$(prompt_with_default "Certificate Type" "$DEFAULT_CERT_TYPE")
    
    # Change Management
    DEFAULT_CHANGE_MGMT="true"
    CHANGE_MGMT=$(prompt_with_default "Enable Change Management (true/false)" "$DEFAULT_CHANGE_MGMT")
    
    echo
    print_info "--- CSR Information ---"
    
    # CSR Details
    DEFAULT_CSR_CN="digicert-demo.com"
    DEFAULT_CSR_C="US"
    DEFAULT_CSR_ST="Utah"
    DEFAULT_CSR_L="Lehi"
    DEFAULT_CSR_O="Digicert"
    DEFAULT_CSR_OU="Product"
    
    CSR_CN=$(prompt_with_default "Common Name (CN)" "$DEFAULT_CSR_CN")
    CSR_C=$(prompt_with_default "Country (C)" "$DEFAULT_CSR_C")
    CSR_ST=$(prompt_with_default "State/Province (ST)" "$DEFAULT_CSR_ST")
    CSR_L=$(prompt_with_default "Locality (L)" "$DEFAULT_CSR_L")
    CSR_O=$(prompt_with_default "Organization (O)" "$DEFAULT_CSR_O")
    CSR_OU=$(prompt_with_default "Organizational Unit (OU)" "$DEFAULT_CSR_OU")
    
    echo
    print_info "--- Network Configuration ---"
    
    # Network Configuration
    DEFAULT_GEOGRAPHY="core"
    DEFAULT_QUIC="false"
    DEFAULT_SECURE_NETWORK="enhanced-tls"
    DEFAULT_SNI_ONLY="false"
    DEFAULT_MUST_HAVE_CIPHERS="ak-akamai-2020q1"
    DEFAULT_OCSP_STAPLING="on"
    DEFAULT_PREFERRED_CIPHERS="ak-akamai-2020q1"
    
    GEOGRAPHY=$(prompt_with_default "Geography" "$DEFAULT_GEOGRAPHY")
    QUIC_ENABLED=$(prompt_with_default "QUIC Enabled (true/false)" "$DEFAULT_QUIC")
    SECURE_NETWORK=$(prompt_with_default "Secure Network" "$DEFAULT_SECURE_NETWORK")
    SNI_ONLY=$(prompt_with_default "SNI Only (true/false)" "$DEFAULT_SNI_ONLY")
    MUST_HAVE_CIPHERS=$(prompt_with_default "Must Have Ciphers" "$DEFAULT_MUST_HAVE_CIPHERS")
    OCSP_STAPLING=$(prompt_with_default "OCSP Stapling (on/off)" "$DEFAULT_OCSP_STAPLING")
    PREFERRED_CIPHERS=$(prompt_with_default "Preferred Ciphers" "$DEFAULT_PREFERRED_CIPHERS")
    
    clear
    echo
    print_info "--- Registration Authority and Validation ---"
    
    # RA and Validation
    DEFAULT_RA="third-party"
    DEFAULT_VALIDATION="third-party"
    
    RA=$(prompt_with_default "Registration Authority (RA)" "$DEFAULT_RA")
    VALIDATION_TYPE=$(prompt_with_default "Validation Type" "$DEFAULT_VALIDATION")
    
    echo
    print_info "--- Admin Contact ---"
    
    # Admin Contact
    DEFAULT_ADMIN_EMAIL="michael.rudloff@digicert.com"
    DEFAULT_ADMIN_FIRSTNAME="Michael"
    DEFAULT_ADMIN_LASTNAME="Rudloff"
    DEFAULT_ADMIN_PHONE="800-896-7973"
    
    ADMIN_EMAIL=$(prompt_with_default "Admin Email" "$DEFAULT_ADMIN_EMAIL")
    ADMIN_FIRSTNAME=$(prompt_with_default "Admin First Name" "$DEFAULT_ADMIN_FIRSTNAME")
    ADMIN_LASTNAME=$(prompt_with_default "Admin Last Name" "$DEFAULT_ADMIN_LASTNAME")
    ADMIN_PHONE=$(prompt_with_default "Admin Phone" "$DEFAULT_ADMIN_PHONE")
    
    echo
    print_info "--- Technical Contact ---"
    
    # Tech Contact
    DEFAULT_TECH_EMAIL="michael.rudloff@akamai.com"
    DEFAULT_TECH_FIRSTNAME="Michael"
    DEFAULT_TECH_LASTNAME="Rudloff"
    DEFAULT_TECH_PHONE="800-896-7973"
    
    TECH_EMAIL=$(prompt_with_default "Tech Email" "$DEFAULT_TECH_EMAIL")
    TECH_FIRSTNAME=$(prompt_with_default "Tech First Name" "$DEFAULT_TECH_FIRSTNAME")
    TECH_LASTNAME=$(prompt_with_default "Tech Last Name" "$DEFAULT_TECH_LASTNAME")
    TECH_PHONE=$(prompt_with_default "Tech Phone" "$DEFAULT_TECH_PHONE")
    
    echo
    print_info "--- Organization Information ---"
    
    # Organization
    DEFAULT_ORG_NAME="Digicert Inc."
    DEFAULT_ORG_ADDR1="2801 North Thanksgiving Way Suite 500"
    DEFAULT_ORG_ADDR2=""
    DEFAULT_ORG_CITY="Lehi"
    DEFAULT_ORG_COUNTRY="US"
    DEFAULT_ORG_PHONE="1.800.896.7973"
    DEFAULT_ORG_POSTAL="84043"
    DEFAULT_ORG_REGION="Utah"
    
    ORG_NAME=$(prompt_with_default "Organization Name" "$DEFAULT_ORG_NAME")
    ORG_ADDR1=$(prompt_with_default "Address Line 1" "$DEFAULT_ORG_ADDR1")
    ORG_ADDR2=$(prompt_with_default "Address Line 2 (optional)" "$DEFAULT_ORG_ADDR2")
    ORG_CITY=$(prompt_with_default "City" "$DEFAULT_ORG_CITY")
    ORG_COUNTRY=$(prompt_with_default "Country" "$DEFAULT_ORG_COUNTRY")
    ORG_PHONE=$(prompt_with_default "Phone" "$DEFAULT_ORG_PHONE")
    ORG_POSTAL=$(prompt_with_default "Postal Code" "$DEFAULT_ORG_POSTAL")
    ORG_REGION=$(prompt_with_default "Region/State" "$DEFAULT_ORG_REGION")
    
    echo
    print_info "--- Additional Settings ---"
    
    # Seat ID for DigiCert (default to common name)
    SEAT_ID=$(prompt_with_default "Seat ID (for DigiCert certificate issuance)" "$CSR_CN")
    
    # Third Party Settings
    DEFAULT_EXCLUDE_SANS="false"
    EXCLUDE_SANS=$(prompt_with_default "Exclude SANs (true/false)" "$DEFAULT_EXCLUDE_SANS")
    
    # DigiCert API Key
    DEFAULT_DIGICERT_API_KEY="01e615c60f4e874a1a6d0d66dc_87d297ee13fb16ac4bade5b94bb6486043532397c921f665b09a1ff689c7ea5c"
    DIGICERT_API_KEY=$(prompt_with_default "Enter DigiCert API Key" "$DEFAULT_DIGICERT_API_KEY")
    
    echo
fi

# Continue from here for both init and renewal modes...

# For init mode, create and submit enrollment
if [ "$MODE" = "init" ]; then
    # ============================================================================
    # STEP 6: Create Enrollment JSON
    # ============================================================================
    
    # Generate unique enrollment filename using CN and timestamp
    if [ -z "$CSR_CN" ]; then
        print_error "Common Name (CSR_CN) is not defined. Cannot create enrollment file."
        exit 1
    fi
    
    ENROLLMENT_FILE="${CSR_CN}_enrollment_$(date +%Y%m%d_%H%M%S).json"
    ENROLLMENT_PATH="$CERT_STORAGE_DIR/$ENROLLMENT_FILE"
    
    print_info "Creating enrollment JSON at $ENROLLMENT_PATH..."
    print_debug "ENROLLMENT_FILE: $ENROLLMENT_FILE"
    print_debug "ENROLLMENT_PATH: $ENROLLMENT_PATH"
    print_debug "CERT_STORAGE_DIR: $CERT_STORAGE_DIR"
    
    # Ensure the directory exists
    if [ ! -d "$CERT_STORAGE_DIR" ]; then
        mkdir -p "$CERT_STORAGE_DIR"
        print_info "Created directory: $CERT_STORAGE_DIR"
    fi
    
    cat > "$ENROLLMENT_PATH" << EOF
{
  "certificateType": "$CERT_TYPE",
  "changeManagement": $CHANGE_MGMT,
  "csr": {
    "c": "$CSR_C",
    "cn": "$CSR_CN",
    "l": "$CSR_L",
    "o": "$CSR_O",
    "ou": "$CSR_OU",
    "st": "$CSR_ST"
  },
  "enableMultiStackedCertificates": false,
  "networkConfiguration": {
    "geography": "$GEOGRAPHY",
    "quicEnabled": $QUIC_ENABLED,
    "secureNetwork": "$SECURE_NETWORK",
    "sniOnly": $SNI_ONLY,
    "disallowedTlsVersions": ["TLSv1", "TLSv1_1"],
    "mustHaveCiphers": "$MUST_HAVE_CIPHERS",
    "ocspStapling": "$OCSP_STAPLING",
    "preferredCiphers": "$PREFERRED_CIPHERS"
  },
  "ra": "$RA",
  "validationType": "$VALIDATION_TYPE",
  "adminContact": {
    "email": "$ADMIN_EMAIL",
    "firstName": "$ADMIN_FIRSTNAME",
    "lastName": "$ADMIN_LASTNAME",
    "phone": "$ADMIN_PHONE"
  },
  "techContact": {
    "email": "$TECH_EMAIL",
    "firstName": "$TECH_FIRSTNAME",
    "lastName": "$TECH_LASTNAME",
    "phone": "$TECH_PHONE"
  },
  "org": {
    "name": "$ORG_NAME",
    "addressLineOne": "$ORG_ADDR1",
    "addressLineTwo": "$ORG_ADDR2",
    "city": "$ORG_CITY",
    "country": "$ORG_COUNTRY",
    "phone": "$ORG_PHONE",
    "postalCode": "$ORG_POSTAL",
    "region": "$ORG_REGION"
  },
  "signatureAlgorithm": null,
  "thirdParty": {
    "excludeSans": $EXCLUDE_SANS
  }
}
EOF
    
    print_info "Enrollment JSON created successfully!"
    echo
    
    # ============================================================================
    # STEP 7: API Call Configuration
    # ============================================================================
    
    print_info "=== API Call Configuration ==="
    echo
    clear
    echo
    print_info "Configuration complete! Ready to submit enrollment."
    echo
    
    # Display summary
    print_info "=== Configuration Summary ==="
    echo "EdgeGrid Config: $EDGERC_PATH"
    echo "Enrollment JSON: $ENROLLMENT_PATH"
    echo "Certificate Storage: $CERT_STORAGE_DIR"
    echo "API Host: $EDGEGRID_HOST"
    echo "Contract ID: $CONTRACT_ID"
    echo
    
    # Prompt to proceed with API call
    read -p "Do you want to submit the enrollment now? (y/n): " PROCEED
    
    if [[ "$PROCEED" =~ ^[Yy]$ ]]; then
        print_info "Submitting enrollment to Akamai CPS..."
        echo
        
        # Make the API call and capture the response
        RESPONSE_FILE="$CERT_STORAGE_DIR/enrollment_response.json"
        
        if http --auth-type edgegrid -a default: POST \
            "https://${EDGEGRID_HOST}/cps/v2/enrollments?contractId=${CONTRACT_ID}" \
            accept:'application/vnd.akamai.cps.enrollment-status.v1+json' \
            content-type:'application/vnd.akamai.cps.enrollment.v12+json' \
            < "$ENROLLMENT_PATH" --body > "$RESPONSE_FILE" 2>&1; then
            
            echo
            print_info "Enrollment submitted successfully!"
            print_info "Response saved to: $RESPONSE_FILE"
            echo
            
            # Display the response for debugging
            print_info "API Response:"
            cat "$RESPONSE_FILE"
            echo
            
            # Parse enrollment ID and change ID from response
            if [ -f "$RESPONSE_FILE" ]; then
                print_info "Parsing enrollment and change IDs from response..."
                
                # More robust parsing using different methods
                ENROLLMENT_ID=$(cat "$RESPONSE_FILE" | grep -oP '(?<=/enrollments/)[0-9]+' | head -1)
                CHANGE_ID=$(cat "$RESPONSE_FILE" | grep -oP '(?<=/changes/)[0-9]+' | head -1)
                
                # Fallback parsing method if first one fails
                if [ -z "$ENROLLMENT_ID" ]; then
                    ENROLLMENT_ID=$(grep -o '/enrollments/[0-9]*' "$RESPONSE_FILE" | grep -o '[0-9]*' | head -1)
                fi
                
                if [ -z "$CHANGE_ID" ]; then
                    CHANGE_ID=$(grep -o '/changes/[0-9]*' "$RESPONSE_FILE" | grep -o '[0-9]*' | head -1)
                fi
                
                # Store in global variables
                GLOBAL_ENROLLMENT_ID="$ENROLLMENT_ID"
                GLOBAL_CHANGE_ID="$CHANGE_ID"
                
                print_info "DEBUG: Enrollment ID = '$ENROLLMENT_ID'"
                print_info "DEBUG: Change ID = '$CHANGE_ID'"
                echo
            fi
        else
            echo
            print_error "Failed to submit enrollment. Please check the error message above."
            exit 1
        fi
    else
        print_info "Enrollment not submitted. Exiting."
        exit 0
    fi
fi

# Continue with the rest of the workflow (CSR retrieval, certificate issuance, etc.)
# This part is common to both init and renewal modes

if [ -n "$ENROLLMENT_ID" ] && [ -n "$CHANGE_ID" ]; then
    echo
    print_info "✓ Enrollment ID: $ENROLLMENT_ID"
    print_info "✓ Change ID: $CHANGE_ID"
    echo
    
    # Save configuration if in init mode and save is enabled
    if [ "$MODE" = "init" ] && [ "$SAVE_CONFIG" = true ]; then
        CONFIG_FILE="$CONFIG_DIR/${CSR_CN}_enrollment_${ENROLLMENT_ID}_$(date +%Y%m%d_%H%M%S).json"
        save_configuration "$CONFIG_FILE" "$ENROLLMENT_ID" "$CHANGE_ID"
    fi
    
    # Automatically poll for CSR availability
    print_info "Waiting for CSR to become available..."
    print_info "Polling every 10 seconds (max 10 minutes)..."
    echo
    
    CSR_JSON_FILE="$CERT_STORAGE_DIR/${CSR_CN}_enrollment_${ENROLLMENT_ID}_csr_response.json"
    MAX_ATTEMPTS=60  # 30 attempts × 10 seconds = 5 minutes
    ATTEMPT=0
    CSR_AVAILABLE=false
    
    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        ATTEMPT=$((ATTEMPT + 1))
        print_info "Attempt $ATTEMPT/$MAX_ATTEMPTS - Checking CSR availability..."
        
        # Try to retrieve the CSR
        if http --auth-type edgegrid -a default: GET \
            "https://${EDGEGRID_HOST}/cps/v2/enrollments/${ENROLLMENT_ID}/changes/${CHANGE_ID}/input/info/third-party-csr" \
            accept:'application/vnd.akamai.cps.csr.v2+json' \
            --body > "$CSR_JSON_FILE" 2>&1; then
            
            # Check if response contains CSR data
            if grep -q '"csrs"' "$CSR_JSON_FILE"; then
                CSR_AVAILABLE=true
                echo
                print_info "✓ CSR is now available!"
                break
            else
                # Check if it's a "not found" or still processing
                if grep -q '"type".*"not-found"' "$CSR_JSON_FILE" || grep -q '"title".*"Not Found"' "$CSR_JSON_FILE"; then
                    echo "   Status: CSR not ready yet, waiting 10 seconds..."
                else
                    echo "   Status: Enrollment still processing, waiting 10 seconds..."
                fi
            fi
        fi
        
        # Wait 10 seconds before next attempt (unless this was the last attempt)
        if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
            sleep 10
        fi
    done
    
    echo
    
    if [ "$CSR_AVAILABLE" = true ]; then
        print_info "CSR retrieved successfully!"
        print_info "Full CSR response saved to: $CSR_JSON_FILE"
        echo
        
        # Verify jq is available
        if ! command_exists jq; then
            print_warning "jq not found. Installing..."
            sudo apt install jq -y
        fi
        
        # Use jq to parse the array of CSRs
        CSR_COUNT=$(jq '.csrs | length' "$CSR_JSON_FILE" 2>/dev/null)
        print_info "Found $CSR_COUNT CSR(s)"
        echo
        
        for ((i=0; i<$CSR_COUNT; i++)); do
            KEY_ALGO=$(jq -r ".csrs[$i].keyAlgorithm" "$CSR_JSON_FILE" 2>/dev/null)
            CSR_CONTENT=$(jq -r ".csrs[$i].csr" "$CSR_JSON_FILE" 2>/dev/null)
            
            CSR_FILE_ALGO="$CERT_STORAGE_DIR/${CSR_CN}_enrollment_${ENROLLMENT_ID}_${KEY_ALGO}.csr"
            
            print_info "Extracting $KEY_ALGO CSR..."
            
            # Save CSR content to file
            echo "$CSR_CONTENT" > "$CSR_FILE_ALGO"
            
            if [ -s "$CSR_FILE_ALGO" ] && grep -q "BEGIN CERTIFICATE REQUEST" "$CSR_FILE_ALGO"; then
                print_info "✓ CSR File Created ($KEY_ALGO)"
                echo "   File: $CSR_FILE_ALGO"
                echo "   Size: $(wc -c < "$CSR_FILE_ALGO") bytes"
                echo
                echo "  Preview:"
                echo "  ----------------------------------------"
                head -n 3 "$CSR_FILE_ALGO" | sed 's/^/  /'
                echo "  ..."
                tail -n 2 "$CSR_FILE_ALGO" | sed 's/^/  /'
                echo "  ----------------------------------------"
                
                # Display CSR details if openssl is available
                if command_exists openssl; then
                    echo
                    echo "  CSR Details:"
                    openssl req -in "$CSR_FILE_ALGO" -noout -text 2>/dev/null | grep -E "Subject:|Public Key Algorithm:" | sed 's/^/  /' || echo "  (Could not parse with openssl)"
                fi
                echo
            else
                print_error "Failed to create valid CSR file for $KEY_ALGO"
                print_info "Debugging - File size: $(ls -lh "$CSR_FILE_ALGO" 2>/dev/null || echo 'file not created')"
                print_info "Debugging - First few chars: $(head -c 50 "$CSR_FILE_ALGO" 2>/dev/null || echo 'cannot read')"
            fi
        done
        
        echo
        print_info "CSR extraction complete!"
        print_info "Files saved to: $CERT_STORAGE_DIR"
        echo
        
        # Create single-line string versions for API calls
        echo
        print_info "Creating single-line string versions for API calls..."
        echo
        
        # Only process CSR files from the current enrollment
        for csr_file in "$CERT_STORAGE_DIR"/${CSR_CN}_enrollment_${ENROLLMENT_ID}_*.csr; do
            if [ -f "$csr_file" ]; then
                # Get the base name without extension
                base_name=$(basename "$csr_file" .csr)
                
                # Create single-line version (replace newlines with \n literal string)
                single_line_file="${csr_file%.csr}_single_line.txt"
                
                # Convert CSR to single line with escaped newlines
                awk '{printf "%s\\n", $0}' "$csr_file" | sed 's/\\n$//' > "$single_line_file"
                
                if [ -s "$single_line_file" ]; then
                    print_info "✓ Single-line version created: $single_line_file"
                    echo "   Size: $(wc -c < "$single_line_file") characters"
                    echo "   Preview: $(head -c 80 "$single_line_file")..."
                    echo
                fi
            fi
        done
        
        echo
        print_info "All single-line CSR strings created!"
        print_info "These files can be used directly in JSON API payloads"
        
        # ============================================================================
        # STEP 7: DigiCert Certificate Issuance
        # ============================================================================
        
        echo
        clear
        print_info "=== DigiCert Certificate Issuance ==="
        echo
        
        # Variables to store certificate details
        ISSUED_CERT_FILE=""
        ISSUED_CERT_TYPE=""
        
        # Find RSA and ECDSA CSR files
        RSA_CSR_FILE=""
        ECDSA_CSR_FILE=""
        
        for csr_file in "$CERT_STORAGE_DIR"/${CSR_CN}_enrollment_${ENROLLMENT_ID}_*.csr; do
            if [ -f "$csr_file" ]; then
                if [[ "$csr_file" == *"RSA"* ]]; then
                    RSA_CSR_FILE="$csr_file"
                elif [[ "$csr_file" == *"ECDSA"* ]]; then
                    ECDSA_CSR_FILE="$csr_file"
                fi
            fi
        done
        
        # Check if both CSRs were found
        if [ -z "$RSA_CSR_FILE" ] || [ -z "$ECDSA_CSR_FILE" ]; then
            print_warning "Could not find both RSA and ECDSA CSR files."
            print_info "RSA CSR: ${RSA_CSR_FILE:-Not found}"
            print_info "ECDSA CSR: ${ECDSA_CSR_FILE:-Not found}"
        else
            print_info "Found CSR files:"
            print_info "RSA CSR: $RSA_CSR_FILE"
            print_info "ECDSA CSR: $ECDSA_CSR_FILE"
            echo

            # Determine certificate type based on AUTO_MODE or config
            if [ "$AUTO_MODE" = true ]; then
                # Use certificate type from config
                if [ "$CERT_TYPE_CHOICE" = "ECDSA" ]; then
                    CSR_CHOICE="2"
                else
                    CSR_CHOICE="1"
                fi
                print_info "Auto mode: Using certificate type from config: $CERT_TYPE_CHOICE"
            else
                # Ask which CSR type to use
                echo "Which certificate type would you like to issue?"
                echo "1) RSA"
                echo "2) ECDSA"
                read -p "Enter your choice (1 or 2): " CSR_CHOICE
            fi

            # Set profile ID and CSR file based on choice
            if [ "$CSR_CHOICE" = "1" ]; then
                PROFILE_ID="f1887d29-ee87-48f7-a873-1a0254dc99a9"
                SELECTED_CSR_FILE="$RSA_CSR_FILE"
                CERT_TYPE_NAME="RSA"
                ISSUED_CERT_TYPE="RSA"
                print_info "Selected: RSA certificate"
                print_info "Using Profile ID: $PROFILE_ID"
            elif [ "$CSR_CHOICE" = "2" ]; then
                PROFILE_ID="8b566220-8e48-4b44-bf4c-20434f4f95c1"
                SELECTED_CSR_FILE="$ECDSA_CSR_FILE"
                CERT_TYPE_NAME="ECDSA"
                ISSUED_CERT_TYPE="ECDSA"
                print_info "Selected: ECDSA certificate"
                print_info "Using Profile ID: $PROFILE_ID"
            else
                print_error "Invalid choice. Skipping DigiCert certificate issuance."
                SELECTED_CSR_FILE=""
            fi
            
            if [ -n "$SELECTED_CSR_FILE" ]; then
                # Prompt for DigiCert API key if not already set
                if [ -z "$DIGICERT_API_KEY" ]; then
                    DEFAULT_DIGICERT_API_KEY="01e615c60f4e874a1a6d0d66dc_87d297ee13fb16ac4bade5b94bb6486043532397c921f665b09a1ff689c7ea5c"
                    echo
                    DIGICERT_API_KEY=$(prompt_with_default "Enter DigiCert API Key" "$DEFAULT_DIGICERT_API_KEY")
                fi
                
                # Read the CSR content and convert to single-line format for JSON
                CSR_CONTENT_RAW=$(cat "$SELECTED_CSR_FILE")
                # Convert to single-line with \n literals for JSON
                CSR_CONTENT=$(echo "$CSR_CONTENT_RAW" | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')
                
                # Create the request JSON
                DIGICERT_REQUEST_FILE="$CERT_STORAGE_DIR/digicert_request_${CERT_TYPE_NAME}.json"
                
                print_info "Creating DigiCert certificate request..."
                
                cat > "$DIGICERT_REQUEST_FILE" << EOF
{
  "profile": {
    "id": "$PROFILE_ID"
  },
  "seat": {
    "seat_id": "$SEAT_ID"
  },
  "csr": "$CSR_CONTENT",
  "attributes": {
    "subject": {
      "common_name": "$CSR_CN"
    }
  },
  "org": {
    "name": "$ORG_NAME",
    "addressLineOne": "$ORG_ADDR1",
    "addressLineTwo": "$ORG_ADDR2",
    "city": "$ORG_CITY",
    "country": "$ORG_COUNTRY",
    "phone": "$ORG_PHONE",
    "postalCode": "$ORG_POSTAL",
    "region": "$ORG_REGION"
  }
}
EOF
                
                print_info "Request JSON created at: $DIGICERT_REQUEST_FILE"
                echo
                
                # Display summary before submission
                print_info "=== DigiCert Certificate Request Summary ==="
                echo "Certificate Type: $CERT_TYPE_NAME"
                echo "Profile ID: $PROFILE_ID"
                echo "Seat ID: $SEAT_ID"
                echo "Common Name: $CSR_CN"
                echo "Organization: $ORG_NAME"
                echo

                # Determine whether to proceed based on AUTO_MODE or config
                if [ "$AUTO_MODE" = true ]; then
                    if [ "$AUTO_SUBMIT_DIGICERT" = "true" ]; then
                        PROCEED_DIGICERT="y"
                        print_info "Auto mode: Submitting certificate request to DigiCert automatically"
                    else
                        PROCEED_DIGICERT="n"
                        print_info "Auto mode: Skipping DigiCert submission (disabled in config)"
                    fi
                else
                    # Prompt to proceed with DigiCert API call
                    read -p "Submit certificate request to DigiCert? (y/n): " PROCEED_DIGICERT
                fi

                if [[ "$PROCEED_DIGICERT" =~ ^[Yy]$ ]]; then
                    print_info "Submitting certificate request to DigiCert..."
                    echo
                    
                    # Make the API call to DigiCert
                    DIGICERT_RESPONSE_FILE="$CERT_STORAGE_DIR/digicert_response_${CERT_TYPE_NAME}.json"
                    
                    if curl --location 'https://demo.one.digicert.com/mpki/api/v1/certificate' \
                        --header 'Content-Type: application/json' \
                        --header "x-api-key: $DIGICERT_API_KEY" \
                        --data "@$DIGICERT_REQUEST_FILE" \
                        --output "$DIGICERT_RESPONSE_FILE" \
                        --write-out "\nHTTP Status: %{http_code}\n" 2>/dev/null; then
                        
                        echo
                        print_info "DigiCert API call completed!"
                        print_info "Response saved to: $DIGICERT_RESPONSE_FILE"
                        echo
                        
                        # Check if response contains a certificate
                        if [ -f "$DIGICERT_RESPONSE_FILE" ] && [ -s "$DIGICERT_RESPONSE_FILE" ]; then
                            # Try to extract certificate from response using jq
                            if command_exists jq; then
                                CERT_CONTENT=$(jq -r '.certificate // empty' "$DIGICERT_RESPONSE_FILE" 2>/dev/null)
                                
                                if [ -n "$CERT_CONTENT" ]; then
                                    print_info "Certificate found in response! Extracting..."
                                    
                                    # Save certificate to file
                                    CERT_FILE="$CERT_STORAGE_DIR/${CSR_CN}_${CERT_TYPE_NAME}_certificate.pem"
                                    ISSUED_CERT_FILE="$CERT_FILE"
                                    echo "$CERT_CONTENT" > "$CERT_FILE"
                                    
                                    if [ -s "$CERT_FILE" ]; then
                                        print_info "✓ Certificate saved to: $CERT_FILE"
                                        echo
                                        
                                        # Display certificate details if openssl is available
                                        if command_exists openssl; then
                                            print_info "Certificate Details:"
                                            openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -E "Subject:|Issuer:|Not Before:|Not After:|Serial Number:" | sed 's/^/  /' || echo "  (Could not parse with openssl)"
                                        fi
                                        
                                        # Extract certificate details for summary
                                        CERT_SERIAL=""
                                        CERT_EXPIRY=""
                                        CERT_CN=""
                                        
                                        if command_exists openssl; then
                                            # Extract serial number (remove spaces and colons)
                                            CERT_SERIAL=$(openssl x509 -in "$CERT_FILE" -noout -serial 2>/dev/null | cut -d'=' -f2)
                                            if [ -z "$CERT_SERIAL" ]; then
                                                # Alternative method: extract from text output
                                                CERT_SERIAL=$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -A1 "Serial Number:" | tail -1 | tr -d ' :')
                                            fi
                                            
                                            # Extract expiration date
                                            CERT_EXPIRY=$(openssl x509 -in "$CERT_FILE" -noout -enddate 2>/dev/null | cut -d'=' -f2)
                                            
                                            # Extract subject CN
                                            CERT_CN=$(openssl x509 -in "$CERT_FILE" -noout -subject 2>/dev/null | grep -o 'CN[[:space:]]*=[[:space:]]*[^,/]*' | cut -d'=' -f2 | sed 's/^[[:space:]]*//')
                                        fi
                                        
                                        # Also try to extract serial number from DigiCert response
                                        SERIAL_NUMBER=$(jq -r '.serial_number // empty' "$DIGICERT_RESPONSE_FILE" 2>/dev/null)
                                        if [ -z "$SERIAL_NUMBER" ]; then
                                            # Try alternative field names
                                            SERIAL_NUMBER=$(jq -r '.serialNumber // empty' "$DIGICERT_RESPONSE_FILE" 2>/dev/null)
                                        fi
                                        if [ -z "$SERIAL_NUMBER" ]; then
                                            SERIAL_NUMBER=$(jq -r '.id // empty' "$DIGICERT_RESPONSE_FILE" 2>/dev/null)
                                        fi
                                        
                                        echo
                                        print_info "========================================="
                                        print_info "     CERTIFICATE ISSUANCE SUCCESSFUL     "
                                        print_info "========================================="
                                        echo
                                        
                                        # Display summary
                                        echo "  Certificate Type:    $CERT_TYPE_NAME"
                                        echo "  Common Name:         ${CERT_CN:-$CSR_CN}"
                                        
                                        # Show serial number from certificate or from JSON response
                                        if [ -n "$CERT_SERIAL" ]; then
                                            echo "  Serial Number:       $CERT_SERIAL"
                                        elif [ -n "$SERIAL_NUMBER" ]; then
                                            echo "  Certificate ID:      $SERIAL_NUMBER"
                                        else
                                            echo "  Serial Number:       (unable to extract)"
                                        fi
                                        
                                        if [ -n "$CERT_EXPIRY" ]; then
                                            echo "  Expiration Date:     $CERT_EXPIRY"
                                        fi
                                        
                                        echo "  Certificate File:    $(basename "$CERT_FILE")"
                                        echo "  Storage Location:    $CERT_STORAGE_DIR"
                                        echo
                                        
                                        # ============================================================================
                                        # STEP 8: Intermediate Authority Certificate Processing
                                        # ============================================================================
                                        
                                        echo
                                        print_info "=== Intermediate Authority Certificate Processing ==="
                                        echo
                                        
                                        # Variable to store ICA certificate content
                                        ICA_CERT_CONTENT=""

                                        # Determine ICA file based on AUTO_MODE or config
                                        if [ "$AUTO_MODE" = true ]; then
                                            # In auto mode, use config value or default location
                                            if [ -z "$ICA_FILE" ]; then
                                                ICA_FILE="$CERT_STORAGE_DIR/rudloff-ica.pem"
                                                print_info "Auto mode: Using default ICA file location: $ICA_FILE"
                                            else
                                                print_info "Auto mode: Using ICA file from config: $ICA_FILE"
                                            fi
                                        elif [ -z "$ICA_FILE" ]; then
                                            # Interactive mode - prompt for ICA certificate file
                                            DEFAULT_ICA_FILE="$CERT_STORAGE_DIR/rudloff-ica.pem"
                                            ICA_FILE=$(prompt_with_default "Enter Intermediate Authority Certificate file location" "$DEFAULT_ICA_FILE")
                                        fi

                                        if [ -f "$ICA_FILE" ]; then
                                            print_info "ICA certificate file found: $ICA_FILE"
                                            
                                            # Convert to single-line with \n literals
                                            ICA_CERT_CONTENT=$(awk '{printf "%s\\n", $0}' "$ICA_FILE" | sed 's/\\n$//')
                                            
                                            # Display ICA certificate details if openssl is available
                                            if command_exists openssl; then
                                                echo
                                                print_info "ICA Certificate Details:"
                                                openssl x509 -in "$ICA_FILE" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /' || echo "  (Could not parse with openssl)"
                                            fi
                                            
                                            # ============================================================================
                                            # STEP 9: Upload Certificate to Akamai
                                            # ============================================================================
                                            
                                            echo
                                            print_info "=== Upload Certificate to Akamai CPS ==="
                                            echo
                                            
                                            if [ -n "$ISSUED_CERT_FILE" ] && [ -f "$ISSUED_CERT_FILE" ] && [ -n "$ICA_CERT_CONTENT" ]; then
                                                print_info "Preparing certificate upload to Akamai..."
                                                echo
                                                print_info "Using:"
                                                print_info "  - Certificate: $(basename "$ISSUED_CERT_FILE")"
                                                print_info "  - Trust Chain: $(basename "$ICA_FILE")"
                                                print_info "  - Algorithm: $ISSUED_CERT_TYPE"
                                                print_info "  - Enrollment ID: $GLOBAL_ENROLLMENT_ID"
                                                print_info "  - Change ID: $GLOBAL_CHANGE_ID"
                                                echo
                                                
                                                # Read the issued certificate and convert to single-line format
                                                ISSUED_CERT_CONTENT=$(awk '{printf "%s\\n", $0}' "$ISSUED_CERT_FILE" | sed 's/\\n$//')
                                                
                                                # Create cert-import.json file
                                                CERT_IMPORT_FILE="$CERT_STORAGE_DIR/cert-import.json"
                                                
                                                print_info "Creating certificate import JSON..."
                                                
                                                cat > "$CERT_IMPORT_FILE" << EOF
{
  "certificatesAndTrustChains": [
    {
      "certificate": "$ISSUED_CERT_CONTENT",
      "keyAlgorithm": "$ISSUED_CERT_TYPE",
      "trustChain": "$ICA_CERT_CONTENT"
    }
  ]
}
EOF
                                                
                                                if [ -s "$CERT_IMPORT_FILE" ]; then
                                                    print_info "✓ Certificate import JSON created: $CERT_IMPORT_FILE"
                                                    echo

                                                    # Determine whether to upload based on AUTO_MODE or config
                                                    if [ "$AUTO_MODE" = true ]; then
                                                        if [ "$AUTO_UPLOAD_CERT" = "true" ]; then
                                                            PROCEED_UPLOAD="y"
                                                            print_info "Auto mode: Uploading certificate to Akamai automatically"
                                                        else
                                                            PROCEED_UPLOAD="n"
                                                            print_info "Auto mode: Skipping certificate upload (disabled in config)"
                                                        fi
                                                    else
                                                        # Prompt to upload certificate to Akamai
                                                        read -p "Upload certificate to Akamai CPS? (y/n): " PROCEED_UPLOAD
                                                    fi

                                                    if [[ "$PROCEED_UPLOAD" =~ ^[Yy]$ ]]; then
                                                        print_info "Uploading certificate to Akamai CPS..."
                                                        echo
                                                        
                                                        # Make the API call to upload certificate
                                                        UPLOAD_RESPONSE_FILE="$CERT_STORAGE_DIR/certificate_upload_response.json"
                                                        
                                                        if http --auth-type edgegrid -a default: POST \
                                                            "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${GLOBAL_CHANGE_ID}/input/update/third-party-cert-and-trust-chain" \
                                                            accept:'application/vnd.akamai.cps.change-id.v1+json' \
                                                            content-type:'application/vnd.akamai.cps.certificate-and-trust-chain.v2+json' \
                                                            < "$CERT_IMPORT_FILE" --body > "$UPLOAD_RESPONSE_FILE" 2>&1; then
                                                            
                                                            echo
                                                            print_info "✓ Certificate uploaded successfully to Akamai!"
                                                            print_info "Response saved to: $UPLOAD_RESPONSE_FILE"
                                                            echo
                                                            
                                                            # Try to parse the new change ID if present
                                                            if [ -f "$UPLOAD_RESPONSE_FILE" ]; then
                                                                NEW_CHANGE_ID=$(grep -oP '(?<="change":|/changes/)[0-9]+' "$UPLOAD_RESPONSE_FILE" | head -1)
                                                                if [ -n "$NEW_CHANGE_ID" ]; then
                                                                    print_info "New Change ID created: $NEW_CHANGE_ID"
                                                                    CURRENT_CHANGE_ID="$NEW_CHANGE_ID"
                                                                    echo
                                                                else
                                                                    CURRENT_CHANGE_ID="$GLOBAL_CHANGE_ID"
                                                                fi
                                                            fi
                                                            
                                                            # ============================================================================
                                                            # STEP 10: Check for Post-Deployment Warnings with Polling
                                                            # ============================================================================
                                                            
                                                            echo
                                                            print_info "=== Checking for Post-Deployment Warnings ==="
                                                            echo
                                                            
                                                            print_info "Waiting for post-verification warnings to be generated..."
                                                            print_info "Polling every 10 seconds (max 1 minute)..."
                                                            echo
                                                            
                                                            # Polling configuration
                                                            MAX_POLL_ATTEMPTS=6  # 6 attempts × 10 seconds = 60 seconds
                                                            POLL_INTERVAL=10     # seconds between attempts
                                                            POLL_ATTEMPT=0
                                                            WARNINGS_FOUND=false
                                                            
                                                            # Variables for storing warnings
                                                            WARNINGS_RESPONSE_FILE="$CERT_STORAGE_DIR/post_verification_warnings.json"
                                                            WARNINGS_TEXT_FILE="$CERT_STORAGE_DIR/post_verification_warnings.txt"
                                                            WARNINGS_CONTENT=""
                                                            
                                                            # Polling loop
                                                            while [ $POLL_ATTEMPT -lt $MAX_POLL_ATTEMPTS ]; do
                                                                POLL_ATTEMPT=$((POLL_ATTEMPT + 1))
                                                                print_info "Attempt $POLL_ATTEMPT/$MAX_POLL_ATTEMPTS - Checking for post-verification warnings..."
                                                                
                                                                # Make the API call to check for warnings
                                                                if http --auth-type edgegrid -a default: GET \
                                                                    "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}/input/info/post-verification-warnings" \
                                                                    accept:'application/vnd.akamai.cps.warnings.v1+json' \
                                                                    --body > "$WARNINGS_RESPONSE_FILE" 2>&1; then
                                                                    
                                                                    # Extract warnings using jq
                                                                    WARNINGS_CONTENT=$(jq -r '.warnings // empty' "$WARNINGS_RESPONSE_FILE" 2>/dev/null)
                                                                    
                                                                    # Check if warnings are found
                                                                    if [ -n "$WARNINGS_CONTENT" ] && [ "$WARNINGS_CONTENT" != "null" ] && [ "$WARNINGS_CONTENT" != "[]" ]; then
                                                                        WARNINGS_FOUND=true
                                                                        echo "   Status: Warnings detected!"
                                                                        break
                                                                    else
                                                                        echo "   Status: No warnings detected yet..."
                                                                    fi
                                                                else
                                                                    echo "   Status: API call failed, will retry..."
                                                                fi
                                                                
                                                                # Wait before next attempt
                                                                if [ $POLL_ATTEMPT -lt $MAX_POLL_ATTEMPTS ] && [ "$WARNINGS_FOUND" = false ]; then
                                                                    sleep $POLL_INTERVAL
                                                                fi
                                                            done
                                                            
                                                            echo
                                                            
                                                            # Process the results
                                                            if [ "$WARNINGS_FOUND" = true ]; then
                                                                print_warning "Post-verification warnings found!"
                                                                echo "$WARNINGS_CONTENT"
                                                                echo

                                                                # Determine whether to acknowledge based on AUTO_MODE or config
                                                                if [ "$AUTO_MODE" = true ]; then
                                                                    if [ "$AUTO_ACK_WARNINGS" = "true" ]; then
                                                                        ACKNOWLEDGE_WARNINGS="y"
                                                                        print_info "Auto mode: Acknowledging warnings automatically"
                                                                    else
                                                                        ACKNOWLEDGE_WARNINGS="n"
                                                                        print_info "Auto mode: Skipping warning acknowledgement (disabled in config)"
                                                                    fi
                                                                else
                                                                    # Prompt to acknowledge warnings
                                                                    read -p "Do you want to acknowledge these warnings? (y/n): " ACKNOWLEDGE_WARNINGS
                                                                fi

                                                                if [[ "$ACKNOWLEDGE_WARNINGS" =~ ^[Yy]$ ]]; then
                                                                    print_info "Acknowledging warnings..."
                                                                    
                                                                    # Create acknowledge.json
                                                                    ACKNOWLEDGE_FILE="$CERT_STORAGE_DIR/acknowledge.json"
                                                                    
                                                                    cat > "$ACKNOWLEDGE_FILE" << 'EOF'
{
  "acknowledgement": "acknowledge"
}
EOF
                                                                    
                                                                    # Submit acknowledgement
                                                                    ACKNOWLEDGE_RESPONSE_FILE="$CERT_STORAGE_DIR/acknowledgement_response.json"
                                                                    
                                                                    if http --auth-type edgegrid -a default: POST \
                                                                        "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}/input/update/post-verification-warnings-ack" \
                                                                        accept:'application/vnd.akamai.cps.change-id.v1+json' \
                                                                        content-type:'application/vnd.akamai.cps.acknowledgement.v1+json' \
                                                                        < "$ACKNOWLEDGE_FILE" --body > "$ACKNOWLEDGE_RESPONSE_FILE" 2>&1; then
                                                                        
                                                                        echo
                                                                        print_info "✓ Warnings acknowledged successfully!"
                                                                        
                                                                        # Try to parse any new change ID from acknowledgement response
                                                                        if [ -f "$ACKNOWLEDGE_RESPONSE_FILE" ]; then
                                                                            ACK_CHANGE_ID=$(grep -oP '(?<="change":|/changes/)[0-9]+' "$ACKNOWLEDGE_RESPONSE_FILE" | head -1)
                                                                            if [ -n "$ACK_CHANGE_ID" ]; then
                                                                                print_info "New Change ID after acknowledgement: $ACK_CHANGE_ID"
                                                                                CURRENT_CHANGE_ID="$ACK_CHANGE_ID"
                                                                            fi
                                                                        fi
                                                                    else
                                                                        print_error "Failed to acknowledge warnings."
                                                                    fi
                                                                fi
                                                            else
                                                                print_info "✓ No post-verification warnings detected."
                                                            fi
                                                            
                                                            # ============================================================================
                                                            # STEP 11: Deploy Certificate to Production
                                                            # ============================================================================
                                                            
                                                            echo
                                                            print_info "=== Production Deployment ==="
                                                            echo

                                                            # Determine whether to deploy based on AUTO_MODE or config
                                                            if [ "$AUTO_MODE" = true ]; then
                                                                if [ "$AUTO_DEPLOY_PROD" = "true" ]; then
                                                                    DEPLOY_TO_PROD="y"
                                                                    print_info "Auto mode: Deploying to production automatically"
                                                                else
                                                                    DEPLOY_TO_PROD="n"
                                                                    print_info "Auto mode: Skipping production deployment (disabled in config)"
                                                                fi
                                                            else
                                                                read -p "Do you want to deploy the certificate to production? (y/n): " DEPLOY_TO_PROD
                                                            fi

                                                            if [[ "$DEPLOY_TO_PROD" =~ ^[Yy]$ ]]; then
                                                                print_info "Starting production deployment process..."
                                                                echo
                                                                print_info "Checking enrollment status for change management requirements..."
                                                                print_info "Polling every 10 seconds (max 10 minutes)..."
                                                                echo
                                                                
                                                                # Polling configuration
                                                                PROD_MAX_ATTEMPTS=60  # 30 attempts × 10 seconds = 5 minutes
                                                                PROD_POLL_INTERVAL=10  # seconds between attempts
                                                                PROD_ATTEMPT=0
                                                                CHANGE_MGMT_REQUIRED=false
                                                                
                                                                # Status check file
                                                                PROD_STATUS_FILE="$CERT_STORAGE_DIR/production_status.json"
                                                                
                                                                while [ $PROD_ATTEMPT -lt $PROD_MAX_ATTEMPTS ]; do
                                                                    PROD_ATTEMPT=$((PROD_ATTEMPT + 1))
                                                                    print_info "Attempt $PROD_ATTEMPT/$PROD_MAX_ATTEMPTS - Checking enrollment status..."
                                                                    
                                                                    # Make the API call to check status
                                                                    if http --auth-type edgegrid -a default: GET \
                                                                        "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}" \
                                                                        accept:'application/vnd.akamai.cps.change.v2+json' \
                                                                        --body > "$PROD_STATUS_FILE" 2>&1; then
                                                                        
                                                                        # Check if allowedInput contains change-management
                                                                        ALLOWED_INPUT=$(jq -r '.allowedInput // []' "$PROD_STATUS_FILE" 2>/dev/null)
                                                                        
                                                                        if echo "$ALLOWED_INPUT" | grep -q "change-management"; then
                                                                            CHANGE_MGMT_REQUIRED=true
                                                                            echo "   Status: Change management acknowledgement required!"
                                                                            break
                                                                        else
                                                                            # Check current status
                                                                            STATUS_STATE=$(jq -r '.statusInfo.state // empty' "$PROD_STATUS_FILE" 2>/dev/null)
                                                                            STATUS_DESC=$(jq -r '.statusInfo.status // empty' "$PROD_STATUS_FILE" 2>/dev/null)
                                                                            
                                                                            echo "   Status: $STATUS_STATE - $STATUS_DESC"
                                                                            
                                                                            if [ "$ALLOWED_INPUT" = "[]" ]; then
                                                                                echo "   Waiting for change management to become available..."
                                                                            fi
                                                                        fi
                                                                    else
                                                                        echo "   Status: API call failed, will retry..."
                                                                    fi
                                                                    
                                                                    # Wait before next attempt
                                                                    if [ $PROD_ATTEMPT -lt $PROD_MAX_ATTEMPTS ] && [ "$CHANGE_MGMT_REQUIRED" = false ]; then
                                                                        sleep $PROD_POLL_INTERVAL
                                                                    fi
                                                                done
                                                                
                                                                echo
                                                                
                                                                if [ "$CHANGE_MGMT_REQUIRED" = true ]; then
                                                                    print_info "✓ Change management is ready to be acknowledged!"
                                                                    echo
                                                                    
                                                                    # Create acknowledgment file
                                                                    PROD_ACKNOWLEDGE_FILE="$CERT_STORAGE_DIR/prod_acknowledge.json"
                                                                    
                                                                    cat > "$PROD_ACKNOWLEDGE_FILE" << 'EOF'
{
    "acknowledgement": "acknowledge"
}
EOF
                                                                    
                                                                    # Submit acknowledgement
                                                                    print_info "Acknowledging production deployment..."
                                                                    PROD_ACK_RESPONSE_FILE="$CERT_STORAGE_DIR/prod_acknowledgement_response.json"
                                                                    
                                                                    if http --auth-type edgegrid -a default: POST \
                                                                        "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}/input/update/change-management-ack" \
                                                                        accept:'application/vnd.akamai.cps.change-id.v1+json' \
                                                                        content-type:'application/vnd.akamai.cps.acknowledgement.v1+json' \
                                                                        < "$PROD_ACKNOWLEDGE_FILE" --body > "$PROD_ACK_RESPONSE_FILE" 2>&1; then
                                                                        
                                                                        echo
                                                                        print_info "✓ Production deployment acknowledged successfully!"
                                                                        print_info "The certificate deployment to production has been initiated."
                                                                        echo

                                                                        # Determine whether to monitor deployment based on AUTO_MODE
                                                                        if [ "$AUTO_MODE" = true ]; then
                                                                            MONITOR_DEPLOYMENT="n"
                                                                            print_info "Auto mode: Skipping production deployment monitoring"
                                                                            print_info "Production deployment has been initiated and will complete in the background."
                                                                            echo
                                                                        else
                                                                            # Ask if user wants to monitor deployment status
                                                                            read -p "Do you want to monitor the deployment status? (y/n): " MONITOR_DEPLOYMENT
                                                                        fi

                                                                        if [[ "$MONITOR_DEPLOYMENT" =~ ^[Yy]$ ]]; then
                                                                            print_info "Monitoring deployment status..."
                                                                            print_info "Checking every 60 seconds. Press Ctrl+C to cancel monitoring."
                                                                            echo
                                                                            
                                                                            # Deployment monitoring loop
                                                                            DEPLOY_STATUS_FILE="$CERT_STORAGE_DIR/deployment_status.json"
                                                                            DEPLOY_COMPLETE=false
                                                                            DEPLOY_CHECK_COUNT=0
                                                                            
                                                                            while [ "$DEPLOY_COMPLETE" = false ]; do
                                                                                DEPLOY_CHECK_COUNT=$((DEPLOY_CHECK_COUNT + 1))
                                                                                
                                                                                print_info "Check #$DEPLOY_CHECK_COUNT - Retrieving deployment status..."
                                                                                
                                                                                if http --auth-type edgegrid -a default: GET \
                                                                                    "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}" \
                                                                                    accept:'application/vnd.akamai.cps.change.v2+json' \
                                                                                    --body > "$DEPLOY_STATUS_FILE" 2>&1; then
                                                                                    
                                                                                    # Extract status information
                                                                                    DEPLOY_STATUS=$(jq -r '.statusInfo.status // empty' "$DEPLOY_STATUS_FILE" 2>/dev/null)
                                                                                    DEPLOY_STATE=$(jq -r '.statusInfo.state // empty' "$DEPLOY_STATUS_FILE" 2>/dev/null)
                                                                                    DEPLOY_DESC=$(jq -r '.statusInfo.description // empty' "$DEPLOY_STATUS_FILE" 2>/dev/null)
                                                                                    
                                                                                    echo
                                                                                    echo "  Current Status: $DEPLOY_STATUS"
                                                                                    echo "  State: $DEPLOY_STATE"
                                                                                    echo "  Description: $DEPLOY_DESC"
                                                                                    echo
                                                                                    
                                                                                    # Check if deployment is complete
                                                                                    if [ "$DEPLOY_STATUS" = "deployed" ] || [ "$DEPLOY_STATE" = "complete" ] || [ "$DEPLOY_STATE" = "completed" ]; then
                                                                                        DEPLOY_COMPLETE=true
                                                                                        print_info "✓ DEPLOYMENT COMPLETE!"
                                                                                        clear
                                                                                        echo
                                                                                        print_info "========================================="
                                                                                        print_info "  PRODUCTION DEPLOYMENT SUCCESSFUL       "
                                                                                        print_info "========================================="
                                                                                        echo
                                                                                        print_info "The certificate has been successfully deployed to production."
                                                                                        echo
                                                                                        
                                                                                        # Show renewal reminder after successful deployment
                                                                                        if [ "$MODE" = "init" ]; then
                                                                                            print_info "📋 RENEWAL REMINDER:"
                                                                                            echo "  This certificate can be renewed before expiration using:"
                                                                                            echo "  $0 --renew $CSR_CN          # Interactive mode"
                                                                                            echo "  $0 --renew $CSR_CN --auto   # Automated mode (cron-ready)"
                                                                                            echo
                                                                                        fi
                                                                                        break
                                                                                    elif [ "$DEPLOY_STATE" = "error" ] || [ "$DEPLOY_STATE" = "failed" ]; then
                                                                                        DEPLOY_COMPLETE=true
                                                                                        print_error "Deployment failed!"
                                                                                        break
                                                                                    else
                                                                                        print_info "Deployment still in progress. Next check in 60 seconds..."
                                                                                        sleep 60
                                                                                    fi
                                                                                else
                                                                                    print_warning "Failed to retrieve status. Will retry in 60 seconds..."
                                                                                    sleep 60
                                                                                fi
                                                                            done
                                                                        else
                                                                            print_info "Deployment monitoring skipped."
                                                                        fi
                                                                    else
                                                                        print_error "Failed to acknowledge production deployment."
                                                                    fi
                                                                else
                                                                    print_warning "Change management acknowledgement not available after 5 minutes."
                                                                fi
                                                            else
                                                                print_info "Production deployment skipped."
                                                                echo

                                                                # ============================================================================
                                                                # STAGING DEPLOYMENT MONITORING (when production is skipped)
                                                                # ============================================================================

                                                                print_info "The certificate has been deployed to staging."
                                                                echo

                                                                # Determine whether to monitor staging based on AUTO_MODE
                                                                if [ "$AUTO_MODE" = true ]; then
                                                                    MONITOR_STAGING="n"
                                                                    print_info "Auto mode: Skipping staging deployment monitoring"
                                                                else
                                                                    read -p "Do you want to monitor the staging deployment status? (y/n): " MONITOR_STAGING
                                                                fi

                                                                if [[ "$MONITOR_STAGING" =~ ^[Yy]$ ]]; then
                                                                    print_info "Monitoring staging deployment status..."
                                                                    print_info "Checking every 60 seconds. Press Ctrl+C to cancel monitoring."
                                                                    echo

                                                                    # Deployment monitoring loop
                                                                    STAGING_STATUS_FILE="$CERT_STORAGE_DIR/staging_deployment_status.json"
                                                                    STAGING_COMPLETE=false
                                                                    STAGING_CHECK_COUNT=0

                                                                    while [ "$STAGING_COMPLETE" = false ]; do
                                                                        STAGING_CHECK_COUNT=$((STAGING_CHECK_COUNT + 1))

                                                                        print_info "Check #$STAGING_CHECK_COUNT - Retrieving staging deployment status..."

                                                                        if http --auth-type edgegrid -a default: GET \
                                                                            "https://${EDGEGRID_HOST}/cps/v2/enrollments/${GLOBAL_ENROLLMENT_ID}/changes/${CURRENT_CHANGE_ID}" \
                                                                            accept:'application/vnd.akamai.cps.change.v2+json' \
                                                                            --body > "$STAGING_STATUS_FILE" 2>&1; then

                                                                            # Extract status information
                                                                            STAGING_STATUS=$(jq -r '.statusInfo.status // empty' "$STAGING_STATUS_FILE" 2>/dev/null)
                                                                            STAGING_STATE=$(jq -r '.statusInfo.state // empty' "$STAGING_STATUS_FILE" 2>/dev/null)
                                                                            STAGING_DESC=$(jq -r '.statusInfo.description // empty' "$STAGING_STATUS_FILE" 2>/dev/null)

                                                                            # Check for allowed input (indicates waiting for production acknowledgement)
                                                                            ALLOWED_INPUT=$(jq -r '.allowedInput // []' "$STAGING_STATUS_FILE" 2>/dev/null)

                                                                            echo
                                                                            echo "  Current Status: $STAGING_STATUS"
                                                                            echo "  State: $STAGING_STATE"
                                                                            echo "  Description: $STAGING_DESC"
                                                                            echo

                                                                            # Check if staging deployment is complete (waiting for production deployment)
                                                                            if echo "$ALLOWED_INPUT" | grep -q "change-management"; then
                                                                                STAGING_COMPLETE=true
                                                                                clear
                                                                                echo
                                                                                print_info "✓ STAGING DEPLOYMENT COMPLETE!"
                                                                                echo
                                                                                print_info "========================================="
                                                                                print_info "   STAGING DEPLOYMENT SUCCESSFUL         "
                                                                                print_info "========================================="
                                                                                echo
                                                                                print_info "The certificate has been successfully deployed to staging."
                                                                                print_info "Status: Waiting for production deployment approval"
                                                                                echo
                                                                                print_info "To deploy to production, run:"
                                                                                echo "  $0 --renew $CSR_CN"
                                                                                echo
                                                                                echo "Or deploy via Akamai Control Center"
                                                                                echo
                                                                                break
                                                                            elif [ "$STAGING_STATE" = "error" ] || [ "$STAGING_STATE" = "failed" ]; then
                                                                                STAGING_COMPLETE=true
                                                                                print_error "Staging deployment failed!"
                                                                                break
                                                                            else
                                                                                print_info "Staging deployment still in progress. Next check in 60 seconds..."
                                                                                sleep 60
                                                                            fi
                                                                        else
                                                                            print_warning "Failed to retrieve status. Will retry in 60 seconds..."
                                                                            sleep 60
                                                                        fi
                                                                    done
                                                                else
                                                                    print_info "Staging deployment monitoring skipped."
                                                                    echo
                                                                    print_info "The certificate will be available on staging shortly."
                                                                    print_info "You can deploy to production later from Akamai Control Center"
                                                                    print_info "or by running: $0 --renew $CSR_CN"
                                                                    echo
                                                                fi
                                                            fi
                                                        else
                                                            print_error "Failed to upload certificate to Akamai."
                                                        fi
                                                    else
                                                        print_info "Certificate upload skipped."
                                                    fi
                                                else
                                                    print_error "Failed to create certificate import JSON file."
                                                fi
                                            else
                                                print_warning "Cannot proceed with certificate upload."
                                            fi
                                        else
                                            print_warning "ICA certificate file not found at: $ICA_FILE"
                                        fi
                                    else
                                        print_error "Failed to save certificate to file."
                                    fi
                                else
                                    print_warning "Could not extract certificate from JSON response."
                                fi
                            else
                                print_error "jq is not available. Cannot parse JSON response."
                            fi
                        else
                            print_error "Response file is empty or does not exist."
                        fi
                    else
                        print_error "Failed to submit certificate request to DigiCert."
                    fi
                else
                    print_info "DigiCert certificate request not submitted."
                fi
            fi
        fi
        
    else
        print_error "CSR did not become available within 5 minutes."
        print_info "The enrollment may still be processing. You can retrieve it later."
    fi
else
    echo
    print_error "Could not parse enrollment ID or change ID from response."
    print_info "Please check the response and try again."
fi

echo
print_info "Script completed!"
print_info "All certificates and CSRs are stored in: $CERT_STORAGE_DIR"

# Update configuration file with last renewal date if in renewal mode
if [ "$MODE" = "renew" ] && [ -f "$CONFIG_TO_LOAD" ]; then
    jq ".last_renewed = \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"" "$CONFIG_TO_LOAD" > "${CONFIG_TO_LOAD}.tmp" && mv "${CONFIG_TO_LOAD}.tmp" "$CONFIG_TO_LOAD"
    print_info "Configuration updated with renewal timestamp"
fi

# Show renewal reminder for successful initial deployments
if [ "$MODE" = "init" ]; then
    if [ -n "$GLOBAL_ENROLLMENT_ID" ] && [ -n "$CSR_CN" ]; then
        echo
        print_info "========================================="
        print_info "        CERTIFICATE RENEWAL INFO         "
        print_info "========================================="
        echo
        print_info "This certificate can be renewed using:"
        echo
        echo "  Option 1 - By Common Name (Interactive):"
        echo "  $0 --renew $CSR_CN"
        echo
        echo "  Option 2 - By Common Name (Automated/Cron-ready):"
        echo "  $0 --renew $CSR_CN --auto"
        echo
        echo "  Option 3 - Using configuration file (Interactive):"
        echo "  $0 --renew-config $CONFIG_DIR/${CSR_CN}_enrollment_${GLOBAL_ENROLLMENT_ID}_*.json"
        echo
        echo "  Option 4 - Using configuration file (Automated/Cron-ready):"
        echo "  $0 --renew-config $CONFIG_DIR/${CSR_CN}_enrollment_${GLOBAL_ENROLLMENT_ID}_*.json --auto"
        echo
        print_info "The renewal process will:"
        echo "  • Use the existing enrollment ID: $GLOBAL_ENROLLMENT_ID"
        echo "  • Automatically fetch the latest pending change from Akamai"
        echo "  • Use the CSR that Akamai generated during renewal initiation"
        echo "  • Issue a new certificate via DigiCert"
        echo "  • Upload and deploy to the same enrollment"
        echo "  • NOT create duplicate enrollments"
        echo
        print_info "AUTOMATED MODE (--auto flag):"
        echo "  When using --auto, all decisions are made from configuration:"
        echo "  ✓ Certificate type (RSA/ECDSA)"
        echo "  ✓ Submit to DigiCert automatically"
        echo "  ✓ Upload certificate to Akamai automatically"
        echo "  ✓ Acknowledge warnings automatically"
        echo "  ✓ Deploy to production automatically"
        echo "  ✓ Perfect for cron jobs - no interactive prompts!"
        echo
        print_info "IMPORTANT: Before running renewal:"
        echo "  1. Initiate renewal in Akamai Control Center"
        echo "  2. Wait for Akamai to generate the new CSR"
        echo "  3. Run this script with --renew flag"
        echo
        print_info "Configuration saved for easy renewal at:"
        echo "  $CONFIG_DIR/${CSR_CN}.json"
        echo
        print_info "CRON JOB EXAMPLE:"
        echo "  # Renew certificate monthly at 2 AM"
        echo "  0 2 1 * * $0 --renew $CSR_CN --auto >> /var/log/akamai-renewal.log 2>&1"
        echo
        print_info "For detailed automation documentation, see:"
        echo "  $(dirname "$0")/AUTOMATION.md"
        echo
    fi
fi