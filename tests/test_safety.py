"""Exercise the startup safety gate against rendered config and unsafe edits."""
import importlib.util
from pathlib import Path
import sys
import unittest

spec = importlib.util.spec_from_file_location('entrypoint', 'image/entrypoint.py')
entrypoint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entrypoint)
CONFIG = Path(sys.argv.pop()).read_text()


class SafetyTests(unittest.TestCase):
    def test_chart_passes_safety_gate(self):
        entrypoint.check_config(CONFIG)

    def test_exit_proxy_and_control_changes_are_rejected(self):
        for old, new in [('ExitRelay 0', 'ExitRelay 1'),
                         ('ExitPolicy reject *:*', 'ExitPolicy accept *:*'),
                         ('SocksPort 0', 'SocksPort 9050'),
                         ('ControlPort 0', 'ControlPort 9051'),
                         ('IPv6Exit 0', 'IPv6Exit 1'),
                         ('ORPort 9001 IPv4Only', 'ORPort 9002'),
                         ('CookieAuthentication 1', 'CookieAuthentication 0')]:
            with self.subTest(option=old), self.assertRaises(ValueError):
                entrypoint.check_config(CONFIG.replace(old, new))

    def test_duplicate_options_are_rejected(self):
        with self.assertRaises(ValueError):
            entrypoint.check_config(CONFIG + '\nExitPolicy accept *:*\n')


if __name__ == '__main__':
    unittest.main()
