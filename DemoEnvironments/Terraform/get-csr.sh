curl --insecure -X POST \
  "https://ec2-3-145-216-176.us-east-2.compute.amazonaws.com/api/" \
  -d "key=LUFRPT1FbHhwTEFkNHhaMWZkQy9jR2hINnk1ZkdoOWs9dEdlQVg1OXVOMkFUVHdFSkRVNjhqWTMrSDJmNXNYWVRSSDJmS0tTR1ZreUVBMkFNc3hxWEVVeWdyWlNtUVhERA==" \
  -d "type=config" \
  -d "action=get" \
  --data-urlencode "xpath=/config/shared/certificate/entry[@name='MyCSR']" | \
  tee raw_response.xml | \
  sed -n '/<csr[^>]*>/,/<\/csr>/p' | \
  sed 's/<csr[^>]*>//g' | \
  sed 's/<\/csr>//g' | \
  sed '/^[[:space:]]*$/d' > MyCSR_clean.csr && \
  echo "CSR extracted to MyCSR_clean.csr" && \
  echo "Raw response saved to raw_response.xml"
