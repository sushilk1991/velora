import unittest
from benchmark_checks import record_result,summarize,repeat_matches,state_recovery_checks,runtime_qualification
class Checks(unittest.TestCase):
    def test_supplied_reference_parity_is_required_for_qualification(self):
        good={'all_main_rows_eos':True,'repeat_equal':True,'cancel_status':'cancelled',
              'after_cancel_status':'eos','state_recovery':{'passed':True},'supervisor_exit_code':0}
        self.assertTrue(runtime_qualification(good))
        self.assertFalse(runtime_qualification(good,True))
        self.assertFalse(runtime_qualification({**good,'backend_token_parity':False},True))
        self.assertTrue(runtime_qualification({**good,'backend_token_parity':True},True))
        self.assertFalse(runtime_qualification({**good,'backend_token_parity':True,'supervisor_exit_code':1},True))
    def test_failures_remain_in_denominator_without_accepted_text(self):
        rows=[record_result('ok',{'status':'eos','text':'Edited.'},.2)]
        for status in ['length','context_limit','deadline','memory_limit']:
            row=record_result(status,{'status':status,'text':'must not accept','partial_text':'diagnostic'},.001)
            self.assertEqual(row['answer'],'');self.assertEqual(row['diagnostic_partial_text'],'diagnostic');rows.append(row)
        report=summarize(rows,5)
        self.assertEqual(report['failed_rows'],4);self.assertEqual(report['eos_only_timing']['count'],1)
        self.assertEqual(report['all_attempts_timing']['count'],5);self.assertFalse(report['all_main_rows_eos'])
    def test_draft_statistics_preserve_failures(self):
        rows=[record_result('failed',{'status':'length','copy_draft':{'proposed':3,'accepted':2,'rollbacks':1,'forward_calls':5,'forward_tokens':12}},.1)]
        report=summarize(rows,1)
        self.assertEqual(report['copy_draft_totals']['accepted'],2)
        self.assertEqual(report['failed_rows'],1)
    def test_identical_failures_are_not_repeat_success(self):
        self.assertFalse(repeat_matches({'status':'length'},{'status':'length'}))
        self.assertTrue(repeat_matches({'status':'eos','text':'x'},{'status':'eos','text':'x'}))
    def test_state_recovery_requires_rebuild_and_exact_success(self):
        good={'status':'eos','text':'x','prompt_tokens':[1,2],'output_tokens':[3]}
        rebuilt={'enabled':True,'hit':False,'reason':'captured_static_prefix','snapshot_bytes':42}
        changed={**good,'prompt_tokens':[1,5],'prefix_cache':rebuilt}
        restored={**good,'prefix_cache':rebuilt}
        overflow={'status':'context_limit','text':'','partial_text':'','output_tokens':[]}
        def check(c=changed,r=restored,e=overflow,recovery=good,enabled=True):
            return state_recovery_checks(good,c,r,e,recovery,enabled)['passed']
        self.assertTrue(check())
        self.assertFalse(check(c={**changed,'prefix_cache':{**rebuilt,'hit':True}}))
        self.assertFalse(check(r={**restored,'output_tokens':[4]}))
        self.assertFalse(check(e={**overflow,'status':'length'}))
        self.assertFalse(check(recovery={**good,'status':'length'}))
        self.assertTrue(check(c={**changed,'prefix_cache':None},r=good,enabled=False))
if __name__=='__main__':unittest.main()


def test_student_header_requires_capture_hit_and_bounded_snapshot():
    from benchmark_checks import header_evidence, runtime_qualification
    cache={'enabled':True,'student_prefix_requested':True,'strategy':'student_header',
        'snapshot_bytes':32*1024*1024,'system_prefix_tokens':64,'header_prefix_tokens':128,'prefix_tokens':192,
        'reason':'captured_student_header','hit':False}
    capture={'prefix_cache':cache};hit={'prefix_cache':{**cache,'reason':'restored','hit':True}}
    assert not header_evidence([capture])['exercised']
    assert header_evidence([capture,hit])['exercised']
    assert not header_evidence([capture,{'prefix_cache':{**hit['prefix_cache'],'snapshot_bytes':32*1024*1024+1}}])['exercised']
    meta={'all_main_rows_eos':True,'repeat_equal':True,'cancel_status':'cancelled',
        'after_cancel_status':'eos','state_recovery':{'passed':True},'supervisor_exit_code':0,
        'student_prefix_cache':True,'student_header_exercised':False,
        'reference_output_supplied':True,'output_reference_parity':True}
    assert not runtime_qualification(meta)
    meta['student_header_exercised']=True
    assert runtime_qualification(meta)
    meta['reference_output_supplied']=False
    assert not runtime_qualification(meta)


def test_output_reference_requires_complete_unique_ids_and_same_provenance():
    from benchmark_checks import REFERENCE_SETTINGS, output_reference_check
    settings={key:False for key in REFERENCE_SETTINGS}
    settings.update(model_sha256='a'*64,data_sha256='b'*64,binary_sha256='c'*64,
                    student_prefix_cache=False)
    row={'id':'one','status':'eos','answer':'hello','prompt_tokens':[1,2],'output_tokens':[3]}
    check=lambda actual,reference,control=settings:output_reference_check(actual,reference,control,settings,['one'])
    assert check([row],[row])['passed']
    assert not check([row],[])['passed']
    assert not check([row],[row,row])['passed']
    assert not check([row],[{**row,'output_tokens':[4]}])['passed']
    assert not check([row],[{**row,'status':'length'}])['passed']
    assert not check([row],[row],{**settings,'binary_sha256':'d'*64})['passed']
    assert not check([row],[row],{**settings,'student_prefix_cache':True})['passed']
    assert not check([row],[row],{**settings,'data_sha256':''})['passed']
