# MLX port of LiquidAI LFM3 (model_type "lfm3") for mlx-lm 0.31.x.
#
# Ported from the checkpoint's own modeling_lfm3.py (LiquidAI/LFM3-1.7B,
# revision 40ebe0aa). No mlx-lm release ships this architecture as of
# 2026-10-27 (latest 0.32.2); this file exists only to benchmark the model.
#
# LFM3 = LFM2 with three changes:
#   - short conv is width 7 (conv_L_cache) instead of 3
#   - attention layers come in two types:
#       full_attention    : rope_theta 1e6, zero-tail partial RoPE (half the
#                           frequencies rotate, the rest stay unrotated)
#       sliding_attention : rope_theta 1e4, full RoPE, 256-token window
#     and every attention output is scaled by a per-head sigmoid gate
#   - sandwich norms: RMSNorm after the operator and after the FFN
#
#   x ─► operator_norm ─► conv | attn ─► post_operator_norm ─► (+x) = h
#   h ─► ffn_norm ─► SwiGLU ─► post_ffn_norm ─► (+h)
#
# Sliding layers keep a plain KVCache and get a windowed mask instead of a
# RotatingKVCache: exact semantics, trimmable, and the extra keys cost
# ~10 KB per token across the five sliding layers.

from dataclasses import dataclass
from typing import Any, List, Optional

import mlx.core as mx
import mlx.nn as nn

from .activations import swiglu
from .base import (
    BaseModelArgs,
    create_attention_mask,
    create_ssm_mask,
    scaled_dot_product_attention,
)
from .cache import ArraysCache, KVCache

FULL = "full_attention"
SLIDING = "sliding_attention"
CONV = "conv"

# Wavelength for an unrotated RoPE pair: position / 1e30 is 0 for any context.
UNROTATED_WAVELENGTH = 1e30


@dataclass
class ModelArgs(BaseModelArgs):
    model_type: str
    vocab_size: int
    hidden_size: int
    intermediate_size: int
    num_hidden_layers: int
    num_attention_heads: int
    num_key_value_heads: int
    head_dim: int
    norm_eps: float
    conv_bias: bool
    conv_L_cache: int
    layer_types: List[str]
    rope_parameters: dict
    sliding_window: int = 256
    use_sandwich_norm: bool = True
    tie_word_embeddings: bool = True


def _rope_wavelengths(params: dict, head_dim: int) -> mx.array:
    """Wavelengths for mx.fast.rope over the whole head (rotate-half pairs
    i and i + head_dim/2).

    The first partial_rotary_factor * head_dim / 2 pairs follow the FULL head
    dimension's progression; the rest do not rotate. Example, head_dim 128,
    factor 0.5: pairs 0..31 rotate at theta^(2i/128), pairs 32..63 stay put.
    """
    base = params["rope_theta"]
    angles = int(params.get("partial_rotary_factor", 1.0) * head_dim) // 2
    rotated = base ** (mx.arange(0, 2 * angles, 2, dtype=mx.float32) / head_dim)
    still = mx.full((head_dim // 2 - angles,), UNROTATED_WAVELENGTH, mx.float32)
    return mx.concatenate([rotated, still])


class Attention(nn.Module):
    def __init__(self, args: ModelArgs, layer_type: str):
        super().__init__()
        dim = args.hidden_size
        self.n_heads = args.num_attention_heads
        self.n_kv_heads = args.num_key_value_heads
        self.head_dim = args.head_dim
        self.scale = self.head_dim**-0.5

        self.q_proj = nn.Linear(dim, self.n_heads * self.head_dim, bias=False)
        self.k_proj = nn.Linear(dim, self.n_kv_heads * self.head_dim, bias=False)
        self.v_proj = nn.Linear(dim, self.n_kv_heads * self.head_dim, bias=False)
        self.o_proj = nn.Linear(self.n_heads * self.head_dim, dim, bias=False)
        self.q_norm = nn.RMSNorm(self.head_dim, eps=args.norm_eps)
        self.k_norm = nn.RMSNorm(self.head_dim, eps=args.norm_eps)
        self.gate_proj = nn.Linear(dim, self.n_heads, bias=False)

        # Underscore: not a parameter, never loaded or saved.
        self._wavelengths = _rope_wavelengths(
            args.rope_parameters[layer_type], self.head_dim
        )

    def _rope(self, x: mx.array, offset: int) -> mx.array:
        return mx.fast.rope(
            x,
            self.head_dim,
            traditional=False,
            base=None,
            scale=1.0,
            offset=offset,
            freqs=self._wavelengths,
        )

    def __call__(self, x, mask=None, cache=None):
        B, L, _ = x.shape
        queries = self.q_norm(self.q_proj(x).reshape(B, L, self.n_heads, -1))
        keys = self.k_norm(self.k_proj(x).reshape(B, L, self.n_kv_heads, -1))
        values = self.v_proj(x).reshape(B, L, self.n_kv_heads, -1)
        queries = queries.transpose(0, 2, 1, 3)
        keys = keys.transpose(0, 2, 1, 3)
        values = values.transpose(0, 2, 1, 3)

        offset = cache.offset if cache is not None else 0
        queries = self._rope(queries, offset)
        keys = self._rope(keys, offset)
        if cache is not None:
            keys, values = cache.update_and_fetch(keys, values)

        output = scaled_dot_product_attention(
            queries, keys, values, cache=cache, scale=self.scale, mask=mask
        )

        # Per-head sigmoid gate on the attention output, before o_proj.
        gate = mx.sigmoid(self.gate_proj(x))[..., None]
        output = output.transpose(0, 2, 1, 3) * gate
        return self.o_proj(output.reshape(B, L, -1))


class ShortConv(nn.Module):
    """LFM2's gated depthwise causal conv; only the width differs."""

    def __init__(self, args: ModelArgs):
        super().__init__()
        self.hidden_size = args.hidden_size
        self.L_cache = args.conv_L_cache
        self.conv = nn.Conv1d(
            in_channels=args.hidden_size,
            out_channels=args.hidden_size,
            kernel_size=self.L_cache,
            groups=args.hidden_size,
            bias=args.conv_bias,
        )
        self.in_proj = nn.Linear(
            args.hidden_size, 3 * args.hidden_size, bias=args.conv_bias
        )
        self.out_proj = nn.Linear(
            args.hidden_size, args.hidden_size, bias=args.conv_bias
        )

    def __call__(self, x, mask=None, cache=None):
        B, C, x = mx.split(self.in_proj(x), 3, axis=-1)
        Bx = B * x
        if mask is not None:
            Bx = mx.where(mask[..., None], Bx, 0)

        if cache is None:
            Bx = mx.pad(Bx, [(0, 0), (self.L_cache - 1, 0), (0, 0)])
            return self.out_proj(C * self.conv(Bx))

        # The cache holds the last L_cache - 1 gated inputs.
        state = cache[0]
        if state is None:
            state = mx.zeros(
                (Bx.shape[0], self.L_cache - 1, self.hidden_size), dtype=Bx.dtype
            )
        Bx = mx.concatenate([state, Bx], axis=1)
        n_keep = self.L_cache - 1
        t = x.shape[1]
        if cache.lengths is not None:
            ends = mx.clip(cache.lengths, 0, t)
            positions = (ends[:, None] + mx.arange(n_keep))[..., None]
            cache[0] = mx.take_along_axis(Bx, positions, axis=1)
        else:
            cache[0] = Bx[:, -n_keep:, :]
        cache.advance(t)
        return self.out_proj(C * self.conv(Bx))


class MLP(nn.Module):
    def __init__(self, args: ModelArgs):
        super().__init__()
        self.w1 = nn.Linear(args.hidden_size, args.intermediate_size, bias=False)
        self.w3 = nn.Linear(args.hidden_size, args.intermediate_size, bias=False)
        self.w2 = nn.Linear(args.intermediate_size, args.hidden_size, bias=False)

    def __call__(self, x):
        return self.w2(swiglu(self.w1(x), self.w3(x)))


class DecoderLayer(nn.Module):
    def __init__(self, args: ModelArgs, layer_type: str):
        super().__init__()
        self.layer_type = layer_type
        self.is_attention_layer = layer_type != CONV
        if self.is_attention_layer:
            self.self_attn = Attention(args, layer_type)
        else:
            self.conv = ShortConv(args)
        self.feed_forward = MLP(args)
        self.operator_norm = nn.RMSNorm(args.hidden_size, eps=args.norm_eps)
        self.ffn_norm = nn.RMSNorm(args.hidden_size, eps=args.norm_eps)
        self.use_sandwich_norm = args.use_sandwich_norm
        if args.use_sandwich_norm:
            self.post_operator_norm = nn.RMSNorm(args.hidden_size, eps=args.norm_eps)
            self.post_ffn_norm = nn.RMSNorm(args.hidden_size, eps=args.norm_eps)

    def __call__(self, x, mask=None, cache=None):
        operator = self.self_attn if self.is_attention_layer else self.conv
        r = operator(self.operator_norm(x), mask=mask, cache=cache)
        if self.use_sandwich_norm:
            r = self.post_operator_norm(r)
        h = x + r

        f = self.feed_forward(self.ffn_norm(h))
        if self.use_sandwich_norm:
            f = self.post_ffn_norm(f)
        return h + f


class Lfm3Model(nn.Module):
    def __init__(self, args: ModelArgs):
        super().__init__()
        self.args = args
        self.embed_tokens = nn.Embedding(args.vocab_size, args.hidden_size)
        self.layers = [DecoderLayer(args, t) for t in args.layer_types]
        self.embedding_norm = nn.RMSNorm(args.hidden_size, eps=args.norm_eps)

        # One representative layer per type builds that type's mask.
        types = args.layer_types
        self._first = {t: types.index(t) for t in (FULL, SLIDING, CONV) if t in types}

    def __call__(self, inputs, cache=None, input_embeddings=None):
        h = input_embeddings if input_embeddings is not None else self.embed_tokens(inputs)
        if cache is None:
            cache = [None] * len(self.layers)

        masks = {}
        if FULL in self._first:
            masks[FULL] = create_attention_mask(h, cache[self._first[FULL]])
        if SLIDING in self._first:
            masks[SLIDING] = create_attention_mask(
                h, cache[self._first[SLIDING]], window_size=self.args.sliding_window
            )
        if CONV in self._first:
            masks[CONV] = create_ssm_mask(h, cache[self._first[CONV]])

        for layer, c in zip(self.layers, cache):
            h = layer(h, masks[layer.layer_type], cache=c)
        return self.embedding_norm(h)


class Model(nn.Module):
    def __init__(self, args: ModelArgs):
        super().__init__()
        self.args = args
        self.model_type = args.model_type
        self.model = Lfm3Model(args)

    def __call__(self, inputs, cache=None, input_embeddings=None):
        out = self.model(inputs, cache, input_embeddings)
        return self.model.embed_tokens.as_linear(out)

    def sanitize(self, weights):
        """Accept both the original HF names and Liquid's MLX export, which
        nests everything under ``language_model.``; torch conv weights are
        (out, 1, k) and MLX wants (out, k, 1)."""
        sanitized = {}
        for name, param in weights.items():
            if name.startswith("language_model."):
                name = name[len("language_model."):]
            if name == "lm_head.weight":
                continue
            if name.endswith("conv.conv.weight") and param.shape[-1] > param.shape[1]:
                param = param.transpose(0, 2, 1)
            sanitized[name] = param
        return sanitized

    @property
    def layers(self):
        return self.model.layers

    def make_cache(self):
        return [
            KVCache() if layer.is_attention_layer else ArraysCache(size=1)
            for layer in self.layers
        ]
