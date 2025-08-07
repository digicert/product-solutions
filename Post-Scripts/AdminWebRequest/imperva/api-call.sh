# Assuming cert-chain.crt contains your full chain with headers/footers
CERT_CHAIN_BASE64=$(cat cert-chain.crt | base64 -w 0)

# For the private key
KEY_BASE64=$(cat cert-chain.key | base64 -w 0)

# Create the API payload
API_PAYLOAD=$(cat <<EOF
{
  "certificate": "${CERT_CHAIN_BASE64}",
  "private_key": "${KEY_BASE64}",
  "auth_type": "RSA"
}
EOF
)

# Make the API call
curl --location --request PUT 'https://my.imperva.com/api/prov/v2/sites/977834857/customCertificate' \
--header 'Content-Type: application/json' \
--header 'x-API-Key: REMOVED_SECRET' \
--header 'x-API-Id: 163179' \
--data "${API_PAYLOAD}"
