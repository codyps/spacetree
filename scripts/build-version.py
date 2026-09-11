#!/usr/bin/env python3
"""Derive the display/installer version without changing release version files."""
import argparse
from pathlib import Path
import re
import subprocess


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def build_version(root, development=False):
    root = Path(root)
    version = (root / 'version.txt').read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('version.txt must contain X.Y.Z')
    if not development:
        return version
    if git(root, 'rev-parse', '--is-shallow-repository') == 'true':
        raise ValueError('Development versioning needs full history (fetch-depth: 0)')
    sha = git(root, 'rev-parse', '--short=12', 'HEAD')
    # Ignore the moving development tag and non-version tags. --long includes
    # the hash even when HEAD is exactly at a stable version tag.
    tags = [t for t in git(root, 'tag', '--merged', 'HEAD').splitlines()
            if re.fullmatch(r'v\d+\.\d+\.\d+', t)]
    if tags:
        match_args = [arg for tag in tags for arg in ('--match', tag)]
        description = git(root, 'describe', '--tags', '--long', '--abbrev=12', *match_args, 'HEAD')
        count = description.rsplit('-', 2)[1]
    else:
        count = git(root, 'rev-list', '--count', 'HEAD')
    changed = subprocess.run(['git', '-C', str(root), 'diff', '--quiet', 'HEAD', '--'], check=False).returncode
    if changed not in (0, 1):
        raise RuntimeError('Could not determine working-tree state')
    return f'{version}-dev.{count}+g{sha}' + ('.dirty' if changed else '')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--development', action='store_true')
    args = parser.parse_args()
    print(build_version(Path(__file__).resolve().parent.parent, args.development))
