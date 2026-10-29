"""Tests for ssh-scripts/validate-certificate.py: client-ssl lookup with server-ssl fallback."""
import unittest
from unittest import mock

from script_loader import FakeShell, load_script, run_main

validate = load_script("validate-certificate")

VS = "/Common/vs_example"
KEY = "www.example.com_20260129T231120Z_6855593c"

VIP_ONE_LINE = (
    'ltm virtual /Common/vs_example { destination /Common/10.0.0.1:443 '
    'profiles { /Common/clientssl_vs { context clientside } /Common/serverssl_vs { context serverside } '
    '/Common/tcp { } } }\n'
)


def clientssl(cert_name):
    return ('ltm profile client-ssl /Common/clientssl_vs { cert-key-chain { ' + cert_name +
            ' { cert /Common/' + cert_name + '.crt chain /Common/ica_' + cert_name + '.crt key /Common/' +
            cert_name + '.key } } defaults-from /Common/clientssl }\n')


def serverssl(cert_name):
    return ('ltm profile server-ssl /Common/serverssl_vs { cert /Common/' + cert_name + '.crt chain /Common/ica_' +
            cert_name + '.crt key /Common/' + cert_name + '.key }\n')


def shell(client_cert, server_cert):
    not_found = validate.F5ShellCommandException("not found", "tmsh")
    return (FakeShell()
            .add(r"list ltm virtual /Common/vs_example one-line", VIP_ONE_LINE)
            .add(r"list ltm profile client-ssl /Common/clientssl_vs", clientssl(client_cert))
            .add(r"list ltm profile client-ssl ", not_found)
            .add(r"list ltm profile server-ssl /Common/serverssl_vs", serverssl(server_cert))
            .add(r"list ltm profile server-ssl ", not_found))


class GetCertificateTest(unittest.TestCase):

    def setUp(self):
        patcher = mock.patch.object(validate, "read_cert_chain",
                                    mock.Mock(return_value={"success": True, "cert_chain": "PEM-CHAIN"}))
        self.read_cert_chain = patcher.start()
        self.addCleanup(patcher.stop)

    def test_found_on_client_ssl_profile(self):
        with mock.patch.object(validate, "run_command", shell(KEY, "unrelated")):
            result = validate.get_certificate(VS, KEY + ".crt")
        self.assertTrue(result["success"])
        self.read_cert_chain.assert_called_once_with("/Common/" + KEY + ".crt", "/Common/ica_" + KEY + ".crt")

    def test_falls_back_to_server_ssl_profile(self):
        with mock.patch.object(validate, "run_command", shell("somethingelse", KEY)):
            result = validate.get_certificate(VS, KEY + ".crt")
        self.assertTrue(result["success"])
        self.read_cert_chain.assert_called_once_with("/Common/" + KEY + ".crt", "/Common/ica_" + KEY + ".crt")

    def test_not_found_anywhere(self):
        with mock.patch.object(validate, "run_command", shell("a", "b")):
            result = validate.get_certificate(VS, KEY + ".crt")
        self.assertFalse(result["success"])
        self.assertIn(KEY, result["error"])
        self.read_cert_chain.assert_not_called()


class MainTest(unittest.TestCase):

    def test_success_prints_certificate(self):
        with mock.patch.object(validate, "run_command", shell(KEY, "x")), \
                mock.patch.object(validate, "read_cert_chain",
                                  mock.Mock(return_value={"success": True, "cert_chain": "PEM-CHAIN"})):
            code, result, _ = run_main(validate, ["-", VS, KEY])
        self.assertEqual(0, code)
        self.assertEqual({"certificate": "PEM-CHAIN"}, result)

    def test_not_found_is_certificate_validation_error(self):
        with mock.patch.object(validate, "run_command", shell("a", "b")):
            code, result, _ = run_main(validate, ["-", VS, KEY])
        self.assertEqual(1, code)
        self.assertEqual("CERTIFICATE_VALIDATION_ERROR", result["code"])

    def test_shell_failure_on_vip_lookup_is_reported_with_shell_command_error(self):
        failing = FakeShell().add(r".*", validate.F5ShellCommandException("permission denied", "tmsh list"))
        with mock.patch.object(validate, "run_command", failing):
            code, result, _ = run_main(validate, ["-", VS, KEY])
        self.assertEqual(1, code)
        self.assertEqual("SHELL_COMMAND_ERROR", result["code"])


if __name__ == "__main__":
    unittest.main()
