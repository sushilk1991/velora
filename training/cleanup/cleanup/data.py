"""Validation and deterministic isolation of public teacher examples."""
import hashlib
import json
import re
import unicodedata
from pathlib import Path


def read(path):
    rows = []
    for number, line in enumerate(Path(path).read_text().splitlines(), 1):
        if line.strip():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{number}: {exc}") from exc
    return rows


def norm(text):
    text = unicodedata.normalize('NFKC', text).casefold()
    return ' '.join(''.join(ch if unicodedata.category(ch)[0] in 'LMN' else ' ' for ch in text).split())


def grams(text, n=8):
    words = norm(text).split()
    return {tuple(words[i:i+n]) for i in range(len(words)-n+1)}


def meaning_warnings(row):
    """Flags for human review, not an automated correctness verdict."""
    raw, target = row['raw'], row['target']
    warnings = []
    if set(re.findall(r'\d+(?:[.,]\d+)*', target)) - set(re.findall(r'\d+(?:[.,]\d+)*', raw)):
        warnings.append('new number')
    # Capitals inside the sentence can indicate newly invented names; false positives are expected.
    names = lambda s: set(re.findall(r'(?<![.!?] )\b[A-Z][a-z]{2,}\b', s))
    if names(target) - names(raw):
        warnings.append('possible new name')
    if len(norm(target).split()) > len(norm(raw).split()) + 5:
        warnings.append('possible added clause')
    return warnings


_NO_LEDGER = object()


def validate(rows, holdout, *, ledger=_NO_LEDGER, require_splits=True, approved_only=True):
    if ledger is not _NO_LEDGER and not isinstance(ledger, dict):
        raise ValueError('source ledger must be a JSON object')
    if not holdout:
        raise ValueError('external holdout must not be empty')
    ids, groups, texts = set(), {}, {}
    htext = set()
    hgrams = set()
    holdout_ids = set()
    for row in holdout:
        if not isinstance(row, dict) or not isinstance(row.get('id'), str) or not row['id'].strip() or row['id'] in holdout_ids:
            raise ValueError('holdout rows must have unique nonempty ids')
        holdout_ids.add(row['id'])
        if not any(isinstance(row.get(f), str) and norm(row[f]) for f in ('raw', 'target', 'template')):
            raise ValueError('holdout row has no content')
        for field in ('raw', 'target', 'template'):
            if isinstance(row.get(field), str):
                htext.add(norm(row[field])); hgrams.update(grams(row[field]))
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('data row must be an object')
        for field in ('id', 'raw', 'target', 'mode', 'language', 'scenario_group', 'visibility'):
            if not isinstance(row.get(field), str) or not row[field].strip():
                raise ValueError(f'missing {field}')
        if row['visibility'] != 'public':
            raise ValueError(f"{row['id']}: non-public row")
        for field, keys in [('source', ('name', 'revision', 'license')), ('teacher', ('name', 'revision')), ('quality_review', ('status', 'reviewer'))]:
            obj = row.get(field)
            if not isinstance(obj, dict) or any(not isinstance(obj.get(k), str) or not obj[k].strip() for k in keys):
                raise ValueError(f"{row['id']}: missing {field} provenance")
        if ledger is not _NO_LEDGER:
            entry = ledger.get('sources', {}).get(row['source']['name']) if isinstance(ledger, dict) and isinstance(ledger.get('sources'), dict) else None
            if not isinstance(entry, dict) or entry.get('kind') not in ('public', 'synthetic') or entry.get('revision') != row['source']['revision'] or entry.get('license') != row['source']['license'] or entry.get('license') not in ledger.get('allowed_licenses', []):
                raise ValueError(f"{row['id']}: source absent from ledger or not permitted")
        if row['quality_review']['status'] not in (('approved',) if approved_only else ('approved', 'generated')):
            raise ValueError(f"{row['id']}: review must be approved")
        if row['id'] in ids:
            raise ValueError(f"duplicate id: {row['id']}")
        ids.add(row['id'])
        if row['mode'] not in ('default', 'message', 'email', 'note', 'code', 'terminal'):
            raise ValueError(f"{row['id']}: invalid mode")
        if not isinstance(row.get('romanize', False), bool) or not isinstance(row.get('instructions', ''), str) or not isinstance(row.get('vocabulary', []), list) or any(not isinstance(x, str) for x in row.get('vocabulary', [])):
            raise ValueError(f"{row['id']}: invalid prompt options")
        split = row.get('split')
        if require_splits and split not in ('train', 'dev'):
            raise ValueError(f"{row['id']}: split must be train or dev")
        if require_splits:
            prior = groups.setdefault(row['scenario_group'], split)
            if prior != split:
                raise ValueError(f"{row['id']}: group crosses splits")
        for field in ('raw', 'target'):
            value = norm(row[field])
            if not value:
                raise ValueError(f"{row['id']}: empty normalized {field}")
            prior = texts.setdefault(value, (row['id'], split))
            if prior[0] != row['id']:
                raise ValueError(f"{row['id']}: duplicate {field} with {prior[0]}")
            if value in htext or grams(row[field]) & hgrams:
                raise ValueError(f"{row['id']}: holdout contamination in {field}")
    # Near-identical templates across train/dev also leak scenario content.
    if require_splits:
        devgrams = set().union(*(grams(r[f]) for r in rows if r['split'] == 'dev' for f in ('raw', 'target')))
        for row in rows:
            if row['split'] == 'train' and any(grams(row[f]) & devgrams for f in ('raw', 'target')):
                raise ValueError(f"{row['id']}: train/dev n-gram contamination")


def assign(rows, seed='velora-cleanup-v1', dev_percent=20):
    if not 0 < dev_percent < 100:
        raise ValueError('dev percent must be between 1 and 99')
    return [dict(row, split=('dev' if int(hashlib.sha256((seed + '\0' + row['scenario_group']).encode()).hexdigest(), 16) % 100 < dev_percent else 'train')) for row in rows]


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()
