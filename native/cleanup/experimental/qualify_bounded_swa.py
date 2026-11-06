#!/usr/bin/env python3
"""Two-arm synthetic SWA boundary/state probe. CLI execution alone loads models."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prefill_sweep as shared

ROOT = shared.ROOT
BOUNDARIES = (255, 256, 257, 511, 512, 513)
RAW = 'The orange ledger is ready for review and the blue folder stays on the desk.'
BAD_DRAFT = RAW.replace('ready for review', 'missing without permission')
PHASES = ('scalar', 'repeat', 'copy', 'wrong_copy', 'repeat_after_wrong_copy')
RECOVERY = ('changed_system', 'restored_system', 'context_error', 'after_context_error', 'cancel', 'after_cancel')

def recovery_targets(targets):
    return list(dict.fromkeys((513, targets[-1])))


def sources():
    return dict(shared.source_hashes(), **{str(Path(__file__).resolve().relative_to(ROOT)): shared.digest(__file__)})


def payload(padding):
    # Match the public student's JSON contract. Padding is vocabulary context,
    # not extra transcript text to be copied. No external/private input is read.
    sys.path.insert(0, str(ROOT / 'training/cleanup'))
    from cleanup import render_messages
    messages = render_messages({'raw': RAW, 'mode': 'default', 'language': 'en',
        'instructions': 'Keep the wording and output only the corrected transcript.',
        'vocabulary': ['x' + ' x' * padding]})
    return messages[0]['content'], messages[1]['content']


def complete(response, budget):
    prompt, output = response.get('prompt_tokens'), response.get('output_tokens')
    return (response.get('event') == 'result' and response.get('status') == 'eos'
        and isinstance(prompt, list) and bool(prompt) and isinstance(output, list) and bool(output)
        and len(output) < budget and all(type(t) is int for t in prompt + output)
        and isinstance(response.get('text'), str) and bool(response['text'].strip()))


def equal(left, right):
    return all(left.get(k) == right.get(k) for k in ('prompt_tokens', 'output_tokens', 'status', 'text', 'partial_text'))


def calibrate(target, request):
    """Use actual worker tokenization; never assume repetitions equal tokens."""
    count = max(0, target - 130)
    seen = set()
    for attempt in range(6):
        if count in seen or count < 0:
            break
        seen.add(count)
        system, user = payload(count)
        if len(user.encode()) > 65536:
            raise ValueError('calibration payload exceeds worker byte limit')
        response = request(f'calibrate-{target}-{attempt}', system, user, budget=1)
        tokens = response.get('prompt_tokens')
        if (response.get('event') != 'result' or response.get('status') not in ('length', 'eos')
            or not isinstance(tokens, list) or not tokens or any(type(t) is not int for t in tokens)):
            raise RuntimeError('calibration failed')
        if len(tokens) == target:
            return {'target_tokens': target, 'padding_repetitions': count, 'system': system, 'user': user,
                    'prompt_tokens': tokens, 'input_sha256': hashlib.sha256(user.encode()).hexdigest()}
        count += target - len(tokens)
    raise RuntimeError(f'exact rendered prompt boundary not reached: {target}')


def exercise(cases, request, budget, context):
    # The changed system invalidates the calibration snapshot. First scalar
    # must recapture the original prefix; following requests test restoration.
    system, user = cases[0]['system'], cases[0]['user']
    request('reset_prefix', system + '\nPreserve punctuation.', user)
    for case in cases:
        for phase in PHASES:
            draft = RAW if phase == 'copy' else BAD_DRAFT if phase == 'wrong_copy' else ''
            request(f"{case['target_tokens']}:{phase}", case['system'], case['user'], draft=draft)
    # Exercise each trigger directly before recovery of both a 513-token
    # boundary and the long target. No claim is made about other boundaries.
    by_target = {case['target_tokens']: case for case in cases}
    for n in recovery_targets([case['target_tokens'] for case in cases]):
        case=by_target[n]; system,user=case['system'],case['user']
        request(f'{n}:changed_system', system + '\nPreserve punctuation.', user)
        request(f'{n}:restored_system', system, user)
        request(f'{n}:context_error', system, ' x' * (context + 1))
        request(f'{n}:after_context_error', system, user)
        cancel=threading.Event();cancel.set()
        request(f'{n}:cancel', system, user, cancel=cancel)
        request(f'{n}:after_cancel', system, user)



def summarize(arms, cases, budget, targets, integrity=()):
    errors = list(integrity)
    recovery = recovery_targets(targets)
    expected = {'reset_prefix', *(f'{n}:{p}' for n in recovery for p in RECOVERY),
                *(f'{n}:{p}' for n in targets for p in PHASES)}
    if [a.get('name') for a in arms] != ['full', 'bounded']:
        errors.append('missing_worker_arm')
    if [c['target_tokens'] for c in cases] != list(targets):
        errors.append('missing_exact_boundary')
    by_arm = {}
    for arm in arms:
        rows = [r for r in arm.get('requests', []) if not r['name'].startswith('calibrate-')]
        records = {r['name']: r['response'] for r in rows}
        by_arm[arm['name']] = records
        if len(records) != len(rows) or set(records) != expected:
            errors.append(arm['name'] + ':incomplete_or_duplicate_requests')
        if arm.get('error') or arm.get('exit_code') != 0:
            errors.append(arm['name'] + ':worker_failure')
        for name, result in records.items():
            if name.endswith(':context_error'):
                valid = result.get('event') == 'result' and result.get('status') == 'context_limit'
            elif name.endswith(':cancel'):
                valid = result.get('event') == 'result' and result.get('status') == 'cancelled'
            else:
                valid = complete(result, budget)
            if not valid:
                errors.append(arm['name'] + ':invalid:' + name)
        for case in cases:
            n = case['target_tokens']; anchor = records.get(f'{n}:scalar', {})
            if anchor.get('prompt_tokens') != case['prompt_tokens'] or len(case['prompt_tokens']) != n:
                errors.append(arm['name'] + ':prompt_boundary:' + str(n))
            for phase in PHASES[1:]:
                if not equal(anchor, records.get(f'{n}:{phase}', {})):
                    errors.append(arm['name'] + ':state_parity:' + str(n) + ':' + phase)
        for n in recovery:
            anchor=records.get(f'{n}:scalar', {})
            for phase in ('restored_system', 'after_context_error', 'after_cancel'):
                if not equal(anchor, records.get(f'{n}:{phase}', {})):
                    errors.append(arm['name'] + ':recovery_parity:' + str(n) + ':' + phase)
        def metric(name, section, field):
            value=records.get(name, {}).get(section)
            return value.get(field) if isinstance(value,dict) else None
        if metric(f'{targets[0]}:scalar','prefix_cache','hit') is not False:
            errors.append(arm['name'] + ':cold_prefix_not_exercised')
        for n in targets:
            if metric(f'{n}:repeat','prefix_cache','hit') is not True:
                errors.append(arm['name'] + ':prefix_restore_not_exercised:' + str(n))
            proposed=metric(f'{n}:copy','copy_draft','proposed')
            if type(proposed) is not int or proposed <= 0:
                errors.append(arm['name'] + ':copy_not_exercised:' + str(n))
            rollbacks=metric(f'{n}:wrong_copy','copy_draft','rollbacks')
            if type(rollbacks) is not int or rollbacks <= 0:
                errors.append(arm['name'] + ':wrong_copy_rollback_not_exercised:' + str(n))
    if set(by_arm) == {'full', 'bounded'}:
        shared_keys = set(shared.READY_SHARED) - {'bounded_swa', 'swa_full'}
        if any(arms[0].get('ready', {}).get(k) != arms[1].get('ready', {}).get(k) for k in shared_keys):
            errors.append('cross_arm_ready_identity')
        # Cancellation may stop at different points; compare cancelled status,
        # exact prompt, and exact subsequent recovery, not partial generation.
        for name in expected:
            if name.endswith(':cancel'):continue
            if not equal(by_arm['full'].get(name, {}), by_arm['bounded'].get(name, {})):
                errors.append('cross_arm_parity:' + name)
        for n in recovery:
            name=f'{n}:cancel'
            if by_arm['full'].get(name, {}).get('prompt_tokens') != by_arm['bounded'].get(name, {}).get('prompt_tokens'):
                errors.append('cross_arm_cancel_prompt:' + str(n))
    return {'qualified': not errors, 'errors': errors, 'targets_total_rendered_prompt_tokens': list(targets),
            'semantic_quality_evaluated': False, 'performance_claim': False,
            'scope': 'Synthetic exact-token SWA boundary and observable prefix/copy/recovery qualification; internal state bytes are not compared.',
            'recovery_targets_total_prompt_tokens': recovery,
            'recovery_scope': 'Only listed targets are tested after system change, context error, and cancellation.',
            'calibration_is_one_token_diagnostic_only': True,
            'cancel_partial_tokens_comparable': False}


def run(args, client_factory=None):
    out = shared.external(args.out)
    if out.exists(): raise FileExistsError(out)
    if args.context not in (8192, 16384) or not 4096 < args.long_tokens <= 16000:
        raise ValueError('context must be 8192/16384 and long prompt 4097..16000')
    if not 16 <= args.max_tokens <= 512 or args.long_tokens + args.max_tokens > args.context:
        raise ValueError('output budget must fit context')
    if not 1 <= args.deadline_ms <= 120000: raise ValueError('invalid deadline')
    args.binary = args.binary.expanduser().resolve(strict=True); args.model = args.model.expanduser().resolve(strict=True)
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK) or shared.digest(args.model) != args.sha256:
        raise ValueError('binary/model identity check failed')
    args.max_output_tokens = 512; args.draft_max = 8
    args.research_long_context = args.copy_draft = args.prefix_cache = args.trace_runtime = True
    identities = {str(p): shared.digest(p) for p in (args.binary, args.model)}
    source_before = sources(); pin = json.loads((shared.NATIVE / 'UPSTREAM.json').read_text())
    targets = (*BOUNDARIES, args.long_tokens)
    out.mkdir(parents=True, mode=0o700); os.chmod(out, 0o700)
    shared.private_json(out/'manifest.json', {'schema': 1, 'artifacts_sha256': identities,
        'source_sha256': source_before, 'upstream': pin,
        'parameters': {k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()},
        'synthetic_public_only': True, 'arm_order': ['full', 'bounded'], 'timing_comparison': False})
    if client_factory is None:
        sys.path.insert(0, str(ROOT/'engine/scripts'))
        from benchmark_long_notes import NotesNativeClient
        client_factory = NotesNativeClient
    arms, cases, integrity = [], [], []
    try:
        for bounded in (False, True):
            args.bounded_swa = bounded
            arm = {'name': 'bounded' if bounded else 'full', 'requests': []}; arms.append(arm)
            client = None
            try:
                client = client_factory(shared.client_options(args, args.prefill_batch), args.model, out/(arm['name']+'.stderr'))
                arm['ready'] = client.transport.ready
                shared.validate_ready(arm['ready'], args, args.prefill_batch, pin['commit'])
                if arm['ready'].get('architecture') != 'lfm3': raise ValueError('LFM3 worker required')
                def request(name, system, user, *, budget=None, draft='', cancel=None):
                    start = time.perf_counter()
                    response = client.transport.generate(system, user, max_tokens=budget or args.max_tokens,
                        deadline_ms=args.deadline_ms, draft_text=draft, cancel=cancel)
                    arm['requests'].append({'name': name, 'system': system, 'user': user, 'draft_text': draft,
                        'max_tokens': budget or args.max_tokens, 'wall_ms': (time.perf_counter()-start)*1000, 'response': response})
                    shared.private_json(out/(arm['name']+'.json'), arm)
                    if (client.transport.unhealthy or response.get('event') != 'result'
                        or response.get('status') not in ('eos', 'length', 'context_limit', 'cancelled')):
                        raise RuntimeError('retired_after_transport_or_protocol_failure')
                    return response
                if not bounded:
                    cases = [calibrate(n, request) for n in targets]
                    shared.private_json(out/'cases.json', cases)
                exercise(cases, request, args.max_tokens, args.context)
            except (Exception, KeyboardInterrupt) as exc:
                arm['error'] = type(exc).__name__ + ': ' + str(exc)
            finally:
                if client is not None:
                    try:
                        client.close(); arm['exit_code'] = client.transport.child.returncode
                    except (Exception, KeyboardInterrupt) as exc:
                        arm['error'] = 'close:' + type(exc).__name__
                shared.private_json(out/(arm['name']+'.json'), arm)
            if arm.get('error') or arm.get('exit_code') != 0: break
    finally:
        for path, sha in identities.items():
            try:
                if shared.digest(path) != sha: integrity.append('artifact_changed:' + path)
            except OSError: integrity.append('artifact_unreadable:' + path)
        try:
            if sources() != source_before: integrity.append('source_changed')
        except OSError:
            integrity.append('source_unreadable_after_probe')
        summary = summarize(arms, cases, args.max_tokens, targets, integrity)
        shared.private_json(out/'summary.json', summary)
    print(json.dumps({'qualified': summary['qualified'], 'failures': len(summary['errors']), 'out': str(out)}))
    return 0 if summary['qualified'] else 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'model', 'out'): p.add_argument('--'+name, type=Path, required=True)
    p.add_argument('--sha256', required=True)
    p.add_argument('--context', type=int, choices=(8192,16384), default=8192)
    p.add_argument('--long-tokens', type=int, default=4097)
    p.add_argument('--max-tokens', type=int, default=128)
    p.add_argument('--deadline-ms', type=int, default=120000)
    p.add_argument('--max-rss-mb', type=int, default=8192)
    p.add_argument('--prefill-batch', type=int, choices=(16,32,64,128,256,512), default=128)
    p.add_argument('--recurrent-rollback', action='store_true')
    args = p.parse_args()
    def stop(signum, frame): raise InterruptedError('signal ' + str(signum))
    for sig in (signal.SIGTERM, signal.SIGHUP): signal.signal(sig, stop)
    return run(args)


if __name__ == '__main__': raise SystemExit(main())
