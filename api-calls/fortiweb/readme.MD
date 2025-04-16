In order to get to the API documentation - you need an account for FNDN: 

https://fndn.fortinet.net/index.php?/fortiapi/939-fortiweb/953/

The account is not free disappointed face 

To send an API call you need the authorization key. In order to receive that we need the following

```
{"username":"admin","password":"Plant%sapsup2!","vdom":"root"}
```

You then need to encode this to base64 by using one of the various websites such as Base64 Encode and Decode - Online  or openssl. 
https://www.base64encode.org/

```shell
echo -n '{"username":"admin","password":"Plant%sapsup2!","vdom":"root"}' | base64
eyJ1c2VybmFtZSI6ImFkbWluIiwicGFzc3dvcmQiOiJQbGFudCVzYXBzdXAyISIsInZkb20iOiJyb290In0=
```
