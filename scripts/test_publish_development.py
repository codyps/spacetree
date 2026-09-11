import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('publish-development.sh').resolve()
SHA = 'a'*40
VERSION = '0.2.0-dev.3+g'+'a'*12
MOCK = r'''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f:f.write(json.dumps(args)+'\n')
if args[0]=='api':
    route=next((a for a in args if a.startswith('repos/')), '')
    if route.endswith('/commits/main'):print(os.environ.get('MAIN_SHA',os.environ['BUILD_SHA']))
    elif route.endswith('/releases'):print('42' if os.environ.get('EXISTING')=='1' else '')
    elif '/matching-refs/' in route:print('b'*40 if os.environ.get('EXISTING')=='1' else '')
elif args[:2]==['release','upload'] and os.environ.get('FAIL_UPLOAD')=='1':sys.exit(1)
elif args[:2]==['release','view']:
    print('SpaceTree-0.1.0-dev.1+g'+'b'*12+'-universal.dmg')
    print('SpaceTree-0.1.0-dev.1+g'+'b'*12+'-universal.dmg.sha256')
    print('other-user-asset.txt')
    print('SpaceTree-'+os.environ['DISPLAY_VERSION']+'-universal.dmg')
'''


class PublicationTests(unittest.TestCase):
    def run_publish(self, **extra):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'gh').write_text(MOCK);(root/'gh').chmod(0o755)
            name=f'SpaceTree-{VERSION}-universal.dmg';(root/name).write_bytes(b'installer')
            digest=hashlib.sha256(b'installer').hexdigest()
            (root/(name+'.sha256')).write_text(f'{digest}  {name}\n')
            log=root/'calls.jsonl'
            env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'],GH_REPO='example/test',
                     BUILD_SHA=SHA,DISPLAY_VERSION=VERSION,BUILD_URL='https://example.invalid/run',CALL_LOG=str(log),**extra)
            result=subprocess.run(['bash',str(SCRIPT)],cwd=root,env=env,capture_output=True,text=True)
            calls=[json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result,calls

    def test_first_release_is_draft_until_upload_completes(self):
        result,calls=self.run_publish()
        self.assertEqual(result.returncode,0,result.stderr)
        creation=next(c for c in calls if c[:2]==['release','create'])
        self.assertIn('--draft',creation)
        upload=next(i for i,c in enumerate(calls) if c[:2]==['release','upload'])
        publish=next(i for i,c in enumerate(calls) if c[:2]==['release','edit'])
        self.assertLess(upload,publish)
        self.assertIn('--latest=false',calls[publish])
        self.assertTrue(any('POST' in c and 'ref=refs/tags/development' in c for c in calls))

    def test_existing_tag_moves_and_only_old_owned_assets_are_removed(self):
        result,calls=self.run_publish(EXISTING='1')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(any(c[:2]==['release','create'] for c in calls))
        self.assertTrue(any('PATCH' in c and 'sha='+SHA in c for c in calls))
        deleted=[c[3] for c in calls if c[:2]==['release','delete-asset']]
        self.assertEqual(len(deleted),2)
        self.assertTrue(all('0.1.0' in name for name in deleted))

    def test_failed_upload_preserves_previous_release_and_assets(self):
        result,calls=self.run_publish(EXISTING='1',FAIL_UPLOAD='1')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:2] in (['release','edit'],['release','delete-asset']) or 'PATCH' in c for c in calls))

    def test_stale_build_never_mutates_release(self):
        result,calls=self.run_publish(MAIN_SHA='b'*40)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(calls),1)
        self.assertIn('main has advanced',result.stdout)
