"""Unit tests for the local faster-whisper transcription path.

These never download weights: faster_whisper.WhisperModel and the ffmpeg-based
audio prep are mocked, so we only exercise our seconds->ms conversion and the
duck-typed transcript object's compatibility with the existing pipeline helpers.
"""

import json
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

from src import video_utils


class _FakeWord:
    def __init__(self, word, start, end, probability=None):
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability


class _FakeSegment:
    def __init__(self, words):
        self.words = words


class _FakeWhisperModel:
    """Stands in for faster_whisper.WhisperModel; records constructor args."""

    last_init = None

    def __init__(self, model_size, device=None, compute_type=None):
        type(self).last_init = (model_size, device, compute_type)

    def transcribe(self, audio_path, word_timestamps=False):
        segments = [
            _FakeSegment(
                [
                    _FakeWord("Hello", 0.0, 0.5, probability=0.9),
                    _FakeWord(" world.", 0.5, 1.25, probability=None),
                ]
            ),
            _FakeSegment(
                [
                    _FakeWord("  ", 1.25, 1.30, probability=0.8),  # whitespace-only -> dropped
                    _FakeWord("Again", 1.30, 2.0, probability=0.95),
                ]
            ),
        ]
        return iter(segments), object()


@pytest.fixture
def fake_faster_whisper(monkeypatch):
    """Inject a fake `faster_whisper` module so the inline import resolves."""
    module = types.ModuleType("faster_whisper")
    module.WhisperModel = _FakeWhisperModel
    monkeypatch.setitem(sys.modules, "faster_whisper", module)
    _FakeWhisperModel.last_init = None
    return module


def test_whisper_transcript_seconds_to_ms_and_pipeline_compatibility(
    tmp_path, fake_faster_whisper
):
    video_path = tmp_path / "clip.mp4"
    video_path.write_bytes(b"")

    # Avoid invoking ffmpeg; return a dummy audio path.
    audio_path = tmp_path / "clip.audio.mp3"
    audio_path.write_bytes(b"")

    with patch.object(
        video_utils, "_prepare_audio_for_transcription", return_value=audio_path
    ):
        result = video_utils.get_video_transcript_whisper(video_path, model_size="small")

    # Model constructed with our size, cpu, int8.
    assert _FakeWhisperModel.last_init == ("small", "cpu", "int8")

    # Output is the formatted [MM:SS - MM:SS] text shape the AI analysis expects.
    assert result
    for line in result.splitlines():
        assert line.startswith("[")
        assert "] " in line

    # The cache was written with the same schema the AssemblyAI path produces.
    cache_path = video_path.with_suffix(".transcript_cache.json")
    payload = json.loads(cache_path.read_text())
    assert payload["version"] == video_utils.TRANSCRIPT_CACHE_SCHEMA_VERSION
    assert payload["utterances"] == []
    assert payload["text"] == "Hello world. Again"

    words = payload["words"]
    # Whitespace-only token dropped -> 3 real words.
    assert [w["text"] for w in words] == ["Hello", "world.", "Again"]

    # seconds -> milliseconds conversion (rounded ints).
    assert words[0]["start"] == 0 and words[0]["end"] == 500
    assert words[1]["start"] == 500 and words[1]["end"] == 1250
    assert words[2]["start"] == 1300 and words[2]["end"] == 2000

    # probability -> confidence, with default 1.0 when None.
    assert words[0]["confidence"] == pytest.approx(0.9)
    assert words[1]["confidence"] == 1.0
    # speaker is always present (None) so _serialize_transcript_word never raises.
    assert all(w["speaker"] is None for w in words)


def test_whisper_transcript_object_serializes_via_existing_helpers():
    """The duck-typed objects must satisfy _serialize_transcript_word and
    format_transcript_for_analysis without any code changes there."""
    word = video_utils._WhisperWord("Hi", start=250, end=750, confidence=0.42)
    serialized = video_utils._serialize_transcript_word(word)
    assert serialized == {
        "text": "Hi",
        "start": 250,
        "end": 750,
        "confidence": 0.42,
        "speaker": None,
    }

    transcript = video_utils._WhisperTranscript([word], "Hi")
    lines = video_utils.format_transcript_for_analysis(transcript)
    assert lines == ["[00:00 - 00:00] Hi"]
