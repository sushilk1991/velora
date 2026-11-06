"""CPU-only qualification accounting and artifact validation."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import pytest

SCRIPT=Path(__file__).resolve().parents[1]/'scripts/qualify_lfm3_artifacts.py'
spec=importlib.util.spec_from_file_location('lfm_qualification',SCRIPT)
qual=importlib.util.module_from_spec(spec);spec.loader.exec_module(qual)


def test_stream_keeps_final_length_token_and_excludes_eos():
    clock=iter([0.0, 0.5, 1.5]).__next__
    responses=[SimpleNamespace(token=11,text='hello',finish_reason=None),
               SimpleNamespace(token=12,text=' world',finish_reason='length')]
    row=qual.capture_stream(responses,clock)
    assert row['output_token_ids']==[11,12] and row['answer']=='hello world'
    assert row['status']=='length' and not row['eos'] and row['output_tokens']==2
    assert (row['first_response_s'],row['after_first_response_s'],row['total_s'])==(0.5,1.0,1.5)
    responses[-1]=SimpleNamespace(token=99,text='!',finish_reason='stop')
    row=qual.capture_stream(responses,iter([0,1,2]).__next__)
    assert row['output_token_ids']==[11] and row['answer']=='hello!' and row['eos']


def test_public_only_and_compare_prompt_and_output_boundaries(tmp_path):
    path=tmp_path/'data.jsonl'
    path.write_text(json.dumps({'id':'a','visibility':'public','raw':'sample','target':'never used'})+'\n')
    assert 'target' not in qual.public_inputs(path)[0]
    path.write_text(json.dumps({'id':'a','raw':'sample'})+'\n')
    with pytest.raises(ValueError,match='public visibility'):qual.public_inputs(path)
    record={'id':'a','prompt_token_ids':[1,2], 'output_token_ids':[3], 'status':'eos','eos':True,'answer':'x'}
    common={'data_sha256':'h','max_output':1024,'versions':{'mlx':'1'},'port_sha256':'port',
        'source_sha256':{'helper':'hash'},'mlx_allocator_cache_limit_bytes':qual.ALLOCATOR_CACHE_LIMIT_BYTES}
    left={**common,'artifact':{'kind':'original_mlx','base_revision':'rev','base_files_sha256':{'base':'a'},
        'adapter_files_sha256':{'adapter':'b'}},'records':[record]}
    right={**common,'artifact':{'kind':'fused_hf_export','source_base_revision':'rev',
        'source_base_files_sha256':{'base':'a'},'source_adapter_files_sha256':{'adapter':'b'}},
        'records':[{**record,'output_token_ids':[4]}]}
    report=qual.compare(left,right)
    assert report['prompt_parity'] and not report['exact_output_parity'] and report['changed_output_ids']==['a']
    right['records'][0]['prompt_token_ids']=[1,3]
    with pytest.raises(ValueError,match='prompt'):qual.compare(left,right)
    with pytest.raises(ValueError,match='input data'):qual.compare(left,{**right,'data_sha256':'other'})


def test_fused_requires_exact_export_files_and_provenance(tmp_path):
    (tmp_path/'config.json').write_text(json.dumps({'model_type':'lfm3','architectures':['Lfm3ForCausalLM']}))
    (tmp_path/'tokenizer.json').write_text('{}')
    (tmp_path/'tokenizer_config.json').write_text('{}')
    (tmp_path/'chat_template.jinja').write_text('template')
    (tmp_path/'model.safetensors').write_bytes(b'weights')
    files={p.name:qual.digest(p) for p in tmp_path.iterdir()}
    provenance=tmp_path/'export-provenance.json'
    provenance.write_text(json.dumps({'status':'exported','base_revision':qual.AUDITED_REVISION,
        'port_sha256':qual.SOURCE_SHA256,'output_files_sha256':files}))
    _,identity=qual.validate_fused(tmp_path,provenance)
    assert identity['kind']=='fused_hf_export' and 'base_revision' not in identity
    (tmp_path/'model.safetensors').write_bytes(b'changed')
    with pytest.raises(ValueError,match='hash mismatch'):qual.validate_fused(tmp_path,provenance)


def test_compare_requires_runtime_and_lineage_match():
    record={'id':'a','prompt_token_ids':[1], 'output_token_ids':[2], 'status':'eos','eos':True,'answer':'ok'}
    common={'data_sha256':'h','max_output':1024,'versions':{'mlx':'1'},'port_sha256':'port',
        'source_sha256':{'helper':'hash'},'mlx_allocator_cache_limit_bytes':qual.ALLOCATOR_CACHE_LIMIT_BYTES,
        'records':[record]}
    original={'kind':'original_mlx','base_revision':'rev','base_files_sha256':{'base':'a'},
        'adapter_files_sha256':{'adapter':'b'}}
    fused={'kind':'fused_hf_export','source_base_revision':'rev','source_base_files_sha256':{'base':'a'},
        'source_adapter_files_sha256':{'adapter':'b'}}
    left={**common,'artifact':original};right={**common,'artifact':fused}
    assert qual.compare(left,right)['exact_output_parity']
    for key in ('versions','port_sha256','source_sha256','mlx_allocator_cache_limit_bytes'):
        with pytest.raises(ValueError,match='runtime provenance'):
            qual.compare(left,{**right,key:'changed'})
    for key in ('source_base_revision','source_base_files_sha256','source_adapter_files_sha256'):
        with pytest.raises(ValueError,match='lineage'):
            qual.compare(left,{**right,'artifact':{**fused,key:'changed'}})


def test_incomplete_identical_outputs_do_not_qualify():
    common={'data_sha256':'h','max_output':10,'versions':{},'port_sha256':'port',
        'source_sha256':{},'mlx_allocator_cache_limit_bytes':qual.ALLOCATOR_CACHE_LIMIT_BYTES}
    original={'kind':'original_mlx','base_revision':'rev','base_files_sha256':{'base':'a'},'adapter_files_sha256':{'adapter':'b'}}
    fused={'kind':'fused_hf_export','source_base_revision':'rev','source_base_files_sha256':{'base':'a'},'source_adapter_files_sha256':{'adapter':'b'}}
    for status in ('length','incomplete'):
        record={'id':'a','prompt_token_ids':[1],'output_token_ids':[2],'status':status,'eos':False,'answer':'truncated'}
        result=qual.compare({**common,'artifact':original,'records':[record]}, {**common,'artifact':fused,'records':[record]})
        assert not result['exact_output_parity'] and result['changed_output_ids']==[]
        assert result['incomplete_case_ids']==['a'] and result['completion_counts']['left'][status]==1
        with pytest.raises(ValueError,match='inconsistent eos'):
            qual.compare({**common,'artifact':original,'records':[{**record,'eos':True}]}, {**common,'artifact':fused,'records':[record]})


def test_fused_rejects_invalid_config_and_missing_tokenizer(tmp_path):
    def write_provenance():
        files={f.name:qual.digest(f) for f in tmp_path.iterdir() if f.name!='export-provenance.json'}
        (tmp_path/'export-provenance.json').write_text(json.dumps({'status':'exported','base_revision':qual.AUDITED_REVISION,
            'port_sha256':qual.SOURCE_SHA256,'output_files_sha256':files}))
    (tmp_path/'config.json').write_text('{}'); (tmp_path/'model.safetensors').write_bytes(b'weights')
    write_provenance()
    with pytest.raises(ValueError,match='tokenizer'):qual.validate_fused(tmp_path,tmp_path/'export-provenance.json')
    (tmp_path/'tokenizer.json').write_text('{}');(tmp_path/'tokenizer_config.json').write_text('{}')
    write_provenance()
    with pytest.raises(ValueError,match='configuration'):qual.validate_fused(tmp_path,tmp_path/'export-provenance.json')
    (tmp_path/'config.json').write_text(json.dumps({'model_type':'lfm3','architectures':['Lfm3ForCausalLM']}));write_provenance()
    with pytest.raises(ValueError,match='chat template'):qual.validate_fused(tmp_path,tmp_path/'export-provenance.json')
    (tmp_path/'tokenizer_config.json').write_text(json.dumps({'chat_template':'template'}));write_provenance()
    qual.validate_fused(tmp_path,tmp_path/'export-provenance.json')


def test_export_preflight_requires_tokenizer_and_renderer(tmp_path):
    exporter_path=SCRIPT.parent/'export_lfm3_native.py'
    exporter_spec=importlib.util.spec_from_file_location('lfm_exporter',exporter_path)
    exporter=importlib.util.module_from_spec(exporter_spec);exporter_spec.loader.exec_module(exporter)
    with pytest.raises(ValueError,match='tokenizer.json'):
        exporter.validate_tokenizer_assets(tmp_path)
    (tmp_path/'tokenizer.json').write_text('{}')
    (tmp_path/'tokenizer_config.json').write_text('{}')
    with pytest.raises(ValueError,match='chat template'):
        exporter.validate_tokenizer_assets(tmp_path)
    (tmp_path/'chat_template.jinja').write_text('  ')
    with pytest.raises(ValueError,match='chat template'):
        exporter.validate_tokenizer_assets(tmp_path)
    (tmp_path/'chat_template.jinja').write_text('valid template')
    exporter.validate_tokenizer_assets(tmp_path)
