"""Tests for the parsers in ssh-scripts/get-configuration-info.py (the inventory script)."""
import unittest

from script_loader import load_script

info = load_script("get-configuration-info")

SYS_VERSION = """
Sys::Version
Main Package
  Product     BIG-IP
  Version     17.5.1.9
  Build       0.174.12
  Edition     Point Release 9
  Date        Tue Aug 12 10:00:00 PDT 2026

Kernel
  Type     Linux
  Release  3.10.0-862.14.4.el7.ve.x86_64
"""


class SysVersionTest(unittest.TestCase):

    def test_main_package_two_token_lines_are_captured(self):
        result = info.process_sys_version_output(SYS_VERSION)
        self.assertEqual("BIG-IP", result["product"])
        self.assertEqual("17.5.1.9", result["version"])
        self.assertEqual("0.174.12", result["build"])

    def test_multi_token_lines_are_ignored(self):
        result = info.process_sys_version_output(SYS_VERSION)
        self.assertNotIn("edition", result, "three-token Edition line is skipped by the parser")
        self.assertNotIn("date", result)

    def test_kernel_two_token_lines_are_also_captured(self):
        # Documented behaviour: the parser only looks for the "Main Package" header and never leaves
        # that category, so two-token Kernel lines land in the result too. Harmless, but if the
        # Java side ever maps "type" or "release" this is where it comes from.
        result = info.process_sys_version_output(SYS_VERSION)
        self.assertEqual("Linux", result["type"])
        self.assertTrue(result["release"].startswith("3.10.0"))


class TmshParserTest(unittest.TestCase):

    def test_declarative_keys_including_default_become_true(self):
        line = 'ltm virtual /Common/vs { destination /Common/10.0.0.1:443 disabled vlans-enabled default }\n'
        _, vip = info.parse_tmsh_output(line, "ltm virtual ")[0].popitem()
        self.assertIs(True, vip["disabled"])
        self.assertIs(True, vip["vlans-enabled"])
        self.assertIs(True, vip["default"])
        self.assertEqual("/Common/10.0.0.1:443", vip["destination"])

    def test_quoted_value_with_escaped_quotes(self):
        line = r'ltm virtual /Common/vs { description "say \"hi\" to all" }' + "\n"
        _, vip = info.parse_tmsh_output(line, "ltm virtual ")[0].popitem()
        self.assertEqual('say "hi" to all', vip["description"])

    def test_multiple_objects_and_non_matching_lines(self):
        output = ('ltm virtual /Common/a { destination /Common/1.1.1.1:443 }\n'
                  'something else entirely\n'
                  'ltm virtual /Common/b { destination /Common/2.2.2.2:443 }\n')
        parsed = info.parse_tmsh_output(output, "ltm virtual ")
        self.assertEqual(2, len(parsed))
        self.assertIn("/Common/a", parsed[0])
        self.assertIn("/Common/b", parsed[1])

    def test_parse_error_is_wrapped_in_plugin_exception(self):
        with self.assertRaises(info.F5PluginException) as ctx:
            info.parse_tmsh_output(None, "ltm virtual ")
        self.assertEqual("TMSH_OUTPUT_PARSE_ERROR", ctx.exception.code)


if __name__ == "__main__":
    unittest.main()
