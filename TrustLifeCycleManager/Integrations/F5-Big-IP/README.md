# DigiCert Trust Lifecycle Manager — F5 BIG-IP Integrations

This folder contains two independent ways to automate certificate delivery to F5 BIG-IP with DigiCert Trust Lifecycle Manager (TLM). Pick the one that fits how TLM reaches the BIG-IP in your environment.

| Folder | Integration type | Runs on | Talks to BIG-IP via | Use it when |
|--------|------------------|---------|---------------------|-------------|
| [admin-webrequest-post-scripts/](admin-webrequest-post-scripts/) | TLM Agent **Admin Web Request (AWR) post-enrollment scripts** | A host with the TLM Agent installed (Linux or Windows) | iControl REST (HTTPS) | You already enroll certificates through a TLM Agent and want it to push the issued cert/key onto named BIG-IP SSL profiles after each enrollment or renewal. |
| [extensibility-custom-plugins/](extensibility-custom-plugins/) | TLM **custom automation plugin** (Java, TLM Plugin SDK) | A DigiCert sensor | iControl REST (connection test) + SSH running Python on the device | You want TLM to manage the BIG-IP as an automation target: discover virtual servers, generate the key and CSR **on the BIG-IP**, install, validate and renew per virtual server, with HA config-sync. |

## admin-webrequest-post-scripts

Shell and PowerShell scripts that the TLM Agent runs after a certificate is issued. The agent hands the script the certificate, the private key and a few arguments. The script uploads them to the BIG-IP and repoints existing Client SSL and/or Server SSL profiles.

| Script | Platform | What it does |
|--------|----------|--------------|
| `Linux/f5_big_ip-awr-both-server-client.sh` | Linux, Bash | Uploads cert/key to `/Common` and updates one named Server SSL profile and/or one named Client SSL profile |
| `Windows/f5_big_ip-awr-both-server-client.ps1` | Windows, PowerShell | Same workflow as the Bash script |
| `Linux/Multi-endpoints-IIS-F5-fixed-Final.ps1` | Windows, PowerShell (IIS needs Windows) | Deploys one certificate to **both** a BIG-IP (expiry-stamped objects, chain extraction, pruning of old objects, config save) **and** the local IIS site (SNI binding) |

The private key is generated wherever the TLM Agent generates it and is then copied to the BIG-IP.

See [admin-webrequest-post-scripts/README.md](admin-webrequest-post-scripts/README.md) for prerequisites, BIG-IP account permissions, AWR arguments, workflow and troubleshooting.

## extensibility-custom-plugins

A TLM automation plugin, packaged as a ZIP that you upload to TLM and run on a DigiCert sensor. TLM drives the full lifecycle per virtual server:

- **Test connection:** REST login check plus an SSH `tmsh` check
- **Generate CSR:** the key pair is created on the BIG-IP (normal or FIPS key storage) and never leaves it
- **Install:** installs the cert and ICA, then updates the bound Client SSL profile in place or copies it to a new profile. It also repoints any Server SSL profile on the same virtual server that carries the certificate being replaced. All of this runs in one tmsh transaction, followed by `save sys config` and HA config-sync
- **Validate:** reads back the live certificate chain from the virtual server
- **Refresh configuration:** inventories virtual servers, certificates, ciphers, HA peers and partitions

| Path | Contents |
|------|----------|
| `automation-plugins/F5-BigIP-Certificate-Automation-Client-Server-SSL-Profiles/` | Maven project (Java 17), embedded device-side Python scripts, `configuration.json` (connector UI) and the built `plugin-dist/f5-automation-plugin-1.0.0.zip` |

See [extensibility-custom-plugins/README.md](extensibility-custom-plugins/README.md) for architecture, connector configuration, BIG-IP requirements, build and deployment.

## Choosing between them

| Consideration | AWR post-scripts | Custom automation plugin |
|---------------|------------------|--------------------------|
| Where the private key is generated | TLM Agent host, then copied to BIG-IP | On the BIG-IP |
| Target selection | Fixed profile names set in the script | Per virtual server, chosen in TLM |
| Profiles it can update | One named Client SSL and/or one named Server SSL profile | The Client SSL profile bound to the virtual server, plus matching Server SSL profiles on it |
| Partitions | `/Common` only | The virtual server's partition |
| Saves config / HA sync | Not done by the two `f5_big_ip-awr-*` scripts. The multi-endpoint script saves config but does not sync | `save sys config` and config-sync to the sync-failover group |
| Unsecured virtual server (no SSL yet) | Not supported, profiles must already exist | Creates and binds a new Client SSL profile |
| Transport required on BIG-IP | iControl REST. Advanced shell is needed only for the Client SSL step in the `f5_big_ip-awr-*` scripts | SSH (port 22) with Advanced shell (bash), plus iControl REST |
| Additional infrastructure | TLM Agent | DigiCert sensor with Java 17 |

## License

Copyright © 2026 DigiCert, Inc. All rights reserved. See the legal notice in each script and the plugin source for full terms.
