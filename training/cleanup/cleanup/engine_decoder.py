"""Experimental single-process student decoder using Velora's MLX cache engine.

Uses private CleanupEngine APIs and must be parity-qualified per model/adapter.
Not a production integration. One request at a time; retire process on watchdog.
"""
from __future__ import annotations
from contextlib import contextmanager
from . import render_messages
from .provenance import load_local_snapshot
from velora_engine import cleanup as production

_copy_tokens_active = False


@contextmanager
def experimental_copy_draft_tokens(tokens=3):
    """Bound one isolated serial model lifetime; never patch the live app."""
    global _copy_tokens_active
    if type(tokens) is not int or tokens not in (3,4,6,8):
        raise ValueError('copy draft tokens must be one of 3,4,6,8')
    if _copy_tokens_active:
        raise RuntimeError('experimental copy token context is already active')
    previous=production.COPY_DRAFT_PASS_TOKENS
    _copy_tokens_active=True
    production.COPY_DRAFT_PASS_TOKENS=tokens
    try:
        yield tokens
    finally:
        production.COPY_DRAFT_PASS_TOKENS=previous
        _copy_tokens_active=False


def student_messages(context, raw, suffix=''):
    row = dict(context)
    row['raw'] = raw
    if suffix:
        row['instructions'] += suffix
    messages = render_messages(row)
    # Match the production engine's control-token defense on the entire
    # untrusted structured user message, including vocabulary and instructions.
    messages[1]['content'] = production.neutralize_control_tokens(messages[1]['content'])
    return messages


def student_prompt(tokenizer, context, raw, suffix=''):
    return tokenizer.apply_chat_template(student_messages(context, raw, suffix), tokenize=False,
        add_generation_prompt=True, enable_thinking=False)


def student_prompt_tokens(tokenizer, context, raw, suffix=''):
    prompt = student_prompt(tokenizer, context, raw, suffix)
    # Match mlx_lm.stream_generate's string-to-token path exactly.
    bos = tokenizer.bos_token
    add_special_tokens = bos is None or not prompt.startswith(bos)
    return list(tokenizer.encode(prompt, add_special_tokens=add_special_tokens))


class StudentEngine(production.CleanupEngine):
    def __init__(self, model_id, snapshot, adapter=None, *, copy_draft=False,
                 max_input=4096, max_output=1024):
        if not 1 <= max_output <= 1024 or max_input < 1:
            raise ValueError('invalid inference caps')
        super().__init__(model_id, local_model_path=snapshot)
        self.adapter = adapter
        self.copy_draft_enabled = copy_draft
        self.max_input, self.max_output = max_input, max_output
        self.context = None
        self.last_prompt_tokens = []
        self.last_output_tokens = []
        self.last_eos = False

    def _load_local_model(self, path):
        return load_local_snapshot(str(path), self.adapter)

    def set_context(self, gate, context):
        if self.unhealthy:
            raise RuntimeError('retire unhealthy process before changing context')
        self.context = (gate.system_prompt, dict(context))

    def _prompt_tokens(self, system_prompt, user_text):
        if self.context is None:
            raise ValueError('student case context is not set')
        base, context = self.context
        if not base or not system_prompt.startswith(base):
            raise ValueError('production prompt does not match current gate')
        return student_prompt_tokens(self._tokenizer, context, user_text, system_prompt[len(base):])

    async def cleanup(self, raw, system_prompt, **kwargs):
        kwargs.pop('queue_timeout_s', None)
        kwargs['max_input_tokens'] = self.max_input
        # Match production's mode contract: transliteration/transform paths do
        # not copy transcript tokens. The experiment flag cannot override it.
        context_romanize = self.context is not None and self.context[1].get('romanize', False)
        kwargs['copy_draft'] = (self.copy_draft_enabled and kwargs.get('copy_draft', False)
            and kwargs.get('check_ratio', True) and not context_romanize)
        # Production probes contain production-only system strings. Student
        # candidates instead vary only transcript text, so all structured
        # controls remain identical; the engine checks exact token-prefix match.
        kwargs['prefix_candidates'] = [(system_prompt, 'alpha'), (system_prompt, 'zulu')]
        return await super().cleanup(raw, system_prompt, **kwargs)

    def _run(self, raw, system_prompt, timeout_ms, check_ratio=True, cancel_event=None,
             allowed_terms=None, prefix_candidates=None, max_tokens_override=None,
             cache_scope=None, max_input_tokens=None, copy_draft=False):
        input_count = len(self._tokenizer.encode(raw))
        cap = min(self.max_output, max(96, int(input_count * (1.8 if check_ratio else 3.0))))
        # Copy is explicitly experimental for this exact process, not a change
        # to production's audited allowlist. _run holds the per-model lock.
        previous = production.COPY_DRAFT_MODELS
        if copy_draft:
            production.COPY_DRAFT_MODELS = previous | {self.model_id}
        try:
            return super()._run(raw, system_prompt, timeout_ms, check_ratio, cancel_event,
                allowed_terms, prefix_candidates, cap, cache_scope, self.max_input, copy_draft)
        finally:
            production.COPY_DRAFT_MODELS = previous

    def _generate_locked(self, system_prompt, user_text, max_tokens, output_timeout_s,
                         cancel_event=None, prefix_candidates=None, cache_scope=None,
                         max_input_tokens=None, copy_draft=False):
        # Instrument the existing algorithm, rather than implementing another
        # decoder. Scoped to the serial model thread in this isolated process.
        import mlx_lm
        original = mlx_lm.stream_generate
        self.last_prompt_tokens = self._prompt_tokens(system_prompt, user_text)
        self.last_output_tokens = []
        self.last_eos = False
        def stream(*args, **kwargs):
            iterator = original(*args, **kwargs)
            try:
                for response in iterator:
                    if response.finish_reason == 'stop':
                        self.last_eos = True
                    else:
                        self.last_output_tokens.append(response.token)
                    yield response
            finally:
                iterator.close()
        mlx_lm.stream_generate = stream
        try:
            result = super()._generate_locked(system_prompt, user_text, max_tokens,
                output_timeout_s, cancel_event, prefix_candidates, cache_scope,
                max_input_tokens, copy_draft)
            if copy_draft:
                # Copy iterator only ends naturally on EOS or cap. A full cap
                # is status=length; watchdog/cancel are not EOS.
                self.last_eos = result.status == 'ok'
            return result
        finally:
            mlx_lm.stream_generate = original

    def _copy_draft_steps(self, *args, **kwargs):
        iterator = super()._copy_draft_steps(*args, **kwargs)
        try:
            for item in iterator:
                self.last_output_tokens.append(item.token)
                yield item
        finally:
            iterator.close()
