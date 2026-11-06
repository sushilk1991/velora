"""Answer-only loss and update-level optimizer safeguards (MLX loaded lazily)."""
import math


def answer_loss(model, batch, lengths):
    import mlx.core as mx
    import mlx.nn as nn
    logits = model(batch[:, :-1])
    targets = batch[:, 1:]
    steps = mx.arange(1, targets.shape[1] + 1)
    mask = mx.logical_and(steps >= lengths[:, 0:1], steps < lengths[:, 1:])
    tokens = mask.sum()
    loss = (nn.losses.cross_entropy(logits, targets) * mask).astype(mx.float32).sum() / tokens
    return loss, tokens


def schedule_value(step, *, peak, total_updates, warmup_updates, cosine, backend=math):
    """Zero-based update step; warmup reaches peak at warmup_updates."""
    if warmup_updates < 0 or total_updates < 1 or warmup_updates >= total_updates:
        raise ValueError('warmup must be nonnegative and less than optimizer updates')
    if cosine:
        span = max(1, total_updates - 1 - warmup_updates)
        decay = peak * 0.5 * (1 + backend.cos(math.pi * (step - warmup_updates) / span))
    else:
        decay = peak
    if warmup_updates:
        warmup = peak * step / warmup_updates
        value = backend.where(step < warmup_updates, warmup, decay) if hasattr(backend, 'where') else (warmup if step < warmup_updates else decay)
    else:
        value = decay
    # MLX's trainer reads optimizer.learning_rate.item() even before the first
    # accumulated update. Constant schedules must return an MLX scalar too.
    return backend.array(value) if hasattr(backend, 'array') else value


def make_optimizer(learning_rate, max_norm):
    import mlx.optimizers as optim
    class ClippedAdam(optim.Adam):
        def apply_gradients(self, gradients, parameters):
            clipped, _ = optim.clip_grad_norm(gradients, max_norm)
            return super().apply_gradients(clipped, parameters)
    return ClippedAdam(learning_rate=learning_rate)
