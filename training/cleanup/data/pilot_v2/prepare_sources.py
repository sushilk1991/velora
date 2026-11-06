"""Group parallel Muse Hindi/Hinglish families before generic curation.

Raw teacher/reviewer receipts remain unchanged. This explicitly joins the
author's hi/hg family namespaces; word overlap alone cannot find translations.
Run once with --out pointing to a new JSONL, then pass it to cleanup curate.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', required=True)
args = parser.parse_args()
source = Path(__file__).parent / 'muse_generated_terra_reviewed.jsonl'
rows = [json.loads(line) for line in source.read_text().splitlines() if line.strip()]
for row in rows:
    if row['source']['name'] != 'velora-muse-synthetic-v2':
        raise ValueError('unexpected source')
    group = row['scenario_group']
    row['original_scenario_group'] = group
    row['scenario_group'] = 'muse-v2-' + re.sub(r'(^|-)(?:hi|hg)(?=-|$)', r'\1parallel', group)
with open(args.out, 'x') as output:
    for row in rows:
        output.write(json.dumps(row, ensure_ascii=False) + '\n')
print(json.dumps({'rows': len(rows), 'parallel_families': len({r['scenario_group'] for r in rows}),
                  'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                  'output_sha256': hashlib.sha256(Path(args.out).read_bytes()).hexdigest()}))
