"""Tests for ssh-scripts/install-certificate.py.

tmsh output fixtures are synthesised from the one-line format the parser expects (``tmsh list ...
one-line``); they were not captured from a live BIG-IP. Replace them with real captures when one is
available and keep the structure.
"""
import base64
import json
import unittest
from unittest import mock

from script_loader import FakeShell, load_script, run_main

install = load_script("install-certificate")

VS = "/Common/vs_example"
OLD_FP = "AABBCCDD"
OTHER_FP = "11223344"

# tmsh -c 'cd /; list ltm virtual /Common/vs_example one-line'
VIP_ONE_LINE = (
    'ltm virtual /Common/vs_example { destination /Common/10.0.0.1:443 ip-protocol tcp mask 255.255.255.255 '
    'description "Public web, HA pair" pool /Common/pool_web '
    'profiles { /Common/clientssl_vs { context clientside } /Common/serverssl_vs { context serverside } '
    '/Common/serverssl_other { context serverside } /Common/tcp { } /Common/http { } } '
    'source 0.0.0.0/0 vlans-enabled }\n'
)
CLIENTSSL_ONE_LINE = (
    'ltm profile client-ssl /Common/clientssl_vs { cert-key-chain { default { cert /Common/old.crt '
    'chain /Common/old_ica.crt key /Common/old.key } } defaults-from /Common/clientssl }\n'
)
SERVERSSL_VS_ONE_LINE = (
    'ltm profile server-ssl /Common/serverssl_vs { cert /Common/old.crt chain /Common/old_ica.crt '
    'key /Common/old.key defaults-from /Common/serverssl }\n'
)
SERVERSSL_OTHER_ONE_LINE = (
    'ltm profile server-ssl /Common/serverssl_other { cert /Common/other.crt chain none '
    'key /Common/other.key defaults-from /Common/serverssl }\n'
)


def device_shell():
    """A standalone BIG-IP with one VIP whose client-ssl and one server-ssl profile share old.crt."""
    not_found = install.F5ShellCommandException("01020036:3: The requested profile was not found", "tmsh")
    return (FakeShell()
            .add(r"list ltm virtual /Common/vs_example one-line", VIP_ONE_LINE)
            .add(r"list ltm profile client-ssl /Common/clientssl_vs one-line", CLIENTSSL_ONE_LINE)
            .add(r"list ltm profile client-ssl /Common/\S+ one-line", not_found)
            .add(r"list ltm profile server-ssl /Common/serverssl_vs one-line", SERVERSSL_VS_ONE_LINE)
            .add(r"list ltm profile server-ssl /Common/serverssl_other one-line", SERVERSSL_OTHER_ONE_LINE)
            .add(r"list ltm profile server-ssl /Common/\S+ one-line", not_found)
            .add(r"list sys crypto cert /Common/old.crt", OLD_FP + "\n")
            .add(r"list sys crypto cert /Common/other.crt", OTHER_FP + "\n")
            .add(r"show sys version", "17.5.1.9\n")
            .add(r"sync-status", "standalone\n")
            .add(r"^echo '.*' > /var/tmp/", "")
            .add(r"^rm /var/tmp/", "")
            .add(r"tmsh save sys config", "")
            .add(r"\| tmsh$", ("", "")))


def json_arg(**overrides):
    payload = {
        "virtualServerName": VS,
        "currentCertificateThumbprint": OLD_FP,
        "keyName": "www.example.com_20260129T231120Z_6855593c",
        "updateSameSslProfile": True,
        "useCommonIca": False,
        "icaSerialNum": None,
        "endEntityCertificate": "-----BEGIN CERTIFICATE-----\nee\n-----END CERTIFICATE-----",
        "icaCertificate": "-----BEGIN CERTIFICATE-----\nica\n-----END CERTIFICATE-----",
        "updateServerSslProfile": True,
        "groupSyncEnabled": False,
    }
    payload.update(overrides)
    return base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")


class ParseInputTest(unittest.TestCase):

    def test_json_mode_types_and_values(self):
        params = install.parse_input(["-", json_arg(groupSyncEnabled="true", useCommonIca=True, icaSerialNum="75bcd15")])
        self.assertEqual(VS, params["virtual_server_name"])
        self.assertEqual(OLD_FP, params["current_certificate_thumbprint"])
        self.assertIs(True, params["update_same_ssl_profile"])
        self.assertIs(True, params["use_common_ica"])
        self.assertEqual("75bcd15", params["ica_serial_number"])
        self.assertIs(True, params["update_server_ssl_profile"])
        self.assertIs(True, params["group_sync_enabled"], "string 'true' must be accepted as a flag")

    def test_json_mode_defaults_for_missing_flags(self):
        payload = json.loads(base64.b64decode(json_arg()))
        del payload["updateServerSslProfile"]
        del payload["groupSyncEnabled"]
        payload["icaCertificate"] = None
        arg = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
        params = install.parse_input(["-", arg])
        self.assertIs(True, params["update_server_ssl_profile"], "server-ssl defaults to on")
        self.assertIs(False, params["group_sync_enabled"], "HA sync defaults to off")
        self.assertEqual("", params["ica_certificate"], "null ICA becomes an empty string")

    def test_positional_mode_legacy_single_credential_plugin(self):
        argv = ["-", VS, OLD_FP, "key1", "false", "true", "75bcd15", "EE-PEM", "ICA-PEM"]
        params = install.parse_input(argv)
        self.assertEqual("key1", params["key_name"])
        self.assertIs(False, params["update_same_ssl_profile"])
        self.assertIs(True, params["use_common_ica"])
        self.assertEqual("EE-PEM", params["ee_certificate"])
        self.assertIs(True, params["update_server_ssl_profile"], "ninth argument absent defaults to true")
        self.assertIs(True, params["group_sync_enabled"],
                      "tenth argument absent keeps the legacy behaviour (sync whenever HA is configured)")

    def test_positional_mode_optional_trailing_flags(self):
        argv = ["-", VS, OLD_FP, "key1", "true", "false", "null", "EE", "ICA", "false", "true"]
        params = install.parse_input(argv)
        self.assertIs(False, params["update_server_ssl_profile"])
        self.assertIs(True, params["group_sync_enabled"])

    def test_too_few_arguments_is_invalid_arguments_error(self):
        with self.assertRaises(install.F5PluginException) as ctx:
            install.parse_input(["-", VS, OLD_FP])
        self.assertEqual("INVALID_ARGUMENTS", ctx.exception.code)

    def test_single_non_json_argument_is_invalid_arguments_error(self):
        with self.assertRaises(install.F5PluginException) as ctx:
            install.parse_input(["-", "not-base64-json"])
        self.assertEqual("INVALID_ARGUMENTS", ctx.exception.code)


class ToBoolTest(unittest.TestCase):

    def test_accepts_booleans_strings_and_none(self):
        self.assertIs(True, install.to_bool(True))
        self.assertIs(True, install.to_bool("true"))
        self.assertIs(True, install.to_bool(" TRUE "))
        self.assertIs(False, install.to_bool("false"))
        self.assertIs(False, install.to_bool(None))
        self.assertIs(False, install.to_bool("yes"))


class TmshParserTest(unittest.TestCase):

    def test_one_line_vip_with_nested_blocks_quoted_value_and_flags(self):
        name, vip = install.parse_tmsh_output(VIP_ONE_LINE, "ltm virtual ")[0].popitem()
        self.assertEqual("/Common/vs_example", name)
        self.assertEqual("Public web, HA pair", vip["description"])
        self.assertEqual("/Common/pool_web", vip["pool"])
        self.assertIs(True, vip["vlans-enabled"])
        self.assertEqual({"context": "clientside"}, vip["profiles"]["/Common/clientssl_vs"])
        self.assertEqual({}, vip["profiles"]["/Common/tcp"], "empty block parses to an empty dict")

    def test_api_status_warning_lines_are_skipped(self):
        output = "[api-status-warning] ltm/virtual: deprecated\n" + VIP_ONE_LINE
        self.assertEqual(1, len(install.parse_tmsh_output(output, "ltm virtual ")))

    def test_client_ssl_cert_key_chain(self):
        _, profile = install.parse_tmsh_output(CLIENTSSL_ONE_LINE, "ltm profile client-ssl ")[0].popitem()
        _, chain = profile["cert-key-chain"].popitem()
        self.assertEqual("/Common/old.crt", chain["cert"])
        self.assertEqual("/Common/old_ica.crt", chain["chain"])


class ProfileLookupTest(unittest.TestCase):

    def test_find_profile_matches_client_ssl_by_thumbprint_and_skips_non_ssl_profiles(self):
        shell = device_shell()
        with mock.patch.object(install, "run_command", shell):
            self.assertEqual("/Common/clientssl_vs", install.find_profile(VS, OLD_FP))
        self.assertTrue(shell.ran(r"list sys crypto cert /Common/old.crt"))
        self.assertFalse(shell.ran(r"list sys crypto cert /Common/other.crt"),
                         "server-ssl certificates must not be fingerprinted by the client-ssl lookup")

    def test_find_profile_returns_none_for_unknown_thumbprint(self):
        with mock.patch.object(install, "run_command", device_shell()):
            self.assertIsNone(install.find_profile(VS, "DEADBEEF"))

    def test_find_server_ssl_profiles_returns_only_profiles_carrying_the_replaced_cert(self):
        with mock.patch.object(install, "run_command", device_shell()):
            self.assertEqual(["/Common/serverssl_vs"], install.find_server_ssl_profiles(VS, OLD_FP))

    def test_get_cert_fingerprint_strips_whitespace(self):
        with mock.patch.object(install, "run_command", device_shell()):
            self.assertEqual(OLD_FP, install.get_cert_fingerprint("/Common/old.crt"))


class ServerSslCommandsTest(unittest.TestCase):

    def test_modify_commands_use_flat_cert_key_chain_properties(self):
        commands = install.get_server_ssl_modify_commands(["Common/serverssl_vs"], "/Common", "newkey", False, None)
        self.assertEqual(
            ["modify ltm profile server-ssl /Common/serverssl_vs cert /Common/newkey.crt key /Common/newkey.key "
             "chain /Common/ica_newkey.crt"], commands)

    def test_modify_commands_use_common_ica_name(self):
        commands = install.get_server_ssl_modify_commands(["Common/s"], "/Common", "k", True, "75bcd15")
        self.assertTrue(commands[0].endswith("chain /Common/ica-digicert-75bcd15.crt"))


class MainFlowTest(unittest.TestCase):
    """Runs main() with the device interactions below find_profile stubbed out."""

    def setUp(self):
        self.shell = device_shell()
        patches = {
            "run_command": self.shell,
            "create_temp_files_for_certs": mock.Mock(return_value=("/var/tmp/ee.crt", "/var/tmp/ica.crt")),
            "remove_temp_files_for_certs": mock.Mock(),
            "save_config": mock.Mock(),
            "replace_certificate_for_existing_profile": mock.Mock(return_value={"success": True}),
            "setup_profile_and_install_certificate": mock.Mock(return_value={"success": True}),
            "copy_profile": mock.Mock(),
            "save_common_ica_certificate": mock.Mock(),
            "is_ha": mock.Mock(return_value=True),
            "ha_sync": mock.Mock(),
        }
        self.mocks = {}
        for name, replacement in patches.items():
            patcher = mock.patch.object(install, name, replacement)
            self.mocks[name] = patcher.start()
            self.addCleanup(patcher.stop)

    def test_success_updates_in_place_and_reports_server_ssl_profiles(self):
        code, result, _ = run_main(install, ["-", json_arg()])
        self.assertEqual(0, code)
        self.assertTrue(result["success"])
        self.assertEqual(["/Common/serverssl_vs"], result["server-ssl-profiles-updated"])
        self.mocks["replace_certificate_for_existing_profile"].assert_called_once()
        kwargs = self.mocks["replace_certificate_for_existing_profile"].call_args.kwargs
        self.assertEqual(["/Common/serverssl_vs"], kwargs["server_ssl_profiles"])
        self.mocks["copy_profile"].assert_not_called()
        self.mocks["save_config"].assert_called_once()
        self.mocks["remove_temp_files_for_certs"].assert_called_once()

    def test_server_ssl_updates_disabled_skips_server_ssl_lookup(self):
        code, result, _ = run_main(install, ["-", json_arg(updateServerSslProfile=False)])
        self.assertEqual(0, code)
        self.assertEqual([], result["server-ssl-profiles-updated"])
        self.assertFalse(self.shell.ran(r"list ltm profile server-ssl"))

    def test_create_new_profile_path_copies_profile_then_rebinds(self):
        code, result, _ = run_main(install, ["-", json_arg(updateSameSslProfile=False)])
        self.assertEqual(0, code)
        self.mocks["copy_profile"].assert_called_once_with(
            "/Common/clientssl_vs", "Common/www.example.com_20260129T231120Z_6855593c")
        self.mocks["setup_profile_and_install_certificate"].assert_called_once()

    def test_unsecured_vip_installs_new_profile_without_lookup(self):
        code, result, _ = run_main(install, ["-", json_arg(currentCertificateThumbprint=None)])
        self.assertEqual(0, code)
        self.mocks["setup_profile_and_install_certificate"].assert_called_once()
        self.mocks["replace_certificate_for_existing_profile"].assert_not_called()
        self.assertFalse(self.shell.ran(r"list ltm virtual"))

    def test_profile_not_found_returns_error_json_and_exit_1(self):
        code, result, _ = run_main(install, ["-", json_arg(currentCertificateThumbprint="DEADBEEF")])
        self.assertEqual(1, code)
        self.assertEqual("CLIENT_SSL_PROFILE_NOT_FOUND", result["code"])
        self.assertIn("DEADBEEF", result["error"])
        self.mocks["replace_certificate_for_existing_profile"].assert_not_called()

    def test_group_sync_disabled_never_syncs_even_on_ha(self):
        code, result, _ = run_main(install, ["-", json_arg(groupSyncEnabled=False)])
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_not_called()
        self.assertEqual(["HA sync not performed as group sync is disabled or HA is not configured"], result["info"])

    def test_group_sync_enabled_syncs_on_ha(self):
        code, result, _ = run_main(install, ["-", json_arg(groupSyncEnabled=True)])
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_called_once()
        self.assertEqual(["HA sync performed as group sync is enabled and HA is configured"], result["info"])

    def test_group_sync_enabled_on_standalone_does_not_sync(self):
        self.mocks["is_ha"].return_value = False
        code, result, _ = run_main(install, ["-", json_arg(groupSyncEnabled=True)])
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_not_called()
        self.assertIn("not performed", result["info"][0])

    def test_use_common_ica_saves_shared_ica_first(self):
        code, _, _ = run_main(install, ["-", json_arg(useCommonIca=True, icaSerialNum="75bcd15")])
        self.assertEqual(0, code)
        self.mocks["save_common_ica_certificate"].assert_called_once_with("75bcd15", "/var/tmp/ica.crt", "/Common")

    def test_legacy_positional_arguments_still_work_and_keep_syncing_on_ha(self):
        argv = ["-", VS, OLD_FP, "key1", "true", "false", "null", "EE", "ICA"]
        code, result, _ = run_main(install, argv)
        self.assertEqual(0, code)
        self.assertTrue(result["success"])
        self.assertEqual(["/Common/serverssl_vs"], result["server-ssl-profiles-updated"])
        self.mocks["ha_sync"].assert_called_once()

    def test_legacy_positional_tenth_argument_can_disable_sync(self):
        argv = ["-", VS, OLD_FP, "key1", "true", "false", "null", "EE", "ICA", "true", "false"]
        code, _, _ = run_main(install, argv)
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_not_called()

    def test_install_failure_reports_installation_error(self):
        self.mocks["replace_certificate_for_existing_profile"].return_value = {
            "success": False, "error": "transaction failed"}
        code, result, _ = run_main(install, ["-", json_arg()])
        self.assertEqual(1, code)
        self.assertEqual("CERTIFICATE_INSTALLATION_ERROR", result["code"])
        self.assertEqual("transaction failed", result["error"])

    def test_unexpected_exception_is_reported_as_unknown_error(self):
        self.mocks["save_config"].side_effect = RuntimeError("disk full")
        code, result, _ = run_main(install, ["-", json_arg()])
        self.assertEqual(1, code)
        self.assertEqual("UNKNOWN_ERROR", result["code"])
        self.assertIn("disk full", result["error"])


if __name__ == "__main__":
    unittest.main()
