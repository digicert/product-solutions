import base64
import json
import os
import re
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


def build_subject_dn_flags(subject_dn_fields):
    """Builds TMSH command flags from subject DN fields."""
    supported_fields = ["organization", "ou", "country", "state", "city", "email-address"]
    flags = []

    if subject_dn_fields:
        for field in supported_fields:
            value = subject_dn_fields.get(field)
            if value:
                # Escape any internal double quotes
                escaped_value = value.replace('"', r'\"')
                # Wrap in double quotes
                flags.append('{0} "{1}"'.format(field, escaped_value))

    return " ".join(flags)


def generate_csr(partition, common_name, dns_names, key_name, key_size, key_type, security_type=None, subject_dn_fields=None):
    """Generates a CSR using the specified parameters."""
    warnings = []
    sans = "" if dns_names == "" else 'subject-alternative-name "{0}"'.format(dns_names)

    if security_type == "fips":
        if not is_fips_enabled():
            security_type = "normal"
            warnings.append("FIPS is not enabled, using 'normal' security type instead.")
    elif security_type == "hsm":
        if not is_hsm_enabled():
            security_type = "normal"
            warnings.append("HSM is not enabled, using 'normal' security type instead.")
    else:
        security_type = "normal"

    key_size_flag = "" if key_type == "ec-private" else "key-size {0}".format(key_size)
    subject_dn_flags = build_subject_dn_flags(subject_dn_fields)

    command = ("tmsh create /sys crypto key {0}/{1}.key key-type {2} {3} security-type {4} "
               "gen-csr common-name {5} {6} {7}").format(partition, key_name, key_type, key_size_flag,
                                                          security_type, common_name, sans, subject_dn_flags).strip()

    try:
        output, err = run_command(command)
    except F5ShellCommandException as e:
        return {"success": False, "error": "Failed to generate CSR: {0}".format(str(e)), "warnings": warnings}

    # The `create crypto key` command returns nothing for BIGIP Version 13.1.1.
    # Whereas it returns the CSR in output for BIGIP Version > 13
    # That's why we need to check if the output is empty and get the CSR via addtional command
    # https://digicertinc.atlassian.net/browse/DA-6928
    if output and "-----BEGIN CERTIFICATE REQUEST-----" in output:
        csr = get_csr_from_output(output)
    else:
        # Try to get the CSR by the key name, adding extension `.csr` to the key name
        # If the output is empty, try to get the CSR by the key name, adding extension `.key` to the key name
        # On >13 BIGIP versions, the CSR is saved with the extension `.key` instead of `.csr`
        command = "tmsh list /sys crypto csr {0}/{1}.csr".format(partition, key_name)
        output, _ = run_command(command)
        if not output:
            command = "tmsh list /sys crypto csr {0}/{1}.key".format(partition, key_name)
            output, _ = run_command(command)
        csr = get_csr_from_output(output)

    return {"success": True, "csr": csr, "warnings": warnings}


def save_config():
    """Saves the configuration."""
    command = "tmsh save sys config"
    run_command(command)


def get_csr_from_output(output):
    """Extracts the CSR from the output of a command."""
    match = re.search(r"-----BEGIN CERTIFICATE REQUEST-----.*-----END CERTIFICATE REQUEST-----", output, re.DOTALL)
    return match.group()



def is_ha():
    """Returns True if the system is in a high-availability configuration."""
    try:
        command = "tmsh show /cm sync-status field-fmt | grep \"    mode\" | awk '{{print $2}}'"
        mode, _ = run_command(command)

        return mode.strip() == "high-availability"
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get high availability info: {0}. Shell command: `{1}`".format(e, e.command),
            "HA_INFO_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get high availability info: {0}".format(e),
            "HA_INFO_FETCH_ERROR"
        )


def ha_sync():
    """Synchronizes the configuration in a high-availability configuration."""
    command = "tmsh list cm device-group all-properties one-line"
    device_groups_output, error = run_command(command)
    device_groups = parse_tmsh_output(device_groups_output, "cm device-group ")

    sync_failover_device_group = None
    for device_group in device_groups:
        device_group_name, device_group_details = device_group.popitem()
        if device_group_details.get("type") == "sync-failover":
            sync_failover_device_group = device_group_name
            break

    if sync_failover_device_group is None:
        raise F5PluginException("Failed to find sync-failover device group", "HA_SYNC_ERROR")

    command = "tmsh run cm config-sync to-group {0}".format(sync_failover_device_group)
    output, error = run_command(command)

    if error:
        raise F5PluginException("Failed to synchronize configuration: {0}".format(error), "HA_SYNC_ERROR")


def is_fips_enabled():
    """Returns True if FIPS is enabled."""
    try:
        command = "tmsh show sys crypto fips"
        output, _ = run_command(command)
        return "not licensed" not in output
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get FIPS info: {0}. Shell command: `{1}`".format(e, e.command),
            "FIPS_INFO_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get FIPS info: {0}".format(e),
            "FIPS_INFO_FETCH_ERROR"
        )


def is_hsm_enabled():
    """Returns True if HSM is enabled."""
    try:
        # TODO: Find better way to check if HSM is enabled
        command = "tmsh list /ltm profile client-ssl | grep -i hsm"
        output, _ = run_command(command)
        return output != ""
    except F5ShellCommandException as e:
        raise F5PluginException(
            "Failed to get HSM info: {0}. Shell command: `{1}`".format(e, e.command),
            "HSM_INFO_FETCH_ERROR"
        )
    except Exception as e:
        raise F5PluginException(
            "Failed to get HSM info: {0}".format(e),
            "HSM_INFO_FETCH_ERROR"
        )


def main():
    full_virtual_server_name = sys.argv[1]
    common_name = sys.argv[2]
    dns_names = sys.argv[3]
    key_name = sys.argv[4]
    key_size = sys.argv[5]
    key_type = sys.argv[6]
    security_type = sys.argv[7]
    subject_dn_fields_arg = sys.argv[8] if len(sys.argv) > 8 else "EMPTY_SUBJECT_DN_FIELDS"

    try:
        if key_type.lower().startswith("rsa"):
            key_type = "rsa-private"
        else:
            key_type = "ec-private"

        vserver_path = full_virtual_server_name.split("/")
        partition = "/{0}".format(vserver_path[1])

        if dns_names == "EMPTY_DNS_NAMES":
            dns_names = ""

        subject_dn_fields = None
        if subject_dn_fields_arg != "EMPTY_SUBJECT_DN_FIELDS":
            subject_dn_fields = json.loads(base64.b64decode(subject_dn_fields_arg).decode("utf-8"))

        result = generate_csr(partition, common_name, dns_names, key_name, key_size, key_type, security_type, subject_dn_fields)

        if not result.get("success"):
            print(json.dumps({"error": result.get("error"), "code": "CSR_GENERATION_ERROR", "warnings": result.get("warnings")}))
            sys.exit(1)

        save_config()

        if is_ha():
            ha_sync()

        print(json.dumps({"csr": result.get("csr"), "warnings": result.get("warnings")}))
    except F5PluginException as e:
        print(json.dumps({"error": str(e), "code": e.code}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e), "code": "UNKNOWN_ERROR", "traceback": traceback.format_exc()}))
        sys.exit(1)


if __name__ == "__main__":
    main()
