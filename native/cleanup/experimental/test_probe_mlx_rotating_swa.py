import importlib.util
from pathlib import Path
from types import SimpleNamespace as NS

import pytest

SCRIPT=Path(__file__).with_name('probe_mlx_rotating_swa.py')
spec=importlib.util.spec_from_file_location('rotating_probe',SCRIPT)
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class KVCache:
    nbytes=16
    offset=0
    keys=NS(shape=(1,2,256,128))


class ArraysCache:
    nbytes=8


class RotatingKVCache(KVCache):
    def __init__(self,max_size,keep): self.max_size=max_size;self.keep=keep


API=NS(KVCache=KVCache,ArraysCache=ArraysCache,RotatingKVCache=RotatingKVCache)


def model():
    kinds=['sliding_attention']*5+['full_attention']*6+['conv']*5
    caches=[KVCache() if k!='conv' else ArraysCache() for k in kinds]
    return NS(args=NS(sliding_window=256),layers=[NS(layer_type=k,is_attention_layer=k!='conv') for k in kinds],
              make_cache=lambda:list(caches)),caches


def test_only_five_sliding_layers_replace_cache_and_other_objects_are_unchanged():
    model_,original=model();result=m.cache_for(model_,True,API)
    assert all(type(c) is RotatingKVCache and c.max_size==256 and c.keep==0 for c in result[:5])
    assert all(a is b for a,b in zip(result[5:],original[5:]))
    assert all(a is b for a,b in zip(m.cache_for(model_,False,API),original))


def test_unexpected_topology_or_window_is_rejected():
    model_,_=model();model_.args.sliding_window=255
    with pytest.raises(ValueError,match='window'):m.cache_for(model_,True,API)
    model_,_=model();model_.layers.pop()
    with pytest.raises(ValueError,match='topology'):m.cache_for(model_,True,API)


def test_absolute_offset_and_retained_window_gate_without_gpu():
    model_,_=model();caches=m.cache_for(model_,True,API)
    for c in caches:
        if isinstance(c,KVCache):c.offset=514
    result=m.check_cache(model_,caches,513,1)
    assert all(r['offset']==514 for r in result if 'offset' in r)
    caches[0].offset=256
    with pytest.raises(ValueError,match='offset mismatch'):m.check_cache(model_,caches,513,1)
    caches[0].offset=514;caches[0].keys=NS(shape=(1,2,512,128))
    with pytest.raises(ValueError,match='exceeds window'):m.check_cache(model_,caches,513,1)


def records(status='length',text='x'):
    cases=[{'id':'file','prompt_tokens':[7]*257}]
    return [{'variant':v,'case_id':'file','prompt_tokens':[7]*257,'output_tokens':[3],
             'status':status,'text':text} for v in m.ORDER],cases


def test_one_token_is_explicitly_diagnostic_and_full_mode_requires_nonempty_eos():
    rows,cases=records();report=m.summarize(rows,cases,1,[])
    assert report['exact_parity'] and report['diagnostic_only'] and not report['completed_output_claim']
    assert not m.summarize(rows,cases,128,[])['exact_parity']
    rows,cases=records('stop','')
    assert not m.summarize(rows,cases,128,[])['exact_parity']
    rows,cases=records('stop','Ready.')
    assert m.summarize(rows,cases,128,[])['completed_output_claim']


@pytest.mark.parametrize('change',['prompt_tokens','output_tokens','status','text'])
def test_exact_prompt_output_status_text_parity(change):
    rows,cases=records();rows[2][change]=[8] if change.endswith('tokens') else 'different'
    assert not m.summarize(rows,cases,1,[])['exact_parity']


def test_incomplete_matrix_and_mutated_provenance_fail():
    rows,cases=records()
    assert not m.summarize(rows[:-1],cases,1,[])['exact_parity']
    assert not m.summarize(rows,cases,1,['artifact changed'])['exact_parity']
    assert not m.summarize([],[],1,[])['exact_parity']


def test_boundary_calibration_uses_whole_chat_templates():
    import json
    class Tokenizer:
        def apply_chat_template(self,messages,**kwargs):
            assert kwargs=={'tokenize':True,'add_generation_prompt':True,'enable_thinking':False}
            try: n=120+json.loads(messages[1]['content'])['vocabulary'][0].count(' x')
            except ValueError:n=600
            return [7]*n
    cases=m.make_cases(Tokenizer(),'system','real external payload',True)
    assert [len(c['prompt_tokens']) for c in cases]==[*m.BOUNDARIES,600]
