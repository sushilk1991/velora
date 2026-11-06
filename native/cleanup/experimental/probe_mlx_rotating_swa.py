#!/usr/bin/env python3
"""Isolated MLX 0.32.2 scalar SWA cache probe; model loading occurs only in CLI."""
import argparse
import gc
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import prefill_sweep as shared
ROOT = shared.ROOT
ORDER = ('full', 'rotating', 'rotating', 'full')
BOUNDARIES = (255, 256, 257, 511, 512, 513)
PINS = {'models/cache.py': 'c96cb169fd5e0ec4584a162dd61dc62ab08ccdca03a9850f8a491ce6809145e6',
        'models/base.py': '63d8e58a4b6f8c0902719499c693647fbf486bbd5d22b09868a07d37e08c83d6',
        'generate.py': '9d46803799f99d6fc7c35fff2d4357c79b1a25ae98cc63efeaaebeb50a7b5f33'}


def cache_for(model, rotating, cache_api):
    caches = model.make_cache(); types = [layer.layer_type for layer in model.layers]
    if len(caches) != len(types) or types.count('sliding_attention') != 5 or types.count('full_attention') != 6:
        raise ValueError('unexpected LFM3 layer/cache topology')
    if model.args.sliding_window != 256: raise ValueError('unexpected sliding window')
    for i, kind in enumerate(types):
        expected = cache_api.KVCache if kind in ('full_attention', 'sliding_attention') else cache_api.ArraysCache
        if type(caches[i]) is not expected: raise ValueError('unexpected original cache class')
        if kind == 'sliding_attention' and rotating:
            caches[i] = cache_api.RotatingKVCache(max_size=256, keep=0)
    return caches


def check_cache(model, caches, prompt_count, emitted_count):
    result = []
    for layer, cache in zip(model.layers, caches):
        info = {'layer_type': layer.layer_type, 'cache_type': type(cache).__name__, 'nbytes': cache.nbytes}
        if layer.is_attention_layer:
            # Pinned generate_step prefetches the next token before yielding.
            if cache.offset != prompt_count + emitted_count: raise ValueError('absolute attention offset mismatch')
            info.update(offset=cache.offset, stored_positions=cache.keys.shape[2])
            if type(cache).__name__ == 'RotatingKVCache' and cache.keys.shape[2] > 256:
                raise ValueError('rotating scalar cache exceeds window after decode')
        result.append(info)
    return result


def render(tokenizer, system, user):
    return tokenizer.apply_chat_template([{'role':'system','content':system},{'role':'user','content':user}],
        tokenize=True, add_generation_prompt=True, enable_thinking=False)


def make_cases(tokenizer, system, user, boundaries):
    cases = []
    if boundaries:
        for target in BOUNDARIES:
            padding = 0; seen = set()
            for _ in range(6):
                if padding < 0 or padding in seen: break
                seen.add(padding)
                synthetic = json.dumps({'mode':'default','language':'en','romanize':False,
                    'instructions':'Keep the wording.', 'vocabulary':['x'+' x'*padding],
                    'transcript':'The orange ledger is ready for review.'})
                tokens = render(tokenizer, system, synthetic)
                if len(tokens) == target:
                    cases.append({'id':str(target),'prompt_tokens':tokens,'synthetic':True}); break
                padding += target-len(tokens)
            else: raise ValueError('boundary calibration exceeded six tokenizer calls')
            if not cases or cases[-1]['id'] != str(target): raise ValueError('system prompt cannot fit exact boundary')
    cases.append({'id':'file','prompt_tokens':render(tokenizer,system,user),'synthetic':False})
    if any(not 1 <= len(c['prompt_tokens']) <= 16384 for c in cases): raise ValueError('prompt must contain 1..16384 tokens')
    return cases


def summarize(records, cases, budget, errors):
    failures = list(errors)
    if not cases or len(records) != 4*len(cases): failures.append('incomplete_matrix')
    for case in cases:
        rows = [r for r in records if r['case_id'] == case['id']]
        if [r['variant'] for r in rows] != list(ORDER): failures.append('missing_or_wrong_order:'+case['id'])
        for row in rows:
            valid = (row['status'] in ('length','stop') and len(row['output_tokens']) == 1 if budget == 1
                     else row['status'] == 'stop' and bool(row['text'].strip()) and len(row['output_tokens']) <= budget)
            if not valid: failures.append('incomplete_or_empty:'+case['id'])
            if row['prompt_tokens'] != case['prompt_tokens']: failures.append('prompt_mismatch:'+case['id'])
            if rows and any(row[k] != rows[0][k] for k in ('prompt_tokens','output_tokens','status','text')):
                failures.append('exact_parity:'+case['id'])
    return {'exact_parity':not failures, 'errors':failures, 'diagnostic_only':budget==1,
            'all_outputs_eos':bool(records) and all(r['status']=='stop' for r in records),
            'completed_output_claim':budget>1 and not failures, 'semantic_quality_evaluated':False,
            'prefix_reuse':False,'copy_draft':False,
            'timing_scope':'first response includes prefill and upstream one-token prefetch; not pure prefill or token-delivery TTFT'}


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('base','adapter','system-file','payload-file','out'): p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--lfm-port',type=Path,default=ROOT/'docs/research/2026-10-27-lfm3-bakeoff/lfm3.py')
    p.add_argument('--prefill-step',type=int,default=512)
    p.add_argument('--max-tokens',type=int,choices=(1,128,1024),default=1)
    p.add_argument('--boundaries',action='store_true')
    a=p.parse_args(argv)
    if not 1 <= a.prefill_step <= 2048: p.error('prefill step must be 1..2048')
    out=shared.external(a.out); system_path=shared.external(a.system_file); user_path=shared.external(a.payload_file)
    if out.exists(): raise FileExistsError(out)
    system=system_path.read_bytes().decode('utf-8'); user=user_path.read_bytes().decode('utf-8')
    if not system.strip() or not user.strip(): raise ValueError('nonempty exact UTF-8 input files required')
    sys.path.insert(0,str(ROOT/'training/cleanup')); sys.path.insert(0,str(ROOT/'engine/scripts'))
    os.environ['HF_HUB_OFFLINE']='1'
    from benchmark_long_notes import verify_lfm_base_adapter
    from cleanup.lfm3_compat import lfm3_architecture
    from cleanup.provenance import load_local_snapshot
    identity=verify_lfm_base_adapter(a.base,a.adapter)
    a.base=Path(identity['base']['snapshot']); a.adapter=Path(identity['adapter']['path'])
    if importlib.metadata.version('mlx-lm') != '0.32.2': raise ValueError('requires inspected mlx-lm 0.32.2')
    package=Path(importlib.metadata.distribution('mlx-lm').locate_file('mlx_lm'))
    if any(shared.digest(package/f)!=sha for f,sha in PINS.items()): raise ValueError('upstream source pin mismatch')
    tracked=[Path(__file__),system_path,user_path,a.lfm_port,*(package/f for f in PINS),
             ROOT/'training/cleanup/cleanup/lfm3_compat.py',ROOT/'training/cleanup/cleanup/provenance.py',
             ROOT/'engine/scripts/benchmark_long_notes.py',Path(shared.__file__)]
    tracked += [f for f in package.rglob('*.py') if f not in tracked]
    before={str(f):shared.digest(f) for f in tracked}
    out.mkdir(mode=0o700,parents=True);os.chmod(out,0o700)
    records=[];cases=[];errors=[]
    shared.private_json(out/'manifest.json',{'identity':identity,'files_sha256':before,'order':ORDER,
        'mlx':importlib.metadata.version('mlx'),'mlx_lm':'0.32.2','prefill_step':a.prefill_step,
        'max_tokens':a.max_tokens,'allocator_cache_limit_bytes':512*1024**2,
        'deadline_policy':'root must run under its bounded GPU process supervisor; no safe in-process native-call interruption'})
    try:
        import mlx.core as mx
        from mlx_lm import stream_generate
        from mlx_lm.generate import generation_stream
        from mlx_lm.models import cache as cache_api
        if 'window_size' not in inspect.signature(cache_api.RotatingKVCache.make_mask).parameters:
            raise ValueError('rotating mask API incompatible')
        mx.set_cache_limit(512*1024**2)
        with lfm3_architecture(a.lfm_port):
            model,tokenizer=load_local_snapshot(str(a.base),str(a.adapter))
            cases=make_cases(tokenizer,system,user,a.boundaries);shared.private_json(out/'cases.json',cases)
            for variant in ORDER:
                for case in cases:
                    gc.collect();mx.clear_cache();mx.reset_peak_memory()
                    caches=cache_for(model,variant=='rotating',cache_api)
                    ids=[];text='';first=None;started=time.perf_counter();last=None
                    generator=stream_generate(model,tokenizer,case['prompt_tokens'],max_tokens=a.max_tokens,
                        prompt_cache=caches,prefill_step_size=a.prefill_step)
                    try:
                        for last in generator:
                            if first is None: first=(time.perf_counter()-started)*1000
                            ids.append(int(last.token));text+=last.text
                    finally: generator.close()
                    mx.synchronize(generation_stream);elapsed=(time.perf_counter()-started)*1000
                    if last is None: raise ValueError('generation produced no response')
                    layers=check_cache(model,caches,len(case['prompt_tokens']),len(ids))
                    records.append({'variant':variant,'case_id':case['id'],'prompt_tokens':case['prompt_tokens'],
                        'output_tokens':ids,'output_ids_include_terminal_eos':True,'status':last.finish_reason,'text':text,
                        'first_response_ms':first,'total_ms':elapsed,'mlx_active_bytes':mx.get_active_memory(),
                        'mlx_peak_bytes':mx.get_peak_memory(),'mlx_cache_bytes':mx.get_cache_memory(),'layers':layers})
                    shared.private_json(out/'records.json',records)
                    del caches,generator,last
            del model,tokenizer
    except Exception as exc: errors.append(type(exc).__name__+': '+str(exc))
    finally:
        try:
            if {str(f):shared.digest(f) for f in tracked}!=before: errors.append('source_or_input_changed')
            if verify_lfm_base_adapter(a.base,a.adapter)!=identity: errors.append('model_or_adapter_changed')
        except Exception as exc: errors.append('postflight:'+type(exc).__name__)
        report=summarize(records,cases,a.max_tokens,errors);shared.private_json(out/'summary.json',report)
    print(json.dumps({'out':str(out),'exact_parity':report['exact_parity'],'diagnostic_only':a.max_tokens==1}))
    return 0 if report['exact_parity'] else 1


if __name__=='__main__': raise SystemExit(main())
