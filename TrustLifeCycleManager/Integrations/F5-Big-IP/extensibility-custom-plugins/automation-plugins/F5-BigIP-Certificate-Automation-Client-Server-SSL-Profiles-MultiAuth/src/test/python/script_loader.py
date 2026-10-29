"""Loads the device-side scripts from src/main/resources/ssh-scripts as importable modules and
provides a fake shell so their tmsh calls can be answered with canned output.

The scripts are plain files with hyphenated names and a ``main()`` guarded by ``__main__``, so they
are loaded by path. Nothing here needs third-party packages: run with
``python3 -m unittest discover -s src/test/python``.
"""
import importlib.util
import io
import json
import os
import re
import sys
from contextlib import redirect_stdout

# The scripts live under src/main/resources and are packaged into the plugin jar. Never let the test
# run drop __pycache__ next to them (build.sh and CI also pass -B as a belt-and-braces measure).
sys.dont_write_bytecode = True

SCRIPTS_DIR = os.path.normpath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "main", "resources", "ssh-scripts"))


def load_script(name):
    """Imports ``<name>.py`` from the ssh-scripts directory under a fresh module object."""
    path = os.path.join(SCRIPTS_DIR, name + ".py")
    module_name = "ssh_script_" + name.replace("-", "_")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeShell(object):
    """Stand-in for a script's ``run_command``.

    Rules are tried in order; the first regex that matches the command decides the result. A rule's
    result is either the stdout string (stderr is ""), a tuple ``(stdout, stderr)``, or an exception
    instance to raise (use the script's ``F5ShellCommandException`` to emulate a failing tmsh call).
    Every executed command is recorded in ``commands`` so tests can assert what reached the device.
    An unmatched command raises ``AssertionError`` so an unexpected tmsh call fails the test loudly.
    """

    def __init__(self, rules=None):
        self.rules = list(rules or [])
        self.commands = []

    def add(self, pattern, result):
        self.rules.append((re.compile(pattern, re.DOTALL), result))
        return self

    def __call__(self, command):
        self.commands.append(command)
        for pattern, result in self.rules:
            if isinstance(pattern, str):
                pattern = re.compile(pattern, re.DOTALL)
            if pattern.search(command):
                if isinstance(result, BaseException):
                    raise result
                if isinstance(result, tuple):
                    return result
                return result, ""
        raise AssertionError("unexpected command: {0}".format(command))

    def ran(self, pattern):
        """True when at least one executed command matches ``pattern``."""
        return any(re.search(pattern, c, re.DOTALL) for c in self.commands)


def run_main(module, argv):
    """Runs ``module.main()`` with ``sys.argv`` replaced, capturing stdout and the exit code.

    Returns ``(exit_code, parsed_json_or_None, raw_stdout)``. Exit code 0 means main returned normally.
    """
    saved_argv = sys.argv
    sys.argv = list(argv)
    buffer = io.StringIO()
    exit_code = 0
    try:
        with redirect_stdout(buffer):
            try:
                module.main()
            except SystemExit as e:
                exit_code = e.code if isinstance(e.code, int) else 1
    finally:
        sys.argv = saved_argv
    raw = buffer.getvalue()
    try:
        parsed = json.loads(raw.strip().split("\n")[-1]) if raw.strip() else None
    except ValueError:
        parsed = None
    return exit_code, parsed, raw
