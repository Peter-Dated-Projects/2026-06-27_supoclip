import json
import subprocess
from unittest.mock import patch

import pytest

from src.ai import TranscriptAnalysis, run_claude_cli_analysis


# A representative inner payload the model is expected to return: strict JSON
# matching the TranscriptAnalysis schema.
SAMPLE_INNER = {
    "most_relevant_segments": [
        {
            "start_time": "00:10",
            "end_time": "00:40",
            "text": "This is a strong standalone clip candidate with plenty of words to pass validation.",
            "relevance_score": 0.9,
            "reasoning": "Self-contained hook and payoff grounded in the transcript.",
        }
    ],
    "summary": "A short test summary.",
    "key_topics": ["testing", "claude cli"],
}


def _completed(stdout: str, returncode: int = 0, stderr: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess(
        args=["claude"], returncode=returncode, stdout=stdout, stderr=stderr
    )


def _envelope(result_text: str) -> str:
    # The `claude --output-format json` envelope wraps the assistant reply in `result`.
    return json.dumps({"type": "result", "subtype": "success", "result": result_text})


def test_parses_captured_json_envelope():
    stdout = _envelope(json.dumps(SAMPLE_INNER))
    with patch("src.ai.subprocess.run", return_value=_completed(stdout)) as mock_run:
        analysis = run_claude_cli_analysis("the prompt", "claude-opus-4-8")

    mock_run.assert_called_once()
    called_cmd = mock_run.call_args.args[0]
    assert called_cmd[:2] == ["claude", "-p"]
    assert "--output-format" in called_cmd and "json" in called_cmd
    assert "--model" in called_cmd and "claude-opus-4-8" in called_cmd

    assert isinstance(analysis, TranscriptAnalysis)
    segment = analysis.most_relevant_segments[0]
    assert segment.start_time == "00:10"
    assert segment.end_time == "00:40"
    assert segment.text.startswith("This is a strong standalone clip")


def test_strips_markdown_code_fences_around_result():
    fenced = "```json\n" + json.dumps(SAMPLE_INNER) + "\n```"
    stdout = _envelope(fenced)
    with patch("src.ai.subprocess.run", return_value=_completed(stdout)):
        analysis = run_claude_cli_analysis("p", "m")

    assert analysis.most_relevant_segments[0].end_time == "00:40"


def test_raises_on_nonzero_exit_with_stderr():
    with patch(
        "src.ai.subprocess.run",
        return_value=_completed("", returncode=1, stderr="auth required"),
    ):
        with pytest.raises(RuntimeError, match="auth required"):
            run_claude_cli_analysis("p", "m")


def test_raises_on_missing_binary():
    with patch("src.ai.subprocess.run", side_effect=FileNotFoundError()):
        with pytest.raises(RuntimeError, match="claude` CLI was not found"):
            run_claude_cli_analysis("p", "m")


def test_raises_on_unexpected_envelope_shape():
    stdout = json.dumps({"unexpected": "shape"})
    with patch("src.ai.subprocess.run", return_value=_completed(stdout)):
        with pytest.raises(RuntimeError, match="Unexpected Claude CLI JSON envelope"):
            run_claude_cli_analysis("p", "m")


def test_raises_when_inner_result_is_not_json():
    stdout = _envelope("not json at all")
    with patch("src.ai.subprocess.run", return_value=_completed(stdout)):
        with pytest.raises(RuntimeError, match="not valid TranscriptAnalysis JSON"):
            run_claude_cli_analysis("p", "m")


def test_coerces_off_enum_hook_type_instead_of_failing():
    # The real `claude` CLI returns free-form JSON, where models routinely emit
    # descriptive hook_type values outside the schema literal (e.g. "bold_claim").
    # The CLI path has no validation-retry loop, so these must be coerced to
    # "none" rather than failing the entire job.
    payload = json.loads(json.dumps(SAMPLE_INNER))
    payload["most_relevant_segments"][0]["virality"] = {
        "hook_score": 22,
        "engagement_score": 20,
        "value_score": 18,
        "shareability_score": 19,
        "total_score": 79,
        "hook_type": "contrarian_mistake",
        "virality_reasoning": "Strong contrarian framing.",
    }
    stdout = _envelope(json.dumps(payload))
    with patch("src.ai.subprocess.run", return_value=_completed(stdout)):
        analysis = run_claude_cli_analysis("p", "m")

    assert analysis.most_relevant_segments[0].virality.hook_type == "none"
