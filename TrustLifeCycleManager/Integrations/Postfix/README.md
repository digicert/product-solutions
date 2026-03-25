# Postfix — TLS Certificate Automation

<img src="https://img.shields.io/badge/Platform-Ubuntu%2024.04-orange?style=flat-square&logo=ubuntu" alt="Ubuntu 24.04"> <img src="https://img.shields.io/badge/Service-Postfix%20SMTP-005FF9?style=flat-square&logo=postfix" alt="Postfix"> <img src="https://img.shields.io/badge/Script-Bash-4EAA25?style=flat-square&logo=gnu-bash" alt="Bash"> <img src="https://img.shields.io/badge/Key%20Types-RSA%20%7C%20ECC-blue?style=flat-square" alt="RSA and ECC">

Production-ready reference script for automated TLS certificate replacement on [Postfix](http://www.postfix.org/) SMTP servers using DigiCert Trust Lifecycle Manager (TLM) Admin Web Request (AWR) post-enrollment hooks.

## Overview

This script is triggered automatically by the DigiCert TLM agent after a certificate is enrolled or renewed. It replaces the TLS certificate used by Postfix for STARTTLS on inbound SMTP connections, validates the new certificate and key, reloads the service, and logs comprehensive before/after evidence of the change.

## How It Works

```
DigiCert TLM                    AWR Post-Enrollment Script                  Postfix
─────────────                   ──────────────────────────                  ───────
                                
Certificate enrolled ──────────►  1. Decode DC1_POST_SCRIPT_DATA
                                  2. Extract cert/key paths
                                  3. Log BEFORE config + live STARTTLS cert
                                  4. Validate cert/key pair match
                                  5. Update main.cf via postconf
                                  6. Reload Postfix  ──────────────────────► New cert served
                                  7. Log AFTER config + live STARTTLS cert
```

## What the Script Does

| Step | Action | Detail |
|------|--------|--------|
| 1 | **BEFORE snapshot** | Reads current `smtpd_tls_cert_file` and `smtpd_tls_key_file` from Postfix configuration using `postconf`. Logs certificate serial, subject, issuer, and validity dates from both the file on disk and a live STARTTLS connection. |
| 2 | **Validate new certificate** | Confirms the new `.crt` and `.key` files exist. Extracts public keys from both and compares hashes to verify they match. Works with both RSA and ECC key types. |
| 3 | **Update Postfix configuration** | Uses `postconf -e` to update `smtpd_tls_cert_file`, `smtpd_tls_key_file`, and ensures `smtpd_tls_security_level = may` is set. |
| 4 | **Reload Postfix** | Reloads the Postfix service to apply the new certificate. Falls back to a full restart if reload fails. Controlled by the `RESTART_POSTFIX` configuration option. |
| 5 | **AFTER snapshot** | Reads the updated Postfix configuration and performs a second live STARTTLS connection to confirm the new certificate is being served. |
| 6 | **Summary** | Logs a side-by-side comparison of the BEFORE and AFTER certificate and key file paths. |

## Certificate/Key Validation

The script uses **public key hash comparison** rather than modulus comparison to verify the certificate and key match. This approach works reliably across both RSA and ECC key types and all OpenSSL versions.

```
openssl x509 -noout -pubkey -in cert.crt | openssl md5    ──┐
                                                             ├── must match
openssl pkey -pubout -in cert.key | openssl md5            ──┘
```

> **Note:** The more commonly referenced `openssl pkey -noout -modulus` command returns empty output for ECC keys on some OpenSSL builds, which can cause false validation failures. The public key extraction method avoids this issue entirely.

## Live STARTTLS Verification

The script performs live STARTTLS checks before and after the certificate replacement to prove what Postfix is actually presenting to connecting mail clients:

```bash
openssl s_client -connect localhost:25 -starttls smtp -servername <myhostname>
```

The `servername` is read automatically from the Postfix configuration (`postconf -h myhostname`), so no hardcoding is required.

## Configuration

The following variables are configured at the top of the script:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to execute the script. Acknowledges the DigiCert legal notice. |
| `RESTART_POSTFIX` | `"true"` | Set to `"true"` to automatically reload Postfix after certificate replacement. Set to `"false"` to update the configuration only (manual reload required). |
| `LOGFILE` | `"/home/ubuntu/tls-guru.log"` | Path to the log file for all script output. |

## AWR Argument Mapping

| Argument | Purpose |
|----------|---------|
| `ARGUMENT_1` | Not used — available for future use |
| `ARGUMENT_2` | Not used — available for future use |
| `ARGUMENT_3` | Not used — available for future use |
| `ARGUMENT_4` | Not used — available for future use |
| `ARGUMENT_5` | Not used — available for future use |

The certificate and key file paths are extracted automatically from the `DC1_POST_SCRIPT_DATA` JSON payload (fields: `certfolder`, `files`).

## Prerequisites

- **Postfix** installed and running with TLS enabled (or the script will enable `smtpd_tls_security_level = may`)
- **OpenSSL** available on the system
- **DigiCert TLM agent** installed and configured with an Admin Web Request profile
- The script must run as **root** (or a user with permission to modify Postfix configuration and reload the service)

## Example Log Output

```
[2026-03-25 10:47:58] ==========================================
[2026-03-25 10:47:58] Starting Postfix TLS certificate replacement...
[2026-03-25 10:47:58] ==========================================
[2026-03-25 10:47:58] --- BEFORE: Current Postfix TLS Configuration ---
[2026-03-25 10:47:58]   smtpd_tls_cert_file = /etc/ssl/certs/ssl-cert-snakeoil.pem
[2026-03-25 10:47:58]   smtpd_tls_key_file  = /etc/ssl/private/ssl-cert-snakeoil.key
[2026-03-25 10:47:58] --- BEFORE: Current certificate details (from file) ---
[2026-03-25 10:47:58]   serial=0B5F25334FC89F8D73C28E53125C24E6
[2026-03-25 10:47:58]   subject=C = US, ST = Utah, L = Saratoga Springs, O = "Win The Customer, LLC", CN = mail.tlsdemo.com
[2026-03-25 10:47:58]   issuer=C = US, O = "DigiCert, Inc.", CN = DigiCert G5 TLS RSA4096 SHA384 2021 CA1
[2026-03-25 10:47:58]   notBefore=Mar 25 00:00:00 2026 GMT
[2026-03-25 10:47:58]   notAfter=Mar 31 23:59:59 2026 GMT
[2026-03-25 10:47:58] --- BEFORE: Live STARTTLS Certificate (servername: postfix.tlsdemo.com) ---
[2026-03-25 10:47:58]   serial=0B5F25334FC89F8D73C28E53125C24E6
[2026-03-25 10:47:58]   subject=C = US, ST = Utah, L = Saratoga Springs, O = "Win The Customer, LLC", CN = mail.tlsdemo.com
[2026-03-25 10:47:58]   issuer=C = US, O = "DigiCert, Inc.", CN = DigiCert G5 TLS RSA4096 SHA384 2021 CA1
[2026-03-25 10:47:58]   notBefore=Mar 25 00:00:00 2026 GMT
[2026-03-25 10:47:58]   notAfter=Mar 31 23:59:59 2026 GMT
[2026-03-25 10:47:58] --- End BEFORE Live STARTTLS Certificate ---
[2026-03-25 10:47:58] Validating new certificate and key files...
[2026-03-25 10:47:58] Certificate and private key match confirmed (public key hash)
[2026-03-25 10:47:58]   Public key hash: MD5(stdin)= a1b2c3d4e5f6...
[2026-03-25 10:47:58] --- New certificate details ---
[2026-03-25 10:47:58]   serial=0A1B2C3D4E5F...
[2026-03-25 10:47:58]   subject=CN = mail.tlsdemo.com
[2026-03-25 10:47:58]   issuer=C = US, O = "DigiCert, Inc.", CN = DigiCert G5 TLS RSA4096 SHA384 2021 CA1
[2026-03-25 10:47:58]   notBefore=Mar 25 00:00:00 2026 GMT
[2026-03-25 10:47:58]   notAfter=Jun 25 23:59:59 2026 GMT
[2026-03-25 10:47:58] Updating Postfix TLS configuration...
[2026-03-25 10:47:58] Successfully updated smtpd_tls_cert_file = /opt/digicert/certs/mail.tlsdemo.com.crt
[2026-03-25 10:47:58] Successfully updated smtpd_tls_key_file = /opt/digicert/certs/mail.tlsdemo.com.key
[2026-03-25 10:47:58] Reloading Postfix to apply new certificate...
[2026-03-25 10:47:58] Postfix reloaded successfully
[2026-03-25 10:48:00] --- AFTER: Updated Postfix TLS Configuration ---
[2026-03-25 10:48:00]   smtpd_tls_cert_file = /opt/digicert/certs/mail.tlsdemo.com.crt
[2026-03-25 10:48:00]   smtpd_tls_key_file  = /opt/digicert/certs/mail.tlsdemo.com.key
[2026-03-25 10:48:00] --- AFTER: Live STARTTLS Certificate (servername: postfix.tlsdemo.com) ---
[2026-03-25 10:48:00]   serial=0A1B2C3D4E5F...
[2026-03-25 10:48:00]   subject=CN = mail.tlsdemo.com
[2026-03-25 10:48:00]   issuer=C = US, O = "DigiCert, Inc.", CN = DigiCert G5 TLS RSA4096 SHA384 2021 CA1
[2026-03-25 10:48:00]   notBefore=Mar 25 00:00:00 2026 GMT
[2026-03-25 10:48:00]   notAfter=Jun 25 23:59:59 2026 GMT
[2026-03-25 10:48:00] --- End AFTER Live STARTTLS Certificate ---
[2026-03-25 10:48:00] ==========================================
[2026-03-25 10:48:00] POSTFIX CERTIFICATE REPLACEMENT SUMMARY:
[2026-03-25 10:48:00] ==========================================
[2026-03-25 10:48:00]   BEFORE cert file: /etc/ssl/certs/ssl-cert-snakeoil.pem
[2026-03-25 10:48:00]   AFTER  cert file: /opt/digicert/certs/mail.tlsdemo.com.crt
[2026-03-25 10:48:00]   BEFORE key file:  /etc/ssl/private/ssl-cert-snakeoil.key
[2026-03-25 10:48:00]   AFTER  key file:  /opt/digicert/certs/mail.tlsdemo.com.key
[2026-03-25 10:48:00]   Postfix reloaded: true
[2026-03-25 10:48:00] ==========================================
```

## Security Considerations

- The script includes **credential obfuscation** in logging — private key content is never written to the log file.
- Certificate/key validation is performed **before** any configuration changes are applied.
- The script exits with a non-zero status on any critical failure, preventing partial or broken configurations.
- A **legal notice gate** must be explicitly accepted before the script will execute.

## Files

| File | Description |
|------|-------------|
| `awr-postfix-crt.sh` | AWR post-enrollment script for Postfix TLS certificate replacement |

## Related Resources

- [DigiCert Trust Lifecycle Manager Documentation](https://docs.digicert.com)
- [Postfix TLS Support](http://www.postfix.org/TLS_README.html)