import datetime as dt
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

import analyze


class AnalysisTests(unittest.TestCase):
    def test_discovery_matches_device_and_read_only_complete_backups(self):
        mounts = '''/dev/disk4s2 on /Volumes/T7 Shield (apfs, local, journaled)
com.apple.TimeMachine.2026-09-08-185544.backup@/dev/disk4s2 on /Volumes/.timemachine/id/2026-09-08-185544.backup (apfs, local, read-only, nobrowse)
com.apple.TimeMachine.2026-09-09-185544.backup@/dev/disk9s2 on /Volumes/.timemachine/other/2026-09-09-185544.backup (apfs, local, read-only)
com.apple.TimeMachine.2026-09-10-185544.backup@/dev/disk4s2 on /Volumes/T7 Shield/2026-09-10-185544.backup (apfs, local)
'''
        with patch.object(Path, 'is_dir', return_value=True):
            found = analyze.discover(Path('/Volumes/T7 Shield'), mounts)
        self.assertEqual(list(found), ['2026-09-08-185544'])

    def test_same_size_rewrite_counts_full_newer_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp)/'old', Path(tmp)/'new'
            old.mkdir(); new.mkdir()
            (new/'database').write_bytes(b'12345')
            data = {'Changes': [{'OlderItem': {'Path': str(old/'database'), 'Size': 5},
                                 'NewerItem': {'Path': str(new/'database'), 'Size': 5},
                                 'Differences': ['mtime']}], 'Totals': {'ChangedSize': 0}}
            rows, errors = analyze.parse_comparison(data, str(old), str(new))
            self.assertEqual(errors, [])
            self.assertEqual((rows[0]['bytes'], rows[0]['delta']), (5, 0))

    def test_tmutil_literal_carriage_return_filename_is_preserved(self):
        raw = b'<plist version="1.0"><dict><key>Path</key><string>Icon\r</string></dict></plist>'
        self.assertEqual(analyze.load_comparison(raw)['Path'], 'Icon\r')

    def test_added_subtree_and_deleted_file_are_counted_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, new = Path(tmp)/'old', Path(tmp)/'new'
            old.mkdir(); new.mkdir(); (new/'folder').mkdir()
            (old/'deleted').write_bytes(b'123')
            data = {'Changes': [{'AddedItem': {'Path': str(new/'folder'), 'Size': 100}},
                                {'RemovedItem': {'Path': str(old/'deleted'), 'Size': 3}},
                                {'OlderItem': {'Path': str(old/'folder')}, 'NewerItem': {'Path': str(new/'folder')}, 'Differences': ['mtime']}], 'Totals': {}}
            rows, errors = analyze.parse_comparison(data, str(old), str(new))
            self.assertEqual(len(rows), 2)
            self.assertTrue(rows[0]['subtree'])
            self.assertEqual(sum(r['bytes'] for r in rows), 100)
            self.assertEqual(sum(r['removed'] for r in rows), 3)

    def test_missing_metadata_reports_unknown_type(self):
        rows, errors = analyze.parse_comparison({'Changes': [{'AddedItem': {'Path': '/nonexistent/new/file', 'Size': 4}}], 'Totals': {}}, '/nonexistent/old', '/nonexistent/new')
        self.assertIsNone(rows[0]['subtree'])
        self.assertEqual(len(errors), 1)

    def test_rejects_truncated_and_outside_paths(self):
        with self.assertRaises(ValueError):
            analyze.parse_comparison({'Changes': []}, '/old', '/new')
        for path in ['/newer/file', '/new/../secrets', '/new']:
            with self.assertRaises(ValueError):
                analyze.relative(path, '/new')

    def test_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            new = Path(tmp)/'new'; new.mkdir(); (new/'alias').symlink_to('/')
            rows, _ = analyze.parse_comparison({'Changes': [{'AddedItem': {'Path': str(new/'alias'), 'Size': 1}}], 'Totals': {}}, '/old', str(new))
            self.assertFalse(rows[0]['subtree'])
            self.assertEqual(rows[0]['path'], 'alias')

    def test_manifest_parses_utc_and_sorts(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'manifest.plist'
            value = {'stats': {'changed': {'logicalSize': 4, 'physicalSize': 4096, 'count': 1}}}
            path.write_bytes(plistlib.dumps([dt.datetime(2026, 9, 2, 1), value, dt.datetime(2026, 9, 1, 1), value]))
            rows = analyze.manifest_timeline(path)
            self.assertLess(rows[0]['date'], rows[1]['date'])
            self.assertEqual(rows[0]['logical'], 4)
            self.assertIsNotNone(dt.datetime.fromisoformat(rows[0]['date']).tzinfo)

    def test_embedded_paths_cannot_inject_html(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = {'path': '</script><script>alert(1)</script>&é'}
            analyze.write_report(Path(tmp), report)
            html = (Path(tmp)/'index.html').read_text()
            embedded = html.split('<script id="report-data" type="application/json">')[1].split('</script>')[0]
            self.assertNotIn('<', embedded)
            self.assertEqual(json.loads(embedded), report)

    def test_cache_keys_separate_sources(self):
        self.assertNotEqual(analyze.cache_paths(Path('/tmp'), '/disk1/old', '/disk1/new'),
                            analyze.cache_paths(Path('/tmp'), '/disk2/old', '/disk2/new'))

    def test_failed_comparison_is_not_cached_as_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            with patch.object(analyze.subprocess, 'Popen') as launch:
                launch.return_value.wait.return_value = 1
                with self.assertRaises(RuntimeError):
                    analyze.compare('/old', '/new', cache)
            raw, meta = analyze.cache_paths(cache, '/old', '/new')
            self.assertFalse(raw.exists())
            self.assertFalse(meta.exists())

    def test_completed_cache_avoids_rescanning(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            raw, meta = analyze.cache_paths(cache, '/old', '/new')
            raw.write_bytes(plistlib.dumps({'Changes': [], 'Totals': {}}))
            meta.write_text(json.dumps({'stderr': ''}))
            with patch.object(analyze.subprocess, 'Popen') as launch:
                data, _ = analyze.compare('/old', '/new', cache)
                self.assertEqual(data['Changes'], [])
                launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
