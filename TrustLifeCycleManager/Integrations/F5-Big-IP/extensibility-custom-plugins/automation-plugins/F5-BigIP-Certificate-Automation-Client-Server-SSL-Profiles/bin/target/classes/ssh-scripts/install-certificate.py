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


def find_profile(full_virtual_server_name, current_certificate_thumbprint):
    """Finds the profile associated with the specified virtual server."""
    command = "tmsh -c 'cd /; list ltm virtual {0} one-line'".format(full_virtual_server_name)
    vip_output, err = run_command(command)
    _, vip = parse_tmsh_output(vip_output, "ltm virtual ")[0].popitem()

    profiles = vip.get("profiles")

    for profile_name, profile_details in profiles.items():
        if profile_details.get("context") == "clientside" and is_client_ssl_profile(profile_name):
            command = "tmsh -c 'cd /; list ltm profile client-ssl {0} one-line'".format(profile_name)
            profile_output, err = run_command(command)
            _, profile = parse_tmsh_output(profile_output, "ltm profile client-ssl ")[0].popitem()
            # TODO: What if we have more than one cert-key-chain?
            _, cert_key_chain = profile.get("cert-key-chain").popitem()
            cert = cert_key_chain.get("cert")
            # This is the output of fingerprint, we have to remove prefix and all semicolons:
            # fingerprint SHA256/F0:6C:EA:CB:6E:74:97:F4:7B:B5:6B:01:BC:E8:73:99:44:99:CA:2B:C1:5A:02:70:84:7F:E7:F2:9A:29:0D:A
            command = ("tmsh -c 'cd /; list sys crypto cert {0}'" +
                       "| grep fingerprint " +
                       "| awk '{{print $2}}' " +
                       "| sed 's/SHA256\///' " +
                       "| sed 's/://g'").format(cert)
            fingerprint, err = run_command(command)
            fingerprint = fingerprint.strip()
            if fingerprint == current_certificate_thumbprint:
                return profile_name


def create_temp_files_for_certs(ee_certificate, ica_certificate, key_name):
    """Creates temporary files for the certificates and key."""
    ee_cert_file = "/var/tmp/{0}.crt".format(key_name)
    ica_cert_file = "/var/tmp/ica_{0}.crt".format(key_name)

    run_command("echo '{0}' > {1}".format(ee_certificate, ee_cert_file))
    run_command("echo '{0}' > {1}".format(ica_certificate, ica_cert_file))

    return ee_cert_file, ica_cert_file


def remove_temp_files_for_certs(ee_cert_file, ica_cert_file):
    """Creates temporary files for the certificates and key."""
    run_command("rm {0}".format(ee_cert_file))
    run_command("rm {0}".format(ica_cert_file))


def replace_certificate_for_existing_profile(ee_cert_file, ica_cert_file, key_name, profile, partition, virtual_server,
                                             use_common_ica, ica_serial_number=None):
    """Installs the certificate on the BIG-IP."""
    cert_chain = get_cert_chain_config_for_tmsh_command(partition, key_name, use_common_ica, ica_serial_number)

    install_ee_cert_command = "install sys crypto cert {0}/{1}.crt from-local-file {2}".format(
        partition, key_name, ee_cert_file)
    install_ica_cert_command = "install sys crypto cert {0}/ica_{1}.crt from-local-file {2}".format(
        partition, key_name, ica_cert_file) if not use_common_ica else ""
    modify_profile_command = "modify ltm profile client-ssl /{0} cert-key-chain replace-all-with {1}".format(
        profile, cert_chain)

    if is_install_cert_supported_in_batch_mode():
        command = "\n".join(["(echo create cli transaction",
                             wrap_with_echo(install_ee_cert_command),
                             wrap_with_echo(install_ica_cert_command),
                             wrap_with_echo(modify_profile_command),
                             "echo submit cli transaction",
                             ") | tmsh"])

        output, err = run_command(command)

        if "transaction failed" in err:
            return {"success": False, "error": "Failed to install certificate: {0}".format(err)}
    else:
        run_command(wrap_with_tmsh(install_ee_cert_command))
        if install_ee_cert_command != "":
            run_command(wrap_with_tmsh(install_ica_cert_command))
        run_command(wrap_with_tmsh(modify_profile_command))

    return {"success": True}


def copy_profile(existing_profile, new_profile):
    """Copies an existing profile."""
    # Details related to the approach: https://my.f5.com/manage/s/article/K51888238
    tmp_file_name = new_profile.replace("/", "-")
    command = "".join([
        "tmsh -c 'list ltm profile client-ssl /{0} one-line'".format(existing_profile),
        "| sed 's,\(ltm profile client-ssl\)[^{{}}]*{{,ltm profile client-ssl /{0} {{,g' ".format(new_profile),
        " > /var/tmp/{0}.conf".format(tmp_file_name)
    ])
    run_command(command)

    command = "tmsh -c 'cd /; load sys config file /var/tmp/{0}.conf merge'".format(tmp_file_name)

    run_command(command)

    # Remove temporary configuration file
    run_command("rm {0}".format("/var/tmp/{0}.conf".format(tmp_file_name)))


def setup_profile_and_install_certificate(ee_cert_file, ica_cert_file, key_name, full_virtual_server_name,
                                          partition,
                                          virtual_server,
                                          use_common_ica, ica_serial_number=None,
                                          profile_created=False, use_defaults_from_option=False,
                                          existing_profile=None):
    """Sets up profile and installs the certificate on the BIG-IP."""
    new_profile = key_name

    cert_chain = get_cert_chain_config_for_tmsh_command(partition, key_name, use_common_ica, ica_serial_number)

    if profile_created:
        create_profile_command = ""
    elif use_defaults_from_option:
        create_profile_command = "create ltm profile client-ssl {0}/{1} defaults-from /{2} cert-key-chain add {3}".format(
            partition, new_profile, existing_profile, cert_chain
        )
    else:  # unsecured vip, create new profile
        create_profile_command = "create ltm profile client-ssl {0}/{1} cert-key-chain add {2}".format(
            partition, new_profile, cert_chain
        )

    if existing_profile:
        unlink_profile_command = "modify ltm virtual {0} profiles delete {{ /{1} }}".format(
            full_virtual_server_name, existing_profile
        )
    else:
        unlink_profile_command = ""

    install_ee_cert_command = "install sys crypto cert {0}/{1}.crt from-local-file {2}".format(
        partition, key_name, ee_cert_file)
    install_ica_cert_command = "install sys crypto cert {0}/ica_{1}.crt from-local-file {2}".format(
        partition, key_name, ica_cert_file) if not use_common_ica else ""
    modify_profile_command = "modify ltm virtual {0} profiles add {{ {1}/{2} {{ context clientside }} }}".format(
        full_virtual_server_name, partition, new_profile
    )

    if is_install_cert_supported_in_batch_mode():
        command = "\n".join(["(echo create cli transaction",
                             wrap_with_echo(install_ee_cert_command),
                             wrap_with_echo(install_ica_cert_command),
                             wrap_with_echo(create_profile_command),
                             wrap_with_echo(unlink_profile_command),
                             wrap_with_echo(modify_profile_command),
                             "echo submit cli transaction",
                             ") | tmsh"])

        output, err = run_command(command)
    else:
        run_command(wrap_with_tmsh(install_ee_cert_command))
        if install_ee_cert_command != "":
            run_command(wrap_with_tmsh(install_ica_cert_command))

        command = "\n".join(["(echo create cli transaction",
                             wrap_with_echo(create_profile_command),
                             wrap_with_echo(unlink_profile_command),
                             wrap_with_echo(modify_profile_command),
                             "echo submit cli transaction",
                             ") | tmsh"])

        output, err = run_command(command)

    if "transaction failed" in err:
        return {"success": False, "error": "Failed to install certificate: {0}".format(err)}

    return {"success": True}


def wrap_with_echo(command):
    """Wraps the command with echo statements."""
    return "echo '{0}'".format(command) if command else ""


def wrap_with_tmsh(command):
    """Wraps the command with tmsh."""
    return "tmsh {0}".format(command) if command else ""


def get_tmos_version():
    """Gets the version of the TMOS."""
    command = "tmsh show sys version | grep -E \"\s+Version\s+\" | awk '{{print $2}}'"
    version, _ = run_command(command)

    return version.strip()


def is_install_cert_supported_in_batch_mode():
    """Checks if the version of the TMOS supports installing certificates in batch mode."""
    # This is a known issue: https://cdn.f5.com/product/bugtracker/ID468505.html
    # https://digicertinc.atlassian.net/browse/DA-6928?focusedCommentId=815377
    supporting_version = 14
    version = get_tmos_version()
    major_version = int(version.split('.')[0])
    return major_version >= supporting_version


def save_config():
    """Saves the configuration."""
    command = "tmsh save sys config"
    run_command(command)


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


def save_common_ica_certificate(ica_serial_number, ica_cert_file, partition):
    """Saves the common ICA certificate."""
    ica_cert_name = get_ica_cert_name(ica_serial_number)
    command = "tmsh install sys crypto cert {0}/{1} from-local-file {2}".format(
        partition, ica_cert_name, ica_cert_file)
    run_command(command)


def get_cert_chain_config_for_tmsh_command(partition, key_name, use_common_ica, ica_serial_number):
    ica_cert_name = "ica_{0}.crt".format(key_name)

    if use_common_ica:
        ica_cert_name = get_ica_cert_name(ica_serial_number)

    return "{{ {1} {{ cert {0}/{1}.crt key {0}/{1}.key chain {0}/{2} }} }}".format(partition, key_name, ica_cert_name)


def get_ica_cert_name(ica_serial_number):
    # F5 supports only 60 characters in ICA file name, ica-digicert-+serialnumber will fit within 60 characters
    return "ica-digicert-" + ica_serial_number + '.crt'


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
    full_virtual_server_name = sys.argv[1]
    current_certificate_thumbprint = sys.argv[2]
    key_name = sys.argv[3]
    update_same_ssl_profile = sys.argv[4]
    use_common_ica = sys.argv[5]
    ica_serial_number = sys.argv[6]
    ee_certificate = sys.argv[7]
    ica_certificate = sys.argv[8]

    try:
        vserver_path = full_virtual_server_name.split("/")
        partition = "/{0}".format(vserver_path[1])
        virtual_server = vserver_path[-1]

        ee_cert_file, ica_cert_file = create_temp_files_for_certs(ee_certificate, ica_certificate, key_name)
        is_unsecured_vip = current_certificate_thumbprint == "null"
        should_create_new_profile = update_same_ssl_profile != "true" and not is_unsecured_vip
        use_common_ica = use_common_ica == "true"

        if use_common_ica:
            save_common_ica_certificate(ica_serial_number, ica_cert_file, partition)

        if is_unsecured_vip:
            result = setup_profile_and_install_certificate(ee_cert_file, ica_cert_file, key_name,
                                                           full_virtual_server_name,
                                                           partition, virtual_server,
                                                           use_common_ica, ica_serial_number,
                                                           profile_created=False, use_defaults_from_option=False,
                                                           existing_profile=None)
        else:
            existing_profile = find_profile(full_virtual_server_name, current_certificate_thumbprint)
            if should_create_new_profile:
                new_profile = "{0}/{1}".format(partition, key_name)[1:]  # remove first character "/"
                copy_profile(existing_profile, new_profile)
                result = replace_certificate_for_existing_profile(ee_cert_file, ica_cert_file, key_name, new_profile,
                                                                  partition, virtual_server, use_common_ica, ica_serial_number)
                if result.get("success"):
                    result = setup_profile_and_install_certificate(ee_cert_file, ica_cert_file, key_name,
                                                                   full_virtual_server_name,
                                                                   partition, virtual_server,
                                                                   use_common_ica, ica_serial_number,
                                                                   profile_created=True, use_defaults_from_option=False,
                                                                   existing_profile=existing_profile)
            else:
                result = replace_certificate_for_existing_profile(ee_cert_file, ica_cert_file, key_name, existing_profile,
                                                                  partition, virtual_server, use_common_ica, ica_serial_number)

        if not result.get("success"):
            print(json.dumps({"error": result.get("error"), "code": "CERTIFICATE_INSTALLATION_ERROR"}))
            sys.exit(1)

        remove_temp_files_for_certs(ee_cert_file, ica_cert_file)

        save_config()

        if is_ha():
            ha_sync()

        print(json.dumps(result))
    except F5PluginException as e:
        print(json.dumps({"error": str(e), "code": e.code}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"error": str(e), "code": "UNKNOWN_ERROR", "traceback": traceback.format_exc()}))
        sys.exit(1)


if __name__ == "__main__":
    main()
