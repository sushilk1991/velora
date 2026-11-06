"""CPU-only checks for GGUF metadata and immutable manifest publication."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import pytest

SCRIPT=Path(__file__).resolve().parents[1]/'scripts/record_lfm3_conversion.py'
spec=importlib.util.spec_from_file_location('lfm_conversion_record',SCRIPT)
rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)


class FakeGGUF:
    LlamaFileType=SimpleNamespace(MOSTLY_BF16=32,MOSTLY_Q8_0=7,MOSTLY_Q4_K_M=15)
    def __init__(self,architecture='lfm3',file_type=7):
        self.architecture=architecture;self.file_type=file_type
    def GGUFReader(self,path,mode):
        assert mode=='r'
        fields={'general.architecture':self.architecture,'general.file_type':self.file_type}
        return SimpleNamespace(get_field=lambda key:SimpleNamespace(contents=lambda:fields[key]))


def test_metadata_requires_matching_architecture_and_file_type():
    assert rec.inspect_gguf('unused',FakeGGUF(),'Q8_0')=={'architecture':'lfm3','file_type':7}
    with pytest.raises(ValueError,match='architecture or file type'):
        rec.inspect_gguf('unused',FakeGGUF('qwen3'),'Q8_0')
    with pytest.raises(ValueError,match='architecture or file type'):
        rec.inspect_gguf('unused',FakeGGUF(file_type=15),'Q8_0')
    assert rec.inspect_gguf('unused',FakeGGUF(file_type=32),'BF16')['file_type']==32


def test_write_pair_hashes_exact_conversion_and_refuses_overwrite(tmp_path):
    prefix=tmp_path/'record'
    conversion,artifact=rec.write_pair(prefix,{'model_sha256':'f'*64},{'kind':'local-trained-gguf'})
    value=json.loads(artifact.read_text())
    assert value['conversion_manifest_path']==str(conversion.resolve())
    assert value['conversion_manifest_sha256']==rec.digest(conversion)
    before=(conversion.read_bytes(),artifact.read_bytes())
    with pytest.raises(FileExistsError):rec.write_pair(prefix,{}, {})
    assert (conversion.read_bytes(),artifact.read_bytes())==before


def test_record_binds_model_export_and_quantizer_without_mutating_gguf(tmp_path,monkeypatch):
    model=tmp_path/'model.gguf';model.write_bytes(b'gguf fixture')
    source=tmp_path/'source';source.mkdir();(source/'convert_hf_to_gguf.py').write_bytes(b'converter')
    export=tmp_path/'export-provenance.json'
    export.write_text(json.dumps({'base_revision':'a'*40,'llama_converter_commit':'b'*40,
        'adapter_files_sha256':{'adapters.safetensors':'c'*64}}))
    quantizer=tmp_path/'quantizer';quantizer.write_bytes(b'quantizer');quantizer.chmod(0o700)
    pins=tmp_path/'pins.json';pins.write_text(json.dumps({'commit':'b'*40,'source_tree_sha256':'d'*64}))
    monkeypatch.setattr(rec,'PIN',pins)
    calls=[]
    monkeypatch.setattr(rec.subprocess,'run',lambda cmd,**kwargs:calls.append((cmd,kwargs)))
    monkeypatch.setattr(rec,'validate_fused',lambda *args:(str(tmp_path),{'files_sha256':{'config.json':'e'*64}}))
    monkeypatch.setattr(rec,'load_verified_gguf',lambda _:FakeGGUF())
    args=SimpleNamespace(gguf=model,llama_source=source,export_provenance=export,quantizer=quantizer,
        quantization='Q8_0',output_prefix=tmp_path/'out')
    original=model.read_bytes();rec.record(args)
    conversion=json.loads((tmp_path/'out.conversion.json').read_text())
    artifact=json.loads((tmp_path/'out.artifact.json').read_text())
    assert calls and calls[0][1]['check'] is True
    assert model.read_bytes()==original and conversion['model_sha256']==rec.digest(model)
    assert conversion['quantizer_binary_sha256']==rec.digest(quantizer)
    assert conversion['source_export_files_sha256']=={'config.json':'e'*64}
    assert artifact['conversion_manifest_sha256']==rec.digest(tmp_path/'out.conversion.json')
    args.quantizer=None;args.output_prefix=tmp_path/'other'
    with pytest.raises(ValueError,match='quantizer binary required'):rec.record(args)
    assert not (tmp_path/'other.conversion.json').exists()
