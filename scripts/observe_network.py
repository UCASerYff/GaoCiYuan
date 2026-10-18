#!/usr/bin/env python3
"""Passive, private process/byte sampling. Never launches the application.

No command arguments, credentials, URLs, DNS names or packet bodies are read.
Short-lived children between samples and delegated browser traffic are outside
this measurement. An absent process is reported as absent, not as zero traffic.
"""
import argparse
import datetime
import json
import subprocess
import time
from pathlib import Path


def process_table():
    raw = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,lstart=,comm='], text=True)
    result = {}
    for line in raw.splitlines():
        fields = line.split(None, 7)
        if len(fields) == 8:
            pid, parent = map(int, fields[:2])
            result[pid] = {'pid': pid, 'parent': parent,
                           'started': ' '.join(fields[2:7]), 'executable': fields[7]}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--duration', type=int, default=120)
    parser.add_argument('--interval', type=int, default=5)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 10 <= args.duration <= 3600 or not 1 <= args.interval <= 60:
        parser.error('duration must be 10..3600; interval must be 1..60 seconds')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + args.duration
    samples = []
    known = {}
    while True:
        table = process_table()
        roots = {pid for pid, p in table.items()
                 if p['executable'].endswith('.app/Contents/MacOS/GaoCiYuan')}
        family = set(roots)
        family.update(pid for pid, identity in known.items()
                      if pid in table and table[pid]['started'] == identity)
        while True:
            children = {pid for pid, p in table.items() if p['parent'] in family}
            if children <= family:
                break
            family.update(children)
        for pid in family:
            known[pid] = table[pid]['started']
        sample = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  'roots': sorted(roots), 'family': [table[p] for p in sorted(family)]}
        if family:
            command = ['/usr/bin/nettop', '-P', '-n', '-x', '-L', '2', '-s', '1',
                       '-J', 'bytes_in,bytes_out']
            for pid in sorted(family): command.extend(['-p', str(pid)])
            result = subprocess.run(command, capture_output=True, text=True, timeout=8)
            sample['nettopCSV'] = result.stdout
            sample['counterAvailable'] = result.returncode == 0
        else:
            sample['counterAvailable'] = False
        samples.append(sample)
        remaining = deadline - time.monotonic()
        if remaining <= 0: break
        time.sleep(min(args.interval, remaining))
    summary = {'durationSeconds': args.duration, 'intervalSeconds': args.interval,
               'appObservedSamples': sum(bool(s['roots']) for s in samples),
               'sampleCount': len(samples), 'mode': 'passive-existing-processes-only',
               'unit': 'bytes; cumulative process socket counters where available',
               'limitations': ['No active scenarios were triggered.',
                              'Absent process is not evidence of zero runtime traffic.',
                              'Short-lived children and delegated browser traffic may be missed.'],
               'samples': samples}
    args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    args.output.chmod(0o600)
    print(json.dumps({k: v for k, v in summary.items() if k != 'samples'}, ensure_ascii=False))


if __name__ == '__main__': main()
