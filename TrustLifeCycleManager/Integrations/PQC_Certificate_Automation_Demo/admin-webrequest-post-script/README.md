# `pqc-certificate-install-awr.sh` — TLM AWR Post-Enrollment Script

A DigiCert **Trust Lifecycle Manager (TLM)** *Admin Web Request* (AWR) post-enrollment
script. TLM runs it on the target host immediately after a certificate is issued and the
files are written to disk. This one takes the freshly issued **PQC (ML-DSA)** certificate
and key, validates them, deploys them to an Apache **PQC vhost**, gracefully reloads
Apache, and then proves the new certificate is actually being served.

Everything the script does is written to a timestamped log file — it produces **no stdout**
and returns only an exit code.

---

## Where it fits

```
   DigiCert TLM                      Target host (Ubuntu + Apache built against OpenSSL 3.5)
   ────────────                      ──────────────────────────────────────────────────────
   1. Issues ML-DSA cert
   2. Agent writes .crt/.key ───────►  <certfolder>/<name>.crt  +  <name>.key
   3. Runs AWR post-script     ───────►  pqc-certificate-install-awr.sh
      with DC1_POST_SCRIPT_DATA           │  validate → deploy → configtest → graceful reload → probe
      (base64 JSON) in the env            ▼
                                       /opt/httpd-pqc/conf/tlm-pqc.crt  (what the vhost serves)
```

The companion lab that builds the Apache/OpenSSL side lives in
[../setup-demo-environment/](../setup-demo-environment/).

---

## Structure of the script

The file has two halves. The first is a **reusable AWR template**; the second is the
**custom logic** for this integration. Only the second half is PQC-specific.

| Lines | Section | What it does |
|-------|---------|--------------|
| 3–31 | Legal notice | DigiCert legal header (a no-op heredoc, not executed). |
| 34–62 | Configuration + gate | Sets `LOGFILE`, defines `log_message()`, and refuses to run unless `LEGAL_NOTICE_ACCEPT="true"`. |
| 64–204 | **Template: payload extraction** | Decodes `DC1_POST_SCRIPT_DATA` and pulls out the cert folder, filenames, and up to 15 profile arguments. |
| 237–270 | Template: sanity logging | Confirms the cert/key exist, counts certs in the chain file, detects the key encoding (RSA / EC / PKCS#8). |
| 272–443 | **Custom: PQC vhost deploy** | Validate → guard → deploy → configtest → graceful reload → health probe. |

### The template half — `DC1_POST_SCRIPT_DATA`

TLM passes a single environment variable, `DC1_POST_SCRIPT_DATA`, containing
**base64-encoded JSON**. The script decodes it and extracts:

| Variable | From | Meaning |
|----------|------|---------|
| `CERT_FOLDER` | `"certfolder"` | Directory the agent wrote the certificate into. |
| `CRT_FILE` / `KEY_FILE` | `"files":[…]` | The `.crt` and `.key` filenames. |
| `CRT_FILE_PATH` / `KEY_FILE_PATH` | derived | `${CERT_FOLDER}/${CRT_FILE}` and `…/${KEY_FILE}`. |
| `ARGUMENT_1` … `ARGUMENT_15` | `"args":[…]` | Free-form arguments configured on the TLM profile. |

Extraction is done with `grep -oP` / `awk` (GNU grep required — this is a Linux-only
script). The decoded JSON is logged verbatim, which makes debugging a profile
misconfiguration straightforward: look at the `Raw JSON content:` block in the log.

If `DC1_POST_SCRIPT_DATA` is unset, the script logs an error and exits `1`.

### The custom half — what actually happens on the host

| # | Step | Failure behaviour |
|---|------|-------------------|
| 0 | Check the PQC OpenSSL binary is executable and the issued cert/key both exist. | `exit 1`, nothing touched. |
| 1 | Parse the certificate with the PQC OpenSSL; log its **subject** and **signature algorithm**. | `exit 1`, nothing touched. |
| 2 | Parse the private key. On failure, log an ML-DSA hint (FIPS 204 *seed-only vs expanded* encoding). | `exit 1`, nothing touched. |
| 3 | **Guard:** confirm key matches cert by SHA-256 of the derived public keys. | `exit 1` — cert not deployed. |
| 4 | Copy cert and key to the deploy paths, `chmod 644` / `600`, log the chain count. | `exit 1` on copy failure (permissions). |
| 5 | `apachectl configtest`. | `exit 1` — **not** reloaded, live server unaffected. |
| 6 | `apachectl -k graceful` if httpd is running, otherwise `-k start`. | `exit 1`, points at Apache's `error_log`. |
| 7 | **Health probe:** `s_client` to `127.0.0.1:<port>` with SNI from the cert CN; compare served vs deployed SHA-256 fingerprint. | Logs a `WARNING` only — exit stays `0`. |

Two design points worth calling out:

- **The key/cert match is compared via public keys, not modulus.** ML-DSA has no modulus,
  so the usual `-modulus | md5` trick doesn't work. Comparing
  `x509 -pubkey` against `pkey -pubout` is algorithm-agnostic and works for RSA, ECC, and ML-DSA alike.
- **Validation happens before the reload.** Apache keeps its currently loaded certificate
  in memory until a successful reload, so any failure in steps 0–5 leaves the live service
  serving the old, working certificate.

> **Certificates are overwritten in place. No backup is taken.** This is deliberate for the
> demo/lab flow. If you need rollback, add a `cp` of the existing files before step 4.

---

## Configuration

### Must be set

| Setting | Line | Notes |
|---------|------|-------|
| `LEGAL_NOTICE_ACCEPT` | 35 | Must be `"true"` or the script exits `1` immediately. |
| `LOGFILE` | 36 | Defaults to `/home/ubuntu/awr-template-logfile.log`. Change it if the TLM agent runs as a different user or the host isn't Ubuntu — the script cannot log its own failure if this path isn't writable. |

### PQC deploy block (lines 338–345)

| Variable | Default | Override |
|----------|---------|----------|
| `APACHE_PREFIX` | `/opt/httpd-pqc` | edit script |
| `PQC_OPENSSL` | `/opt/openssl-pqc/bin/openssl` | edit script |
| `DEPLOY_CRT` | `${APACHE_PREFIX}/conf/tlm-pqc.crt` | `ARGUMENT_1` |
| `DEPLOY_KEY` | `${APACHE_PREFIX}/conf/tlm-pqc.key` | `ARGUMENT_2` |
| `PQC_VHOST_PORT` | `8443` | `ARGUMENT_3` |

`ARGUMENT_1/2/3` come from the TLM profile's **argument list**. Passing them from TLM keeps
one copy of the script generic across hosts rather than forking it per environment; leave
them empty and the defaults apply.

> `PQC_OPENSSL` **must** be a PQC-capable OpenSSL (3.5+). The distro's system OpenSSL cannot
> parse ML-DSA and every validation step would fail — or, worse, mislead you.

---

## Deploying it in TLM

1. Attach this file as the certificate profile's **post-enrollment (AWR) script**.
2. Set `LEGAL_NOTICE_ACCEPT="true"`.
3. Set `LOGFILE` to a path the agent's user can write.
4. Optionally add the deploy cert path, key path, and port as profile arguments 1, 2, 3.
5. Make sure the agent's execution user can **write to the Apache `conf` directory** and
   **run `apachectl`** (root is simplest; otherwise grant ownership plus `sudo` on `apachectl`).
6. Confirm the vhost's `SSLCertificateFile` / `SSLCertificateKeyFile` point at exactly the
   same paths as `DEPLOY_CRT` / `DEPLOY_KEY` — this is the single most common misconfiguration.

Host requirements: Linux with **GNU grep** (`grep -oP`), `base64`, `awk`, `stat -c`, `pgrep`,
Apache built against OpenSSL 3.5+, and the PQC OpenSSL at `PQC_OPENSSL`.

---

## Reading the log

A successful run ends with:

```
[…] GUARD: key matches certificate (public keys identical).
[…] Deployed cert -> /opt/httpd-pqc/conf/tlm-pqc.crt (certs in file: 1), key -> …. Overwritten, no backup.
[…] apachectl configtest: Syntax OK
[…] Apache gracefully reloaded.
[…] Health probe: SNI=pqc-demo.digicert-demo.com  deployed_fp=AB:CD:…  served_fp=AB:CD:…
[…] SUCCESS: PQC vhost on :8443 is serving the newly issued certificate (ML-DSA-87).
[…] Script execution completed
```

Exit code is `0` on success and on a *served-fingerprint mismatch* (step 7 warns but does not
fail); `1` for any earlier failure.

---

## Troubleshooting

| Log line | Cause / fix |
|----------|-------------|
| `ERROR: DC1_POST_SCRIPT_DATA environment variable is not set` | Script wasn't invoked as an AWR post-enrollment hook, or was run manually. To test by hand, export a base64 JSON payload first. |
| `ERROR: Legal notice not accepted` | Set `LEGAL_NOTICE_ACCEPT="true"` on line 35. |
| `ERROR: PQC-capable OpenSSL not found/executable` | Fix `PQC_OPENSSL`, or the OpenSSL 3.5 build isn't installed on this host. |
| `ERROR: certificate failed to parse` | Almost always the wrong OpenSSL. Verify with `/opt/openssl-pqc/bin/openssl x509 -in <cert> -noout -text`. |
| `ERROR: private key failed to parse` … *ML-DSA seed vs expanded* | FIPS 204 private-key encoding mismatch — TLM emitted one form, this OpenSSL build accepts the other. |
| `ERROR: private key does NOT match certificate` | The agent wrote a key from a different enrollment, or `"files"` extraction picked up the wrong `.key`. Check the `Files array content:` line. |
| `ERROR: failed to write …` | The agent's user can't write to `/opt/httpd-pqc/conf`. |
| `ERROR: 'apachectl configtest' failed` | Config error unrelated to the cert, or the vhost references a path that no longer exists. Live server is untouched. |
| `WARNING: served cert fingerprint does not match deployed cert` | The vhost `SSLCertificateFile` points somewhere other than `DEPLOY_CRT`, or the vhost isn't on `PQC_VHOST_PORT`. The cert was deployed — it just isn't the one being served. |
| Nothing in the log at all | `LOGFILE` isn't writable by the agent's user. |
| Empty `CERT_FOLDER` / `CRT_FILE` | Non-GNU `grep` (no `-oP`), or the payload shape differs from what the extractors expect. Compare against the `Raw JSON content:` block. |

Manual verification of the deployed pair, always with the PQC OpenSSL:

```bash
OSSL=/opt/openssl-pqc/bin/openssl

$OSSL x509 -in /opt/httpd-pqc/conf/tlm-pqc.crt -noout -text | grep -i "Signature Algorithm"
diff <($OSSL x509 -in /opt/httpd-pqc/conf/tlm-pqc.crt -noout -pubkey) \
     <($OSSL pkey -in /opt/httpd-pqc/conf/tlm-pqc.key -pubout)          # no output = match
echo | $OSSL s_client -connect 127.0.0.1:8443 -brief 2>&1 | grep -iE "Signature type|Verification"
```

---

## Adapting it

The template half (payload extraction, logging, existence checks) is generic to any TLM AWR
post-enrollment task. To repurpose the script, replace only the block between
`# ADD CUSTOM LOGIC HERE:` (line 323) and `# END CUSTOM LOGIC` (line 444). The variables
available there are documented inline at lines 276–313 — cert paths, `CERT_COUNT`, `KEY_TYPE`,
`ARGUMENT_1`–`ARGUMENT_15`, the raw `JSON_STRING`, and the `log_message` helper.

Known gaps in the current custom block:

- **Chain handling.** If TLM emits the issuing chain as a *separate* file, Apache will serve
  the leaf only. Concatenate it (leaf first) into `DEPLOY_CRT` — see the note at line 401.
- **No rollback.** Deployment overwrites without a backup, by design.
- **Single vhost.** One cert/key pair, one port. Deploying to several vhosts means looping
  over additional arguments.
