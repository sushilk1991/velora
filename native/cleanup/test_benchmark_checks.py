import unittest
from benchmark_checks import record_result,summarize,repeat_matches,state_recovery_checks
class Checks(unittest.TestCase):
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
