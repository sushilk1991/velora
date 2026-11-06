import unittest
from benchmark_checks import state_recovery_checks
class Recovery(unittest.TestCase):
    def test_header_capture_requires_bounded_positive_metadata(self):
        response=dict(status='eos',text='Synthetic',prompt_tokens=[1,2],output_tokens=[3])
        cache=dict(enabled=True,hit=False,reason='captured_student_header',snapshot_bytes=8,
                   student_prefix_requested=True,strategy='student_header',header_prefix_tokens=128,system_prefix_tokens=64,prefix_tokens=192)
        changed=dict(response,prompt_tokens=[4,5],prefix_cache=cache)
        restored=dict(response,prefix_cache=cache)
        error=dict(status='context_limit',text='',partial_text='',output_tokens=[])
        def checks(c):return state_recovery_checks(response,dict(changed,prefix_cache=c),restored,error,restored,True,True)
        self.assertTrue(checks(cache)['passed'])
        system=dict(cache,reason='captured_static_prefix',strategy='system')
        self.assertFalse(checks(system)['passed'])
        self.assertTrue(state_recovery_checks(response,dict(changed,prefix_cache=system),
            dict(restored,prefix_cache=system),error,restored,True,False)['passed'])
        for key,value in [('student_prefix_requested',False),('strategy','system'),('header_prefix_tokens',0),('prefix_tokens',1025),('prefix_tokens',193),('snapshot_bytes',0),('snapshot_bytes',32*1024*1024+1),('hit',True)]:
            with self.subTest(key=key,value=value):self.assertFalse(checks(dict(cache,**{key:value}))['passed'])
if __name__=='__main__':unittest.main()
