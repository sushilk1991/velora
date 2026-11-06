#!/usr/bin/env python3
"""Inspect or explicitly export an audited MLX LFM3 LoRA to HF-layout tensors.

Default inspection reads metadata/headers and hashes, importing no MLX. --execute
is a separately scheduled model operation. GGUF conversion is a separate command.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import shutil
import struct
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'training/cleanup'))
BASE_REVISION='4d6d94c9c2c2f249f1f740f4f08e071b0dbfe099'
LLAMA_REVISION='4b77dee0524c64b8471869232e2958bd9589607d'
PORT=ROOT/'docs/research/2026-10-27-lfm3-bakeoff/lfm3.py'


def digest(path):
    with Path(path).open('rb') as handle:return hashlib.file_digest(handle,'sha256').hexdigest()


def tensor_headers(path):
    """Read only the bounded safetensors JSON header, never tensor payloads."""
    with Path(path).open('rb') as handle:
        size=handle.read(8)
        if len(size)!=8:raise ValueError('truncated safetensors length')
        length=struct.unpack('<Q',size)[0]
        if not 2<=length<=16*1024*1024:raise ValueError('safetensors header size outside bound')
        header=json.loads(handle.read(length))
    return {key:value for key,value in header.items() if key!='__metadata__'}


def hf_config(config):
    if (config.get('model_type')!='lfm3' or config.get('architectures')!=['Lfm3ForCausalLM']
            or config.get('tie_word_embeddings') is not True or config.get('conv_bias') is not False
            or config.get('conv_L_cache')!=7 or config.get('use_sandwich_norm') is not True):
        raise ValueError('unsupported LFM3 architecture configuration')
    result=dict(config)
    for key in ('quantization','quantization_config','auto_map'):result.pop(key,None)
    result['dtype']='bfloat16'
    result['torch_dtype']='bfloat16'
    return result


def validate_tokenizer_assets(path):
    """Require tokenizer inputs and a usable chat renderer before model work."""
    path=Path(path)
    for name in ('tokenizer.json','tokenizer_config.json'):
        if not (path/name).is_file():raise ValueError('missing required tokenizer asset: '+name)
    tokenizer_config=json.loads((path/'tokenizer_config.json').read_text())
    template=path/'chat_template.jinja'
    if not ((template.is_file() and template.read_text().strip()) or tokenizer_config.get('chat_template')):
        raise ValueError('missing chat template')


def hf_tensor(name,value):
    """Invert this repository's audited MLX sanitize layout, not tensor math."""
    if not name.startswith('model.') or any(part in ('lora_a','lora_b','scales','biases','linear') for part in name.split('.')):
        raise ValueError('unfused, quantized or unexpected tensor: '+name)
    if name.endswith('.conv.conv.weight'):
        if len(value.shape)!=3 or tuple(value.shape[1:])!=(7,1):
            raise ValueError('expected MLX depthwise convolution [out,7,1]')
        value=value.transpose(0,2,1)
    return name,value


def expected_shapes(config):
    h=config['hidden_size'];f=config['intermediate_size'];d=config['head_dim']
    q=config['num_attention_heads'];k=config['num_key_value_heads']
    result={'model.embed_tokens.weight':(config['vocab_size'],h),'model.embedding_norm.weight':(h,)}
    if len(config['layer_types'])!=config['num_hidden_layers']:raise ValueError('layer count mismatch')
    for index,kind in enumerate(config['layer_types']):
        prefix=f'model.layers.{index}.'
        shapes={name+'.weight':(h,) for name in ('operator_norm','ffn_norm','post_operator_norm','post_ffn_norm')}
        shapes.update({'feed_forward.w1.weight':(f,h),'feed_forward.w3.weight':(f,h),'feed_forward.w2.weight':(h,f)})
        if kind=='conv':
            shapes.update({'conv.conv.weight':(h,1,7),'conv.in_proj.weight':(3*h,h),'conv.out_proj.weight':(h,h)})
        elif kind in ('full_attention','sliding_attention'):
            shapes.update({'self_attn.q_proj.weight':(q*d,h),'self_attn.k_proj.weight':(k*d,h),
                'self_attn.v_proj.weight':(k*d,h),'self_attn.o_proj.weight':(h,q*d),
                'self_attn.q_norm.weight':(d,),'self_attn.k_norm.weight':(d,),'self_attn.gate_proj.weight':(q,h)})
        else:raise ValueError('unknown LFM3 layer type')
        result.update({prefix+name:shape for name,shape in shapes.items()})
    return result


def validate_shapes(weights,config):
    expected=expected_shapes(config)
    if set(weights)!=set(expected):
        raise ValueError('export tensor keys mismatch: missing='+str(sorted(set(expected)-set(weights)))+' extra='+str(sorted(set(weights)-set(expected))))
    if any(tuple(weights[name].shape)!=shape for name,shape in expected.items()):
        raise ValueError('export tensor shape mismatch')


def inspect(args):
    from cleanup.provenance import resolve_model
    from cleanup.lfm3_compat import SOURCE_SHA256
    if digest(PORT)!=SOURCE_SHA256:raise ValueError('architecture port source changed')
    base=args.base.expanduser().absolute()
    if not base.is_dir():raise ValueError('existing local base required; downloads disabled')
    if args.base_revision!=BASE_REVISION:raise ValueError('only the audited MLX 8-bit base revision is supported')
    snapshot,files=resolve_model(str(base),args.base_revision)
    config=hf_config(json.loads((base/'config.json').read_text()))
    validate_tokenizer_assets(base)
    adapter=args.adapter.expanduser().resolve(strict=True)
    if digest(adapter/'adapters.safetensors')!=args.adapter_sha256:raise ValueError('adapter SHA256 mismatch')
    adapter_config=json.loads((adapter/'adapter_config.json').read_text())
    if adapter_config.get('fine_tune_type')!='lora' or adapter_config.get('num_layers')!=config['num_hidden_layers']:
        raise ValueError('expected full-depth LoRA adapter')
    headers=tensor_headers(adapter/'adapters.safetensors')
    if not headers or any(not key.endswith(('.lora_a','.lora_b')) for key in headers):
        raise ValueError('adapter must contain only LoRA arrays')
    if not all((key[:-7]+('.lora_b' if key.endswith('.lora_a') else '.lora_a')) in headers for key in headers):
        raise ValueError('adapter contains an unpaired LoRA array')
    identity={'schema':1,'base_revision':args.base_revision,'base_path':snapshot,'base_files_sha256':files,
        'adapter_files_sha256':{name:digest(adapter/name) for name in ('adapter_config.json','adapters.safetensors')},
        'adapter_path':str(adapter),'adapter_arrays':len(headers),'expected_export_tensors':len(expected_shapes(config)),
        'adapter_provenance_sha256':{p.name:digest(p) for p in sorted(adapter.glob('*.json'))},
        'port_sha256':digest(PORT),'exporter_sha256':digest(Path(__file__)),'llama_converter_commit':LLAMA_REVISION,
        'output_layout':'HF model.* names; conv [out,1,7]; tied embedding, no separate lm_head',
        'numerical_limit':'LoRA fusion rounds weights; dequantized MLX8bit base is not original HF BF16. Further GGUF quantization changes weights.',
        'runtime_qualified':False,'semantic_quality_qualified':False}
    return base,adapter,config,identity


def execute(args,base,adapter,config,identity):
    destination=args.output.expanduser().absolute()
    staging=destination.with_name(destination.name+'.partial')
    if destination.exists() or staging.exists():raise ValueError('output/partial directory exists; use a new destination')
    # No heavyweight import or model work occurs without explicit --execute.
    import mlx.core as mx
    from mlx.utils import tree_flatten,tree_unflatten
    from mlx_lm.utils import dequantize_model
    from cleanup.provenance import load_local_snapshot
    from cleanup.lfm3_compat import lfm3_architecture
    mx.set_cache_limit(512*1024*1024)
    staging.mkdir(parents=True)
    with lfm3_architecture(PORT):
        model,_=load_local_snapshot(str(base),str(adapter))
        modules=[(name,module.fuse(dequantize=True)) for name,module in model.named_modules() if hasattr(module,'fuse')]
        if len(modules)*2!=identity['adapter_arrays']:raise ValueError('loaded LoRA module count differs from adapter')
        model.update_modules(tree_unflatten(modules))
        model=dequantize_model(model)
        weights=dict(hf_tensor(name,value) for name,value in tree_flatten(model.parameters()))
        validate_shapes(weights,config)
        shards=[];current={};size=0
        for name,value in sorted(weights.items()):
            value=value.astype(mx.bfloat16)
            if current and size+value.nbytes>1024**3:shards.append(current);current={};size=0
            current[name]=value;size+=value.nbytes
        if current:shards.append(current)
        index={'metadata':{'total_size':sum(v.size*2 for v in weights.values())},'weight_map':{}}
        for number,shard in enumerate(shards,1):
            filename=f'model-{number:05d}-of-{len(shards):05d}.safetensors'
            # Fail closed on nonfinite merged tensors. This is scheduled model work.
            if not all(bool(mx.all(mx.isfinite(value)).item()) for value in shard.values()):raise ValueError('nonfinite fused weights')
            mx.save_safetensors(str(staging/filename),shard,metadata={'format':'pt'})
            index['weight_map'].update({name:filename for name in shard})
        (staging/'model.safetensors.index.json').write_text(json.dumps(index,indent=2)+'\n')
        (staging/'config.json').write_text(json.dumps(config,indent=2)+'\n')
        # Byte-identical tokenizer/template and license assets; no remote model code.
        for name in ('tokenizer.json','tokenizer_config.json','special_tokens_map.json','chat_template.jinja',
                     'tokenizer.model','generation_config.json','LICENSE','LICENSE.txt','NOTICE','NOTICE.txt'):
            if (base/name).is_file():shutil.copyfile(base/name,staging/name)
        validate_tokenizer_assets(staging)
        if any(digest(adapter/name)!=sha for name,sha in identity['adapter_files_sha256'].items()):
            raise ValueError('adapter changed while exporting')
        identity.update(status='exported',mlx=importlib.metadata.version('mlx'),mlx_lm=importlib.metadata.version('mlx-lm'),
            peak_mlx_bytes=mx.get_peak_memory(),output_files_sha256={p.name:digest(p) for p in sorted(staging.iterdir()) if p.is_file()})
        (staging/'export-provenance.json').write_text(json.dumps(identity,indent=2)+'\n')
        staging.rename(destination)
    return identity


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base',type=Path,required=True)
    parser.add_argument('--base-revision',default=BASE_REVISION)
    parser.add_argument('--adapter',type=Path,required=True)
    parser.add_argument('--adapter-sha256',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--execute',action='store_true')
    args=parser.parse_args()
    base,adapter,config,identity=inspect(args)
    if args.execute:identity=execute(args,base,adapter,config,identity)
    else:identity['status']='inspection_only_no_model_loaded'
    print(json.dumps(identity,indent=2))


if __name__=='__main__':main()
