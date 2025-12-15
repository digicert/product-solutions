#!/bin/bash

# Avi Controller Configuration
AVI_CONTROLLER="alb-a.site-a.vcf.lab"
AVI_USER="admin"
AVI_PASSWORD="VMware123!VMware123"
AVI_API_VERSION="22.1.3"

# Certificate Configuration
CERT_NAME="demo-self-signed-cert"
CERT_CN="demo.example.com"
CERT_DAYS=365
CERT_KEY_SIZE=2048

# Temp files
WORK_DIR=$(mktemp -d)
KEY_FILE="${WORK_DIR}/server.key"
CERT_FILE="${WORK_DIR}/server.crt"
COOKIE_FILE="${WORK_DIR}/avi_cookies.txt"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo -e "\n${YELLOW}Cleaning up temporary files...${NC}"
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

generate_certificate() {
    echo -e "${YELLOW}Generating self-signed certificate...${NC}"
    
    openssl req -x509 -nodes -days ${CERT_DAYS} -newkey rsa:${CERT_KEY_SIZE} \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/C=US/ST=California/L=San Francisco/O=Demo Organization/OU=IT/CN=${CERT_CN}" \
        2>/dev/null

    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to generate certificate${NC}"
        exit 1
    fi

    echo -e "${GREEN}Certificate generated successfully${NC}"
    openssl x509 -in "${CERT_FILE}" -noout -subject -dates
}

authenticate_avi() {
    echo -e "\n${YELLOW}Authenticating to Avi Controller...${NC}"
    
    HTTP_CODE=$(curl -s -k -o /dev/null -w "%{http_code}" \
        -c "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${AVI_USER}\",\"password\":\"${AVI_PASSWORD}\"}" \
        "https://${AVI_CONTROLLER}/login")

    if [ "${HTTP_CODE}" != "200" ]; then
        echo -e "${RED}Authentication failed (HTTP ${HTTP_CODE})${NC}"
        exit 1
    fi

    CSRF_TOKEN=$(grep -i "csrftoken" "${COOKIE_FILE}" | awk '{print $NF}')
    
    if [ -z "${CSRF_TOKEN}" ]; then
        echo -e "${RED}Failed to obtain CSRF token${NC}"
        exit 1
    fi

    echo -e "${GREEN}Authentication successful${NC}"
}

upload_certificate() {
    echo -e "\n${YELLOW}Uploading certificate to Avi...${NC}"

    CERT_CONTENT=$(cat "${CERT_FILE}")
    KEY_CONTENT=$(cat "${KEY_FILE}")

    PAYLOAD=$(jq -n \
        --arg name "${CERT_NAME}" \
        --arg cert "${CERT_CONTENT}" \
        --arg key "${KEY_CONTENT}" \
        '{
            "name": $name,
            "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
            "certificate": {
                "certificate": $cert
            },
            "key": $key
        }')

    RESPONSE=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -H "X-CSRFToken: ${CSRF_TOKEN}" \
        -H "Referer: https://${AVI_CONTROLLER}/" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        -X POST \
        -d "${PAYLOAD}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate")

    if echo "${RESPONSE}" | grep -q '"uuid"'; then
        CERT_UUID=$(echo "${RESPONSE}" | jq -r '.uuid')
        echo -e "${GREEN}Certificate uploaded successfully${NC}"
        echo "  Name: ${CERT_NAME}"
        echo "  UUID: ${CERT_UUID}"
        echo -e "\n${GREEN}View in: Templates > Security > SSL/TLS Certificates${NC}"
    elif echo "${RESPONSE}" | grep -q "already exist"; then
        echo -e "${YELLOW}Certificate already exists - updating...${NC}"
        update_certificate
    else
        echo -e "${RED}Failed to upload certificate${NC}"
        echo "Response: ${RESPONSE}"
        exit 1
    fi
}

update_certificate() {
    EXISTING=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate?name=${CERT_NAME}")

    CERT_UUID=$(echo "${EXISTING}" | jq -r '.results[0].uuid')

    if [ -z "${CERT_UUID}" ] || [ "${CERT_UUID}" = "null" ]; then
        echo -e "${RED}Could not find existing certificate UUID${NC}"
        exit 1
    fi

    CERT_CONTENT=$(cat "${CERT_FILE}")
    KEY_CONTENT=$(cat "${KEY_FILE}")

    PAYLOAD=$(jq -n \
        --arg name "${CERT_NAME}" \
        --arg cert "${CERT_CONTENT}" \
        --arg key "${KEY_CONTENT}" \
        --arg uuid "${CERT_UUID}" \
        '{
            "uuid": $uuid,
            "name": $name,
            "type": "SSL_CERTIFICATE_TYPE_VIRTUALSERVICE",
            "certificate": {
                "certificate": $cert
            },
            "key": $key
        }')

    RESPONSE=$(curl -s -k \
        -b "${COOKIE_FILE}" \
        -H "Content-Type: application/json" \
        -H "X-CSRFToken: ${CSRF_TOKEN}" \
        -H "Referer: https://${AVI_CONTROLLER}/" \
        -H "X-Avi-Version: ${AVI_API_VERSION}" \
        -X PUT \
        -d "${PAYLOAD}" \
        "https://${AVI_CONTROLLER}/api/sslkeyandcertificate/${CERT_UUID}")

    if echo "${RESPONSE}" | grep -q '"uuid"'; then
        echo -e "${GREEN}Certificate updated successfully${NC}"
        echo "  Name: ${CERT_NAME}"
        echo "  UUID: ${CERT_UUID}"
    else
        echo -e "${RED}Failed to update certificate${NC}"
        echo "Response: ${RESPONSE}"
        exit 1
    fi
}

# Main
echo "=============================================="
echo " Avi SSL Certificate Upload Script"
echo "=============================================="

command -v openssl >/dev/null 2>&1 || { echo -e "${RED}openssl required${NC}"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo -e "${RED}curl required${NC}"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}jq required - install with: apt install jq${NC}"; exit 1; }

generate_certificate
authenticate_avi
upload_certificate

echo -e "\n${GREEN}Done!${NC}"