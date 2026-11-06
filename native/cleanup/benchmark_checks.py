"""Pure CPU accounting: unsuccessful generation never becomes accepted text."""
import collections,statistics,re

def record_result(identity,response,seconds):
    status=response.get('status','request_error')
    return {'id':identity,'answer':response.get('text','') if status=='eos' else '',
            'diagnostic_partial_text':response.get('partial_text',''),
            'seconds':seconds,'worker_ms':response.get('elapsed_ms'),
            'runtime_trace':response.get('runtime_trace'),'backend_sampling':response.get('backend_sampling'),'status':status,'error':response.get('error'),'prefix_cache':response.get('prefix_cache'),'copy_draft':response.get('copy_draft'),
            'prompt_tokens':response.get('prompt_tokens',[]),
            'output_tokens':response.get('output_tokens',[]),'rss_bytes':response.get('rss_bytes')}

def timing(values):
    return {'count':len(values),'p50_seconds':statistics.median(values) if values else None,
            'p95_seconds':sorted(values)[int(.95*(len(values)-1))] if values else None}

def summarize(records,expected):
    eos=[r for r in records if r['status']=='eos']
    return {'expected_rows':expected,'attempted_rows':len(records),'eos_rows':len(eos),
            'copy_draft_totals':{key:sum((r.get('copy_draft') or {}).get(key,0) for r in records) for key in ['proposed','accepted','rollbacks','forward_calls','forward_tokens']},
            'failed_rows':expected-len(eos),'status_counts':dict(collections.Counter(r['status'] for r in records)),
            'failed_ids':[r['id'] for r in records if r['status']!='eos'],
            'all_attempts_timing':timing([r['seconds'] for r in records]),
            'eos_only_timing':timing([r['seconds'] for r in eos]),
            'all_main_rows_eos':len(eos)==expected==len(records)}

def repeat_matches(first,second):
    return first.get('status')==second.get('status')=='eos' and all(first.get(k)==second.get(k) for k in ['text','prompt_tokens','output_tokens'])


def runtime_qualification(meta,reference_required=False):
    """All supplied evidence is a gate; optional reference parity is not advisory."""
    return (meta.get('all_main_rows_eos') is True and meta.get('repeat_equal') is True
        and meta.get('cancel_status')=='cancelled' and meta.get('after_cancel_status')=='eos'
        and (meta.get('state_recovery') or {}).get('passed') is True
        and (not reference_required or meta.get('backend_token_parity') is True)
        and (not meta.get('student_prefix_cache') or (meta.get('student_header_exercised') is True
            and meta.get('reference_output_supplied') is True and meta.get('output_reference_parity') is True))
        and meta.get('supervisor_exit_code',0)==0)


def state_recovery_checks(reference,changed_system,restored_system,context_error,recovered,cache_enabled,student_enabled=False):
    def rebuilt(response):
        cache=response.get('prefix_cache') or {}
        system=cache.get('reason')=='captured_static_prefix'
        system_size=cache.get('system_prefix_tokens');header_size=cache.get('header_prefix_tokens');prefix_size=cache.get('prefix_tokens')
        header=(cache.get('reason')=='captured_student_header'
            and cache.get('student_prefix_requested') is True
            and cache.get('strategy')=='student_header'
            and all(type(x) is int for x in (system_size,header_size,prefix_size))
            and header_size>0 and 0<system_size<prefix_size<=1024
            and prefix_size==system_size+header_size)
        size=cache.get('snapshot_bytes')
        valid_size=type(size) is int and 0<size<=32*1024*1024
        return cache.get('enabled') is True and cache.get('hit') is False and (header if student_enabled else system) and valid_size
    checks={
        'changed_system_eos':changed_system.get('status')=='eos',
        'changed_system_prompt_differs':changed_system.get('prompt_tokens')!=reference.get('prompt_tokens'),
        'changed_system_cache_rebuilt':not cache_enabled or rebuilt(changed_system),
        'original_system_cache_rebuilt':not cache_enabled or rebuilt(restored_system),
        'original_system_exact_recovery':repeat_matches(reference,restored_system),
        'forced_context_limit':context_error.get('status')=='context_limit' and not context_error.get('text') and not context_error.get('partial_text') and not context_error.get('output_tokens'),
        'context_limit_exact_recovery':repeat_matches(reference,recovered),
    }
    return {'passed':all(checks.values()),'checks':checks}


REFERENCE_SETTINGS=('model_sha256','data_sha256','binary_sha256','context_tokens','copy_draft',
    'draft_max_tokens','recurrent_rollback','backend_sampling','backend_token_only','direct_argmax',
    'trace_runtime','prefix_reuse','prefill_batch_tokens','research_long_context','max_tokens',
    'max_output_tokens','deadline_ms','bounded_swa','temperature')


def header_evidence(records):
    counts={'captures':0,'hits':0}
    for row in records:
        cache=row.get('prefix_cache') or {}
        if not isinstance(cache,dict):continue
        size=cache.get('snapshot_bytes');prefix=cache.get('prefix_tokens');system=cache.get('system_prefix_tokens');header=cache.get('header_prefix_tokens')
        if (cache.get('enabled') is not True or cache.get('student_prefix_requested') is not True
            or cache.get('strategy')!='student_header' or type(size) is not int or not 0<size<=32*1024*1024
            or type(prefix) is not int or type(system) is not int or type(header) is not int
            or not 0<system<prefix<=1024 or header!=prefix-system):continue
        if cache.get('reason')=='captured_student_header' and cache.get('hit') is False:counts['captures']+=1
        elif cache.get('reason')=='restored' and cache.get('hit') is True:counts['hits']+=1
    return {**counts,'exercised':counts['captures']>0 and counts['hits']>0}


def output_reference_check(records,reference,reference_meta,current_meta,expected_ids):
    errors=[]
    for key in REFERENCE_SETTINGS:
        left=reference_meta.get(key);right=current_meta.get(key)
        if left is None or right is None or left!=right:errors.append('setting_mismatch:'+key)
    for key in ('model_sha256','data_sha256','binary_sha256'):
        if not isinstance(current_meta.get(key),str) or not re.fullmatch('[0-9a-f]{64}',current_meta[key]):
            errors.append('invalid_hash:'+key)
    if reference_meta.get('student_prefix_cache',False) is not False:
        errors.append('reference_must_disable_student_prefix')
    expected=list(expected_ids)
    if not expected or len(set(expected))!=len(expected):errors.append('invalid_expected_ids')
    def index(rows,label):
        if not isinstance(rows,list):errors.append(label+'_not_list');return {}
        result={}
        for row in rows:
            if not isinstance(row,dict) or not isinstance(row.get('id'),str):
                errors.append(label+'_invalid_row');continue
            identity=row['id']
            if identity in result:errors.append(label+'_duplicate_id')
            result[identity]=row
        if set(result)!=set(expected):errors.append(label+'_id_coverage')
        return result
    actual=index(records,'actual');control=index(reference,'reference')
    for identity in expected:
        a=actual.get(identity);b=control.get(identity)
        if not a or not b:continue
        for row in (a,b):
            if (row.get('status')!='eos' or not isinstance(row.get('answer'),str) or not row['answer'].strip()
                or not isinstance(row.get('prompt_tokens'),list) or not row['prompt_tokens']
                or not isinstance(row.get('output_tokens'),list) or not row['output_tokens']
                or any(type(t) is not int for t in row['prompt_tokens']+row['output_tokens'])):
                errors.append('incomplete:'+identity);break
        if any(a.get(k)!=b.get(k) for k in ('status','answer','prompt_tokens','output_tokens')):
            errors.append('mismatch:'+identity)
    return {'passed':not errors,'errors':errors,'expected_ids':len(expected),'actual_ids':len(actual),'reference_ids':len(control)}
