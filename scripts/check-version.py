#!/usr/bin/env python3
"""Check the shared release version before building or publishing an installer."""
import json
import os
from pathlib import Path
import re
import sys


def validate(version, manifest_version, tag=''):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('version.txt must contain a numeric X.Y.Z release version')
    if version != manifest_version:
        raise ValueError('version.txt disagrees with .release-please-manifest.json')
    if tag and tag != f'v{version}':
        raise ValueError(f'Release tag {tag!r} does not match version.txt ({version})')


def main():
    root = Path(__file__).resolve().parent.parent
    version = (root / 'version.txt').read_text().strip()
    manifest = json.loads((root / '.release-please-manifest.json').read_text())
    try:
        validate(version, manifest['.'], os.environ.get('RELEASE_TAG', ''))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    print(f'Release version: {version}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
