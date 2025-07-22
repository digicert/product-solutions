# Create PQC Demo Lab

Before creating a new PQC related profiles, you will need to create a new root and ica as each key requires its own root and ica


![](assets/20250722_131452_pqc.png)

## Compile OpenSSL 3.5.1

By default, the OS integrated OpenSSL version does not support PQC and there is currently (July 2025) no pre-compiled version of OpenSSL that does.

So we need to do that ourselves.

Update and install the following pre-requisites

```bash
sudo apt update
sudo apt install -y build-essential jq git perl python3 make wget zlib1g-dev libssl-dev
```
