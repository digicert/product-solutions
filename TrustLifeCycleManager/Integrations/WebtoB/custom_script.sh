#!/bin/bash

# Set Webtob environment variables
export WEBTOBDIR=/root/webtob/
export PATH="${WEBTOBDIR}/bin:${PATH}"
export LD_LIBRARY_PATH="${WEBTOBDIR}/lib:${LD_LIBRARY_PATH}"

clear
#Define Variables
host=$1
emailaddress=$2
eabkeyidentifier=$3
eabkeyhmac=$4
key=$5
directoryuri=$6


value=$directoryuri
value=${value#\"}
directoryuri=${value%\"}

# Shut Down WebToB
/root/webtob/bin/wsdown -i

# Run Certbot
certbot certonly --server $directoryuri --config-dir ./acme/ --eab-kid $eabkeyidentifier --eab-hmac-key $eabkeyhmac --force-renew --agree-tos --no-redirect --expand -d $host --email $emailaddress --no-autorenew --preferred-challenges http --standalone --key-type $key -n --no-verify-ssl

# Moving new certificate to WebToB
# cp /home/ubuntu/tlm_agent_3.0.14_linux64/user-scripts/acme/live/webtob.tlsguru.io/cert.pem /root/webtob/ssl/webtob.pem
# cp /home/ubuntu/tlm_agent_3.0.14_linux64/user-scripts/acme/live/webtob.tlsguru.io/privkey.pem /root/webtob/ssl/webtob.key

# Create Symbolic Links
ln -sf /home/ubuntu/tlm_agent_3.0.14_linux64/user-scripts/acme/live/webtob.tlsguru.io/cert.pem /root/webtob/ssl/webtob.pem
ln -sf /home/ubuntu/tlm_agent_3.0.14_linux64/user-scripts/acme/live/webtob.tlsguru.io/privkey.pem /root/webtob/ssl/webtob.key

# Start WebToB
/root/webtob/bin/wsboot

# Complete Script
returnCode=$?
echo "The command exit status : ${returnCode}"
exit $returnCode




