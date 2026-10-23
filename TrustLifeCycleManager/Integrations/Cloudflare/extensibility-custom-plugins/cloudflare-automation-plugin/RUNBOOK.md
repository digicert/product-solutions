# Cloudflare automation plugin – manual test procedure

Run this against a real zone **before** uploading the plugin to TLM, and again whenever Cloudflare
or the plugin changes. Every step issues the same API call the plugin makes
(`runbook/cloudflare-runbook.sh`), so a step that works here works in the plugin and vice versa.

Prerequisites: `curl`, `jq`, `openssl`; a zone on a **Business or Enterprise** plan (custom
certificates are not available on Free/Pro); an API token with *Zone → SSL and Certificates → Edit*
and *Zone → Zone → Read* on that zone.

```bash
export CF_ZONE_ID=<32-hex zone id>
export CF_API_TOKEN='<token>'
cd runbook
```

| Step | Command | Plugin operation | Expect |
|---|---|---|---|
| 0 | `./cloudflare-preflight.sh` (add `--write-test` to also create and delete one throwaway CSR) | all | every check PASS; a WARN on *certificate body retrievable from the edge* means TLM will list that asset without a certificate; the script exits 1 on any FAIL |
| 1 | `./cloudflare-runbook.sh verify` | testConnection | `success: true`, `result.status: active` |
| 2 | `./cloudflare-runbook.sh zone` | testConnection / discovery | zone `name`, `status: active`, plan name |
| 3 | `./cloudflare-runbook.sh certs` | refreshConfiguration | one line per custom certificate with `hosts`, `status`, `expires_on` |
| 4 | `./cloudflare-runbook.sh discover` | refreshConfiguration | for each host a served certificate whose `notAfter` equals the listed `expires_on` → the plugin will have the PEM; if the probe shows a different certificate (Universal SSL, origin), the asset is surfaced without body |
| 5 | `./cloudflare-runbook.sh csr www.example.com example.com` | generateCsr (Cloudflare mode) | `id` + PEM `csr`; note the id |
| 6 | submit the CSR to the CA (TLM / DigiCert ONE), save the leaf (+ ICA) as `cert.pem` | – | – |
| 7a | `./cloudflare-runbook.sh update <existing id> cert.pem csr:<csr id>` | installCertificate (update strategy) | `success: true`, same `id`, new `expires_on`, `status: active` (or `pending` for a few seconds) |
| 7b | `./cloudflare-runbook.sh upload cert.pem csr:<csr id> sni_custom force` then `delete <old id>` | installCertificate (replace strategy) | new `id`; old one gone from `certs` |
| 8 | `./cloudflare-runbook.sh cert <id>` and `probe www.example.com` | validateCertificate | `status: active`, `expires_on` = leaf notAfter; probe serves the new serial (edge propagation can take a minute) |
| 9 | `./cloudflare-runbook.sh csrs` / `delete-csr <old id>` | CSR clean-up | older CSRs for the CN removed, current one kept |

Sensor-key mode: generate the key/CSR locally instead of step 5
(`openssl req -new -newkey rsa:2048 -nodes -keyout key.pem -out req.csr -subj '/CN=www.example.com/O=…/L=…/ST=…/C=US'`)
and pass `key.pem` instead of `csr:<id>` in steps 7a/7b.

Record the outcome (date, zone, plan, which steps passed) in the README's *Tested with* section.
