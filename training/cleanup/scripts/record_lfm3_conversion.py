#!/usr/bin/env python3
"""Record verified local LFM3 export and GGUF conversion metadata without model inference.

These records bind operator-provided conversion provenance to hashed artifacts;
they are not a cryptographic attestation that the conversion was performed.
"""
from __future__ import annotations
import argparse
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'training/cleanup/scripts'))
from qualify_lfm3_artifacts import validate_fused, digest

PIN=ROOT/'native/cleanup/UPSTREAM.json'
VERIFY=ROOT/'native/cleanup/verify_source.py'


def inspect_gguf(path, gguf, quantization):
    """Read scalar metadata only; GGUFReader opens a read-only mapping."""
    reader=gguf.GGUFReader(path,mode='r')
    arch=reader.get_field('general.architecture')
    file_type=reader.get_field('general.file_type')
    if arch is None or file_type is None:
        raise ValueError('GGUF missing architecture or file type metadata')
    arch=arch.contents();file_type=file_type.contents()
    expected={'BF16':gguf.LlamaFileType.MOSTLY_BF16,
              'Q8_0':gguf.LlamaFileType.MOSTLY_Q8_0,
              'Q4_K_M':gguf.LlamaFileType.MOSTLY_Q4_K_M}[quantization]
    if arch!='lfm3' or type(file_type) is not int or file_type!=int(expected):
        raise ValueError('GGUF architecture or file type does not match request')
    return {'architecture':arch,'file_type':file_type}


def load_verified_gguf(source):
    """Only import the package under the source tree already verified by caller."""
    if any(name=='gguf' or name.startswith('gguf.') for name in sys.modules):
        raise RuntimeError('gguf is already imported')
    package=(source/'gguf-py').resolve(strict=True)
    if not package.is_relative_to(source):
        raise ValueError('GGUF reader must be inside the verified source tree')
    sys.path.insert(0,str(package))
    sys.dont_write_bytecode=True
    module=importlib.import_module('gguf')
    if not Path(module.__file__).resolve().is_relative_to(package):
        raise RuntimeError('GGUF reader was not loaded from verified source')
    return module


def write_pair(prefix, conversion, artifact):
    """Publish complete files atomically without replacing existing paths."""
    prefix=Path(prefix).expanduser().absolute()
    conversion_path=Path(str(prefix)+'.conversion.json')
    artifact_path=Path(str(prefix)+'.artifact.json')
    if conversion_path.exists() or conversion_path.is_symlink() or artifact_path.exists() or artifact_path.is_symlink():
        raise FileExistsError('output already exists')
    if not prefix.parent.is_dir():raise ValueError('output directory does not exist')
    temp_paths=[];created=[]
    try:
        fd,name=tempfile.mkstemp(prefix='.lfm3-record-',dir=prefix.parent)
        temp_paths.append(Path(name))
        with os.fdopen(fd,'w') as out:
            json.dump(conversion,out,ensure_ascii=False,indent=2);out.write('\n');out.flush();os.fsync(out.fileno())
        artifact={**artifact,'conversion_manifest_path':str(conversion_path.resolve()),
                  'conversion_manifest_sha256':digest(temp_paths[0])}
        fd,name=tempfile.mkstemp(prefix='.lfm3-record-',dir=prefix.parent)
        temp_paths.append(Path(name))
        with os.fdopen(fd,'w') as out:
            json.dump(artifact,out,ensure_ascii=False,indent=2);out.write('\n');out.flush();os.fsync(out.fileno())
        for temp,dest in zip(temp_paths,(conversion_path,artifact_path)):
            os.link(temp,dest);created.append(dest)
    except BaseException:
        for path in created:path.unlink(missing_ok=True)
        raise
    finally:
        for path in temp_paths:path.unlink(missing_ok=True)
    return conversion_path,artifact_path


def record(args):
    model=args.gguf.expanduser().resolve(strict=True)
    source=args.llama_source.expanduser().resolve(strict=True)
    export_path=args.export_provenance.expanduser().resolve(strict=True)
    if not model.is_file() or not source.is_dir():raise ValueError('GGUF and local source required')
    if args.quantization!='BF16' and args.quantizer is None:
        raise ValueError('quantizer binary required for quantized artifacts')
    quantizer=args.quantizer.expanduser().resolve(strict=True) if args.quantizer else None
    if quantizer is not None and (not quantizer.is_file() or not os.access(quantizer,os.X_OK)):
        raise ValueError('quantizer must be an executable regular file')
    pins=json.loads(PIN.read_text())
    subprocess.run([sys.executable,str(VERIFY),str(source),str(PIN)],check=True,capture_output=True,text=True)
    _,fused=validate_fused(export_path.parent,export_path)
    export=json.loads(export_path.read_text())
    if export.get('llama_converter_commit')!=pins['commit']:
        raise ValueError('export converter commit differs from pinned source')
    adapter=export.get('adapter_files_sha256',{}).get('adapters.safetensors')
    if not isinstance(adapter,str) or len(adapter)!=64 or any(c not in '0123456789abcdef' for c in adapter):
        raise ValueError('export missing adapter hash')
    before=digest(model)
    metadata=inspect_gguf(model,load_verified_gguf(source),args.quantization)
    if digest(model)!=before:raise ValueError('GGUF changed during metadata inspection')
    conversion={'schema':1,'kind':'lfm3-gguf-conversion',
        'source_export_provenance_sha256':digest(export_path),'source_export_files_sha256':fused['files_sha256'],
        'model_sha256':before,'quantization':args.quantization,'converter_commit':pins['commit'],
        'converter_source_sha256':digest(source/'convert_hf_to_gguf.py'),
        'quantizer_binary_sha256':digest(quantizer) if quantizer else None,'gguf_metadata':metadata,
        'upstream_pin':pins,'source_path':str(source),
        'quantizer_binary_path':str(quantizer) if quantizer else None,'recorder_sha256':digest(Path(__file__)),
        'provenance_limit':'Operator-recorded provenance; hashes are not cryptographic proof of conversion.'}
    artifact={'schema':1,'kind':'local-trained-gguf','model_sha256':before,
        'source_export_provenance_sha256':conversion['source_export_provenance_sha256'],
        'export_provenance_path':str(export_path),'source_base_revision':export['base_revision'],
        'source_adapter_sha256':adapter,'quantization':args.quantization,'converter_commit':pins['commit']}
    conversion_path,artifact_path=write_pair(args.output_prefix,conversion,artifact)
    print(json.dumps({'conversion_manifest':str(conversion_path),'artifact_manifest':str(artifact_path),
                      'model_sha256':before,'gguf_metadata':metadata}))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gguf',type=Path,required=True)
    parser.add_argument('--quantization',choices=('BF16','Q8_0','Q4_K_M'),required=True)
    parser.add_argument('--export-provenance',type=Path,required=True)
    parser.add_argument('--llama-source',type=Path,required=True)
    parser.add_argument('--quantizer',type=Path)
    parser.add_argument('--output-prefix',type=Path,required=True)
    record(parser.parse_args())


if __name__=='__main__':main()
