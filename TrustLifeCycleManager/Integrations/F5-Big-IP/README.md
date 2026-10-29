# DigiCert Trust Lifecycle Manager — F5 BIG-IP Integrations

This folder holds two independent ways to automate certificate delivery to F5 BIG-IP with DigiCert Trust Lifecycle Manager (TLM). Each subfolder has its own detailed README covering architecture, configuration, permissions and troubleshooting.

## 1. Admin Web Request (AWR) post-enrollment scripts

**Folder:** [admin-webrequest-post-scripts/](admin-webrequest-post-scripts/) · **Details:** [README](admin-webrequest-post-scripts/README.md)

These are scripts that the **TLM Agent** runs after it enrolls or renews a certificate. The agent passes the issued certificate and private key to the script. The script pushes them to the BIG-IP over iControl REST and repoints existing Client SSL and/or Server SSL profiles.

| Script | Agent OS | Purpose |
|--------|----------|---------|
| `Linux/f5_big_ip-awr-both-server-client.sh` | Linux | Update a named Server SSL and/or Client SSL profile |
| `Windows/f5_big_ip-awr-both-server-client.ps1` | Windows | Same as the Linux script |
| `Windows/Multi-endpoints-IIS-F5-fixed-Final.ps1` | Windows | Deploy one certificate to a BIG-IP **and** the local IIS site |

**Use this when** you already enroll through a TLM Agent and want a lightweight push to fixed, pre-existing profiles.

## 2. Extensibility: custom automation plugins

**Folder:** [extensibility-custom-plugins/](extensibility-custom-plugins/) · **Details:** [README](extensibility-custom-plugins/README.md)

These are TLM automation plugins (Java, TLM Plugin SDK) that run on a **DigiCert sensor**. TLM manages each BIG-IP virtual server as an automation target. The plugin:

- discovers virtual servers
- generates the key and CSR **on the BIG-IP**
- installs the certificate into the Client SSL profile, and into any matching Server SSL profile, in one tmsh transaction
- saves the configuration and config-syncs HA pairs
- validates the deployed certificate

| Plugin | Purpose |
|--------|---------|
| `automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles-MultiAuth` | Full lifecycle with several ways to log in: shared, separate REST and SSH accounts, or SSH only. Supports remote (RADIUS/TACACS+/LDAP) accounts, secrets-manager credentials and a configurable SSH port |

**Use this when** you want TLM to own the full lifecycle per virtual server, with keys that never leave the BIG-IP.

## At a glance

| | AWR post-scripts | Custom automation plugins |
|---|---|---|
| Runs on | TLM Agent host | DigiCert sensor |
| Private key generated on | Agent host, then copied to BIG-IP | BIG-IP |
| Connects to BIG-IP via | iControl REST | SSH (lifecycle) + iControl REST (connection test) |
| Targets | Fixed profile names in `/Common` | Any virtual server and partition discovered by TLM |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script and the plugin source for full terms.
