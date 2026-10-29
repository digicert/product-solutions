# DigiCert TLM AWR Post-Enrollment Script — Apache, multiple servers over SSH

Pushes a certificate issued by DigiCert Trust Lifecycle Manager (TLM) to any number of Apache servers over SSH, installs it at a per-server path, and optionally reloads Apache. Triggered by the TLM Agent as an Admin Web Request (AWR) post-enrollment script on Linux. Everything runs non-interactively.

## Overview

The TLM Agent enrolls or renews a certificate on the host where it runs. This script then:

1. **Decodes** `DC1_POST_SCRIPT_DATA` (Base64 JSON) to find the `.crt` and `.key` files TLM wrote.
2. **Loops over every entry in `SERVERS`** (and optionally a server list file). There is no upper limit.
3. For each server, over SSH:
   - creates a private staging directory with `mktemp -d`,
   - uploads the certificate, the private key and a small installer with `scp`,
   - runs the installer in one SSH session: verifies that the key matches the certificate (`openssl`), backs up the files being replaced, installs the certificate (`0644`) and key (`0600`) atomically with `install` + `mv`, runs the config test, reloads Apache, deletes the staging directory.
4. **Continues with the next server when one fails** (configurable), logs a summary and exits non-zero if any server failed.

The installer is embedded in this script as a heredoc; there is only one file to deploy on the TLM Agent host.

## Prerequisites

| Where | Requirement |
|---|---|
| TLM Agent host | Bash, `ssh`, `scp`, `base64`, `grep -P`, `mktemp`. `sshpass` only when any server uses `auth=password`. |
| TLM Agent host | For `auth=key`: the private key file readable by the user the agent runs the script as. |
| TLM Agent host | Host keys: default `STRICT_HOST_KEY_CHECKING="accept-new"` trusts a host on first contact (OpenSSH 7.6+). Use `"yes"` and a pre-populated `KNOWN_HOSTS_FILE` for a stricter setup. |
| Each Apache server | SSH login for the configured user, `bash`, `install`, `mktemp`. `openssl` recommended (key/cert match check is skipped without it). |
| Each Apache server | Unless `use_sudo=false`: `sudo` rights for the login user. Either a `NOPASSWD` rule or a password supplied via `sudo_pass` / `sudo_pass_file`. `Defaults requiretty` must not apply to that user. |
| Each Apache server | Apache's `SSLCertificateFile` / `SSLCertificateKeyFile` already point at `cert_dest` / `key_dest`. |

## Configuration

All settings live at the top of the script.

```bash
LEGAL_NOTICE_ACCEPT="true"
LOGFILE="/home/ubuntu/awr-apache-multi-server.log"

SERVERS=(
    "host=web1.example.com|auth=key|keyfile=/home/ubuntu/.ssh/tlm_deploy_ed25519"
    "host=web2.example.com|port=2222|user=deploy|auth=password|pass_file=/home/ubuntu/.tlm/web2.pass|reload_cmd=systemctl reload httpd|configtest_cmd=httpd -t"
    "host=10.0.0.15|auth=password|pass=ChangeMe123|sudo_pass=ChangeMe123|cert_dest=/etc/httpd/ssl/www.crt|key_dest=/etc/httpd/ssl/www.key|reload=false"
)
```

Each `SERVERS` entry is one target: `key=value` pairs separated by `|` (`SERVER_FIELD_SEP`). Only `host` is required. Any field that is left out takes the matching `DEFAULT_*` value, so a fleet of identical servers needs only `host=...` per line.

### Per-server fields

| Field | Default from | Description |
|---|---|---|
| `host` | — | Hostname or IP (required) |
| `port` | `DEFAULT_SSH_PORT` | SSH port |
| `user` | `DEFAULT_SSH_USER` | SSH login user |
| `auth` | `DEFAULT_AUTH` | `key` or `password` |
| `keyfile` | `DEFAULT_SSH_KEYFILE` | Private key on the agent host (`auth=key`) |
| `pass` | `DEFAULT_SSH_PASS` | SSH password inline (`auth=password`) |
| `pass_file` | `DEFAULT_SSH_PASS_FILE` | File on the agent host whose first line is the SSH password. Preferred over `pass` |
| `sudo_pass` | `DEFAULT_SUDO_PASS` | Password for `sudo` on the target (install and reload) |
| `sudo_pass_file` | `DEFAULT_SUDO_PASS_FILE` | File on the agent host whose first line is the sudo password |
| `use_sudo` | `DEFAULT_USE_SUDO` | `false` when the SSH user is root or owns the destination and can reload Apache itself |
| `cert_dest` | `DEFAULT_CERT_DEST` | Absolute path of the certificate on the target |
| `key_dest` | `DEFAULT_KEY_DEST` | Absolute path of the private key on the target |
| `backup` | `DEFAULT_BACKUP` | Keep `<file>.<UTC timestamp>.backup` of replaced files |
| `reload` | `DEFAULT_RELOAD` | Reload Apache after the install |
| `configtest_cmd` | `DEFAULT_CONFIGTEST_CMD` | Run before the reload; the reload is skipped if it fails. Empty string skips the test |
| `reload_cmd` | `DEFAULT_RELOAD_CMD` | Reload command, for example `systemctl reload apache2` or `systemctl reload httpd` |

Sudo password resolution: `sudo_pass_file`, then `sudo_pass`, then (for `auth=password`) the SSH password. If nothing is set the installer uses `sudo -n`, which needs a `NOPASSWD` rule.

Values must not contain the separator. If a password does, change `SERVER_FIELD_SEP` or put the password in a file.

### Global settings

| Variable | Default | Description |
|---|---|---|
| `SERVER_LIST_FILE` | `""` | Optional file with one server entry per line (`#` comments allowed). Appended to `SERVERS`. Keeps passwords out of the script; protect it with mode `0600` |
| `DEFAULT_*` | see script | Fallback for each per-server field |
| `SSH_CONNECT_TIMEOUT` | `15` | Seconds |
| `STRICT_HOST_KEY_CHECKING` | `accept-new` | `accept-new`, `yes` or `no` |
| `KNOWN_HOSTS_FILE` | `""` | Custom known_hosts file; empty uses the ssh default for the user running the agent |
| `STOP_ON_FIRST_FAILURE` | `false` | `true` stops after the first failed server |
| `SERVER_FIELD_SEP` | `\|` | Separator between fields in a server entry |

## How the non-interactive parts work

- **SSH key auth** uses `BatchMode=yes`, `IdentitiesOnly=yes` and `-i keyfile`. The key must have no passphrase, or an agent must be available to the user running the TLM Agent.
- **SSH password auth** uses `sshpass -e`. The password is handed over in the `SSHPASS` environment variable of that one process, never on the command line.
- **sudo** on the target reads the password from stdin with `sudo -S -p ''`. The main script pipes the password into the single SSH session that runs the installer. With no password it uses `sudo -n`.
- **Host keys** are accepted on first contact with `StrictHostKeyChecking=accept-new`; a changed host key still fails the connection.
- **No prompts anywhere**: a missing key, missing `sshpass`, an unusable sudo or a changed host key fails that server with a logged reason instead of hanging.

## Logging

Everything goes to `$LOGFILE`. Output from the remote installer is logged with a `remote>` prefix. Passwords are masked in log lines. A typical successful server looks like:

```
Server 1/2: web1.example.com
  user=ubuntu port=22 auth=key use_sudo=true
  cert_dest=/etc/ssl/certs/tlm-apache.crt
  key_dest=/etc/ssl/private/tlm-apache.key
  backup=true reload=true configtest_cmd='apachectl configtest' reload_cmd='systemctl reload apache2'
  [1/3] Creating staging directory on web1.example.com...
  [2/3] Uploading certificate, key and installer...
  [3/3] Installing (sudo: NOPASSWD (sudo -n), reload: true)...
    remote> certificate/key pair verified: subject=CN=www.example.com notAfter=...
    remote> backup: /etc/ssl/certs/tlm-apache.crt -> /etc/ssl/certs/tlm-apache.crt.20261028-144928Z.backup
    remote> installed /etc/ssl/certs/tlm-apache.crt (mode 0644)
    remote> installed /etc/ssl/private/tlm-apache.key (mode 0600)
    remote> config test passed
    remote> Apache reloaded
  RESULT: SUCCESS
DEPLOYMENT SUMMARY: 2 succeeded, 0 failed, 2 configured
```

## Remote installer exit codes

| Code | Meaning |
|---|---|
| 2 | Staged files missing, unparsable, or the private key does not match the certificate. Nothing changed on the target |
| 3 | `sudo` not usable non-interactively (wrong password, no `NOPASSWD`, `requiretty`). Nothing changed |
| 4 | Backup or install failed |
| 5 | Config test failed. Certificate and key are installed, Apache was **not** reloaded; backups are next to the files |
| 6 | Reload command failed |

## Troubleshooting

| Symptom in log | Likely cause |
|---|---|
| `auth=password requires 'sshpass'` | Install `sshpass` on the TLM Agent host |
| `auth=key but keyfile ... is missing or unreadable` | Wrong path, or the agent runs as a different user than the one that owns the key |
| `SSH connection or mktemp failed: Permission denied` | Wrong user/password/key, or password auth disabled in `sshd_config` |
| `SSH connection or mktemp failed: Host key verification failed` | Host key changed, or `STRICT_HOST_KEY_CHECKING="yes"` without an entry in `KNOWN_HOSTS_FILE` |
| `remote> ERROR: sudo is not usable non-interactively` | No `NOPASSWD` rule and no sudo password, wrong sudo password, or `Defaults requiretty` |
| `remote> ERROR: private key does not match the certificate` | TLM wrote a key that does not belong to the certificate; check the enrollment profile |
| `remote> ERROR: config test failed` | Apache config broken, or `cert_dest`/`key_dest` do not match the vhost. Files are installed, previous versions are in `*.backup` |

## Testing

The script was exercised against an Ubuntu 24.04 `sshd` container (users with key + `NOPASSWD` sudo and password + password sudo, fake `apachectl`/`httpd`/`systemctl`) using synthesised fixtures: a throwaway EC certificate and key generated with `openssl`, and a `DC1_POST_SCRIPT_DATA` payload built the way the TLM Agent sends it. The embedded installer was additionally run standalone for the happy path, backup on re-run, mismatched key, failing config test and failing reload.
