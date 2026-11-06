"""Pure CPU accounting: unsuccessful generation never becomes accepted text."""
import collections,statistics

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


def state_recovery_checks(reference,changed_system,restored_system,context_error,recovered,cache_enabled):
    def rebuilt(response):
        cache=response.get('prefix_cache') or {}
        return cache.get('enabled') is True and cache.get('hit') is False and cache.get('reason')=='captured_static_prefix' and cache.get('snapshot_bytes',0)>0
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
