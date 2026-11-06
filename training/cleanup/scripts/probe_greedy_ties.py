#!/usr/bin/env python3
"""Public case 046 only: observe greedy normalization on the same logits tensor.

This diagnostic adds evaluation barriers and can alter lazy graph fusion or
scheduling. It never replaces the tensor returned to stream_generate. A failed
baseline reproduction limits what its numerical observations establish.
"""
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'engine/scripts'))
sys.path.insert(0,str(ROOT/'training/cleanup'))
CASE_ID='qualification-v2-046'
MAX_OUTPUT=16
CAPTURE_STEPS=3


def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()


def load_case(path):
    matches=[]
    for line in Path(path).read_text().splitlines():
        if not line.strip():continue
        row=json.loads(line)
        if row.get('id')==CASE_ID:
            if row.get('visibility')!='public':raise ValueError('probe case must explicitly be public')
            matches.append({key:row[key] for key in ('id','raw','mode','language','romanize','instructions','vocabulary')})
    if len(matches)!=1:raise ValueError('expected exactly one public qualification-v2-046')
    return matches[0]


def validate_identity(baseline,revision,files,adapter_files,versions):
    expected={'base_revision':revision,'base_files_sha256':files,'adapter_sha256':adapter_files,'versions':versions}
    if any(baseline.get(key)!=value for key,value in expected.items()):
        raise ValueError('model, adapter, tokenizer or package identity differs from the old baseline')
    if baseline.get('decoder')!='stream':raise ValueError('an old stream baseline is required')
    matches=[row for row in baseline.get('records',[]) if row.get('id')==CASE_ID]
    if len(matches)!=1 or not matches[0].get('eos') or len(matches[0].get('output_token_ids',[]))<2:
        raise ValueError('baseline needs one successful case046 with at least two output tokens')
    return matches[0]


def observe_logits(logits):
    import mlx.core as mx
    flat=logits.reshape(-1)
    if logits.ndim!=2 or logits.shape[0]!=1:raise ValueError('single-sequence logits required')
    native_norm=logits-mx.logsumexp(logits,keepdims=True)
    fp32=logits.astype(mx.float32)
    fp32_norm=fp32-mx.logsumexp(fp32,keepdims=True)
    indices=mx.stack([mx.argmax(flat),mx.argmax(native_norm.reshape(-1)),mx.argmax(fp32_norm.reshape(-1))])
    raw_values=flat[indices]
    native_values=native_norm.reshape(-1)[indices]
    fp32_values=fp32_norm.reshape(-1)[indices]
    top_two=mx.topk(flat,2)
    normalizer=mx.logsumexp(logits,keepdims=True)
    # One explicit diagnostic barrier per captured callback. Only bounded
    # arrays (3 choices/values, 2 maxima, 1 normalizer) cross to Python.
    mx.eval(indices,raw_values,native_values,fp32_values,top_two,normalizer)
    choices=indices.tolist()
    raw=raw_values.tolist();native=native_values.tolist();f32=fp32_values.tolist()
    top=sorted(top_two.tolist(),reverse=True)
    candidates={str(token):{'raw_logit':raw[i],'native_normalized':native[i],'fp32_normalized':f32[i]}
        for i,token in enumerate(choices)}
    return {'dtype':str(logits.dtype),'shape':list(logits.shape),
        'raw_argmax':choices[0],'native_normalized_argmax':choices[1],'fp32_normalized_argmax':choices[2],
        'raw_top_two_values':top,'raw_top_two_margin':top[0]-top[1],
        'native_logsumexp':normalizer.item(),'selected_candidate_values':candidates,
        'native_normalization_changed_choice':choices[0]!=choices[1],
        'fp32_normalization_matches_raw':choices[0]==choices[2]}


class Recorder:
    def __init__(self,observer=observe_logits):
        self.observer=observer
        self.calls=0
        self.records=[]
    def __call__(self,tokens,logits):
        self.calls+=1
        if self.calls<=CAPTURE_STEPS:
            self.records.append({'callback_index':self.calls-1,'history_tokens':int(tokens.size),
                **self.observer(logits)})
        return logits


def run(args):
    from benchmark_personal_student import local_snapshot, source_hash
    from benchmark_resources import configure_student_allocator, STUDENT_CACHE_LIMIT_BYTES
    from cleanup.engine_decoder import student_prompt,student_prompt_tokens
    from cleanup.provenance import adapter_hashes,load_local_snapshot
    if args.output.exists():raise FileExistsError(args.output)
    baseline=json.loads(args.baseline.read_text())
    case=load_case(args.data)
    if baseline.get('data_sha256')!=digest(args.data):raise ValueError('public fixture file differs from baseline')
    snapshot,files=local_snapshot(args.base,args.base_revision)
    if json.loads((Path(snapshot)/'config.json').read_text()).get('model_type')!='qwen3_5':
        raise ValueError('this probe is restricted to the Qwen3.5 case046 investigation')
    adapter=str(args.adapter.resolve(strict=True))
    adapters=adapter_hashes(adapter)
    versions={name:importlib.metadata.version(name) for name in ('mlx','mlx-lm','transformers')}
    previous=validate_identity(baseline,args.base_revision,files,adapters,versions)
    manifest_path=Path(adapter)/'manifest.json'
    if manifest_path.exists():
        manifest=json.loads(manifest_path.read_text())
        if manifest.get('base_revision')!=args.base_revision or manifest.get('snapshot_files_sha256')!=files:
            raise ValueError('adapter manifest differs from pinned base')
    configure_student_allocator()
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler
    model,tokenizer=load_local_snapshot(snapshot,adapter)
    context={key:case[key] for key in ('mode','language','romanize','instructions','vocabulary')}
    prompt=student_prompt(tokenizer,context,case['raw'])
    prompt_ids=student_prompt_tokens(tokenizer,context,case['raw'])
    if prompt_ids!=previous['prompt_token_ids']:raise ValueError('prompt token IDs differ from old baseline')
    observer=Recorder()
    output=[];eos=False
    iterator=stream_generate(model,tokenizer,prompt=prompt,max_tokens=MAX_OUTPUT,
        sampler=make_sampler(temp=0),logits_processors=[observer])
    try:
        for response in iterator:
            if response.finish_reason=='stop':eos=True
            else:output.append(response.token)
    finally:
        iterator.close()
    old_output=previous['output_token_ids']
    checks={'prompt_tokens_match':prompt_ids==previous['prompt_token_ids'],
        'first_two_output_tokens_match':output[:2]==old_output[:2],
        'bounded_output_tokens_match':output==old_output[:MAX_OUTPUT],
        'eos_matches_if_baseline_fits':eos if len(old_output)<MAX_OUTPUT else not eos}
    report={'case_id':CASE_ID,'max_output_tokens':MAX_OUTPUT,'capture_steps':CAPTURE_STEPS,
        'data_sha256':digest(args.data),'baseline_sha256':digest(args.baseline),
        'baseline_source_sha256':baseline.get('source_sha256'),'baseline_runner_sha256':baseline.get('runner_sha256'),
        'base_revision':args.base_revision,'base_files_sha256':files,'adapter_sha256':adapters,'versions':versions,
        'adapter_manifest_sha256':digest(manifest_path) if manifest_path.exists() else None,
        'probe_sha256':digest(__file__),'current_eval_source_sha256':source_hash(),
        'mlx_allocator_cache_limit_bytes':STUDENT_CACHE_LIMIT_BYTES,
        'baseline_mlx_allocator_cache_limit_bytes':baseline.get('mlx_allocator_cache_limit_bytes','not recorded'),
        'input_sha256':hashlib.sha256(case['raw'].encode()).hexdigest(),
        'prompt_token_ids':prompt_ids,'baseline_output_token_ids':old_output,
        'output_token_ids':output,'eos':eos,'reproduction_checks':checks,'reproduction_passed':all(checks.values()),
        'processor_callback_calls':observer.calls,'captured_callbacks':len(observer.records),
        'explicit_diagnostic_eval_boundaries':len(observer.records),'gpu_kernel_dispatches':'not measured',
        'measurements':observer.records,
        'native_normalization_changed_any_observed_choice':any(row['native_normalization_changed_choice'] for row in observer.records),
        'tensor_return_policy':'Every logits processor invocation returns the identical incoming tensor; no dtype/value replacement.',
        'limitations':['Added evaluation barriers and host reads can alter lazy graph fusion/scheduling.',
            'Same-tensor comparisons isolate normalization for the observed tensor, not causes of every decoder difference.',
            'No latency claim; no model-quality qualification; no private data; no production decoder change.']}
    with args.output.open('x') as destination:json.dump(report,destination,indent=2,allow_nan=False)
    print(json.dumps({'output':str(args.output),'reproduced':report['reproduction_passed'],
        'normalization_changed_choice':report['native_normalization_changed_any_observed_choice'],
        'callbacks':observer.calls,'captured':len(observer.records)}))
    return 0 if report['reproduction_passed'] else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('data','baseline','base','adapter','output'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--base-revision',required=True)
    return run(parser.parse_args())


if __name__=='__main__':raise SystemExit(main())
