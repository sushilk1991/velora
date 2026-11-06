"""Export contracts use small CPU arrays; never load MLX or real weights."""
import importlib.util
import json
from pathlib import Path
import struct
from types import SimpleNamespace

import numpy as np
import pytest

SCRIPT=Path(__file__).resolve().parents[2]/'training/cleanup/scripts/export_lfm3_native.py'
spec=importlib.util.spec_from_file_location('lfm3_export',SCRIPT)
export=importlib.util.module_from_spec(spec);spec.loader.exec_module(export)


def config():
    return {'model_type':'lfm3','architectures':['Lfm3ForCausalLM'],'tie_word_embeddings':True,
        'conv_bias':False,'conv_L_cache':7,'use_sandwich_norm':True,'hidden_size':2,
        'intermediate_size':4,'head_dim':2,'num_attention_heads':1,'num_key_value_heads':1,
        'vocab_size':8,'layer_types':['conv','full_attention'],'num_hidden_layers':2,
        'quantization':{'bits':8},'quantization_config':{'bits':8},'auto_map':{'AutoModel':'remote'}}


def safetensor_header(path,header):
    data=json.dumps(header).encode();path.write_bytes(struct.pack('<Q',len(data))+data)


def test_inverse_conv_layout_is_value_preserving_and_strict():
    value=np.arange(14).reshape(2,7,1)
    name='model.layers.0.conv.conv.weight'
    key,converted=export.hf_tensor(name,value)
    assert key==name and converted.shape==(2,1,7)
    np.testing.assert_array_equal(converted[:,0,:],value[:,:,0])
    with pytest.raises(ValueError,match='depthwise'):export.hf_tensor(name,converted)
    for bad in ('model.layers.0.lora_a','model.layers.0.scales','lm_head.weight','language_model.model.weight'):
        with pytest.raises(ValueError,match='unexpected tensor'):export.hf_tensor(bad,value)


def test_tied_hf_config_and_complete_shape_contract():
    original=config();result=export.hf_config(original)
    assert original['quantization']=={'bits':8}
    assert not {'quantization','quantization_config','auto_map'} & result.keys()
    shapes=export.expected_shapes(result)
    assert 'lm_head.weight' not in shapes
    assert shapes['model.layers.0.conv.conv.weight']==(2,1,7)
    weights={key:SimpleNamespace(shape=shape) for key,shape in shapes.items()}
    export.validate_shapes(weights,result)
    weights['model.layers.1.self_attn.gate_proj.weight'].shape=(2,2)
    with pytest.raises(ValueError,match='shape mismatch'):export.validate_shapes(weights,result)
    weights.pop('model.embedding_norm.weight')
    with pytest.raises(ValueError,match='keys mismatch'):export.validate_shapes(weights,result)
    with pytest.raises(ValueError,match='configuration'):export.hf_config({**original,'tie_word_embeddings':False})


def test_header_reader_and_inspection_require_pinned_paired_lora(tmp_path):
    base=tmp_path/'snapshots'/export.BASE_REVISION;base.mkdir(parents=True)
    (base/'config.json').write_text(json.dumps(config()))
    (base/'tokenizer.json').write_text('{}')
    (base/'tokenizer_config.json').write_text('{}')
    (base/'chat_template.jinja').write_text('{{ messages }}')
    safetensor_header(base/'model.safetensors',{})
    adapter=tmp_path/'adapter';adapter.mkdir()
    (adapter/'adapter_config.json').write_text(json.dumps({'fine_tune_type':'lora','num_layers':2}))
    path=adapter/'adapters.safetensors'
    keys={'model.layers.0.conv.in_proj.lora_a':{'shape':[2,1]},'model.layers.0.conv.in_proj.lora_b':{'shape':[1,6]}}
    safetensor_header(path,keys)
    args=SimpleNamespace(base=base,base_revision=export.BASE_REVISION,adapter=adapter,adapter_sha256=export.digest(path))
    _,_,_,identity=export.inspect(args)
    assert identity['adapter_arrays']==2 and not identity['runtime_qualified']
    args.adapter_sha256='0'*64
    with pytest.raises(ValueError,match='SHA256 mismatch'):export.inspect(args)
    safetensor_header(path,{next(iter(keys)):next(iter(keys.values()))})
    args.adapter_sha256=export.digest(path)
    with pytest.raises(ValueError,match='unpaired'):export.inspect(args)
    path.write_bytes(struct.pack('<Q',17*1024*1024))
    with pytest.raises(ValueError,match='header size'):export.tensor_headers(path)
