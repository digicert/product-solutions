#!/bin/bash
# Builds the plugin: Java unit + integration tests, device-script tests, fat jar, dist zip, checksums.
# Requires GITHUB_TOKEN (read:packages) and GITHUB_ACTOR for the DigiCert plugin-sdk package registry.
set -o pipefail

cd "$(dirname "$0")" || exit 1

# Check for required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is not set."
    echo "Please set it with: export GITHUB_TOKEN=your_token_here"
    exit 1
fi

# Function to check token permissions
check_token_permissions() {
    echo "Checking GitHub token permissions..."

    # Get token scopes from GitHub API
    RESPONSE=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -I "https://api.github.com/user")

    HTTP_STATUS=$(echo "$RESPONSE" | head -n 1 | cut -d' ' -f2)
    SCOPES=$(echo "$RESPONSE" | grep -i "x-oauth-scopes:" | cut -d' ' -f2- | tr -d '\r\n')

    if [ "$HTTP_STATUS" != "200" ]; then
        echo "✗ Error: Invalid or expired GitHub token (HTTP $HTTP_STATUS)"
        prompt_for_new_token
        return 1
    fi

    echo "Token scopes: $SCOPES"

    # Check if token has read:packages or repo scope
    if echo "$SCOPES" | grep -q "read:packages\|repo"; then
        echo "✓ Token has sufficient permissions for package access"
        return 0
    else
        echo "✗ Error: GitHub token does not have sufficient permissions."
        prompt_for_new_token
        return 1
    fi
}

# Function to prompt user for new token
prompt_for_new_token() {
    echo ""
    echo "The token needs 'read:packages' permission to access GitHub Packages."
    echo ""
    echo "Please create a new Personal Access Token with the following scopes:"
    echo "  - read:packages (to read packages from GitHub Packages)"
    echo "  - repo (if accessing private repositories)"
    echo ""
    echo "Steps to create a token:"
    echo "1. Go to: https://github.com/settings/tokens"
    echo "2. Click 'Generate new token (classic)'"
    echo "3. Select the 'read:packages' scope"
    echo "4. Copy the token and update GITHUB_TOKEN in this script or set as environment variable"
    echo ""
    exit 1
}

# Check token permissions
check_token_permissions

# Check for GITHUB_ACTOR, use GITHUB_USER as fallback
if [ -z "$GITHUB_ACTOR" ]; then
    if [ -n "$GITHUB_USER" ]; then
        echo "GITHUB_ACTOR not set, using GITHUB_USER ($GITHUB_USER) as fallback"
        export GITHUB_ACTOR="$GITHUB_USER"
    else
        echo "Error: Neither GITHUB_ACTOR nor GITHUB_USER environment variables are set."
        echo "Please set GITHUB_ACTOR with: export GITHUB_ACTOR=your_github_username"
        exit 1
    fi
fi

# Device-side script tests (plain unittest, no third-party packages). Skipped when python3 is absent.
if command -v python3 &>/dev/null; then
    echo "Running device script tests..."
    # -B: no __pycache__ under src/main/resources, which would otherwise end up inside the plugin jar.
    python3 -B -m unittest discover -s src/test/python -p 'test_*.py' || { echo "Device script tests failed. Exiting."; exit 1; }
else
    echo "python3 not found; skipping device script tests."
fi

# Unit tests (surefire), integration tests (failsafe), fat jar and dist zip.
mvn clean verify -s settings.xml -U

if [ $? -ne 0 ]; then
    echo "Build failed. Exiting."
    exit 1
fi

pushd ./plugin-dist > /dev/null || exit 1
# Use sha256sum on Linux, shasum on macOS
if command -v sha256sum &>/dev/null; then
    SHA_CMD="sha256sum"
else
    SHA_CMD="shasum -a 256"
fi

CHECKSUM_FILE="checksums"
echo "" > $CHECKSUM_FILE
echo "SHA2 checksum for TPM" >> $CHECKSUM_FILE
echo "\`\`\`" >> $CHECKSUM_FILE
find . -name "*.zip" | xargs $SHA_CMD | sed 's|  \./|  |' >> $CHECKSUM_FILE
echo "\`\`\`" >> $CHECKSUM_FILE
cat $CHECKSUM_FILE
popd > /dev/null
