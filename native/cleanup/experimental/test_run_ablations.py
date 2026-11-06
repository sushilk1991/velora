"""CPU-only tests for failure accounting and immutable-baseline comparison."""
import copy
import unittest

from run_ablations import compare


def artifact():
    rows = [dict(id=f"case-{i}", status="eos", answer="ok", diagnostic_partial_text="",
                 prompt_tokens=[1, 2], output_tokens=[3], error=None,
                 seconds=.1, worker_ms=99, copy_draft={"forward_calls": 2}) for i in range(64)]
    rows[-1].update(status="length", answer="", diagnostic_partial_text="unfinished")
    response = dict(status="eos", text="ok", partial_text="", prompt_tokens=[1, 2], output_tokens=[3])
    meta = dict(model_sha256="model", binary_sha256="binary", data_sha256="data", context_tokens=4096,
                max_tokens=256, temperature=0, prefix_reuse=True, trace_runtime=True,
                repeat_equal=True, repeat_statuses=["eos", "eos"], cancel_status="cancelled",
                after_cancel_status="eos", supervisor_exit_code=0,
                ready=dict(model_sha256="model", template_sha256="template", llama_commit="pin",
                           architecture="lfm3", vocab_size=128000, context_tokens=4096),
                source_sha256={key: "hash" for key in ("benchmark.py", "benchmark_checks.py", "supervise.py")},
                state_recovery=dict(passed=True, responses={key: copy.deepcopy(response) for key in
                    ("changed_system", "restored_system", "context_error", "context_recovery")}))
    return dict(path="test.jsonl", sha256="rows", meta_sha256="meta", rows=rows, meta=meta, read_errors=[])


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.baseline = artifact()
        self.candidate = copy.deepcopy(self.baseline)

    def check(self):
        return compare(self.baseline, self.candidate)

    def test_known_failure_is_counted_not_qualified(self):
        result = self.check()
        self.assertTrue(result["relative_runtime_parity"])
        self.assertFalse(result["model_qualified"])
        self.assertEqual(result["accounting"]["status_counts"], {"eos": 63, "length": 1})
        self.assertEqual(result["accounting"]["all_recorded_latency"]["count"], 64)
        self.assertEqual(result["matched_latency_ratio_median"], 1)

    def test_partial_length_output_matters(self):
        self.candidate["rows"][-1]["diagnostic_partial_text"] = "different"
        result = self.check()
        self.assertFalse(result["relative_runtime_parity"])
        self.assertIn("diagnostic_partial_text", result["exact_mismatches"][0]["fields"])

    def test_missing_failure_does_not_disappear(self):
        self.candidate["rows"].pop()
        result = self.check()
        self.assertFalse(result["complete_expected_rows"])
        self.assertEqual(result["missing_ids"], ["case-63"])
        self.assertIsNone(result["matched_latency_ratio_median"])

    def test_duplicate_or_reordered_rows_fail(self):
        self.candidate["rows"][-1] = copy.deepcopy(self.candidate["rows"][0])
        self.assertFalse(self.check()["relative_runtime_parity"])
        self.candidate = copy.deepcopy(self.baseline)
        self.candidate["rows"].reverse()
        self.assertFalse(self.check()["relative_runtime_parity"])

    def test_recovery_output_change_fails(self):
        self.candidate["meta"]["state_recovery"]["responses"]["context_recovery"]["output_tokens"] = [4]
        self.assertFalse(self.check()["relative_runtime_parity"])

    def test_missing_metadata_or_token_change_fails(self):
        self.candidate["meta"] = {}
        self.assertFalse(self.check()["relative_runtime_parity"])
        self.candidate = copy.deepcopy(self.baseline)
        self.candidate["rows"][0]["prompt_tokens"] = [9]
        self.assertFalse(self.check()["relative_runtime_parity"])

    def test_trace_difference_disallows_speed_comparison(self):
        self.candidate["meta"]["trace_runtime"] = False
        result = self.check()
        self.assertTrue(result["relative_runtime_parity"])
        self.assertFalse(result["speed_comparison_eligible"])

    def test_request_error_and_absent_timing_remain_failures(self):
        self.candidate["rows"][0].update(status="request_error", error="memory_limit", seconds=None, worker_ms=None)
        result = self.check()
        self.assertFalse(result["relative_runtime_parity"])
        self.assertEqual(result["accounting"]["status_counts"]["request_error"], 1)
        self.assertEqual(result["accounting"]["all_recorded_latency"]["count"], 63)

    def test_token_only_requires_nonzero_checked_samples(self):
        self.candidate["meta"]["backend_token_only"] = True
        self.candidate["meta"]["ready"]["backend_token_only"] = True
        self.assertFalse(self.check()["relative_runtime_parity"])
        for row in self.candidate["rows"]:
            row["backend_sampling"] = dict(enabled=True, token_only=True, sampled_tokens=3, filtered_rows_checked=3)
        self.assertTrue(self.check()["relative_runtime_parity"])
        self.candidate["rows"][0]["backend_sampling"]["filtered_rows_checked"] = 0
        self.assertFalse(self.check()["relative_runtime_parity"])


if __name__ == "__main__":
    unittest.main()
