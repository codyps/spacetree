import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('check_version', Path(__file__).with_name('check-version.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class VersionTests(unittest.TestCase):
    def test_matching_version_and_tag(self):
        module.validate('0.2.3', '0.2.3', 'v0.2.3')
        module.validate('0.2.3', '0.2.3')

    def test_manifest_mismatch(self):
        with self.assertRaises(ValueError):
            module.validate('0.2.3', '0.2.2')

    def test_tag_mismatch(self):
        with self.assertRaises(ValueError):
            module.validate('0.2.3', '0.2.3', 'v0.2.2')

    def test_invalid_versions(self):
        for version in ['v1.2.3', '1.2', '01.2.3', '1.2.3-beta.1', '1.2.3\nother']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                module.validate(version, version)
