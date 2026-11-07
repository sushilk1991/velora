import copy
from types import SimpleNamespace
import unittest

from english_context import STOCK_DEFAULT, compact_context, contains_soft_source


class EnglishContextTests(unittest.TestCase):
    def setUp(self):
        self.gate = SimpleNamespace(
            use_llm=True, reason="llm", romanize=False,
            mode=SimpleNamespace(name="Default", prompt=STOCK_DEFAULT["prompt"], formatting="full"),
        )
        self.config = SimpleNamespace(auto_punctuation=True, soft_corrections={"lung": "Airlearn"})
        self.context = {"mode":"default", "language":"en", "romanize":False,
                        "instructions":"existing rules", "vocabulary":["Example App"]}

    def test_stock_default_uses_trained_task_without_duplicate_rules(self):
        original = copy.deepcopy(self.context)
        result = compact_context(self.gate, self.config, "Send the draft tomorrow.", self.context)
        self.assertEqual(result, {**original, "instructions":""})
        self.assertEqual(self.context, original)

    def test_custom_default_prompt_is_preserved(self):
        self.gate.mode.prompt += " Always preserve paragraph breaks."
        self.assertEqual(compact_context(self.gate,self.config,"hello",self.context), self.context)

    def test_requested_light_strength_is_preserved(self):
        self.gate.mode.formatting = "light"
        self.assertEqual(compact_context(self.gate,self.config,"hello",self.context), self.context)

    def test_punctuation_preference_is_preserved(self):
        self.config.auto_punctuation = False
        self.assertEqual(compact_context(self.gate,self.config,"hello",self.context), self.context)

    def test_matching_learned_correction_context_is_preserved(self):
        self.assertEqual(compact_context(self.gate,self.config,"The LUNG app is open.",self.context), self.context)
        self.assertFalse(contains_soft_source("The plunging water level.", {"lung":"Airlearn"}))
        self.assertTrue(contains_soft_source("A lung-related question.", {"lung":"Airlearn"}))

    def test_other_modes_and_transformations_are_preserved(self):
        for field, value in [("reason","smart_terminal"),("romanize",True),("use_llm",False)]:
            gate=copy.deepcopy(self.gate);setattr(gate,field,value)
            self.assertEqual(compact_context(gate,self.config,"hello",self.context), self.context)
        self.gate.mode.name="Message"
        self.assertEqual(compact_context(self.gate,self.config,"hello",self.context), self.context)

    def test_unicode_source_matching(self):
        self.assertTrue(contains_soft_source("JOSÉ is here.", {"Jose\u0301":"another spelling"}))


if __name__ == "__main__":
    unittest.main()
