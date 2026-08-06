"""
VMware Avi Certificate Management provider for DigiCert ACME with EAB.

Required Avi Certificate Management Profile parameters:
    acme_directory_url
    eab_kid
    eab_hmac_key          (mark as sensitive)

Optional parameters:
    contact               Email address, or comma-separated email addresses
    acme_account_key      PEM RSA account key (mark as sensitive)
    request_timeout_seconds  Default: 30
    poll_timeout_seconds     Default: 300
    debug                    true/false; default: false

The optional acme_account_key is recommended for HA deployments where the same
ACME account identity must be used on every controller node and after container
or controller restarts. If omitted, a profile-scoped key is generated and
cached under /tmp with mode 0600.
"""

import base64
import binascii
import fcntl
import hashlib
import hmac
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import time
import traceback
from email.utils import parsedate_to_datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


VERSION = "2.0.0"
USER_AGENT = "digicert-acme-avi/{}".format(VERSION)
DEFAULT_REQUEST_TIMEOUT = 30
DEFAULT_POLL_TIMEOUT = 300
MAX_BAD_NONCE_RETRIES = 5
ACCOUNT_KEY_DIRECTORY = "/tmp"


class AcmeClientError(RuntimeError):
    """An actionable local or ACME protocol error."""


class AcmeHttpError(AcmeClientError):
    """An HTTP error that retains the structured ACME response for retries."""

    def __init__(self, stage, method, url, code, response, headers):
        self.stage = stage
        self.method = method
        self.url = url
        self.code = code
        self.response = response
        self.headers = headers
        detail = _safe_response_text(response)
        super(AcmeHttpError, self).__init__(
            "{}: {} {} returned HTTP {}: {}".format(
                stage, method, url, code, detail
            )
        )


def _log(message):
    print(message, flush=True)


def _b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _decode_b64url(value, field_name):
    if isinstance(value, bytes):
        encoded = value.strip()
    else:
        try:
            encoded = str(value).strip().encode("ascii")
        except UnicodeEncodeError:
            raise AcmeClientError("{} must contain only Base64URL characters".format(field_name))

    if not encoded:
        raise AcmeClientError("{} is empty".format(field_name))
    if not re.fullmatch(br"[A-Za-z0-9_-]+={0,2}", encoded):
        raise AcmeClientError("{} is not valid Base64URL data".format(field_name))

    encoded = encoded.rstrip(b"=")
    if len(encoded) % 4 == 1:
        raise AcmeClientError("{} has an invalid Base64URL length".format(field_name))

    try:
        return base64.urlsafe_b64decode(encoded + (b"=" * (-len(encoded) % 4)))
    except (TypeError, ValueError, binascii.Error) as exc:
        raise AcmeClientError("Unable to decode {}: {}".format(field_name, exc))


def _json_bytes(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _safe_response_text(response, limit=4096):
    if isinstance(response, (dict, list)):
        text = json.dumps(response, sort_keys=True)
    elif response is None:
        text = "<empty response>"
    else:
        text = str(response).strip() or "<empty response>"
    if len(text) > limit:
        return text[:limit] + "... [truncated]"
    return text


def _parse_response(body, headers):
    text = body.decode("utf-8", errors="replace")
    content_type = headers.get("Content-Type", "") if headers is not None else ""
    if text and ("json" in content_type.lower() or text.lstrip().startswith(("{", "["))):
        try:
            return json.loads(text)
        except ValueError:
            pass
    return text


def _require_https_url(url, field_name):
    try:
        parsed = urlsplit(url)
    except Exception as exc:
        raise AcmeClientError("{} is not a valid URL: {}".format(field_name, exc))
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        raise AcmeClientError("{} must be an absolute HTTPS URL".format(field_name))
    return url


def _required_text(kwargs, name):
    value = kwargs.get(name)
    if value is None or not str(value).strip():
        raise AcmeClientError("Missing required parameter: {}".format(name))
    return str(value).strip()


def _as_bool(value, default=False):
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in ("true", "1", "yes", "on"):
        return True
    if normalized in ("false", "0", "no", "off", ""):
        return False
    raise AcmeClientError("Boolean value expected, got {!r}".format(value))


def _positive_int(value, name, default, maximum):
    if value is None or str(value).strip() == "":
        return default
    try:
        parsed = int(str(value).strip())
    except (TypeError, ValueError):
        raise AcmeClientError("{} must be an integer".format(name))
    if parsed < 1 or parsed > maximum:
        raise AcmeClientError("{} must be between 1 and {}".format(name, maximum))
    return parsed


def _normalize_contact(value):
    if value is None:
        return None
    if isinstance(value, (list, tuple)):
        entries = list(value)
    else:
        entries = re.split(r"[,;]", str(value))

    contacts = []
    for entry in entries:
        entry = str(entry).strip()
        if not entry:
            continue
        address = entry[7:] if entry.lower().startswith("mailto:") else entry
        if "@" not in address or any(char.isspace() for char in address):
            raise AcmeClientError("Invalid contact email address: {!r}".format(entry))
        contact = "mailto:{}".format(address)
        if contact not in contacts:
            contacts.append(contact)
    return contacts or None


def _cmd(command, stage, command_input=None, timeout=120):
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE if command_input is not None else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as exc:
        raise AcmeClientError("{}: unable to start command: {}".format(stage, exc))

    try:
        stdout, stderr = process.communicate(command_input, timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
        raise AcmeClientError("{}: command timed out after {} seconds".format(stage, timeout))

    if process.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise AcmeClientError(
            "{}: command exited with status {}: {}".format(
                stage, process.returncode, detail or "no error output"
            )
        )
    return stdout


def _atomic_write_private_file(path, data):
    descriptor, temporary_path = tempfile.mkstemp(
        prefix=".digicert-acme-key-", dir=os.path.dirname(path)
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            descriptor = None
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
        os.chmod(path, 0o600)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if os.path.exists(temporary_path):
            os.unlink(temporary_path)


def _account_key_path(directory_url, eab_kid, hmac_key):
    digest = hashlib.sha256(
        directory_url.encode("utf-8")
        + b"\x00"
        + eab_kid.encode("utf-8")
        + b"\x00"
        + hmac_key
    ).hexdigest()[:24]
    return os.path.join(ACCOUNT_KEY_DIRECTORY, "digicert_acme_{}.key".format(digest))


def _prepare_account_key(path, supplied_key, debug=False):
    lock_path = path + ".lock"
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    lock_descriptor = os.open(lock_path, flags, 0o600)

    try:
        os.fchmod(lock_descriptor, 0o600)
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX)

        if supplied_key:
            key_text = str(supplied_key).strip()
            if "\\n" in key_text and "\n" not in key_text:
                key_text = key_text.replace("\\n", "\n")
            if "-----BEGIN" not in key_text or "PRIVATE KEY-----" not in key_text:
                raise AcmeClientError("acme_account_key is not a PEM private key")
            key_data = (key_text + "\n").encode("utf-8")
            existing = None
            if os.path.isfile(path):
                with open(path, "rb") as stream:
                    existing = stream.read()
            if existing != key_data:
                _atomic_write_private_file(path, key_data)
                if debug:
                    _log("DEBUG: Installed the configured ACME account key.")
        elif not os.path.isfile(path):
            _log("Generating a profile-scoped ACME account key...")
            key_data = _cmd(
                ["openssl", "genrsa", "4096"],
                "Generating ACME account key",
                timeout=180,
            )
            _atomic_write_private_file(path, key_data)
        elif debug:
            _log("DEBUG: Reusing the profile-scoped ACME account key.")

        os.chmod(path, 0o600)
        _cmd(
            ["openssl", "rsa", "-in", path, "-check", "-noout"],
            "Validating ACME account key",
        )
    finally:
        try:
            fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(lock_descriptor)


def _account_jwk(account_key_path):
    modulus_output = _cmd(
        ["openssl", "rsa", "-in", account_key_path, "-noout", "-modulus"],
        "Reading ACME account key modulus",
    ).decode("ascii", errors="strict").strip()
    match = re.fullmatch(r"Modulus=([0-9A-Fa-f]+)", modulus_output)
    if not match:
        raise AcmeClientError("Unable to parse the ACME account key modulus")

    key_text = _cmd(
        ["openssl", "rsa", "-in", account_key_path, "-noout", "-text"],
        "Reading ACME account key exponent",
    ).decode("utf-8", errors="replace")
    exponent_match = re.search(r"publicExponent:\s*(\d+)", key_text)
    if not exponent_match:
        raise AcmeClientError("Unable to parse the ACME account key exponent")

    modulus = bytes.fromhex(match.group(1))
    exponent_number = int(exponent_match.group(1))
    exponent = exponent_number.to_bytes(
        max(1, (exponent_number.bit_length() + 7) // 8), "big"
    )
    return {"e": _b64url(exponent), "kty": "RSA", "n": _b64url(modulus)}


def _csr_names(csr_path, avi_common_name=None):
    _cmd(
        ["openssl", "req", "-in", csr_path, "-noout", "-verify"],
        "Verifying CSR signature",
    )
    subject = _cmd(
        ["openssl", "req", "-in", csr_path, "-noout", "-subject", "-nameopt", "RFC2253"],
        "Reading CSR subject",
    ).decode("utf-8", errors="replace").strip()
    text = _cmd(
        ["openssl", "req", "-in", csr_path, "-noout", "-text"],
        "Reading CSR extensions",
    ).decode("utf-8", errors="replace")

    subject_value = subject.split("subject=", 1)[-1].strip()
    common_name_match = re.search(r"(?:^|,)CN=([^,]+)", subject_value)
    csr_common_name = common_name_match.group(1).replace("\\,", ",").strip() if common_name_match else None

    supplied_common_name = str(avi_common_name).strip() if avi_common_name else None
    if csr_common_name and supplied_common_name:
        if csr_common_name.rstrip(".").lower() != supplied_common_name.rstrip(".").lower():
            raise AcmeClientError(
                "AVI common name {!r} does not match CSR common name {!r}".format(
                    supplied_common_name, csr_common_name
                )
            )
    if csr_common_name is None and supplied_common_name:
        csr_common_name = supplied_common_name

    san_values = []
    text_lines = text.splitlines()
    for index, line in enumerate(text_lines):
        if "X509v3 Subject Alternative Name:" not in line:
            continue
        base_indent = len(line) - len(line.lstrip())
        block = []
        for following in text_lines[index + 1 :]:
            if not following.strip():
                continue
            indentation = len(following) - len(following.lstrip())
            if indentation <= base_indent:
                break
            block.append(following.strip())
        san_values.extend(block)

    san_text = " ".join(san_values)
    ip_sans = re.findall(r"IP Address:([^,\s]+)", san_text, flags=re.IGNORECASE)
    if ip_sans:
        raise AcmeClientError(
            "IP address SANs are not supported by this provider: {}".format(
                ", ".join(ip_sans)
            )
        )

    names = re.findall(r"(?:^|,\s*)DNS:([^,\s]+)", san_text, flags=re.IGNORECASE)
    if csr_common_name:
        names.append(csr_common_name)

    normalized = []
    for name in names:
        name = name.strip()
        if not name:
            continue
        if name.endswith("."):
            name = name[:-1]
        if not name or any(char.isspace() for char in name) or "/" in name:
            raise AcmeClientError("Invalid DNS identifier in CSR: {!r}".format(name))
        if len(name) > 253:
            raise AcmeClientError("DNS identifier is too long: {!r}".format(name))
        lowered = name.lower()
        if lowered not in normalized:
            normalized.append(lowered)

    if not normalized:
        raise AcmeClientError("The CSR contains no Common Name or DNS SAN identifiers")
    return sorted(normalized)


def _retry_after_seconds(headers, default=2, maximum=30):
    if headers is None:
        return default
    value = headers.get("Retry-After")
    if not value:
        return default
    try:
        return max(0, min(int(value), maximum))
    except (TypeError, ValueError):
        try:
            retry_at = parsedate_to_datetime(value)
            seconds = int(retry_at.timestamp() - time.time())
            return max(0, min(seconds, maximum))
        except (TypeError, ValueError, OverflowError):
            return default


def _validate_certificate_matches_csr(certificate_pem, csr_path):
    certificate_match = re.search(
        r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
        certificate_pem,
        flags=re.DOTALL,
    )
    if not certificate_match:
        raise AcmeClientError("ACME certificate response did not contain a PEM certificate")

    descriptor, certificate_path = tempfile.mkstemp(prefix="avi-acme-cert-", suffix=".pem")
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            descriptor = None
            stream.write(certificate_match.group(0) + "\n")

        csr_public_key = _cmd(
            ["openssl", "req", "-in", csr_path, "-noout", "-pubkey"],
            "Reading CSR public key",
        )
        certificate_public_key = _cmd(
            ["openssl", "x509", "-in", certificate_path, "-noout", "-pubkey"],
            "Reading issued certificate public key",
        )
        if csr_public_key.strip() != certificate_public_key.strip():
            raise AcmeClientError("Issued certificate public key does not match the CSR")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if os.path.exists(certificate_path):
            os.unlink(certificate_path)


def get_crt(
    csr_path,
    avi_common_name,
    acme_directory_url,
    eab_kid,
    eab_hmac_key,
    contact=None,
    acme_account_key=None,
    request_timeout=DEFAULT_REQUEST_TIMEOUT,
    poll_timeout=DEFAULT_POLL_TIMEOUT,
    debug=False,
):
    """Request a PEM certificate chain from DigiCert using ACME EAB."""

    acme_directory_url = _require_https_url(acme_directory_url, "acme_directory_url")
    hmac_key = _decode_b64url(eab_hmac_key, "eab_hmac_key")
    domains = _csr_names(csr_path, avi_common_name)
    _log("CSR identifiers: {}".format(", ".join(domains)))

    tls_context = ssl.create_default_context()
    available_nonce = [None]
    account_url = [None]

    def http_request(method, url, stage, data=None, headers=None, expected_codes=None):
        _require_https_url(url, "{} URL".format(stage))
        request_headers = {"User-Agent": USER_AGENT}
        if headers:
            request_headers.update(headers)
        request = Request(url, data=data, headers=request_headers, method=method)
        try:
            with urlopen(request, context=tls_context, timeout=request_timeout) as response:
                body = response.read()
                code = response.getcode()
                response_headers = response.headers
        except HTTPError as exc:
            body = exc.read()
            response_headers = exc.headers
            parsed = _parse_response(body, response_headers)
            raise AcmeHttpError(stage, method, url, exc.code, parsed, response_headers)
        except (URLError, OSError, ssl.SSLError) as exc:
            raise AcmeClientError("{}: {} {} failed: {}".format(stage, method, url, exc))

        parsed = _parse_response(body, response_headers)
        if expected_codes is not None and code not in expected_codes:
            raise AcmeHttpError(stage, method, url, code, parsed, response_headers)
        return parsed, code, response_headers

    def remember_nonce(headers):
        if headers is not None:
            nonce = headers.get("Replay-Nonce")
            if nonce:
                available_nonce[0] = nonce

    def new_nonce():
        if available_nonce[0]:
            nonce = available_nonce[0]
            available_nonce[0] = None
            return nonce

        nonce_url = directory["newNonce"]
        try:
            _, _, headers = http_request(
                "HEAD",
                nonce_url,
                "Getting ACME nonce",
                headers={"Accept": "*/*"},
                expected_codes={200, 204},
            )
        except AcmeHttpError as exc:
            if exc.code not in (400, 404, 405, 501):
                raise
            _, _, headers = http_request(
                "GET",
                nonce_url,
                "Getting ACME nonce",
                headers={"Accept": "*/*"},
                expected_codes={200, 204},
            )
        nonce = headers.get("Replay-Nonce") if headers is not None else None
        if not nonce:
            raise AcmeClientError("ACME nonce response did not include Replay-Nonce")
        return nonce

    def signed_request(url, payload, stage, accept="application/json"):
        for attempt in range(MAX_BAD_NONCE_RETRIES + 1):
            payload64 = "" if payload is None else _b64url(_json_bytes(payload))
            protected = {
                "alg": "RS256",
                "nonce": new_nonce(),
                "url": url,
            }
            if account_url[0] is None:
                protected["jwk"] = jwk
            else:
                protected["kid"] = account_url[0]
            protected64 = _b64url(_json_bytes(protected))
            signing_input = "{}.{}".format(protected64, payload64).encode("ascii")
            signature = _cmd(
                ["openssl", "dgst", "-sha256", "-sign", account_key_path],
                "Signing ACME request",
                command_input=signing_input,
            )
            jws = _json_bytes(
                {
                    "payload": payload64,
                    "protected": protected64,
                    "signature": _b64url(signature),
                }
            )
            try:
                result, code, headers = http_request(
                    "POST",
                    url,
                    stage,
                    data=jws,
                    headers={
                        "Accept": accept,
                        "Content-Type": "application/jose+json",
                    },
                    expected_codes={200, 201, 202, 204},
                )
                remember_nonce(headers)
                return result, code, headers
            except AcmeHttpError as exc:
                remember_nonce(exc.headers)
                problem_type = (
                    exc.response.get("type") if isinstance(exc.response, dict) else None
                )
                if (
                    exc.code == 400
                    and problem_type == "urn:ietf:params:acme:error:badNonce"
                    and attempt < MAX_BAD_NONCE_RETRIES
                ):
                    if debug:
                        _log(
                            "DEBUG: ACME rejected a nonce; retrying ({}/{}).".format(
                                attempt + 1, MAX_BAD_NONCE_RETRIES
                            )
                        )
                    continue
                raise
        raise AcmeClientError("ACME badNonce retry limit exceeded")

    _log("Getting ACME directory...")
    directory, _, directory_headers = http_request(
        "GET",
        acme_directory_url,
        "Getting ACME directory",
        headers={"Accept": "application/json"},
        expected_codes={200},
    )
    remember_nonce(directory_headers)
    if not isinstance(directory, dict):
        raise AcmeClientError("ACME directory response was not a JSON object")
    for required_endpoint in ("newNonce", "newAccount", "newOrder"):
        endpoint = directory.get(required_endpoint)
        if not endpoint:
            raise AcmeClientError(
                "ACME directory is missing required endpoint: {}".format(required_endpoint)
            )
        _require_https_url(endpoint, "ACME {}".format(required_endpoint))

    account_key_path = _account_key_path(acme_directory_url, eab_kid, hmac_key)
    _prepare_account_key(account_key_path, acme_account_key, debug=debug)
    jwk = _account_jwk(account_key_path)

    _log("Registering or locating the ACME account...")
    eab_protected64 = _b64url(
        _json_bytes({"alg": "HS256", "kid": eab_kid, "url": directory["newAccount"]})
    )
    eab_payload64 = _b64url(_json_bytes(jwk))
    eab_signing_input = "{}.{}".format(eab_protected64, eab_payload64).encode("ascii")
    eab_signature = hmac.new(hmac_key, eab_signing_input, hashlib.sha256).digest()
    external_account_binding = {
        "payload": eab_payload64,
        "protected": eab_protected64,
        "signature": _b64url(eab_signature),
    }

    registration_payload = {
        "externalAccountBinding": external_account_binding,
        "termsOfServiceAgreed": True,
    }
    if contact:
        registration_payload["contact"] = contact

    account, account_code, account_headers = signed_request(
        directory["newAccount"], registration_payload, "Registering ACME account"
    )
    location = account_headers.get("Location") if account_headers is not None else None
    if not location:
        raise AcmeClientError("ACME account response did not include a Location header")
    account_url[0] = _require_https_url(location, "ACME account")
    _log("ACME account {}.".format("created" if account_code == 201 else "located"))

    if contact and isinstance(account, dict) and account.get("contact") != contact:
        signed_request(
            account_url[0], {"contact": contact}, "Updating ACME account contact"
        )

    _log("Creating ACME order...")
    order_payload = {
        "identifiers": [{"type": "dns", "value": domain} for domain in domains]
    }
    order, _, order_headers = signed_request(
        directory["newOrder"], order_payload, "Creating ACME order"
    )
    if not isinstance(order, dict):
        raise AcmeClientError("ACME newOrder response was not a JSON object")
    order_url = order_headers.get("Location") if order_headers is not None else None
    if not order_url:
        raise AcmeClientError("ACME newOrder response did not include a Location header")
    order_url = _require_https_url(order_url, "ACME order")

    authorizations = order.get("authorizations")
    if not isinstance(authorizations, list):
        raise AcmeClientError("ACME order did not contain an authorizations list")
    for authorization_url in authorizations:
        authorization, _, _ = signed_request(
            authorization_url, None, "Reading ACME authorization"
        )
        if not isinstance(authorization, dict):
            raise AcmeClientError("ACME authorization response was not a JSON object")
        identifier = authorization.get("identifier", {}).get("value", "<unknown>")
        if authorization.get("wildcard"):
            identifier = "*.{}".format(identifier)
        status = authorization.get("status")
        _log("Authorization for {}: {}".format(identifier, status or "unknown"))
        if status == "valid":
            continue
        if status == "pending":
            raise AcmeClientError(
                "Domain {} is not pre-validated in DigiCert; this provider does not "
                "implement HTTP-01 or DNS-01 challenges".format(identifier)
            )
        raise AcmeClientError(
            "Authorization for {} is {}: {}".format(
                identifier, status or "unknown", _safe_response_text(authorization)
            )
        )

    finalize_url = order.get("finalize")
    if not finalize_url:
        raise AcmeClientError("ACME order did not contain a finalize URL")
    _log("Finalizing ACME order...")
    csr_der = _cmd(
        ["openssl", "req", "-in", csr_path, "-outform", "DER"],
        "Converting CSR to DER",
    )
    current_order, _, current_headers = signed_request(
        finalize_url,
        {"csr": _b64url(csr_der)},
        "Finalizing ACME order",
    )

    deadline = time.monotonic() + poll_timeout
    while True:
        if not isinstance(current_order, dict):
            current_order = {}
        status = current_order.get("status")
        if status == "valid":
            break
        if status == "invalid":
            raise AcmeClientError(
                "ACME order became invalid: {}".format(_safe_response_text(current_order))
            )
        if status not in (None, "pending", "ready", "processing"):
            raise AcmeClientError(
                "ACME order returned unexpected status {!r}: {}".format(
                    status, _safe_response_text(current_order)
                )
            )

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AcmeClientError(
                "Timed out after {} seconds waiting for DigiCert to issue the certificate; "
                "check whether the TLM request requires approval".format(poll_timeout)
            )
        delay = min(_retry_after_seconds(current_headers), remaining)
        if debug:
            _log(
                "DEBUG: Order status is {}; checking again in {} seconds.".format(
                    status or "not supplied", int(delay)
                )
            )
        time.sleep(delay)
        current_order, _, current_headers = signed_request(
            order_url, None, "Polling ACME order"
        )

    certificate_url = current_order.get("certificate")
    if not certificate_url:
        raise AcmeClientError("Valid ACME order did not contain a certificate URL")
    _log("Downloading issued certificate...")
    certificate_pem, _, _ = signed_request(
        certificate_url,
        None,
        "Downloading issued certificate",
        accept="application/pem-certificate-chain",
    )
    if not isinstance(certificate_pem, str):
        raise AcmeClientError("ACME certificate response was not PEM text")
    _validate_certificate_matches_csr(certificate_pem, csr_path)
    _log("Certificate issued and validated successfully.")
    return certificate_pem


def certificate_request(csr, common_name, kwargs):
    """Entry point required by VMware Avi Certificate Management Profiles."""

    kwargs = kwargs or {}
    debug = False
    csr_path = None
    _log("Running DigiCert TLM ACME provider version {}".format(VERSION))

    try:
        debug = _as_bool(kwargs.get("debug", "false"))
        acme_directory_url = _required_text(kwargs, "acme_directory_url")
        eab_kid = _required_text(kwargs, "eab_kid")
        eab_hmac_key = _required_text(kwargs, "eab_hmac_key")
        contact = _normalize_contact(kwargs.get("contact"))
        acme_account_key = kwargs.get("acme_account_key")
        request_timeout = _positive_int(
            kwargs.get("request_timeout_seconds"),
            "request_timeout_seconds",
            DEFAULT_REQUEST_TIMEOUT,
            300,
        )
        poll_timeout = _positive_int(
            kwargs.get("poll_timeout_seconds"),
            "poll_timeout_seconds",
            DEFAULT_POLL_TIMEOUT,
            3600,
        )

        if not isinstance(csr, str) or "-----BEGIN CERTIFICATE REQUEST-----" not in csr:
            raise AcmeClientError("AVI did not provide a PEM certificate signing request")

        descriptor, csr_path = tempfile.mkstemp(prefix="avi-acme-csr-", suffix=".pem")
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(csr)

        if debug:
            _log("DEBUG: Request timeout: {} seconds".format(request_timeout))
            _log("DEBUG: Poll timeout: {} seconds".format(poll_timeout))
            _log("DEBUG: Contact configured: {}".format(bool(contact)))
            _log("DEBUG: Explicit account key configured: {}".format(bool(acme_account_key)))

        return get_crt(
            csr_path=csr_path,
            avi_common_name=common_name,
            acme_directory_url=acme_directory_url,
            eab_kid=eab_kid,
            eab_hmac_key=eab_hmac_key,
            contact=contact,
            acme_account_key=acme_account_key,
            request_timeout=request_timeout,
            poll_timeout=poll_timeout,
            debug=debug,
        )
    except Exception as exc:
        print(
            "ERROR: DigiCert TLM ACME certificate request failed: {}".format(exc),
            file=sys.stderr,
            flush=True,
        )
        if debug:
            traceback.print_exc(file=sys.stderr)
        raise
    finally:
        if csr_path and os.path.exists(csr_path):
            try:
                os.unlink(csr_path)
            except OSError as exc:
                print(
                    "WARNING: Unable to remove temporary CSR file: {}".format(exc),
                    file=sys.stderr,
                    flush=True,
                )
