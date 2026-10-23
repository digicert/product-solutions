import json
import subprocess
import sys
import traceback


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

    return stdout, stderr


def parse_line(tokens):
    """Parses a single line of TMSH output into a dictionary."""
    declarative_keys = ['disabled', 'internal', 'ip-forward', 'vlans-enabled', 'enabled']
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
                result[key] = parse_line(tokens)
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


def parse_tmsh_output(output, prefix_to_remove):
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
                parsed_line = parse_line(remove_prefix(line, prefix_to_remove).split(' '))
                if parsed_line:
                    results.append(parsed_line)
        return results
    except Exception as e:
        raise F5PluginException("Failed to parse TMSH output: {0}".format(e), "TMSH_OUTPUT_PARSE_ERROR")


def get_certificate(virtual_server_name, certificate_name):
    """Finds the profile associated with the specified virtual server."""
    command = "tmsh -c 'cd /; list ltm virtual {0} one-line'".format(virtual_server_name)
    vip_output, err = run_command(command)
    _, vip = parse_tmsh_output(vip_output, "ltm virtual ")[0].popitem()

    profiles = vip.get("profiles") or {}

    for profile_name, profile_details in profiles.items():
        if profile_details.get("context") == "clientside" and is_client_ssl_profile(profile_name):
            command = "tmsh -c 'cd /; list ltm profile client-ssl {0} all-properties one-line'".format(profile_name)
            profile_output, err = run_command(command)
            _, profile = parse_tmsh_output(profile_output, "ltm profile client-ssl ")[0].popitem()
            cert_key_chain = profile.get("cert-key-chain")
            cert = None
            chain = None
            if cert_key_chain:
                cert_obj = cert_key_chain.get(certificate_name[:-4])
                if cert_obj:
                    cert = cert_obj.get("cert")
                    chain = cert_obj.get("chain")

            if not cert or not chain:
                cert = profile.get("cert")
                if cert.endswith(certificate_name):
                    chain = profile.get("chain")

            if cert and chain:
                return read_cert_chain(cert, chain)

    # No client-ssl profile presents the certificate. The install step also repoints server-ssl profiles
    # (serverside context) that carried the replaced certificate, so look there before giving up.
    for profile_name, profile_details in profiles.items():
        if profile_details.get("context") == "serverside" and is_server_ssl_profile(profile_name):
            command = "tmsh -c 'cd /; list ltm profile server-ssl {0} one-line'".format(profile_name)
            profile_output, err = run_command(command)
            _, profile = parse_tmsh_output(profile_output, "ltm profile server-ssl ")[0].popitem()
            # server-ssl profiles use flat cert/key/chain properties, not a cert-key-chain block.
            cert = profile.get("cert")
            if cert and cert != "none" and cert.endswith(certificate_name):
                return read_cert_chain(cert, profile.get("chain"))

    return {
        "success": False,
        "error": "Certificate {0} not found on the virtual server {1}".format(
            certificate_name, virtual_server_name)
    }


def find_cert_file(cert_object_name):
    """Resolves a sys crypto cert object name to its file in the filestore."""
    command = 'find /config/filestore/files_d/*_d/certificate_d -name "*{0}*"'.format(
        cert_object_name.replace("/", ":"))
    path, _ = run_command(command)
    return path.split('\n')[0].strip()


def read_cert_chain(cert, chain):
    """Returns the PEM of the cert object followed by its chain object (if any)."""
    cert_path = find_cert_file(cert)
    chain_path = find_cert_file(chain) if chain and chain != "none" else ""
    command = 'cat {0} {1}'.format(cert_path, chain_path).strip()
    cert_chain, _ = run_command(command)
    return {"success": True, "cert_chain": cert_chain}


def is_server_ssl_profile(profile):
    """Checks if the profile is a server-ssl profile (same reasoning as is_client_ssl_profile)."""
    command = "tmsh -c 'cd /; list ltm profile server-ssl {0} one-line'".format(profile)

    try:
        run_command(command)
        return True
    except F5ShellCommandException as e:
        return False


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


def main():
    virtual_server_name = sys.argv[1]
    key_name = sys.argv[2]

    try:
        result = get_certificate(virtual_server_name, "{0}.crt".format(key_name))

        if not result.get("success"):
            print(json.dumps({"error": result.get("error"), "code": "CERTIFICATE_VALIDATION_ERROR"}))
            sys.exit(1)

        print(json.dumps({"certificate": result.get("cert_chain")}))
    except F5PluginException as e:
        print(json.dumps({"error": str(e), "code": e.code}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e), "code": "UNKNOWN_ERROR", "traceback": traceback.format_exc()}))
        sys.exit(1)


if __name__ == "__main__":
    main()
