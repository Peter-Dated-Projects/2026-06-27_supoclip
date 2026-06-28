# Handoff: Local Whisper Transcription and claude-cli LLM Provider

This document describes two independent features added to the backend so the app
can run with zero paid API keys when self-hosted natively:

1. Local transcription via `faster-whisper` (no AssemblyAI key required).
2. A `claude-cli` LLM provider that drives a locally installed Claude Code
   `claude` binary using its own subscription auth (no `ANTHROPIC_API_KEY`, no
   per-token billing).

The two features are orthogonal: you can enable either, both, or neither. The
default configuration is unchanged (AssemblyAI for transcription, an API-key LLM
provider for analysis), so existing deployments behave exactly as before.

## TL;DR

| Feature | Turn it on with | Replaces | Works in Docker? |
|---|---|---|---|
| Local Whisper transcription | `TRANSCRIPTION_PROVIDER=whisper` | AssemblyAI transcription | Yes |
| claude-cli LLM provider | `LLM=claude-cli:<model>` | An API-key LLM provider | No (self-host/native only) |

Both default to the previous behavior when unset: `TRANSCRIPTION_PROVIDER`
defaults to `assemblyai`, and `LLM` keeps using whatever API-key provider it
already used.

---

## Feature 1: Local transcription via faster-whisper

### What changed

A second transcription backend was added alongside AssemblyAI. When enabled, the
app transcribes audio locally with `faster-whisper` (a CPU-friendly Whisper
reimplementation) instead of calling AssemblyAI. This removes the
`ASSEMBLY_AI_API_KEY` requirement for transcription and makes transcription free.

The key design choice was to make the local path produce output that is
shape-compatible with the AssemblyAI path so that nothing downstream had to
branch. The Whisper code adapts its results into small duck-typed objects whose
attributes match what the AssemblyAI objects expose, which lets it reuse the same
caching, formatting, and `.transcript_cache.json` schema with no changes
elsewhere.

### Files touched

| File | Change |
|---|---|
| `backend/src/config.py` | New `TRANSCRIPTION_PROVIDER` env var, normalized by `_normalize_transcription_provider` (accepts `whisper`, otherwise falls back to `assemblyai`). Stored as `config.transcription_provider`. Standardized on `WHISPER_MODEL_SIZE`, stored as `config.whisper_model_size`, with `WHISPER_MODEL` kept as a back-compat fallback and a final default of `base`. |
| `backend/src/video_utils.py` | New `get_video_transcript_whisper(video_path, model_size)`. Reuses `_prepare_audio_for_transcription` (16 kHz mono), runs `faster_whisper.WhisperModel(model_size, device="cpu", compute_type="int8")` with `word_timestamps=True`, and adapts output into duck-typed `_WhisperWord` / `_WhisperTranscript` objects. It then reuses `cache_transcript_data` and `format_transcript_for_analysis`, exactly like the AssemblyAI path. |
| `backend/src/services/video_service.py` | `generate_transcript` now routes on provider: if `transcription_provider == "whisper"` it calls `get_video_transcript_whisper` (imported from `..video_utils`); otherwise it uses the existing AssemblyAI path. In fast processing mode the Whisper path drops the model to `base`, mirroring how the AssemblyAI path drops to its lighter speech model. |
| `backend/pyproject.toml` | Replaced the previous `openai-whisper` / `whisper` dependency with `faster-whisper>=1.0.0`. |
| `backend/Dockerfile` | Sets `HF_HOME=/app/.cache/huggingface` and `XDG_CACHE_HOME=/app/.cache`, and creates the cache directory, so model weights download into a known location. |
| `docker-compose.yml` | Adds a `whisper_models` named volume mounted at `/app/.cache` on both `backend` and `worker`, plus the `TRANSCRIPTION_PROVIDER`, `WHISPER_MODEL_SIZE`, `HF_HOME`, and `XDG_CACHE_HOME` env vars. |

### How to configure

| Variable | Default | Purpose |
|---|---|---|
| `TRANSCRIPTION_PROVIDER` | `assemblyai` | Set to `whisper` to transcribe locally; any other value falls back to AssemblyAI. |
| `WHISPER_MODEL_SIZE` | `base` (app default); `medium` in docker-compose | Whisper model size: `tiny`, `base`, `small`, `medium`, or `large`. Larger is more accurate and slower. |
| `WHISPER_MODEL` | unset | Back-compat fallback for `WHISPER_MODEL_SIZE`; prefer `WHISPER_MODEL_SIZE` for new setups. |

Native local example:

```bash
export TRANSCRIPTION_PROVIDER=whisper
export WHISPER_MODEL_SIZE=base
```

Docker: set `TRANSCRIPTION_PROVIDER=whisper` (and optionally `WHISPER_MODEL_SIZE`)
in your root `.env`, then restart the stack. The `whisper_models` volume keeps the
downloaded weights across restarts.

### How to verify

- Run the unit tests: `backend/tests/unit/test_whisper_transcription.py`.
- End to end: set `TRANSCRIPTION_PROVIDER=whisper`, process a short video, and
  confirm a clip is produced with synced subtitles. On the first run with a model
  size you have not used before, expect a one-time weight download.
- Confirm the cache: a `.transcript_cache.json` is written next to the source and
  has the same schema as the AssemblyAI path (so a cached run skips
  re-transcription).

### Gotchas

- Timestamp units. `faster-whisper` emits timestamps in SECONDS. The downstream
  pipeline (and the AssemblyAI path) expects MILLISECONDS, so
  `get_video_transcript_whisper` converts seconds to ms when building
  `_WhisperWord` objects. If you touch that code, keep the conversion or all clip
  timings and subtitles will be off by 1000x.
- No utterances. The duck-typed `_WhisperTranscript` sets `utterances = []` on
  purpose, which makes `format_transcript_for_analysis` fall back to grouping
  words. Do not "fix" this by synthesizing utterances; the empty list is what
  keeps the two providers interchangeable.
- First-run download. Weights are fetched from HuggingFace on first use. In Docker
  this is why the `whisper_models` volume exists. Weights are not baked into the
  image, which keeps the image small and lets the model size stay configurable; the
  tradeoff is a one-time download (and a mid-job download if the volume is missing).
- CPU only. The model runs with `device="cpu"` and `compute_type="int8"`. Large
  model sizes on CPU can be slow on long videos; pick a smaller size if latency
  matters.

---

## Feature 2: claude-cli LLM provider

### What changed

A new LLM provider, `claude-cli`, lets the analysis step run against a locally
installed Claude Code `claude` binary in headless mode, using that binary's own
auth (subscription / OAuth login). This means no `ANTHROPIC_API_KEY` and no
per-token billing for the segment-selection step.

Unlike every other provider, `claude-cli` does not go through the pydantic-ai
`Agent`. It shells out to the `claude` CLI, parses the JSON envelope the CLI
returns, strips any markdown code fences, and parses the inner JSON into the same
`TranscriptAnalysis` model the Agent path produces.

### Files touched

| File | Change |
|---|---|
| `backend/src/ai.py` | `claude-cli` added to `SUPPORTED_LLM_PROVIDERS`. Config validation in `_get_missing_llm_key_error`: for `claude-cli` it requires `shutil.which("claude")` (the binary on PATH) instead of an API key. New `run_claude_cli_analysis(prompt, model)` (synchronous; called via `asyncio.to_thread`) runs `claude -p <prompt> --output-format json --model <model>` with a 900s timeout. New `_extract_claude_cli_result_text` pulls the reply out of the CLI's JSON envelope (prefers `result`, falls back to text/response/output, fails loudly on unexpected shape). New `_strip_markdown_code_fences` cleans the inner payload. `get_most_relevant_parts_by_transcript` branches on provider: the `claude-cli` path bypasses the Agent (and so re-runs the config check manually) and calls `run_claude_cli_analysis`; all other providers use the existing Agent path. |
| `backend/src/ai.py` (`ViralityAnalysis`) | New `_coerce_hook_type` field validator (`mode="before"`) that maps any off-enum or free-form `hook_type` value to `none` instead of failing. This exists because the claude-cli path parses free-form model JSON rather than schema-constrained Agent output. |

### How to configure

| Variable | Value | Purpose |
|---|---|---|
| `LLM` | `claude-cli:<model>` | Selects the provider and model, for example `claude-cli:claude-opus-4-8`. |

Requirements:

- The `claude` CLI must be installed and on `PATH` (`which claude` must succeed).
- The CLI must already be authenticated (run it once interactively to log in).
- No `ANTHROPIC_API_KEY` is needed; the CLI uses its own auth.

Example:

```bash
export LLM=claude-cli:claude-opus-4-8
which claude   # must print a path
```

### How to verify

- Run the unit tests: `backend/tests/unit/test_ai_claude_cli.py`.
- Misconfiguration check: with `LLM=claude-cli:...` set but `claude` not on PATH,
  the backend should report a clear "claude CLI was not found on PATH" error rather
  than failing obscurely.
- End to end (native only): set `LLM=claude-cli:<model>`, process a short video,
  and confirm segments are selected and clips are produced.

### Gotchas

- Self-host / native only. The `claude` binary is not present inside the Docker
  containers, so `claude-cli` does NOT work in the Docker stack. Hosted or
  Docker-based deployments must use an API-key LLM provider
  (`google-gla:*`, `openai:*`, `anthropic:*`, or `ollama:*`). See the section
  below.
- Free-form JSON. Because this path parses model output that is not
  schema-constrained, the model can return values the strict schema would reject.
  The `_coerce_hook_type` validator absorbs off-enum `hook_type` values so a single
  odd field does not fail the whole job. If you add new constrained enums to the
  analysis model, consider whether they need similar coercion on the claude-cli
  path.
- Timeout. `run_claude_cli_analysis` uses a 900-second subprocess timeout. Very
  long transcripts or a slow CLI run can hit it; that surfaces as a failed
  analysis step.
- Envelope shape. `_extract_claude_cli_result_text` deliberately fails loudly if
  the CLI's JSON envelope does not have a recognizable result field. A future
  `claude` CLI version that changes its `--output-format json` shape would break
  here, which is intentional (loud failure over silent wrong output).

---

## Self-host vs Docker

| Combination | Whisper transcription | claude-cli LLM |
|---|---|---|
| Native / self-host (no containers) | Supported | Supported |
| Docker stack | Supported (weights persist in the `whisper_models` volume) | NOT supported (no `claude` binary in the container) |

Practical guidance:

- Fully free, native setup: `TRANSCRIPTION_PROVIDER=whisper` plus
  `LLM=claude-cli:<model>` removes both the AssemblyAI key and the LLM API key.
- Docker setup: you can still drop the AssemblyAI key by using Whisper, but you
  must keep an API-key LLM provider for analysis.

## Tests

- `backend/tests/unit/test_whisper_transcription.py` covers the local Whisper
  transcription path.
- `backend/tests/unit/test_ai_claude_cli.py` covers the claude-cli provider
  (config validation, envelope parsing, and analysis).

Run them with the standard backend test command (`make test-backend`, or
`pytest` from `backend/`).
