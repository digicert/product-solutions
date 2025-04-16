# Upload PCKS12 to Fortiweb using API
curl -k --location -g --request POST 'https://ec2-18-218-166-16.us-east-2.compute.amazonaws.com:8443/api/v2.0/system/certificate.local.import_certificate' \
--header 'Authorization: REMOVED_SECRET' \
--header 'Accept: application/json' \
--header 'Content-Type: multipart/form-data' \
--form 'certificateWithKeyFile=@//Users/michaelrudloff/Desktop/certificate.pfx' \
--form 'password="P4ssw0rd!"' \
--form 'type=PKCS12Certificate'
