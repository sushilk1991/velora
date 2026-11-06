"""No audio models: exact coverage and honest long-transcription failure tests."""
import importlib.util
from pathlib import Path
import numpy as np
import pytest

p = Path(__file__).resolve().parents[1] / 'scripts' / 'benchmark_long_transcription.py'
spec = importlib.util.spec_from_file_location('benchmark_long_transcription', p)
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)

class Track:
    def __init__(self, samples):
        self.samples = np.arange(samples, dtype=np.float32)
    def __len__(self):
        return len(self.samples)
    def read(self, a, z, *, cancel):
        return self.samples[a:z]


def test_exact_audio_seams_and_timestamps():
    track = Track(3 * b.SAMPLE_RATE)
    spans = [(0, b.SAMPLE_RATE), (b.SAMPLE_RATE, len(track))]
    seen = []
    def fake(backend, pcm):
        seen.extend(pcm.astype(int))
        return 'late' if pcm[0] else 'start'
    rows = b.decode_track(track, object(), spans, fake)
    assert seen == list(range(len(track)))
    assert rows[1]['start_ms'] == 1000 and rows[-1]['end_ms'] == 3000
    assert b.clock(rows[1]['start_sample']) == '00:00:01'
    assert [r['text'] for r in rows] == ['start', 'late']


def test_gap_overlap_and_missing_tail_rejected():
    for spans in ([(0, 4), (5, 10)], [(0, 6), (5, 10)], [(0, 9)]):
        with pytest.raises(ValueError):
            b.verify_ranges(spans, 10)


def test_failures_and_empty_spans_are_explicit():
    def fake(backend, pcm):
        if pcm[0] == 0:
            raise RuntimeError('synthetic')
        return ''
    rows = b.decode_track(Track(4), object(), [(0, 2), (2, 4)], fake)
    assert [r['status'] for r in rows] == ['failed', 'empty']
    assert rows[0]['error_type'] == 'RuntimeError'
    assert rows[1]['start_sample'] == 2


def test_real_meeting_caf_loader_and_planner_cpu(tmp_path):
    sf = pytest.importorskip('soundfile')
    path = tmp_path / 'meeting.caf'
    sf.write(str(path), np.zeros(2 * b.SAMPLE_RATE, dtype=np.float32), b.SAMPLE_RATE,
             format='CAF', subtype='PCM_16')
    track = b.load_meeting_media(str(path), meeting_root=tmp_path, cancel=lambda: False)
    try:
        spans = b.plan_meeting_slices(track, b.SAMPLE_RATE, cancel=lambda: False)
        b.verify_ranges(spans, len(track))
        assert len(track) == 2 * b.SAMPLE_RATE
        assert spans == [(0, len(track))]
    finally:
        track.close()


def test_empty_transcription_never_claims_full_coverage():
    assert b.report_status([{'status': 'ok'}, {'status': 'empty'}]) == 'partial'
    assert b.report_status([{'status': 'ok'}, {'status': 'failed'}]) == 'partial'
    assert b.report_status([{'status': 'ok'}, {'status': 'ok'}]) == 'complete'
    assert b.report_status([]) == 'partial'


@pytest.mark.parametrize('changed', ['audio', 'weights', 'source', 'extra_model_file'])
def test_input_identity_detects_changed_decoding_inputs(tmp_path, changed):
    audio = tmp_path / 'audio.caf'; audio.write_bytes(b'audio')
    model = tmp_path / 'snapshot'; model.mkdir()
    weights = model / 'weights.safetensors'; weights.write_bytes(b'weights')
    source = tmp_path / 'stt.py'; source.write_text('original')
    before = b.input_identity(audio, model, [source])
    target = {'audio': audio, 'weights': weights, 'source': source,
              'extra_model_file': model / 'other.safetensors'}[changed]
    target.write_bytes(b'changed')
    assert b.identity_changes(before, b.input_identity(audio, model, [source]))


def test_hf_snapshot_symlinks_are_hashed_by_weight_bytes(tmp_path):
    audio = tmp_path / 'audio.caf'; audio.write_bytes(b'audio')
    blob = tmp_path / 'blob'; blob.write_bytes(b'weights')
    model = tmp_path / 'snapshot'; model.mkdir()
    (model / 'weights.safetensors').symlink_to(blob)
    value = b.input_identity(audio, model, [])
    assert value['model_files_sha256'] == {'weights.safetensors': b.digest(blob)}
    assert not b.identity_changes(value, b.input_identity(audio, model, []))
