import importlib.util
import os
import sys
import unittest


spec = importlib.util.spec_from_file_location("summon", __file__.replace("summon-test.py", "summon.py"))
summon = importlib.util.module_from_spec(spec)
assert spec.loader
sys.modules[spec.name] = summon
spec.loader.exec_module(summon)


def popup(**overrides):
    value = {
        "command": ["/bin/example", "--safe"],
        "class": "com.example.Popup",
        "title": "Example",
        "workingDirectory": "/tmp",
        "environment": {},
        "preload": True,
        "maxWidth": 1100,
        "maxHeight": 820,
        "widthRatio": 0.85,
        "heightRatio": 0.85,
    }
    value.update(overrides)
    return value


class ConfigTests(unittest.TestCase):
    def test_parses_declarative_popup(self):
        parsed = summon.parse_config({"apps": {"example": popup()}})
        self.assertEqual(parsed["example"].command, ("/bin/example", "--safe"))
        self.assertTrue(parsed["example"].preload)

    def test_rejects_commands_that_need_a_shell(self):
        with self.assertRaisesRegex(summon.SummonError, "absolute path"):
            summon.parse_config({"apps": {"example": popup(command=["example", "; rm -rf /"])}})

    def test_rejects_duplicate_classes_and_unknown_settings(self):
        with self.assertRaisesRegex(summon.SummonError, "registered more than once"):
            summon.parse_config({"apps": {"one": popup(), "two": popup()}})
        with self.assertRaisesRegex(summon.SummonError, "unknown settings"):
            summon.parse_config({"apps": {"one": popup(typo=True)}})

    def test_runtime_override_must_be_absolute(self):
        previous = os.environ.get("SUMMON_RUNTIME_DIR")
        try:
            os.environ["SUMMON_RUNTIME_DIR"] = "relative"
            with self.assertRaisesRegex(summon.SummonError, "must be absolute"):
                summon.runtime_directory()
            os.environ["SUMMON_RUNTIME_DIR"] = "/tmp/example-summon"
            self.assertEqual(str(summon.runtime_directory()), "/tmp/example-summon")
        finally:
            if previous is None:
                os.environ.pop("SUMMON_RUNTIME_DIR", None)
            else:
                os.environ["SUMMON_RUNTIME_DIR"] = previous


class HyprlandTests(unittest.TestCase):
    def setUp(self):
        self.popup = summon.parse_config({"apps": {"example": popup()}})["example"]

    def test_target_accounts_for_rotation_scale_and_panels(self):
        target = summon.popup_target([{
            "focused": True,
            "width": 1800,
            "height": 2880,
            "scale": 2,
            "transform": 1,
            "reserved": [10, 20, 30, 40],
            "activeWorkspace": {"id": 4, "name": "4"},
            "specialWorkspace": {"id": 0, "name": ""},
        }], self.popup)
        self.assertEqual(target, (4, 1100, 714))

    def test_active_special_workspace_is_preserved(self):
        target = summon.popup_target([{
            "focused": True,
            "width": 1920,
            "height": 1080,
            "scale": 1,
            "transform": 0,
            "reserved": [0, 0, 0, 0],
            "activeWorkspace": {"id": 4, "name": "4"},
            "specialWorkspace": {"id": -98, "name": "special:notes"},
        }], self.popup)
        self.assertEqual(target[0], "special:notes")

    def test_lua_escapes_values_and_checks_exact_window_ownership(self):
        self.assertEqual(summon.lua_string('a"b\\c\n'), '"a\\"b\\\\c\\010"')
        rule = summon.popup_rule(self.popup, 900, 700, "summon")
        self.assertIn('class = "^com\\\\.example\\\\.Popup$"', rule)
        self.assertIn('workspace = "special:summon silent"', rule)
        focus = summon.focus_popup(self.popup, "0xabc123", 4, 900, 700)
        self.assertIn('address:0xabc123', focus)
        self.assertIn('window.class ~= "com.example.Popup"', focus)
        with self.assertRaisesRegex(summon.SummonError, "invalid popup address"):
            summon.focus_popup(self.popup, "activewindow", 4, 900, 700)


if __name__ == "__main__":
    unittest.main()
