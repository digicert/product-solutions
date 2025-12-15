# ACME URL: https://demo.one.digicert.com/mpki/api/v1/acme/v2/directory 
# Key identifier (KID): kT__XL6_ifUSCqAsygt4Hn3T_e8Uw9o_O4DHUCUMmms 
# HMAC key: REMOVED_SECRET

# Parameters to be created in the Avi Controller for this script:
# acme_directory_url
# eab_kid
# eab_hmac_key
# contact

'''
###
# Name: digicert_acme_mgmt_profile.py
# Version: 1.0.0
# License: MIT
#
# Description -
#     This is a python script used for automatically requesting and renewing certificates
#     from DigiCert via ACME with External Account Binding (EAB).
#
# Setup -
#     1. This content needs to be imported in the Avi Controller in the settings menu
#        at <<Templates - Security - Certificate Management>>.
#     2. Create the following script params:
#        - acme_directory_url (e.g., https://acme.digicert.com/v2/acme/directory/)
#        - eab_kid (Key Identifier from DigiCert)
#        - eab_hmac_key (HMAC Key from DigiCert - mark as sensitive)
#        - contact (email address, optional)
#     3. Go to <<Templates - Security - SSL/TLS Certificates>>, click on <<Create>>
#        and then <<Application Certificate>>.
#     4. Specify a suitable name to identify this certificate in Avi Controller.
#     5. Change <<Type>> to <<CSR>>
#     6. Set <<Common Name>> to the domain and select the "Certificate Management" profile.
#     7. Save and wait for the certificate to be requested and imported.
#
# Note -
#     1. This script is for DigiCert with PRE-VALIDATED domains (OV/EV certificates).
#        Domain validation happens out-of-band in DigiCert, not via HTTP-01 challenge.
#     2. For DV certificates requiring HTTP-01/DNS-01 challenge, additional logic is needed.
#
# Parameters -
#     acme_directory_url  - DigiCert ACME directory URL (Required)
#     eab_kid             - External Account Binding Key ID (Required)
#     eab_hmac_key        - External Account Binding HMAC Key (Required, Sensitive)
#     contact             - Email address for account registration (Optional)
#
# DigiCert ACME URLs -
#     CertCentral: https://acme.digicert.com/v2/acme/directory/
#     TLM:         https://one.digicert.com/mpki/api/v1/acme/v2/directory
#
###
'''

import base64, binascii, hashlib, hmac, os, json, re, ssl, subprocess, time
from urllib.request import urlopen, Request
from tempfile import NamedTemporaryFile

VERSION = "1.0.0"
ACCOUNT_KEY_PATH = "/tmp/digicert_acme.key"


def get_crt(csr, acme_directory_url, eab_kid, eab_hmac_key, contact=None, debug=False):
    directory, acct_headers, alg, jwk = None, None, None, None  # global variables

    # helper function - base64 encode for jose spec
    def _b64(b):
        return base64.urlsafe_b64encode(b).decode('utf8').replace("=", "")

    # helper function - run external commands
    def _cmd(cmd_list, stdin=None, cmd_input=None, err_msg="Command Line Error"):
        proc = subprocess.Popen(cmd_list, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = proc.communicate(cmd_input)
        if proc.returncode != 0:
            raise IOError("{0}\n{1}".format(err_msg, err))
        return out

    # helper function - make request and automatically parse json response
    def _do_request(url, data=None, err_msg="Error", depth=0, verify=True):
        try:
            ctx = ssl.create_default_context()
            if not verify:
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
            resp = urlopen(Request(url, data=data, headers={"Content-Type": "application/jose+json", "User-Agent": "digicert-acme-avi"}), context=ctx)
            resp_data, code, headers = resp.read().decode("utf8"), resp.getcode(), resp.headers
        except IOError as e:
            resp_data = e.read().decode("utf8") if hasattr(e, "read") else str(e)
            code, headers = getattr(e, "code", None), {}
        try:
            resp_data = json.loads(resp_data)
        except ValueError:
            pass
        if depth < 100 and code == 400 and resp_data['type'] == "urn:ietf:params:acme:error:badNonce":
            raise IndexError(resp_data)
        if code not in [200, 201, 204]:
            raise ValueError("{0}:\nUrl: {1}\nData: {2}\nResponse Code: {3}\nResponse: {4}".format(err_msg, url, data, code, resp_data))
        return resp_data, code, headers

    # helper function - make signed requests
    def _send_signed_request(url, payload, err_msg, depth=0):
        payload64 = "" if payload is None else _b64(json.dumps(payload).encode('utf8'))
        new_nonce = _do_request(directory['newNonce'])[2]['Replay-Nonce']
        protected = {"url": url, "alg": alg, "nonce": new_nonce}
        protected.update({"jwk": jwk} if acct_headers is None else {"kid": acct_headers['Location']})
        protected64 = _b64(json.dumps(protected).encode('utf8'))
        protected_input = "{0}.{1}".format(protected64, payload64).encode('utf8')
        out = _cmd(["openssl", "dgst", "-sha256", "-sign", ACCOUNT_KEY_PATH], stdin=subprocess.PIPE, cmd_input=protected_input, err_msg="OpenSSL Error")
        data = json.dumps({"protected": protected64, "payload": payload64, "signature": _b64(out)})
        try:
            return _do_request(url, data=data.encode('utf8'), err_msg=err_msg, depth=depth)
        except IndexError:
            return _send_signed_request(url, payload, err_msg, depth=(depth + 1))

    # helper function - poll until complete
    def _poll_until_not(url, pending_statuses, err_msg):
        result, t0 = None, time.time()
        while result is None or result['status'] in pending_statuses:
            assert (time.time() - t0 < 3600), "Polling timeout"
            time.sleep(0 if result is None else 2)
            result, _, _ = _send_signed_request(url, None, err_msg)
        return result

    # Generate or reuse account key
    if os.path.exists(ACCOUNT_KEY_PATH):
        if debug:
            print("DEBUG: Reusing account key.")
    else:
        print("Account key not found. Generating account key...")
        out = _cmd(["openssl", "genrsa", "4096"], err_msg="OpenSSL Error")
        with open(ACCOUNT_KEY_PATH, 'w') as f:
            f.write(out.decode("utf-8"))

    # Parse account key to get public key
    print("Parsing account key...")
    out = _cmd(["openssl", "rsa", "-in", ACCOUNT_KEY_PATH, "-noout", "-text"], err_msg="OpenSSL Error")
    pub_pattern = r"modulus:\s*\n\s*([\s\S]*?)\npublicExponent:\s*(\d+)"
    match = re.search(pub_pattern, out.decode('utf8'), re.MULTILINE | re.DOTALL)
    if match:
        pub_hex = re.sub(r"[\s:]", "", match.group(1))
        # Remove leading 00 if present (ASN.1 padding)
        if pub_hex.startswith("00"):
            pub_hex = pub_hex[2:]
        pub_exp = match.group(2)
    else:
        raise ValueError("Could not parse public key from account key")
    
    pub_exp = "{0:x}".format(int(pub_exp))
    pub_exp = "0{0}".format(pub_exp) if len(pub_exp) % 2 else pub_exp
    alg = "RS256"
    jwk = {
        "e": _b64(binascii.unhexlify(pub_exp.encode("utf-8"))),
        "kty": "RSA",
        "n": _b64(binascii.unhexlify(pub_hex.encode("utf-8"))),
    }
    accountkey_json = json.dumps(jwk, sort_keys=True, separators=(',', ':'))
    thumbprint = _b64(hashlib.sha256(accountkey_json.encode('utf8')).digest())

    # Parse CSR for domains
    print("Parsing CSR...")
    out = _cmd(["openssl", "req", "-in", csr, "-noout", "-text"], err_msg="Error loading {0}".format(csr))
    domains = set([])
    common_name = re.search(r"Subject:.*? CN\s?=\s?([^\s,;/]+)", out.decode('utf8'))
    if common_name is not None:
        domains.add(common_name.group(1))
    subject_alt_names = re.search(r"X509v3 Subject Alternative Name: (?:critical)?\n +([^\n]+)\n", out.decode('utf8'), re.MULTILINE | re.DOTALL)
    if subject_alt_names is not None:
        for san in subject_alt_names.group(1).split(", "):
            if san.startswith("DNS:"):
                domains.add(san[4:])
    print("Found domains: {0}".format(", ".join(domains)))

    # Get the ACME directory
    print("Getting directory...")
    directory, _, _ = _do_request(acme_directory_url, err_msg="Error getting directory")
    print("Directory found!")

    # Create External Account Binding (EAB)
    print("Creating External Account Binding...")
    eab_protected = {
        "alg": "HS256",
        "kid": eab_kid,
        "url": directory['newAccount']
    }
    eab_protected64 = _b64(json.dumps(eab_protected).encode('utf8'))
    eab_payload64 = _b64(json.dumps(jwk).encode('utf8'))
    eab_signing_input = "{0}.{1}".format(eab_protected64, eab_payload64).encode('utf8')
    
    # Decode HMAC key (it's base64url encoded)
    hmac_key = base64.urlsafe_b64decode(eab_hmac_key + '==')
    eab_signature = hmac.new(hmac_key, eab_signing_input, hashlib.sha256).digest()
    eab_signature64 = _b64(eab_signature)
    
    external_account_binding = {
        "protected": eab_protected64,
        "payload": eab_payload64,
        "signature": eab_signature64
    }

    # Register account with EAB
    print("Registering account...")
    reg_payload = {
        "termsOfServiceAgreed": True,
        "externalAccountBinding": external_account_binding
    }
    if contact is not None:
        reg_payload["contact"] = contact
    
    account, code, acct_headers = _send_signed_request(directory['newAccount'], reg_payload, "Error registering")
    print("Registered!" if code == 201 else "Already registered!")

    # Create a new order
    print("Creating new order...")
    order_payload = {"identifiers": [{"type": "dns", "value": d} for d in domains]}
    order, _, order_headers = _send_signed_request(directory['newOrder'], order_payload, "Error creating new order")
    print("Order created!")

    # For pre-validated domains, authorizations should already be valid
    # Check authorization status
    for auth_url in order['authorizations']:
        authorization, _, _ = _send_signed_request(auth_url, None, "Error getting authorization")
        domain = authorization['identifier']['value']
        print("Authorization for {0}: {1}".format(domain, authorization['status']))
        
        if authorization['status'] == 'valid':
            print("Domain {0} already validated!".format(domain))
        elif authorization['status'] == 'pending':
            # For pre-validated domains in DigiCert, this shouldn't happen
            # But if it does, we'd need HTTP-01 or DNS-01 challenge here
            raise ValueError("Domain {0} requires validation. Please pre-validate in DigiCert or use HTTP-01 challenge.".format(domain))

    # Finalize the order with the CSR
    print("Signing certificate...")
    csr_der = _cmd(["openssl", "req", "-in", csr, "-outform", "DER"], err_msg="DER Export Error")
    _send_signed_request(order['finalize'], {"csr": _b64(csr_der)}, "Error finalizing order")

    # Poll the order to monitor when it's done
    order = _poll_until_not(order_headers['Location'], ["pending", "processing"], "Error checking order status")
    if order['status'] != "valid":
        raise ValueError("Order failed: {0}".format(order))

    # Download the certificate
    certificate_pem, _, _ = _send_signed_request(order['certificate'], None, "Certificate download failed")
    print("Certificate signed!")

    return certificate_pem


def certificate_request(csr, common_name, kwargs):
    # Extract parameters from kwargs
    acme_directory_url = kwargs.get('acme_directory_url', None)
    eab_kid = kwargs.get('eab_kid', None)
    eab_hmac_key = kwargs.get('eab_hmac_key', None)
    contact = kwargs.get('contact', None)
    debug = kwargs.get('debug', 'false')

    print("Running version {}".format(VERSION))

    # Validate required parameters
    if not acme_directory_url:
        raise ValueError("Missing required parameter: acme_directory_url")
    if not eab_kid:
        raise ValueError("Missing required parameter: eab_kid")
    if not eab_hmac_key:
        raise ValueError("Missing required parameter: eab_hmac_key")

    if debug.lower() == "true":
        debug = True
        print("Debug enabled.")
    else:
        debug = False

    print("acme_directory_url is: {}".format(acme_directory_url))
    print("eab_kid is: {}".format(eab_kid[:10] + "..." if eab_kid else "None"))
    print("contact is: {}".format(contact))

    # Format contact as array if provided
    if contact is not None and "@" in contact:
        contact = ["mailto:{}".format(contact)]
        print("Contact set to: {}".format(contact))

    # Create CSR temp file
    csr_temp_file = NamedTemporaryFile(mode='w', delete=False)
    csr_temp_file.close()

    with open(csr_temp_file.name, 'w') as f:
        f.write(csr)

    signed_crt = None
    try:
        signed_crt = get_crt(
            csr_temp_file.name,
            acme_directory_url,
            eab_kid,
            eab_hmac_key,
            contact=contact,
            debug=debug
        )
    finally:
        os.remove(csr_temp_file.name)

    print(signed_crt)
    return signed_crt