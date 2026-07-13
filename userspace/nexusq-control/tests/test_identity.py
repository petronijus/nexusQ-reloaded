import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import unittest

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

if __name__ == "__main__":
    unittest.main()
