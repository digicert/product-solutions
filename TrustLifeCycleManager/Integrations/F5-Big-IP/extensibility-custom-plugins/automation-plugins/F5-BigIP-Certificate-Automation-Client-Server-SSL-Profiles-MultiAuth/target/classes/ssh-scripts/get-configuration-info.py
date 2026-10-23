import json
import os.path
import re
import subprocess
import sys
import traceback

# The map is used to filter out protocols that are not needed.
remove_protocol_filter_map = {
    "no-tlsv1.3": ["TLSv1.3"],
    "no-tlsv1.1": ["TLSv1.1"],
    "no-tlsv1.2": ["TLSv1.2"],
    "no-tls": ["TLSv1.3", "TLSv1.1", "TLSv1.2", "TLSv1.0"],
    "no-sslv3": ["SSLv3"],
    "no-tlsv1": ["TLSv1.0"],
    "no-ssl": ["SSLv3"],
    "no-dtls": ["DTLSv1"]
}

# The map is used to convert the protocol format to the openssl format.
openssl_protocol_format_map = {
    "SSL3": "SSLv3",
    "SSLv3": "SSLv3",
    "TLS1": "TLSv1.0",
    "TLS1.0": "TLSv1.0",
    "TLS1.1": "TLSv1.1",
    "TLS1.2": "TLSv1.2",
    "TLS1.3": "TLSv1.3",
    "DTLS1": "DTLSv1",
    "DTLS1.0": "DTLSv1"
}


class F5PluginException(Exception):
    def __init__(self, message, code):
        super(F5PluginException, self).__init__(message)
        self.code = code


class F5ShellCommandException(F5PluginException):
    def __init__(self, message, command):
        full_message = "{0}. Command: {1}".format(message, command)
        super(F5ShellCommandException, self).__init__(full_message, "SHELL_COMMAND_ERROR")
        self.command = command


def run_command(command):
    """Executes a system command and returns its output."""
    process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    stdout, stderr = process.communicate()

    if process.returncode != 0:
        raise F5ShellCommandException(stderr, command)

    return stdout

def parse_line(tokens,declarative_keys):
    """Parses a single line of TMSH output into a dictionary."""
    result = {}
    is_key = True
    key = None
    while tokens:
        token = tokens.pop(0)
        if is_key:
            key = token
            if key in declarative_keys:
                result[key] = True
                continue
            if key == '}':
                break
            is_key = False
        else:
            value = token
            is_key = True
            if value == '{':
                result[key] = parse_line(tokens,declarative_keys)
                continue
            if value.startswith('"'):
                # Parses a quoted value, handling escaped quotes.
                tokens.insert(0, value[1:])
                parts = []
                while tokens:
                    token = tokens.pop(0)
                    if token.endswith('"') and not token.endswith('\\"'):
                        parts.append(token[:-1])
                        break
                    parts.append(token)
                value = ' '.join(parts)
            result[key] = value.replace('\\"', '"')

    return result


def parse_tmsh_output(output, prefix_to_remove,declarative_keys= ['disabled', 'internal', 'ip-forward', 'vlans-enabled', 'enabled', 'default']):
    """Parses TMSH output, removing prefixes and skipping warnings."""
    def should_skip_line(line):
        return line.startswith("[api-status-warning]")

    def remove_prefix(line, prefix):
        return line[len(prefix):]

    try:
        lines = [line for line in output.split('\n') if line and not should_skip_line(line)]
        results = []
        for line in lines:
            if line.startswith(prefix_to_remove):
                parsed_line = parse_line(remove_prefix(line, prefix_to_remove).split(' '),declarative_keys)
                if parsed_line:
                    results.append(parsed_line)

        return results
    except Exception as e:
        raise F5PluginException("Failed to parse TMSH output: {0}".format(e), "TMSH_OUTPUT_PARSE_ERROR")


def process_virtual_servers(vips):
    """Processes and transforms VIP configurations."""
    processed_vips = []
    client_ssl_profiles = []
    skipped_vips = []
    service_dict = get_service_dict()
    service_dict.update({"any": "0"})
    for server_name,server_data in vips.items():
        # When it has been parsed it's in the following format:
        # [
        #     {"partition/virtual-server-name1": {...data...}},
        #     {"partitions/virtual-server-name2": {...data...}},
        # ]
        # It's better to have the list of virtual servers in the following format:
        # [
        #     {"virtual-server-name": "virtual-server-name1", ...data...},
        #     {"virtual-server-name": "virtual-server-name2", ...data...},
        # ]
        partition = server_data.get('partition')
        # Remove partition from the server name
        server_name = server_name.replace(partition + '/', '')
        server_data['virtual-server-name'] = server_name

        profiles = server_data.get('profiles')
        is_server_ssl = False
        if not update_vip_destination(server_data, service_dict):
            skipped_vips.append(server_data)
        else:
            if profiles:
                for profile_name, profile_details in profiles.items():

                    if profile_details.get('context') == 'clientside' and is_client_ssl_profile(profile_name):
                        client_ssl_profiles.append({
                            "virtual-server-name": server_name,
                            "profile-name": profile_name
                        })
                        if server_data not in processed_vips:
                            server_data['ssl-state'] = 1
                            processed_vips.append(server_data)
                    elif profile_details.get('context') == 'serverside' and is_server_ssl_profile(profile_name):
                        # Only used to classify the VIP (ssl-state 2 = server-side SSL only). server-ssl
                        # certificates are deliberately not reported as separate certificate entries: the
                        # install flow targets the client-ssl profile and repoints matching server-ssl
                        # profiles alongside it, so a cert bound to both is already visible via client-ssl,
                        # and a server-ssl-only cert could not be renewed through this plugin.
                        is_server_ssl = True

                if is_server_ssl and server_data not in processed_vips:
                    server_data['ssl-state'] = 2
                    processed_vips.append(server_data)
                elif server_data not in processed_vips:
                    server_data['ssl-state'] = 0
                    processed_vips.append(server_data)
            else:
                server_data['ssl-state'] = 0
                processed_vips.append(server_data)

            ip, port = server_data.get('destination').split(':')
            server_data['ip'] = ip
            server_data['port'] = port

    # Filter out not needed keys
    needed_keys = ['destination', 'partition', 'virtual-server-name', 'ip', 'port', 'ssl-state']
    processed_vips = [dict((k, vip[k]) for k in vip if k in needed_keys) for vip in processed_vips]
    skipped_vips = [dict((k, vip[k]) for k in vip if k in needed_keys) for vip in skipped_vips]

    return {
        "vips": processed_vips,
        "client-ssl-profiles": client_ssl_profiles,
        "skipped-vips": skipped_vips
    }


def update_vip_destination(vip,service_dict):
    """Updates VIP destination to ip:port format."""
    destination = vip.get('destination')

    # 'destination' is as follows: partition/ip:port
    # remove the partition part
    ip_port = re.sub(r'^[^/]+/', '', destination)

    if ip_port.count(":") != 1:
        return False

    vip['destination'] = ip_port

    # sometimes the port is declared as service name, so we need to resolve it
    # /etc/services file comprises the mapping of service names to port numbers
    ip, port = ip_port.split(':')
    if port.isdigit() is False:
        port = service_dict.get(port)
        if port:
            vip['destination'] = "{0}:{1}".format(ip, port.strip())

    return True

# Function to extract blocks of 'ltm profile client-ssl'
def extract_blocks(content, start):
    blocks = []
    stack = []  # To keep track of nested braces
    current_block = []
    for line in content.splitlines():
        stripped_line = line.strip()

        if stripped_line.startswith(start):
            if stack:
                # If there's an unclosed block, save it first
                blocks.append("\n".join(current_block))
                current_block = []

        current_block.append(line)

        if "{" in stripped_line:
            stack.append("{")
        if "}" in stripped_line:
            stack.pop()
            if not stack:
                # End of the current block
                blocks.append("\n".join(current_block))
                current_block = []

    if current_block:
        blocks.append("\n".join(current_block))  # Add any remaining block

    return blocks

# Helper function to parse nested structures
def parse_block(lines):
    obj = {}
    while lines:
        line = lines.pop(0).strip()

        # If the line opens a nested block, recursively parse it
        if line.endswith("{"):
            key = line[:-1].strip()
            obj[key] = parse_block(lines)  # Recursively parse nested blocks
        elif line == "}":
            break  # End of the current block
        else:
            # Handle key-value pairs
            parts = line.split(" ")
            if len(parts) == 2:
                if parts[1] != 'none':
                    obj[parts[0]] = parts[1]
            else:
                obj[parts[0]] = None
    return obj
def parse_profiles_output(output):
    """Parses profiles output."""
    # The output is as follows:
    # ltm profile client-ssl APartition/CCPUB.winthecustomer.com_24Feb09_EYEiHk {
    #     cert APartition/CCPUB.winthecustomer.com_24Feb09_EYEiHk.crt
    #     chain APartition/ica-digicert-0cf5bd062b5602f47ab8502c23ccf066.crt
    #     ...
    # }
    # ltm profile client-ssl APartition/CCPUB.winthecustomer.com_24Feb09_EYEiHl {
    #     cert APartition/CCPUB.winthecustomer.com_24Feb09_EYEiHl.crt
    #     chain APartition/ica-digicert-0cf5bd062b5602f47ab8502c23ccf066.crt
    #     ...
    # }
    # ...
    # Extract all ltm profile client-ssl blocks
    blocks = extract_blocks(output,"ltm profile client-ssl")
    parsed_data = {}

    # Parse each block
    for block in blocks:
        # Extract the profile name for the key
        profile_name_match = re.match(r'ltm profile client-ssl ([^{]+)', block)
        if not profile_name_match:
            continue  # Skip if no profile name is found

        profile_name = profile_name_match.group(1).strip()
        # Remove the 'ltm profile client-ssl' header to focus on the block content
        block_content = re.sub(r'^ltm profile client-ssl [^{]+{\s*', '', block, count=1).strip()
        lines = block_content.splitlines()
        # Parse the block into a dictionary
        parsed_block = parse_block(lines)
        # Add the parsed block to the final result as a key-value pair
        parsed_data[profile_name] = parsed_block

    return parsed_data

def get_certificates_for_profiles(client_ssl_profiles):
    """Adds certificates to profiles."""
    try:
        command = "tmsh -q -c 'cd /; list ltm profile client-ssl recursive cert chain cert-key-chain'"
        output = run_command(command)
        profiles_data = parse_profiles_output(output)
        for profile in client_ssl_profiles:
            profile_name = profile.get('profile-name')
            virtual_server_name = profile.get('virtual-server-name')
            if profile_name and virtual_server_name:
                profile_data = profiles_data.get(profile_name)
                cert = profile_data.get('cert')
                chain = profile_data.get('chain')
                if not cert:
                    cert_key_chain = profile_data.get("cert-key-chain")
                    if cert_key_chain:
                        list_cert_key_chain = list(cert_key_chain)
                        if list_cert_key_chain:
                            cert_key_obj = cert_key_chain.get(list_cert_key_chain[0]) #get first entry from cert key
                            # as we assume it to be the valid certificate
                            cert = cert_key_obj.get('cert')
                            chain = cert_key_obj.get('chain')

                cert_path = None
                chain_path = None
                if cert:
                    # Find cert
                    command = 'find /config/filestore/files_d/*_d/certificate_d -name "*{0}*"'.format(cert.replace("/", ":"))
                    cert_path = run_command(command).split("\n")[0].strip()

                if chain:
                    # Find chain
                    command = 'find /config/filestore/files_d/*_d/certificate_d -name "*{0}*"'.format(chain.replace("/", ":"))
                    chain_path = run_command(command).split("\n")[0].strip()

                if cert_path and chain_path:
                    command = 'cat {0} {1}'.format(cert_path, chain_path)
                    cert_chain = run_command(command)
                    profile['cert'] = cert_chain
                elif cert_path:
                    command = 'cat {0}'.format(cert_path)
                    cert_chain = run_command(command)
                    profile['cert'] = cert_chain
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get certificates for profiles: {0}. Shell command: `{1}`".format(e, e.command),
            "CERTIFICATES_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get certificates for profiles: {0}".format(e),
            "CERTIFICATES_FETCH_ERROR"
        )


def get_chains_and_protocols_for_profiles(client_ssl_profiles):
    """Gets chains and protocols for profiles."""
    try:
        command = "tmsh -q -c 'cd /; list ltm profile client-ssl recursive ciphers cipher-group options'"
        output = run_command(command)
        profiles_data = parse_profiles_output(output)

        cipher_groups_dict = {}
        ciphers_dict = {}

        for profile in client_ssl_profiles:
            profile_name = profile.get('profile-name')
            virtual_server_name = profile.get('virtual-server-name')
            if profile_name and virtual_server_name:
                profile_data = profiles_data.get(profile_name)
                cipher_group = profile_data.get('cipher-group')
                ciphers = profile_data.get('ciphers')
                options = profile_data.get('options')

                not_allowed_protocols = []
                if options:
                    for option in options:
                        if option in remove_protocol_filter_map:
                            not_allowed_protocols.extend(remove_protocol_filter_map[option])

                # If cipher-group is not blank and not none, retrieve ciphers and protocols via the following command:
                # - `tmsh show ltm cipher group {group-name}`
                # Otherwise, hanlde the ciphers value:
                # - `tmm --clientciphers {ciphers} | awk '{{print $3,$5}}'`

                # Store the cipher group and ciphers in a dictionary to avoid multiple calls to the shell
                if cipher_group and cipher_group != "none":
                    if cipher_group not in cipher_groups_dict:
                        command = 'tmsh show ltm cipher group /{0}'.format(cipher_group)
                        cipher_group_output = run_command(command)
                        # For version >= 14 the output is handled as follows:
                        # [admin@dc-f514-246:Active:Standalone] ~ # tmsh show ltm cipher group /Common/f5-default
                        #
                        # ---------------------------
                        # Ltm::Cipher::Group
                        # ---------------------------
                        # Name                         f5-default
                        # Cipher Result                ECDHE-RSA-AES128-GCM-SHA256/TLS1.2
                        # DH-Groups Result             P256:X25519:P384
                        # Signature Algorithms Result  RSA-PKCS1-SHA256:RSA-PSS-SHA256
                        if "Cipher Result" in cipher_group_output:
                            lines = cipher_group_output.split('\n')
                            for line in lines:
                                if line.startswith("Cipher Result"):
                                    cipher_groups_dict[cipher_group] = process_cipher_group_string(line.split()[-1])
                        else:
                            # For version < 14 the output is handled as follows:
                            # [admin@gp2-ft2-f5-227:Active:Standalone] ~ # tmsh show ltm cipher group /Common/f5-default
                            #
                            # ------------------
                            # Ltm::Cipher::Group
                            # ------------------
                            # Name        Result
                            # ------------------
                            # f5-default  ECDHE-RSA-AES128-GCM-SHA256/TLS1.2:ECDHE-RSA-AES128-CBC-SHA/TLS1.0
                            cipher_group_name = os.path.basename(cipher_group)  # Get group name only, without partition
                            if cipher_group_name in cipher_group_output:
                                lines = cipher_group_output.split('\n')
                                for line in lines:
                                    if line.startswith(cipher_group_name):
                                        cipher_groups_dict[cipher_group] = process_cipher_group_string(line.split()[-1])
                    if cipher_group in cipher_groups_dict:
                        profile['cipher_group'] = {}
                        for protocol in cipher_groups_dict[cipher_group].keys():
                            if protocol not in not_allowed_protocols:
                                profile['cipher_group'][protocol] = cipher_groups_dict[cipher_group][protocol]
                elif ciphers and ciphers != "none":
                    # [admin@dc-f514-246:Active:Standalone] ~ # tmm --clientciphers DEFAULT | awk '{{print $3,$5}}'
                    # BITS CIPHER
                    # ECDHE-RSA-AES128-GCM-SHA256 TLS1.2
                    # ECDHE-RSA-AES128-CBC-SHA TLS1
                    if ciphers not in ciphers_dict:
                        command = "tmm --clientciphers {0} | awk '{{print $3,$5}}'".format(ciphers)
                        ciphers_output = run_command(command)
                        split_ciphers_output = ciphers_output.split("\n")
                        split_ciphers_output.pop(0)  # Remove the first line with headers
                        ciphers_dict[ciphers] = process_ciphers_list(split_ciphers_output)
                    if ciphers in ciphers_dict:
                        profile['ciphers'] = {}
                        for protocol in ciphers_dict[ciphers].keys():
                            if protocol not in not_allowed_protocols:
                                profile['ciphers'][protocol] = ciphers_dict[ciphers][protocol]
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get ciphers anf protocols for profiles: {0}. Shell command: `{1}`".format(e, e.command),
            "CIPHERS_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get ciphers anf protocols for profiles: {0}".format(e),
            "CIPHERS_FETCH_ERROR"
        )


def process_cipher_group_string(cipher_string):
    """Processes and transforms cipher group string."""
    # The input is as follows:
    # ECDHE-RSA-AES128-GCM-SHA256/TLS1.2:ECDHE-RSA-AES128-CBC-SHA/TLS1.0
    ciphers_dict = {}
    ciphers_list = cipher_string.split(":")
    for cipher in ciphers_list:
        if cipher.strip():
            cipher_name, protocol = cipher.split("/")
            protocol = openssl_protocol_format_map.get(protocol)
            if protocol not in ciphers_dict:
                ciphers_dict[protocol] = set()
            ciphers_dict[protocol].add(cipher_name)
    return ciphers_dict


def process_ciphers_list(cipher_list):
    """Processes and transforms ciphers list."""
    # The input is as follows:
    # ['ECDHE-RSA-AES128-GCM-SHA256 TLS1.2', 'ECDHE-RSA-AES128-CBC-SHA TLS1']
    ciphers_dict = {}
    for cipher in cipher_list:
        if cipher.strip():
            cipher_name, protocol = cipher.split(" ")
            protocol = openssl_protocol_format_map.get(protocol)
            if protocol not in ciphers_dict:
                ciphers_dict[protocol] = set()
            ciphers_dict[protocol].add(cipher_name)
    return ciphers_dict

def clean_extract_cert(cert_string):
    try:
        pem_pattern = r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----"
        # Find all certificates in the string using regex
        certs = re.findall(pem_pattern, cert_string, re.DOTALL)
        if not certs:
            return ""

        return "\n".join(certs) + "\n"
    except Exception as e:
        return ""

def process_certificates(vips, client_ssl_profiles):
    """Processes and transforms certificates."""
    certificates_list = []
    for profile in client_ssl_profiles:
        server_name = profile.get('virtual-server-name')
        cert = clean_extract_cert(profile.get('cert'))
        ciphers = profile.get('cipher_group') if profile.get('cipher_group') else profile.get('ciphers')
        vip = next(item for item in vips if item.get("virtual-server-name") == server_name)
        certificates_list.append({
            "cert": cert,
            "destination": vip.get('destination'),
            "ip": vip.get('ip'),
            "port": vip.get('port'),
            "sni": is_sni(server_name, client_ssl_profiles),
            "cipher-discovery": "#".join(["protocol:{0};ciphers:{1}".format(k, ",".join(ciphers[k])) for k in
                                          ciphers.keys()]) if ciphers else None
        })
    return certificates_list


def process_sys_version_output(text):
    """Processes and transforms system version output."""
    # Sample input:
    #
    # Sys::Version
    # Main Package
    #   Product     BIG-IP
    #   Version     13.1.1
    #   Build       0.0.4
    #   Edition     Final
    #   Date        Fri Jul 20 17:55:49 PDT 2018
    #
    # Kernel
    #   Type     Linux
    #   Release  3.10.0-514.26.2.el7.ve.x86_64
    result = {}
    lines = text.split('\n')
    current_category = None

    for line in lines:
        line = line.strip()
        if not line or "Sys::Version" in line:
            continue

        # Check for a category header
        if "Main Package" == line:
            current_category = line
        else:
            # Parse key-value pairs
            if current_category:
                key_value = line.split()
                if len(key_value) == 2:
                    key, value = key_value
                    result[key.lower()] = value

    return result


def is_sni(virtual_server_name, client_ssl_profiles):
    """Checks if it's SNI case."""
    # TODO: update it as follows
    # According to Suhail:
    # we distinguish a VIP based on unique certificates attached.
    # If there are 3 unique profiles then that VIP is marked as SNI
    # And the sni-default is internally handled
    profiles_with_same_vip = [index for index in range(len(client_ssl_profiles)) if
                              client_ssl_profiles[index].get("virtual-server-name") == virtual_server_name]

    return len(profiles_with_same_vip) > 1


def get_hostname():
    """Gets hostname."""
    command = 'tmsh list cm device hostname | grep hostname'
    output = run_command(command)
    # the line is as follows: `    hostname dc-f514-246.symclab.net`
    hostname = output.split("\n")[0].strip().split()[1]
    return hostname


def get_peers_info():
    """Gets HA peers."""
    try:
        command = 'tmsh list cm device-group device_trust_group one-line'
        output = run_command(command)

        _, device_trust_group_info = parse_tmsh_output(output, "cm device-group ")[0].popitem()
        devices = device_trust_group_info.get('devices')

        peers = []
        for device in devices.keys():
            command = 'tmsh list cm device {0} management-ip failover-state'.format(device)
            output = run_command(command)
            lines = output.split('\n')
            management_ip = ''
            failover_state = ''
            for line in lines:
                if line.startswith("    management-ip"):
                    management_ip = line.split()[1]
                if line.startswith("    failover-state"):
                    failover_state = line.split()[1]

            peers.append({
                "management-ip": management_ip,
                "failover-state": failover_state,
            })

        floating_ip = get_floating_ip()
        if floating_ip:
            peers.append({
                "management-ip": floating_ip,
                "failover-state": "floating"
            })

        return peers
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get HA peers: {0}. Shell command: `{1}`".format(e, e.command),
            "HA_PEERS_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get HA peers: {0}".format(e),
            "HA_PEERS_FETCH_ERROR"
        )


def parse_net_self_output(output):
    """Parses network self configuration output into JSON format."""
    try:
        net_self_entries = []

        # Split the output by lines and process each line
        lines = output.strip().split('\n')

        for line in lines:
            line = line.strip()
            if not line or not line.startswith('net self'):
                continue

            # Parse the line format: net self <name> { <properties> }
            # Handle both simple and nested properties like allow-service { default }

            # Extract the name part after "net self"
            if '{' in line:
                name_part = line.split('{')[0].replace('net self', '').strip()

                # Find the content between the outermost braces
                brace_start = line.find('{')
                brace_end = line.rfind('}')
                if brace_start != -1 and brace_end != -1:
                    properties_part = line[brace_start + 1:brace_end].strip()

                    # Tokenize the properties part for parsing
                    tokens = properties_part.split()

                    # Use the existing parse_line function logic to handle nested structures
                    declarative_keys = ['disabled', 'internal', 'ip-forward', 'vlans-enabled', 'enabled', 'default', 'floating']
                    properties = parse_line(tokens, declarative_keys)

                    net_self_entry = {"name": name_part}
                    net_self_entry.update(properties)

                    net_self_entries.append(net_self_entry)

        return net_self_entries

    except Exception as e:
        raise F5PluginException(
            "Failed to parse network self output: {0}".format(e),
            "NET_SELF_PARSE_ERROR"
        )


def get_floating_ip():
    """Get floating IP"""
    try:
        output = run_command("tmsh list net self one-line")
        nets = parse_net_self_output(output)
        floating_ip = None
        for net in nets:
            if (net.get('floating') == 'enabled'
                    and net.get('traffic-group') != 'traffic-group-local-only'):
                address = net.get('address')
                if address and "/" in address:
                    address = address.split("/")[0]
                floating_ip = address
                break

        return floating_ip
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get floating IP: {0}. Shell command: `{1}`".format(e, e.command),
            "FLOATING_IP_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get floating IP: {0}".format(e),
            "FLOATING_IP_FETCH_ERROR"
        )


def parse_vip_output(vips_output):
    blocks = extract_blocks(vips_output,"ltm virtual")
    parsed_data = {}

    # Parse each block
    for block in blocks:
        # Extract the profile name for the key
        vserver_name_match = re.match(r'ltm virtual ([^{]+)', block)
        if not vserver_name_match:
            continue  # Skip if no profile name is found

        vserver_name = vserver_name_match.group(1).strip()
        # Remove the 'ltm virtual' header to focus on the block content
        block_content = re.sub(r'^ltm virtual [^{]+{\s*', '', block, count=1).strip()
        lines = block_content.splitlines()
        # Parse the block into a dictionary
        parsed_block = parse_block(lines)
        # Add the parsed block to the final result as a key-value pair
        parsed_data[vserver_name] = parsed_block

    return parsed_data


def get_virtual_servers():
    """Gets virtual servers."""
    vips_output = run_command("tmsh -c 'cd /; list ltm virtual recursive partition destination source profiles'")
    vips = parse_vip_output(vips_output)
    processed_vips = process_virtual_servers(vips)
    return processed_vips


def get_service_dict():
    """Gets service dict."""
    services = {}
    service_out = run_command("cat /etc/services")
    for line in service_out.split("\n"):
        # Strip whitespace and ignore comments or empty lines
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        # Split the line into parts
        parts = line.split()
        if len(parts) < 2:
            continue

        # Extract service name and port/protocol
        service_name = parts[0]
        port_protocol = parts[1]

        # Split port and protocol
        if "/" in port_protocol:
            port, protocol = port_protocol.split("/")

            # Add to dictionary, using port as the value
            if service_name not in services:
                services[service_name] = port

    # Print the resulting dictionary
    return services

def get_certificates(processed_vips):
    """Gets certificates."""
    vips = processed_vips.get('vips')
    client_ssl_profiles = processed_vips.get('client-ssl-profiles')

    get_certificates_for_profiles(client_ssl_profiles)
    get_chains_and_protocols_for_profiles(client_ssl_profiles)
    certificates = process_certificates(vips, client_ssl_profiles)
    return certificates


def get_system_info():
    """Gets system info."""
    try:
        system_info_output = run_command("tmsh show sys version detail")
        system_info = process_sys_version_output(system_info_output)
        hostname = get_hostname()
        system_info['hostname'] = hostname
        return system_info
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get system info: {0}. Shell command: `{1}`".format(e, e.command),
            "SYSTEM_INFO_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get system info: {0}".format(e),
            "SYSTEM_INFO_FETCH_ERROR"
        )


def get_partitions():
    """Gets partitions."""
    try:
        output = run_command("tmsh list auth partition one-line")
        # The output is as follows:
        # [admin@gp2-cws-f515-68:Active:In Sync] ~ # tmsh list auth partition one-line
        # auth partition Additional { }
        # auth partition Common { description "Repository for system objects and shared objects." }
        partitions = parse_tmsh_output(output, "auth partition ")
        return [partition.popitem()[0] for partition in partitions]
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get partitions: {0}. Shell command: `{1}`".format(e, e.command),
            "PARTITIONS_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get partitions: {0}".format(e),
            "PARTITIONS_FETCH_ERROR"
        )


def is_client_ssl_profile(profile):
    """Checks if the profile is a client-ssl profile."""
    # This check has been added when the plugin was tested with iApp enabled.
    # It was found that there are profiles that are in clienside context, but not client-ssl profiles.
    # So, we need to check if the profile is a client-ssl profile.
    # Example:
    # iappnew.app/iappnew_tcp-wan-optimized {
    #   context clientside
    # }
    # tmsh list ltm profile client-ssl iappnew.app/iappnew_tcp-wan-optimized
    # 01020036:3: The requested ClientSSL Profile (/Common/iappnew.app/iappnew_tcp-wan-optimized) was not found.
    #
    # But `tmsh list ltm profile tcp iappnew.app/iappnew_tcp-wan-optimized` works fine.
    command = "tmsh -c 'cd /; list ltm profile client-ssl {0} one-line'".format(profile)

    try:
        run_command(command)
        return True
    except F5ShellCommandException as e:
        return False


def is_server_ssl_profile(profile):
    """Checks if the profile is a server-ssl profile (same reasoning as is_client_ssl_profile)."""
    command = "tmsh -c 'cd /; list ltm profile server-ssl {0} one-line'".format(profile)

    try:
        run_command(command)
        return True
    except F5ShellCommandException as e:
        return False


def main():
    try:
        processed_vips = get_virtual_servers()
        certificates = get_certificates(processed_vips)
        system_info = get_system_info()
        peers = get_peers_info()
        partitions = get_partitions()
    except F5PluginException as e:
        print(json.dumps({"error": str(e), "code": e.code}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e), "code": "UNKNOWN_ERROR", "traceback": traceback.format_exc()}))
        sys.exit(1)

    print(json.dumps({
        "system-info":system_info,
        "vips": processed_vips.get("vips"),
        "skipped-vips": processed_vips.get("skipped-vips"),
        "certificates": certificates,
        "peers": peers,
        "partitions": partitions
    }))

if __name__ == "__main__":
    main()
