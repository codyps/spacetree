#!/usr/bin/env python3
"""Read mounted APFS Time Machine backups and build an offline change report."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import time

STAMP = r"\d{4}-\d{2}-\d{2}-\d{6}"
VERSION = 1


def load_comparison(raw):
    # tmutil writes literal CR characters in XML filename strings (e.g. Icon\r).
    # XML parsers otherwise normalize these to LF and corrupt the actual path.
    raw = re.sub(rb'<string>(.*?)</string>',
                 lambda match: match[0].replace(b'\r', b'&#13;'), raw, flags=re.S)
    return plistlib.loads(raw)


def discover(destination, mount_text=None):
    """Match snapshot devices to the exact destination, not similarly named disks."""
    if mount_text is None:
        mount_text = subprocess.check_output(['/sbin/mount'], text=True)
    mounts = []
    for line in mount_text.splitlines():
        match = re.fullmatch(r'(.*?) on (.*?) \((.*?)\)', line)
        if match:
            mounts.append(match.groups())
    devices = [source for source, path, _ in mounts if path == str(destination)]
    if len(devices) != 1:
        raise ValueError(f'Cannot identify mounted destination: {destination}')
    result = {}
    for source, path, flags in mounts:
        match = re.fullmatch(r'com\.apple\.TimeMachine\.(' + STAMP + r')\.backup@(.*)', source)
        if match and match[2] == devices[0] and 'read-only' in flags.split(', '):
            root = Path(path) / (match[1] + '.backup')
            if root.is_dir():
                result[match[1]] = str(root)
    return dict(sorted(result.items()))


def manifest_timeline(path):
    """Apple's observed manifest is an alternating UTC date / metadata array."""
    with open(path, 'rb') as stream:
        values = plistlib.load(stream)
    if not isinstance(values, list) or len(values) % 2:
        raise ValueError('Unsupported backup_manifest.plist schema')
    rows = []
    for date, value in zip(values[::2], values[1::2]):
        if not isinstance(date, dt.datetime) or not isinstance(value, dict):
            raise ValueError('Invalid manifest date/metadata pair')
        local = date.replace(tzinfo=dt.timezone.utc).astimezone()
        changed = value['stats']['changed']
        rows.append(dict(id=local.strftime('%Y-%m-%d-%H%M%S'), date=local.isoformat(),
                         logical=changed['logicalSize'], physical=changed['physicalSize'],
                         count=changed['count']))
    return sorted(rows, key=lambda row: row['date'])


def relative(path, root):
    # Lexical normalization: never resolve a backup symlink into live files.
    path, root = os.path.normpath(path), os.path.normpath(root)
    if os.path.commonpath([path, root]) != root or path == root:
        raise ValueError(f'Comparison returned a path outside its backup: {path}')
    return os.path.relpath(path, root)


def parse_comparison(data, older, newer):
    """Keep tmutil subtree summaries intact; count them once, as subtrees."""
    if not isinstance(data.get('Changes'), list) or 'Totals' not in data:
        raise ValueError('Incomplete tmutil comparison (missing Changes or Totals)')
    rows, errors = [], []
    for change in data['Changes']:
        if 'AddedItem' in change:
            item, before, kind, root = change['AddedItem'], {}, 'added', newer
        elif 'RemovedItem' in change:
            item, before, kind, root = change['RemovedItem'], {}, 'removed', older
        elif 'NewerItem' in change and 'OlderItem' in change:
            item, before, kind, root = change['NewerItem'], change['OlderItem'], 'modified', newer
        else:
            raise ValueError('Unrecognized tmutil change record')
        name = relative(item['Path'], root)
        if before:
            if relative(before['Path'], older) != name:
                raise ValueError('Mismatched paths in modification record')
        # Size-less records are directory metadata changes, not file payloads.
        if 'Size' not in item and 'Size' not in before:
            continue
        is_directory = None
        try:
            is_directory = stat.S_ISDIR(os.lstat(item['Path']).st_mode)
        except OSError as error:
            errors.append(f'{name}: {error.strerror}')
        old_size = int(before.get('Size', 0)) if kind == 'modified' else (int(item.get('Size', 0)) if kind == 'removed' else 0)
        new_size = 0 if kind == 'removed' else int(item.get('Size', 0))
        rows.append(dict(path=name, kind=kind, bytes=new_size, removed=old_size if kind == 'removed' else 0,
                         delta=new_size-old_size, old=old_size, new=new_size,
                         subtree=is_directory, differences=change.get('Differences', [])))
    return rows, errors


def cache_paths(cache, older, newer):
    identity = json.dumps([VERSION, older, newer, '-s', '-t', '-E', '-X'])
    key = hashlib.sha256(identity.encode()).hexdigest()[:24]
    return cache / (key + '.plist'), cache / (key + '.json')


def compare(older, newer, cache):
    raw, meta = cache_paths(cache, older, newer)
    if raw.exists() and meta.exists():
        info = json.loads(meta.read_text())
        data = load_comparison(raw.read_bytes())
        return data, info
    partial, stderr_path = raw.with_suffix('.partial'), raw.with_suffix('.stderr')
    command = ['/usr/bin/tmutil', 'compare', '-s', '-t', '-E', '-X', older, newer]
    start = time.monotonic()
    with partial.open('wb') as out, stderr_path.open('wb') as err:
        process = subprocess.Popen(command, stdout=out, stderr=err)
        try:
            while True:
                try:
                    code = process.wait(timeout=15)
                    break
                except subprocess.TimeoutExpired:
                    print(f'  Comparing… {time.monotonic()-start:.0f}s, {partial.stat().st_size:,} output bytes', flush=True)
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise
    stderr = stderr_path.read_text(errors='replace')
    if code:
        raise RuntimeError(f'tmutil exited {code}: {stderr[-2000:]}')
    data = load_comparison(partial.read_bytes())
    if 'Totals' not in data:
        raise ValueError('tmutil did not finish its comparison')
    info = dict(command=command, stderr=stderr, seconds=round(time.monotonic()-start, 1))
    partial.replace(raw)
    meta.write_text(json.dumps(info))
    return data, info


def write_report(output, report):
    output.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(report, ensure_ascii=True, separators=(',', ':'))
    (output / 'report.json').write_text(payload)
    # Prevent filenames from ending the JSON script element or injecting markup.
    embedded = payload.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    template = Path(__file__).with_name('report.html').read_text()
    temporary = output / 'index.html.partial'
    temporary.write_text(template.replace('/*REPORT_DATA*/', embedded))
    temporary.replace(output / 'index.html')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--output', type=Path, default=Path('backup-reports/time-machine'))
    parser.add_argument('--last', type=int, default=3, help='Compare the last N mounted backup intervals (default: 3; 0: timeline only)')
    parser.add_argument('--pair', nargs=2, action='append', metavar=('OLDER', 'NEWER'), help='Compare named YYYY-MM-DD-HHMMSS snapshots instead of --last; repeatable')
    args = parser.parse_args()
    if args.last < 0:
        parser.error('--last must be nonnegative')
    destination = args.destination.resolve()
    output = args.output.resolve()
    # Never place outputs on the source volume or mounted backup history.
    if output.is_relative_to(destination) or output.is_relative_to(Path('/Volumes/.timemachine')):
        parser.error('--output must be outside the backup volume and snapshot mounts')
    snapshots = discover(destination)
    ids = list(snapshots)
    timeline = manifest_timeline(destination / 'backup_manifest.plist')
    selected = args.pair or (list(zip(ids, ids[1:]))[-args.last:] if args.last else [])
    for older, newer in selected:
        if older not in snapshots or newer not in snapshots or older >= newer:
            parser.error(f'Pair must name two mounted snapshots in chronological order: {older}, {newer}')
    if not ids:
        parser.error('No read-only snapshots mounted for this disk. Run: tmutil listbackups -d "' + str(destination) + '" -m')
    cache = output / 'cache'
    cache.mkdir(parents=True, exist_ok=True)
    report = dict(destination=str(destination), generated=dt.datetime.now().astimezone().isoformat(),
                  timeline=timeline, snapshots=snapshots, comparisons=[], pending=len(selected), errors=[])
    write_report(output, report)
    print(f'{len(timeline)} manifest entries; {len(snapshots)} mounted snapshots. Report: {output / "index.html"}', flush=True)
    try:
        for older, newer in selected:
            print(f'{older} → {newer}', flush=True)
            try:
                data, info = compare(snapshots[older], snapshots[newer], cache)
                rows, errors = parse_comparison(data, snapshots[older], snapshots[newer])
                report['comparisons'].append(dict(older=older, newer=newer, rows=rows,
                    totals=data['Totals'], warnings=errors + ([info['stderr']] if info['stderr'] else [])))
                print(f'  {len(rows):,} changes; {sum(r["bytes"] for r in rows)/1e9:.2f} GB affected file/subtree sizes', flush=True)
            except (OSError, ValueError, RuntimeError, plistlib.InvalidFileException) as error:
                report['errors'].append(f'{older} → {newer}: {error}')
                print(f'  Failed: {error}', file=sys.stderr)
            report['pending'] -= 1
            write_report(output, report)
    except KeyboardInterrupt:
        report['errors'].append('Analysis cancelled. Completed comparisons are retained; rerun to resume from cache.')
        write_report(output, report)
        return 130
    return 1 if report['errors'] else 0


if __name__ == '__main__':
    sys.exit(main())
