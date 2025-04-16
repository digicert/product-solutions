# Upload PEM Certificate to Fortiweb using API
curl -k --location -g --request POST 'https://ec2-18-218-166-16.us-east-2.compute.amazonaws.com:8443/api/v2.0/system/certificate.local.import_certificate' \
--header 'Authorization: eyJ1c2VybmFtZSI6ImFkbWluIiwicGFzc3dvcmQiOiJQbGFudCVzYXBzdXAyISIsInZkb20iOiJyb290In0=' \
--header 'Accept: application/json' \
--header 'Content-Type: multipart/form-data' \
--form 'certificateFile=@//Users/michaelrudloff/Desktop/cert.pem' \
--form 'keyFile=@//Users/michaelrudloff/Desktop/key.pem' \
--form 'type=certificate'
