import base64
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("configure_updater", Path(__file__).with_name("configure-updater.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdaterConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.key = base64.b64encode(bytes(range(32))).decode()
        self.info = {"SpaceTreeDisplayVersion": "0.2.0", "CFBundleVersion": "12"}

    def test_disabled_build_has_no_sparkle_settings(self):
        self.assertEqual(module.configure(self.info, ""), self.info)

    def test_stable_feed_and_opt_in_defaults(self):
        info = module.configure(self.info, self.key)
        self.assertEqual(info["SUFeedURL"], "https://github.com/codyps/spacetree/releases/latest/download/appcast.xml")
        self.assertFalse(info["SUEnableAutomaticChecks"])
        self.assertFalse(info["SUAutomaticallyUpdate"])
        self.assertFalse(info["SUEnableSystemProfiling"])
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
        self.assertEqual(info["SUSignedFeedFailureExpirationInterval"], 0)
        self.assertEqual(info["CFBundleVersion"], "12")

    def test_development_feed_is_separate_and_supports_forks(self):
        self.info["SpaceTreeDisplayVersion"] = "0.2.0-dev.14+gabc123def456"
        info = module.configure(self.info, self.key, "someone/fork")
        self.assertEqual(info["SUFeedURL"], "https://github.com/someone/fork/releases/download/development/appcast.xml")

    def test_rejects_bad_keys_and_repositories(self):
        for key in ["oops", base64.b64encode(b"short").decode(), self.key + "\n"]:
            with self.assertRaises(ValueError):
                module.configure(self.info, key)
        for repo in ["https://example.com/repo", "owner/repo/extra", "owner/repo?x"]:
            with self.assertRaises(ValueError):
                module.configure(self.info, self.key, repo)
