# DigiCert TLM Agent — IBM WebSphere Application Server Certificate Rotation AWR Post-Delivery Script

## Overview

Bash automation script that rotates the active SSL/TLS certificate in **IBM WebSphere Application Server (traditional)** running in a Podman container, triggered by the DigiCert TLM Agent as a post-delivery script on every renewal.

The script receives the newly delivered PKCS12 via `DC1_POST_SCRIPT_DATA` and:

1. Backs up the full keystore (`key.p12`), trust store (`trust.p12`), and security config (`security.xml`), plus exports the current live cert+key to a standalone password-protected PFX.
2. Imports the new cert into `NodeDefaultKeyStore` under a fresh timestamped alias (`<cert-CN>_<timestamp>`), then calls `replaceCertificate` and `modifySSLConfig` to bind it to `NodeDefaultSSLSettings` (covers both admin console port 9043 and app HTTPS port 9443).
3. Restarts the WAS container and verifies the new cert is served on both ports.
4. On any failure after the swap begins, automatically restores the backup and restarts, leaving WAS in its pre-swap state.

## Scripts

| File | Platform | Shell |
|------|----------|-------|
| [Linux/websphere-awr.sh](Linux/websphere-awr.sh) | Linux | Bash |

## Requirements

- Bash 4.0 or later.
- Podman installed on the host (when `RUN_IN_CONTAINER="true"`), with the WAS container running.
- `openssl` on the host PATH for Phase 6 certificate verification (non-fatal if absent).
- WAS Java `keytool` accessible inside the container at the configured path.
- `wsadmin.sh` accessible inside the container at the profile `bin/` path.
- Network access from the TLM Agent host to the Podman socket (local).
- A secrets file at `/opt/digicert/conf/was-cert.conf` (root:root, mode `600`) or equivalent environment variables.

## Secrets

Create `/opt/digicert/conf/was-cert.conf` (root:root, mode `600`) with the following content and fill in the real passwords:

```bash
# was-cert.conf -- secrets for websphere-awr.sh
# Install: sudo cp was-cert.conf /opt/digicert/conf/was-cert.conf
#          sudo chown root:root /opt/digicert/conf/was-cert.conf
#          sudo chmod 600 /opt/digicert/conf/was-cert.conf
# Do NOT commit this file to source control.

WAS_ADMIN_PASS='<websphere-admin-password>'
KEYSTORE_PASS='<keystore-password>'
BACKUP_PFX_PASS='<backup-pfx-password>'

# Optional overrides (uncomment to override script defaults)
# PFX_PASSWORD='<pfx-delivery-password>'
# CELL_NAME='DefaultCell01'
# NODE_NAME='DefaultNode01'
# SERVER_NAME='server1'
# CONTAINER_NAME='was1'
# CERT_FOLDER='/opt/digicert/certs'
# TARGET_ALIAS='default'
```

| Variable | Description |
|----------|-------------|
| `WAS_ADMIN_PASS` | WebSphere administrative console password (for the user set in `WAS_ADMIN_USER`) |
| `KEYSTORE_PASS` | Password for `key.p12` and `trust.p12` (WAS default is `WebAS`) |
| `PFX_PASSWORD` | Password on the TLM-delivered PFX. Also accepted from the `DC1_POST_SCRIPT_DATA` payload `password` field — that takes precedence |
| `BACKUP_PFX_PASS` | Password protecting the exported old-cert PFX written to `BACKUP_DIR`. Optional — if not set, the standalone export is skipped (full `key.p12` backup still covers rollback) |

Resolved at runtime with precedence **environment variable > secrets file > clean failure**. The script refuses to source the file unless its permissions are `600` or `400`.

## Configuration

Edit the `CONFIGURATION` block at the top of the script before deploying:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEGAL_NOTICE_ACCEPT` | `"false"` | Must be set to `"true"` to allow execution |
| `RUN_IN_CONTAINER` | `"true"` | `true` = run wsadmin via `podman exec`; `false` = bare-metal host |
| `CONTAINER_NAME` | `"was1"` | Podman container name hosting WAS |
| `WAS_PROFILE` | `/opt/IBM/WebSphere/AppServer/profiles/AppSrv01` | Full path to the WAS profile directory |
| `CELL_NAME` | `"DefaultCell01"` | WAS cell name |
| `NODE_NAME` | `"DefaultNode01"` | WAS node name |
| `SERVER_NAME` | `"server1"` | WAS server name |
| `WAS_ADMIN_USER` | `"wsadmin"` | WAS administrative user |
| `KEYSTORE_NAME` | `"NodeDefaultKeyStore"` | Target keystore for certificate import |
| `TARGET_ALIAS` | `"default"` | Fallback alias if live alias cannot be detected from SSL config |
| `CERT_FOLDER` | `/opt/digicert/certs` | Directory where TLM delivers the PFX |
| `BACKUP_DIR` | `/opt/digicert/backups` | Directory for keystore backups and old-cert PFX exports |
| `LOGFILE` | `/opt/digicert/log/was_cert_replace.log` | Script log file path |
| `RESTART_SERVER` | `"true"` | Whether to restart WAS after the swap |
| `AUTO_ROLLBACK` | `"true"` | Automatically restore the backup if the swap fails |
| `RESTART_DETACHED` | `"false"` | `true` = issue restart and return immediately without waiting (use when the TLM agent kills long-running post-scripts) |
| `STARTUP_WAIT_SECS` | `90` | Maximum seconds to wait for WAS readiness after restart |
| `BACKUP_KEEP` | `10` | Number of backup sets to retain; older sets are pruned automatically |

## Arguments (passed via `DC1_POST_SCRIPT_DATA` `args` array)

This script does **not** use the `args` array in `DC1_POST_SCRIPT_DATA`. All required inputs (`certfolder`, `files`, `password`) are read directly from the top-level fields of the JSON payload. No arguments need to be configured in the AWR post-delivery script settings.

## Production execution steps

    Step 1: Deploy the script to the TLM Agent host
        1. Copy websphere-awr.sh to /opt/digicert/scripts/
        2. Set ownership and permissions:
                chmod +x /opt/digicert/scripts/websphere-awr.sh
        3. Edit the CONFIGURATION block at the top of the script to match the
           target environment (container name, WAS profile path, cell/node/server names).
        4. Create /opt/digicert/conf/was-cert.conf (root:root 0600) with the required passwords.

    Step 2: Upload script to DigiCert ONE Portal
        5. Go to Discovery and Automation tools > Scripts
        6. Click Add script for > DigiCert Agents
        7. Enter script name and set:
                - Operating System: Linux
                - Script type: Admin request post-delivery
        8. Click Add and verify script

    Step 3: Configure Admin Web Request (AWR)
        9. Go to Inventory > Admin web request
       10. In STEP 1, fill in the request parameters
       11. In STEP 2:
                - Click Add
                - Select Agent
                - Click Apply

    Step 4: Set certificate delivery
       12. Under DigiCert Agents, select the appropriate Agent
       13. Under Destination 1, configure:
                - Format: PKCS12
                - Target path: /opt/digicert/certs
                - Set the password for certificate files (this becomes PFX_PASSWORD in the payload)
       14. Enable Run post delivery Scripts
       15. Select the uploaded websphere-awr.sh script
       16. No ARGUMENT values are required

    Step 5: Complete request
       17. Proceed with the remaining configuration steps and submit

Note: The TLM Agent populates `DC1_POST_SCRIPT_DATA` and invokes the script during delivery.

## Behavior

1. Validate legal notice acceptance and resolve secrets (`was-cert.conf` or env vars).
2. Pre-flight: verify the Podman container is running and WAS tools are accessible.
3. Resolve the PFX path from `DC1_POST_SCRIPT_DATA` (`certfolder` + `files`) or scan `CERT_FOLDER` directly.
4. Inspect the PFX with `keytool`: read alias, cert CN, issuer, validity; derive the new alias as `<cert-CN>_<timestamp>`.
5. Back up `key.p12`, `trust.p12`, and `security.xml` to `BACKUP_DIR`. If `BACKUP_PFX_PASS` is set, export the current live cert+key to a standalone PFX for portable rollback.
6. Arm auto-rollback (`AUTO_ROLLBACK=true`): any subsequent failure triggers `restore_backup` automatically.
7. Generate and execute a Jython script via `wsadmin -conntype NONE` to:
   - Detect the currently-bound alias from `NodeDefaultSSLSettings` (self-adapting; no hardcoded alias assumed).
   - Import the new cert under the fresh timestamped alias (import before delete — prevents CWPKI0707E "last cert" error).
   - Call `replaceCertificate` (rewrites SSL config refs from old alias to new) then `modifySSLConfig` (explicit bind, covers the case where the old binding was `(none)`).
   - Verify the alias is present, CA-issued, and bound; print `VERIFY-OK` or `VERIFY-FAIL`.
8. Save the WAS config (`AdminConfig.save()`).
9. Restart the container (`podman restart`); wait up to `STARTUP_WAIT_SECS` for a readiness log marker (non-fatal timeout — cert is already saved).
10. Verify the served cert on ports 9043 and 9443 via `openssl s_client`.
11. Prune backup sets older than `BACKUP_KEEP` entries per type.

## CLI flags (manual / lab use)

| Flag | Description |
|------|-------------|
| `-d` | DEBUG logging (most verbose) |
| `-q` | Quiet: WARN and above only |
| `-n` | Stage the swap but do not restart WAS |
| `--rollback [TIMESTAMP]` | Restore the newest backup, or a specific `YYYYMMDD_HHMMSS` timestamp |
| `--list-backups` | List available restore points and exit |
| `-h` | Usage help |

```bash
# Run a swap by hand (uses newest PFX in the cert folder), verbose
/opt/digicert/scripts/websphere-awr.sh -d

# Stage only — no restart
/opt/digicert/scripts/websphere-awr.sh -n

# List available rollback points
/opt/digicert/scripts/websphere-awr.sh --list-backups

# Roll back to the newest (or a specific) backup
/opt/digicert/scripts/websphere-awr.sh --rollback
/opt/digicert/scripts/websphere-awr.sh --rollback 20260707_153449
```

## Verifying a run

```bash
# Script result line
grep 'status=' /opt/digicert/log/was_cert_replace.log | tail -1
# expect: status=SUCCESS  or  status=ROLLBACK_SUCCESS

# Served cert on both ports
echo | openssl s_client -connect localhost:9443 2>/dev/null | openssl x509 -noout -subject -issuer
echo | openssl s_client -connect localhost:9043 2>/dev/null | openssl x509 -noout -subject -issuer

# SSL config binding (alias should be <fqdn>_<timestamp>)
podman exec was1 /opt/IBM/WebSphere/AppServer/profiles/AppSrv01/bin/wsadmin.sh \
  -lang jython -conntype NONE \
  -c "print AdminTask.getSSLConfig('[-alias NodeDefaultSSLSettings -scopeName (cell):DefaultCell01:(node):DefaultNode01]')" \
  | grep -o 'serverKeyAlias [^]]*'
```

Success: subject `CN=<your-fqdn>`, issuer = your DigiCert issuing CA, and `serverKeyAlias <your-fqdn>_<timestamp>`.

## Logging

Logs are written to:

- `/opt/digicert/log/was_cert_replace.log`

DEBUG, INFO, WARN, and ERROR messages are written with timestamps. All secret values (`WAS_ADMIN_PASS`, `KEYSTORE_PASS`, `PFX_PASSWORD`, `BACKUP_PFX_PASS`) are masked in every log entry. Log files are rotated at 5 MB with up to 5 retained.

## Exit codes

- `0` — certificate swap succeeded (`status=SUCCESS`) or manual rollback succeeded (`status=ROLLBACK_SUCCESS`).
- `1` — legal notice not accepted, a required secret is missing, pre-flight failed, the swap failed and auto-rollback succeeded (`status=FAILED_ROLLED_BACK`), or rollback also failed (`status=FAILED_ROLLBACK_FAILED`).

## Security considerations

- Do not hardcode passwords in the script. Use the secrets file (`was-cert.conf`, root:root `0600`) or environment variables.
- The script refuses to read the secrets file if its permissions are not `600` or `400`.
- All secret values are masked in log output using pattern replacement before writing.
- `BACKUP_PFX_PASS` should be distinct from the WAS keystore password; using the WAS default password for the backup export is explicitly rejected.
- Temp Jython scripts written to `/tmp` are deleted immediately after use.

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Script exits with "Legal notice not accepted" | `LEGAL_NOTICE_ACCEPT` is not `"true"` | Set `LEGAL_NOTICE_ACCEPT="true"` in the CONFIGURATION block |
| `DC1_POST_SCRIPT_DATA` not set | Script not invoked through the TLM Agent post-delivery hook | Verify TLM Agent post-delivery configuration and execution context |
| `No PFX/P12 found in /opt/digicert/certs` | TLM Agent did not write the PFX before invoking the script, or `CERT_FOLDER` is wrong | Check TLM Agent delivery logs and confirm the target path matches `CERT_FOLDER` |
| `Missing required secret(s): WAS_ADMIN_PASS` | Secrets file missing, wrong path, or wrong permissions | Confirm `/opt/digicert/conf/was-cert.conf` exists, is owned root:root, and has mode `600` |
| `VERIFY-FAIL` in Jython output | Cert imported but not bound, still self-signed, or alias missing | Check wsadmin logs; confirm `NodeDefaultSSLSettings` scope matches `CELL_NAME`/`NODE_NAME` |
| Container restart times out | WAS traditional takes 3–5 min to initialize | Set `RESTART_DETACHED="true"` — the cert is already saved; WAS activates it on its own |
| Auto-rollback triggered | Any error occurred after the swap began | Confirm `status=FAILED_ROLLED_BACK` in the log; the pre-swap cert is restored and WAS is running |
| `CellDefaultTrustStore` warning | Standalone WAS profile has no cell trust store | Expected; the script skips it gracefully. The node trust store is authoritative |
| Console shows `SRVE0255E` at `/` | WAS has no app at the root context | Not a cert error. Use `/ibm/console` for the admin console |
| Alias mismatch after renewal | Old alias was hardcoded in an application config | The alias changes each renewal (`<fqdn>_<timestamp>`). Applications should reference the SSL config, not a hardcoded alias |

## Legal

See the `LEGAL_NOTICE` heredoc at the top of `websphere-awr.sh` for the full DigiCert legal notice. `LEGAL_NOTICE_ACCEPT` must be `"true"` for the script to run.
