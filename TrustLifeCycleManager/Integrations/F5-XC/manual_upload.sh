curl -X PUT \
  https://digicert.console.ves.volterra.io/api/config/namespaces/default/certificates/tls \
  -H "Authorization: APIToken <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {
      "name": "tls",
      "namespace": "default"
    },
    "spec": {
      "certificate_url": "string:///'"$(cat 3days.com.crt | base64 -w 0)"'",
      "private_key": {
        "blindfold_secret_info": {
          "decryption_provider": "ves-io-default-blindfold",
          "store_provider": "ves-io-default-secret",
          "url": "string:///'"$(cat 3days.com.key | base64 -w 0)"'"
        }
      }
    }
  }'



## Replace: 

curl -X PUT \
  https://digicert.console.ves.volterra.io/api/config/namespaces/default/certificates/tls \
  -H "Authorization: APIToken WnZvSpExfE9N/U44qnYOTcrH7Es=" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {
      "name": "tls",
      "namespace": "default"
    },
    "spec": {
      "certificate_url": "string:///'"$(cat 365days.com.crt | base64 -w 0)"'",
      "private_key": {
        "clear_secret_info": {
          "url": "string:///'"$(cat 365days.com.key | base64 -w 0)"'"
        }
      }
    }
  }'



# First delete the existing certificate
curl -X DELETE \
  https://digicert.console.ves.volterra.io/api/config/namespaces/default/certificates/tls \
  -H "Authorization: APIToken WnZvSpExfE9N/U44qnYOTcrH7Es=" \
  -H "Content-Type: application/json"

# Wait a moment for deletion to complete
sleep 2

# Then create the new certificate
curl -X POST \
  https://digicert.console.ves.volterra.io/api/config/namespaces/default/certificates \
  -H "Authorization: APIToken WnZvSpExfE9N/U44qnYOTcrH7Es=" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {
      "name": "tls",
      "namespace": "default"
    },
    "spec": {
      "certificate_url": "string:///'"$(cat 365days.com.crt | base64 -w 0)"'",
      "private_key": {
        "clear_secret_info": {
          "url": "string:///'"$(cat 365days.com.key | base64 -w 0)"'"
        }
      }
    }
  }'