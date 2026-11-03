"""Bark 3.0 on the Apple Neural Engine: Core ML encoder (fixed 15 s windows, exact weights) + numpy TDT decoder.

  pip install coremltools numpy soundfile soxr
  python bark_coreml.py recording.wav                 # encoder on the Neural Engine
  python bark_coreml.py recording.wav --units gpu     # or the GPU / cpu
  python bark_coreml.py recording.wav --bench 20      # time 20 repeats

Clips up to 15 s are read in one pass by the smallest window that holds them; longer audio is cut at pauses into pieces of
at most 15 s. 0.25 s of silence is added in front of each piece (the evaluated setting)."""
import argparse, json, os, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOWS = (8, 15)
SR, HOP, NFFT, WIN = 16000, 160, 512, 400


class Frontend:
    """numpy port of transformers' ParakeetFeatureExtractor (preemphasis, centred STFT, slaney mel, log, per-utterance norm)."""
    def __init__(self, mel_filters):
        self.mel = mel_filters.astype(np.float32)                                  # [128, 257]
        w = np.hanning(WIN)                                                         # symmetric, = torch.hann_window(periodic=False)
        self.window = np.zeros(NFFT, np.float32); off = (NFFT - WIN) // 2; self.window[off:off + WIN] = w

    def __call__(self, x):
        x = np.asarray(x, np.float32)
        L = len(x)
        x = np.concatenate([x[:1], x[1:] - 0.97 * x[:-1]])
        xp = np.pad(x, (NFFT // 2, NFFT // 2))
        n = 1 + (len(xp) - NFFT) // HOP
        idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
        spec = np.fft.rfft(xp[idx] * self.window, axis=1)
        power = (spec.real ** 2 + spec.imag ** 2).astype(np.float32)               # [n, 257]
        feats = np.log(power @ self.mel.T + 2 ** -24)                               # [n, 128]
        valid = L // HOP
        v = feats[:valid]
        mean = v.mean(0); std = np.sqrt(((v - mean) ** 2).sum(0) / max(1, valid - 1))
        feats = (feats - mean) / (std + 1e-5)
        feats[valid:] = 0
        return feats.astype(np.float32), valid


def enc_len(n):
    for _ in range(3): n = (n - 1) // 2 + 1                                         # 3 stride-2 convs, k=3, pad=1
    return n


class Decoder:
    """TDT greedy decoding on the CPU, identical to transformers' ParakeetForTDT.generate (batch 1)."""
    def __init__(self, npz, vocab):
        z = np.load(npz)
        W = lambda k: (z[k + ".q"].astype(np.float32) * z[k + ".s"].astype(np.float32)[:, None]) if k + ".q" in z else z[k].astype(np.float32)
        self.emb = W("decoder.embedding.weight")
        self.lstm = [(W(f"decoder.lstm.weight_ih_l{i}"), W(f"decoder.lstm.weight_hh_l{i}"),
                      W(f"decoder.lstm.bias_ih_l{i}") + W(f"decoder.lstm.bias_hh_l{i}")) for i in range(2)]
        self.proj_w, self.proj_b = W("decoder.decoder_projector.weight"), W("decoder.decoder_projector.bias")
        self.head_w, self.head_b = W("joint.head.weight"), W("joint.head.bias")
        self.mel = z["mel_filters"]
        self.V = vocab["vocab_size"]; self.blank = vocab["blank_id"]; self.durations = vocab["durations"]
        self.max_sym = vocab["max_symbols_per_step"]
        self.pieces = vocab["pieces"]; self.special = set(vocab["special_ids"])

    def _step(self, tok, state):
        x = self.emb[tok]; new = []
        for (wi, wh, b), (h, c) in zip(self.lstm, state):
            g = wi @ x + wh @ h + b
            i, f, gg, o = np.split(g, 4)
            i, f, o = 1 / (1 + np.exp(-i)), 1 / (1 + np.exp(-f)), 1 / (1 + np.exp(-o))
            c = f * c + i * np.tanh(gg); h = o * np.tanh(c); new.append((h, c)); x = h
        return self.proj_w @ x + self.proj_b, new

    def decode(self, enc):                                                          # enc [T, 640] (projected)
        T = enc.shape[0]; H = self.emb.shape[1]
        state = [(np.zeros(H, np.float32), np.zeros(H, np.float32)) for _ in range(2)]
        dec, state = self._step(self.blank, state)
        t, out, sym = 0, [], 0
        while t < T:
            logits = self.head_w @ np.maximum(enc[t] + dec, 0) + self.head_b
            tok = int(np.argmax(logits[:self.V])); d = self.durations[int(np.argmax(logits[self.V:]))]
            if tok == self.blank:
                t += max(d, 1); sym = 0
            else:
                out.append(tok); dec, state = self._step(tok, state)
                sym += 1
                if d == 0 and sym >= self.max_sym: d = 1
                if d > 0: sym = 0
                t += d
        return out

    def detok(self, ids):
        return "".join(self.pieces[i] for i in ids if i not in self.special and i < len(self.pieces)).replace("▁", " ").strip()


def segments(x, max_s=15.0, min_s=5.0):
    """Cut audio longer than 15 s at pauses: within each [min_s, max_s] stretch, cut in the middle of the quietest
    200 ms span (smoothed 10 ms energy), so no word is split."""
    if len(x) <= int(max_s * SR): return [x]
    fr = SR // 100                                                                  # 10 ms frames
    e = np.convolve((x[: len(x) // fr * fr].reshape(-1, fr) ** 2).mean(1), np.ones(20) / 20, mode="same")
    out, start = [], 0
    while len(x) - start > max_s * SR:
        lo, hi = (start + int(min_s * SR)) // fr, (start + int(max_s * SR)) // fr
        cut = (lo + int(np.argmin(e[lo:hi]))) * fr + fr // 2
        out.append(x[start:cut]); start = cut
    out.append(x[start:])
    return out


class Transcriber:
    def __init__(self, folder=HERE, units="ane", encoder=None, pad_s=0.25):
        self.vocab = json.load(open(f"{folder}/vocab.json"))
        self.dec = Decoder(f"{folder}/decoder.npz", self.vocab)
        self.front = Frontend(self.dec.mel)
        self.pad = int(pad_s * SR)
        if encoder is None:
            import coremltools as ct
            cu = {"ane": ct.ComputeUnit.CPU_AND_NE, "gpu": ct.ComputeUnit.CPU_AND_GPU, "cpu": ct.ComputeUnit.CPU_ONLY,
                  "all": ct.ComputeUnit.ALL}[units]
            self.enc = {w: ct.models.MLModel(f"{folder}/BarkEncoder.mlpackage", compute_units=cu, function_name=f"w{w}")
                        for w in WINDOWS}
            self.run = lambda w, f, m: self.enc[w].predict({"features": f.astype(np.float16), "mask": m})["encoded"]
        else:
            self.run = encoder                                                       # (window, feats, mask) -> [1, T', 640]

    def _piece(self, x):
        x = np.concatenate([np.zeros(self.pad, np.float32), x.astype(np.float32)])
        feats, valid = self.front(x)
        w = next(w for w in WINDOWS if len(x) <= w * SR)
        T = w * 100 + 1
        f = np.zeros((1, T, 128), np.float32); f[0, :len(feats)] = feats[:T]
        m = np.zeros((1, T), np.int32); m[0, :valid] = 1
        enc = np.asarray(self.run(w, f, m))[0].astype(np.float32)[:enc_len(valid)]
        if not np.isfinite(enc).all(): raise FloatingPointError("Non-finite Core ML encoder output; stop inference")
        return self.dec.decode(enc)

    def transcribe(self, wave, sr=SR):
        if sr != SR:
            import soxr; wave = soxr.resample(wave, sr, SR)
        return " ".join(self.dec.detok(self._piece(s)) for s in segments(np.asarray(wave, np.float32), max_s=max(WINDOWS) - self.pad / SR)).strip()


if __name__ == "__main__":
    import soundfile as sf
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("audio"); ap.add_argument("--folder", default=HERE); ap.add_argument("--units", default="ane")
    ap.add_argument("--bench", type=int, default=0)
    a = ap.parse_args()
    tr = Transcriber(a.folder, a.units)
    wave, sr = sf.read(a.audio, dtype="float32", always_2d=True); wave = wave.mean(1)
    t0 = time.time(); text = tr.transcribe(wave, sr); first = time.time() - t0
    print(text)
    if a.bench:
        ts = []
        for _ in range(a.bench):
            t0 = time.time(); tr.transcribe(wave, sr); ts.append(time.time() - t0)
        dur = len(wave) / sr; med = float(np.median(ts))
        print(f"audio {dur:.1f} s | first call {first*1000:.0f} ms | median {med*1000:.1f} ms | {med/dur*60000:.1f} ms per audio minute | {dur/med:.0f}x realtime")
