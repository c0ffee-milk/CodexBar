#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("claude_statusline_bridge.py")
SPEC = importlib.util.spec_from_file_location("bridge", SCRIPT)
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class ClaudeStatusLineBridgeTests(unittest.TestCase):
    def test_install_coexists_and_uninstall_preserves_other_settings(self):
        with tempfile.TemporaryDirectory(prefix="statusline ' ") as directory:
            root = Path(directory)
            settings_path = root / ".claude/settings.json"
            settings_path.parent.mkdir()
            original = b'{"env":{"KEEP":"yes"},"statusLine":{"type":"command","command":"printf vi:; cat","padding":2}}\n'
            settings_path.write_bytes(original)
            BRIDGE.configure("install", root)
            installed = json.loads(settings_path.read_bytes())
            self.assertEqual(installed["env"], {"KEEP": "yes"})
            self.assertEqual(installed["statusLine"]["padding"], 2)
            backups = list(settings_path.parent.glob("*.bak"))
            self.assertEqual(backups[0].read_bytes(), original)
            BRIDGE.configure("install", root)
            payload = b'{"rate_limits":{"seven_day":{"used_percentage":81,"resets_at":1990000000}}}'
            result = subprocess.run(installed["statusLine"]["command"], shell=True, input=payload,
                                    capture_output=True, check=True)
            self.assertEqual(result.stdout, b"vi:" + payload)
            cache_file = root / ".codexbar/claude-statusline.json"
            cache = json.loads(cache_file.read_bytes())
            self.assertEqual(cache["rate_limits"]["seven_day"]["used_percentage"], 81)
            self.assertGreater(cache["updated_at"], 0)
            self.assertEqual(cache_file.stat().st_mode & 0o777, 0o600)
            result = subprocess.run(installed["statusLine"]["command"], shell=True, input=b"broken JSON",
                                    capture_output=True, check=True)
            self.assertEqual(result.stdout, b"vi:broken JSON")
            installed["new_setting"] = True
            settings_path.write_text(json.dumps(installed))
            BRIDGE.configure("uninstall", root)
            restored = json.loads(settings_path.read_bytes())
            self.assertEqual(restored["statusLine"], json.loads(original)["statusLine"])
            self.assertTrue(restored["new_setting"])

    def test_missing_and_invalid_rate_limits_do_not_refresh_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache.json"
            data = b'{"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":1990000000}}}'
            BRIDGE.cache(data, cache)
            before = cache.read_bytes(), cache.stat().st_mtime_ns
            BRIDGE.cache(b"{}", cache)
            self.assertEqual((cache.read_bytes(), cache.stat().st_mtime_ns), before)
            for payload in (b'{"rate_limits":[]}',
                            b'{"rate_limits":{"five_hour":{"used_percentage":true,"resets_at":1}}}',
                            b'{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":1}}}'):
                with self.assertRaises(ValueError):
                    BRIDGE.cache(payload, cache)
            self.assertEqual((cache.read_bytes(), cache.stat().st_mtime_ns), before)

    def test_settings_drift_and_invalid_json_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            BRIDGE.configure("install", root)
            settings_path = root / ".claude/settings.json"
            changed = b'{"statusLine":{"command":"a user replacement"},"keep":42}'
            settings_path.write_bytes(changed)
            with self.assertRaises(RuntimeError):
                BRIDGE.configure("uninstall", root)
            self.assertEqual(settings_path.read_bytes(), changed)
            settings_path.write_bytes(b"invalid JSON")
            with self.assertRaises(ValueError):
                BRIDGE.configure("install", root)
            self.assertEqual(settings_path.read_bytes(), b"invalid JSON")


if __name__ == "__main__":
    unittest.main()
