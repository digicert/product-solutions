"""Tests for ssh-scripts/generate-csr.py: argument handling and the HA sync toggle."""
import base64
import json
import unittest
from unittest import mock

from script_loader import load_script, run_main

gen = load_script("generate-csr")

CSR = "-----BEGIN CERTIFICATE REQUEST-----\nMIIB\n-----END CERTIFICATE REQUEST-----"
SUBJECT = base64.b64encode(json.dumps({"organization": "Example Inc", "country": "US"}).encode()).decode()


def argv(*extra):
    base = ["-", "/Common/vs_example", "www.example.com", '"DNS:www.example.com,DNS:alt.example.com"',
            "www.example.com_20260129T231120Z_6855593c", "2048", "RSA", "normal", SUBJECT]
    return base + list(extra)


class GenerateCsrMainTest(unittest.TestCase):

    def setUp(self):
        patches = {
            "generate_csr": mock.Mock(return_value={"success": True, "csr": CSR, "warnings": []}),
            "save_config": mock.Mock(),
            "is_ha": mock.Mock(return_value=True),
            "ha_sync": mock.Mock(),
        }
        self.mocks = {}
        for name, replacement in patches.items():
            patcher = mock.patch.object(gen, name, replacement)
            self.mocks[name] = patcher.start()
            self.addCleanup(patcher.stop)

    def test_arguments_are_normalised_and_forwarded(self):
        code, result, _ = run_main(gen, argv())
        self.assertEqual(0, code)
        self.assertEqual(CSR, result["csr"])
        args = self.mocks["generate_csr"].call_args.args
        self.assertEqual("/Common", args[0], "partition is derived from the virtual server path")
        self.assertEqual("www.example.com", args[1])
        self.assertEqual('"DNS:www.example.com,DNS:alt.example.com"', args[2])
        self.assertEqual("2048", args[4])
        self.assertEqual("rsa-private", args[5], "RSA maps to the tmsh key type")
        self.assertEqual("normal", args[6])
        self.assertEqual({"organization": "Example Inc", "country": "US"}, args[7])

    def test_ec_key_type_and_empty_markers(self):
        base = argv()
        base[3] = "EMPTY_DNS_NAMES"
        base[6] = "ECDSA"
        base[8] = "EMPTY_SUBJECT_DN_FIELDS"
        code, _, _ = run_main(gen, base)
        self.assertEqual(0, code)
        args = self.mocks["generate_csr"].call_args.args
        self.assertEqual("", args[2])
        self.assertEqual("ec-private", args[5])
        self.assertIsNone(args[7])

    def test_group_sync_argument_absent_keeps_legacy_sync_on_ha(self):
        # The single-credential plugin never sends the 9th argument; it must behave as before the flag existed.
        code, result, _ = run_main(gen, argv())
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_called_once()
        self.assertEqual(["HA sync performed as group sync is enabled and HA is configured"], result["info"])

    def test_group_sync_false_never_syncs(self):
        code, result, _ = run_main(gen, argv("false"))
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_not_called()
        self.assertEqual(["HA sync not performed as group sync is disabled or HA is not configured"], result["info"])

    def test_group_sync_true_on_ha_syncs_after_save(self):
        manager = mock.Mock()
        manager.attach_mock(self.mocks["save_config"], "save_config")
        manager.attach_mock(self.mocks["ha_sync"], "ha_sync")
        code, result, _ = run_main(gen, argv("true"))
        self.assertEqual(0, code)
        self.assertEqual([mock.call.save_config(), mock.call.ha_sync()], manager.mock_calls)
        self.assertEqual(["HA sync performed as group sync is enabled and HA is configured"], result["info"])

    def test_group_sync_true_on_standalone_does_not_sync(self):
        self.mocks["is_ha"].return_value = False
        code, result, _ = run_main(gen, argv("true"))
        self.assertEqual(0, code)
        self.mocks["ha_sync"].assert_not_called()
        self.assertIn("not performed", result["info"][0])

    def test_generation_failure_reports_csr_generation_error_with_warnings(self):
        self.mocks["generate_csr"].return_value = {"success": False, "error": "key exists", "warnings": ["w1"]}
        code, result, _ = run_main(gen, argv())
        self.assertEqual(1, code)
        self.assertEqual("CSR_GENERATION_ERROR", result["code"])
        self.assertEqual("key exists", result["error"])
        self.assertEqual(["w1"], result["warnings"])
        self.mocks["save_config"].assert_not_called()

    def test_plugin_exception_keeps_its_code(self):
        self.mocks["generate_csr"].side_effect = gen.F5PluginException("fips not enabled", "FIPS_NOT_ENABLED")
        code, result, _ = run_main(gen, argv())
        self.assertEqual(1, code)
        self.assertEqual("FIPS_NOT_ENABLED", result["code"])


if __name__ == "__main__":
    unittest.main()
