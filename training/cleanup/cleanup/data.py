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


def duplicate_policy(ledger):
    value = ledger.get('duplicate_policy', 'strict') if isinstance(ledger, dict) else 'strict'
    if value not in ('strict', 'same-component-contract'):
        raise ValueError('unknown duplicate policy')
    return value


def task_contract(row):
    """Exact fields rendered to the model; provenance and split are not prompt inputs."""
    return json.dumps([row.get('mode'), row.get('language'), row.get('romanize', False),
                       row.get('instructions', ''), row.get('vocabulary', [])],
                      ensure_ascii=False, separators=(',', ':'))


def prompt_isolation(ledger):
    """Validate explicit prompt-isolation policy; never infer shared templates."""
    if not isinstance(ledger,dict):return False, ()
    enabled=ledger.get('isolate_prompt_fields',False)
    if type(enabled) is not bool:raise ValueError('isolate_prompt_fields must be boolean')
    templates=ledger.get('shared_instruction_templates',[])
    if not isinstance(templates,list) or any(not isinstance(x,str) or not x.strip() for x in templates):
        raise ValueError('shared_instruction_templates must be a list of nonempty strings')
    return enabled,tuple(templates)


def content_fields(row, *, include_template=False, ledger=None, include_short_vocabulary=False):
    """Yield isolated scenario text under the optional, explicit ledger policy.

    Short vocabulary is exposed only for whole-heldout exact matching, not for
    component links. The context suffix must be verified before stripping it.
    """
    context=row.get('scenario_context','')
    if not isinstance(context,str):raise ValueError(f"{row.get('id')}: scenario_context must be a string")
    for field in ('raw','target')+(('template',) if include_template else ()):
        if isinstance(row.get(field),str):yield field,row[field]
    if context.strip():yield 'scenario_context',context
    enabled,templates=prompt_isolation(ledger)
    if not enabled:return
    instructions=row.get('instructions','')
    vocabulary=row.get('vocabulary',[])
    if not isinstance(instructions,str) or not isinstance(vocabulary,list) or any(not isinstance(x,str) for x in vocabulary):
        raise ValueError(f"{row.get('id')}: invalid prompt options")
    marker='\n\nPrevious text (context only, do NOT repeat it): «'
    marker_text='Previous text (context only, do NOT repeat it):'
    if context.strip() and not (include_template and 'instructions' not in row):
        suffix=marker+context+'».'
        if not norm(context) or not instructions.endswith(suffix) or instructions.count(marker_text)!=1:
            raise ValueError(f"{row.get('id')}: scenario_context must match the production instruction suffix")
        instructions=instructions[:-len(suffix)]
    elif marker_text in instructions:
        raise ValueError(f"{row.get('id')}: scenario_context missing from production instruction suffix")
    if instructions.strip() and instructions not in templates:
        yield 'instructions',instructions
    for value in vocabulary:
        if norm(value) and (include_short_vocabulary or len(norm(value).split())>=8):
            yield 'vocabulary',value


def connected_components(rows, *, ledger=None):
    """Derive components from families, normalized content and eight-grams.

    This graph is the component authority for opt-in corpora: frozen rows can
    retain their original scenario_group bytes even when a new row joins them.
    """
    parent=list(range(len(rows)))
    def find(i):
        while parent[i]!=i:
            parent[i]=parent[parent[i]];i=parent[i]
        return i
    def union(a,b):
        a=find(a);b=find(b)
        if a!=b:parent[max(a,b)]=min(a,b)
    owners={}
    for i,row in enumerate(rows):
        keys={('family',row['scenario_group'])}
        keys.update(('text',norm(value)) for _,value in content_fields(row,ledger=ledger))
        keys.update(('gram',gram) for _,value in content_fields(row,ledger=ledger) for gram in grams(value))
        for key in keys:
            if key in owners:union(i,owners[key])
            else:owners[key]=i
    result={}
    for i,row in enumerate(rows):result.setdefault(find(i),[]).append(row)
    return list(result.values())


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
    if ledger is not _NO_LEDGER:
        licenses=ledger.get('allowed_licenses',[])
        if not isinstance(licenses,(list,tuple,set)) or any(not isinstance(x,str) or not x.strip() for x in licenses):
            raise ValueError('allowed_licenses must be a container of nonempty strings')
    prompt_isolation(ledger)
    if not holdout:
        raise ValueError('external holdout must not be empty')
    policy = duplicate_policy(ledger)
    ids, groups, texts, contracts = set(), {}, {}, {}
    htext = set()
    hgrams = set()
    holdout_ids = set()
    for row in holdout:
        if not isinstance(row, dict) or not isinstance(row.get('id'), str) or not row['id'].strip() or row['id'] in holdout_ids:
            raise ValueError('holdout rows must have unique nonempty ids')
        holdout_ids.add(row['id'])
        if not any(norm(value) for _,value in content_fields(row, include_template=True, ledger=ledger)):
            raise ValueError('holdout row has no content')
        for _,value in content_fields(row, include_template=True, ledger=ledger):
            htext.add(norm(value)); hgrams.update(grams(value))
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
        context = row.get('scenario_context', '')
        # This marker is produced by the app, not arbitrary shared instructions.
        # Reject hidden or mismatched context rather than silently losing isolation.
        fields = list(content_fields(row,ledger=ledger))
        holdout_fields = list(content_fields(row,ledger=ledger,include_short_vocabulary=True))
        marker = '\n\nPrevious text (context only, do NOT repeat it): «'
        instructions = row.get('instructions', '')
        marker_text = 'Previous text (context only, do NOT repeat it):'
        if context.strip():
            suffix = marker + context + '».'
            if not norm(context) or not instructions.endswith(suffix) or instructions.count(marker_text) != 1:
                raise ValueError(f"{row['id']}: scenario_context must match the production instruction suffix")
        elif marker_text in instructions:
            raise ValueError(f"{row['id']}: scenario_context missing from production instruction suffix")
        split = row.get('split')
        if require_splits and split not in ('train', 'dev'):
            raise ValueError(f"{row['id']}: split must be train or dev")
        if require_splits:
            prior = groups.setdefault(row['scenario_group'], split)
            if prior != split:
                raise ValueError(f"{row['id']}: group crosses splits")
        if policy == 'same-component-contract':
            key=(task_contract(row), row['raw'])
            if key in contracts:
                prior_target, prior_id = contracts[key]
                if prior_target == row['target']:
                    raise ValueError(f"{row['id']}: duplicate task contract and pair with {prior_id}")
                raise ValueError(f"{row['id']}: conflicting targets for task contract and raw with {prior_id}")
            contracts[key]=(row['target'],row['id'])
        for field, content in fields:
            value = norm(content)
            if not value:
                raise ValueError(f"{row['id']}: empty normalized {field}")
            prior = texts.setdefault(value, (row['id'], split))
            if prior[0] != row['id']:
                if policy == 'strict':
                    raise ValueError(f"{row['id']}: duplicate {field} with {prior[0]}")
                if require_splits and prior[1] != split:
                    raise ValueError(f"{row['id']}: normalized content crosses splits with {prior[0]}")
        for field, content in holdout_fields:
            if norm(content) in htext or grams(content) & hgrams:
                raise ValueError(f"{row['id']}: holdout contamination in {field}")
    if policy == 'same-component-contract' and require_splits:
        for component in connected_components(rows,ledger=ledger):
            if len({r['split'] for r in component})>1:
                raise ValueError('connected component crosses splits')
    # Near-identical templates across train/dev also leak scenario content.
    if require_splits:
        devgrams = set().union(*(grams(value) for r in rows if r['split'] == 'dev' for _,value in content_fields(r,ledger=ledger)))
        for row in rows:
            if row['split'] == 'train' and any(grams(value) & devgrams for _,value in content_fields(row,ledger=ledger)):
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
