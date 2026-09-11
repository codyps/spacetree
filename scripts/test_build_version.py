import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('build_version', Path(__file__).with_name('build-version.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BuildVersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git('init', '-q')
        self.git('config', 'tag.gpgSign', 'false')
        self.git('config', 'tag.forceSignAnnotated', 'false')
        self.git('config', 'core.hooksPath', '/dev/null')
        (self.root/'version.txt').write_text('0.2.0\n')
        self.commit()

    def git(self, *args):
        return module.git(self.root, *args)

    def commit(self):
        self.git('add', '.')
        self.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture')

    def test_stable_is_unchanged(self):
        self.assertEqual(module.build_version(self.root), '0.2.0')

    def test_no_tag_falls_back_to_commit_count(self):
        self.assertEqual(module.build_version(self.root, True), f'0.2.0-dev.1+g{self.git("rev-parse", "--short=12", "HEAD")}')

    def test_exact_tag_still_has_hash_and_zero_distance(self):
        self.git('tag', 'v0.2.0')
        self.assertIn('-dev.0+g', module.build_version(self.root, True))

    def test_rolling_and_nonversion_tags_do_not_change_distance(self):
        self.git('tag', 'v0.2.0')
        (self.root/'new').write_text('next')
        self.commit()
        self.git('tag', 'development')
        self.git('tag', 'v99.0.0-beta.1')
        self.assertIn('-dev.1+g', module.build_version(self.root, True))

    def test_modified_sources_are_identified(self):
        (self.root/'version.txt').write_text('0.3.0\n')
        self.assertTrue(module.build_version(self.root, True).endswith('.dirty'))

    def test_shallow_history_is_rejected(self):
        clone = self.root/'shallow'
        subprocess.run(['git', 'clone', '-q', '--depth=1', self.root.as_uri(), str(clone)], check=True)
        with self.assertRaisesRegex(ValueError, 'full history'):
            module.build_version(clone, True)
