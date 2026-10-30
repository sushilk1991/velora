#!/usr/bin/env python3
"""Measure MLX copy bandwidth and shipped projection throughput under one lock."""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import statistics
import struct
import subprocess
import time

_LOCK = Path('/tmp/velora-bench.lock')
_QUANT_GROUP_SIZE = 64
_WARMUP_RUNS = 3
_MEASURE_RUNS = 20
_PROBE_TOKENS = (1, 150, 256)
_COPY_SHAPE = (8192, 32768)


def _header(path):
    # Header offsets describe stored bytes, including quant scales and biases.
    with path.open('rb') as stream:
        return json.loads(stream.read(struct.unpack('<Q', stream.read(8))[0]))


def _manifest(root):
    # Tied embedding is read by the output projection; count its full matrix once.
    header = _header(root / 'model.safetensors')
    tensors = {k:v for k,v in header.items() if k != '__metadata__'}
    config = json.loads((root / 'config.json').read_text())
    bits = config['quantization']['bits']
    stored = sum(v['data_offsets'][1]-v['data_offsets'][0] for v in tensors.values())
    # Shipped files include vision and MTP tensors which text decode never reads.
    text = {k:v for k,v in tensors.items()
            if k.startswith('language_model.model.') and '.mtp.' not in k}
    text_bytes = sum(v['data_offsets'][1]-v['data_offsets'][0] for v in text.values())
    elements = sum(math.prod(v['shape'])*32//bits for k,v in text.items()
                   if k.endswith('.weight') and len(v['shape'])==2 and k[:-7]+'.scales' in text)
    # Lazy cache-only prefill does not evaluate the tied output projection for
    # every input token. Keep its elements separate for phase FLOP accounting.
    output_elements = math.prod(text['language_model.model.embed_tokens.weight']['shape'])*32//bits
    return {'path':str(root),'stored_bytes':stored,'text_weight_bytes_per_pass':text_bytes,
            'projection_elements':elements,'prefill_body_elements':elements-output_elements,
            'output_projection_elements':output_elements,'bits':bits,'revision':root.name}


def _timed(operation, repeats, byte_count=0, flops=0):
    # Evaluate every result: lazy graph construction alone measures CPU dispatch.
    import mlx.core as mx
    for _ in range(_WARMUP_RUNS):
        mx.eval(operation())
    samples=[]
    for _ in range(repeats):
        load1=os.getloadavg()[0]
        started=time.perf_counter_ns()
        output=operation()
        mx.eval(output)
        ns=time.perf_counter_ns()-started
        samples.append({'ns':ns,'load1':load1,'load1_end':os.getloadavg()[0],
                        'gb_s':byte_count/ns if byte_count else None,
                        'tflops':flops/ns/1000 if flops else None})
    return samples


def _main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-path',type=Path,action='append',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    with _LOCK.open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if subprocess.run(['pgrep','-x','Velora'],capture_output=True).returncode==0:
            raise SystemExit('Quit Velora before measuring')
        import mlx.core as mx
        # A padded row view is noncontiguous by one element. contiguous emits a
        # real copy (1 GiB read + 1 GiB write), well beyond the system cache.
        source=mx.ones((_COPY_SHAPE[0],_COPY_SHAPE[1]+1),dtype=mx.float32)
        mx.eval(source)
        view=source[:,1:]
        copied=view.size*view.itemsize
        copy=_timed(lambda:mx.contiguous(view),_MEASURE_RUNS,byte_count=2*copied)
        del source,view
        mx.clear_cache()
        report={'mlx_version':mx.__version__ if hasattr(mx,'__version__') else None,
                'copy_bytes_read_write':2*copied,'copy':copy,'models':[]}
        for root in args.model_path:
            manifest=_manifest(root)
            weights=mx.load(str(root/'model.safetensors'))
            prefix='language_model.model.layers.0.mlp.gate_proj'
            w,scales,biases=(weights[prefix+'.'+name] for name in ('weight','scales','biases'))
            hidden=json.loads((root/'config.json').read_text())['text_config']['hidden_size']
            mx.eval(w,scales,biases)
            manifest['matmul']=[]
            for tokens in _PROBE_TOKENS:
                inputs=mx.ones((tokens,hidden),dtype=mx.bfloat16)
                mx.eval(inputs)
                samples=_timed(lambda:mx.quantized_matmul(inputs,w,scales,biases,
                    transpose=True,group_size=_QUANT_GROUP_SIZE,bits=manifest['bits']),_MEASURE_RUNS,
                    flops=2*tokens*hidden*w.shape[0])
                manifest['matmul'].append({'tokens':tokens,'samples':samples})
            report['models'].append(manifest)
            del weights,w,scales,biases,inputs
            mx.clear_cache()
        args.output.write_text(json.dumps(report,indent=2))
        print(json.dumps({'copy_gb_s_p50':statistics.median(s['gb_s'] for s in copy),
                          'models':[{k:v for k,v in m.items() if k!='matmul'} for m in report['models']]}))


if __name__=='__main__':
    _main()
