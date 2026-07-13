import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "nexusq-control")

def load_daemon():
    spec = importlib.util.spec_from_loader(
        "nexusq_control", importlib.machinery.SourceFileLoader("nexusq_control", DAEMON))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

class TestIdentity(unittest.TestCase):
    def test_load_identity_from_file(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "device.json")
            with open(p, "w") as f:
                json.dump({"name": "Obývák Q", "room": "livingroom"}, f)
            ident = mod.load_identity(p)
        self.assertEqual(ident["name"], "Obývák Q")
        self.assertEqual(ident["room"], "livingroom")

    def test_load_identity_missing_file_falls_back(self):
        mod = load_daemon()
        os.environ["NEXUSQ_NAME"] = "EnvName"
        try:
            ident = mod.load_identity("/nonexistent/device.json")
        finally:
            del os.environ["NEXUSQ_NAME"]
        self.assertEqual(ident["name"], "EnvName")
        self.assertEqual(ident["room"], "")

    def test_load_identity_garbage_file_falls_back(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "device.json")
            with open(p, "w") as f:
                f.write("{not json")
            ident = mod.load_identity(p)
        self.assertEqual(ident["name"], "Nexus Q")

    def test_load_identity_non_dict_json_falls_back(self):
        mod = load_daemon()
        for payload in ("null", "[1, 2, 3]"):
            with tempfile.TemporaryDirectory() as d:
                p = os.path.join(d, "device.json")
                with open(p, "w") as f:
                    f.write(payload)
                os.environ.pop("NEXUSQ_NAME", None)
                ident = mod.load_identity(p)
            self.assertEqual(ident["name"], "Nexus Q")
            self.assertEqual(ident["room"], "")


class TestStartSetupMode(unittest.TestCase):
    def test_start_setup_mode_timeout_maps_to_unavailable(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            flag_path = os.path.join(d, "nexusq-setup.force")
            with patch.object(mod, "SETUP_FORCE_FLAG", flag_path), \
                 patch.object(mod.subprocess, "run",
                               side_effect=mod.subprocess.TimeoutExpired(cmd="systemctl", timeout=15)):
                with self.assertRaises(mod.Err) as ctx:
                    mod.start_setup_mode()
                self.assertEqual(ctx.exception.code, "unavailable")
                self.assertFalse(os.path.exists(flag_path))

    def test_start_setup_mode_arm_failure_maps_to_unavailable(self):
        mod = load_daemon()
        with tempfile.TemporaryDirectory() as d:
            # Set SETUP_FORCE_FLAG to a path in a nonexistent subdirectory
            # so open() will raise OSError when trying to create the file
            flag_path = os.path.join(d, "nonexistent-subdir", "flag")
            with patch.object(mod, "SETUP_FORCE_FLAG", flag_path):
                with self.assertRaises(mod.Err) as ctx:
                    mod.start_setup_mode()
                self.assertEqual(ctx.exception.code, "unavailable")
                self.assertIn("cannot arm setup mode", ctx.exception.message)


if __name__ == "__main__":
    unittest.main()
