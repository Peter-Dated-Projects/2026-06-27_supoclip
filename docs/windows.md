# Running SupoClip on Windows

This guide covers running SupoClip on Windows. The project's main entrypoint,
`frieren.sh`, is a bash script and does not run in native PowerShell, so this page
gives Windows users a clear path. A minimal PowerShell helper, `frieren.ps1`, ships
alongside it for the most-used Docker commands.

Audience: a Windows developer cloning the repo for the first time.

## Which path should I use?

There are two ways to run SupoClip on Windows:

- **Path A - Docker Desktop (recommended).** Everything runs in containers. This
  is the least-friction path and behaves the same as on macOS or Linux.
- **Path B - native Windows dev.** You run the backend, worker, and frontend
  directly on Windows. This is more work and only necessary if you need the
  `claude-cli` LLM provider, which cannot run inside Docker.

**Rule of thumb: use Path A (Docker) unless you specifically need the `claude-cli`
LLM provider.** The `claude` binary is not present inside the containers, so
`claude-cli` only works when the backend runs natively. Local Whisper
transcription (`TRANSCRIPTION_PROVIDER=whisper`), by contrast, works fine in
Docker. See
[Handoff: Local Whisper and claude-cli provider](./handoff-local-whisper-and-claude-cli.md)
for the full details on both providers.

The stack is five services: Frontend (Next.js, port 3107), Backend API (FastAPI,
port 8000, docs at `/docs`), an ARQ worker, PostgreSQL (port 5432), and Redis
(port 6379).

---

## Path A: Docker Desktop on Windows (recommended)

This runs the whole stack in containers via Docker Desktop's WSL2 backend. It is
OS-agnostic and the least-friction option.

### 1. Install Docker Desktop with WSL2

1. Install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).
2. During or after install, enable the **WSL2 backend** (Docker Desktop ->
   Settings -> General -> "Use the WSL 2 based engine"). Docker Desktop will
   prompt you to install WSL2 if it is missing.
3. Confirm Docker works by opening PowerShell and running `docker compose version`.

### 2. Clone and configure

```powershell
git clone <your-fork-or-repo-url> supoclip
cd supoclip
Copy-Item .env.example .env
```

Open `.env` in an editor and fill in your keys. For the default configuration you
need `ASSEMBLY_AI_API_KEY` (transcription) and one LLM key, set via `LLM` plus the
matching key (`GOOGLE_API_KEY`, `OPENAI_API_KEY`, or `ANTHROPIC_API_KEY`). See
[Configuration](./configuration.md) for the full list.

To avoid paying for transcription, set `TRANSCRIPTION_PROVIDER=whisper` in `.env`
to transcribe locally with faster-whisper (CPU). This works in Docker; the model
weights download on first run and persist in the `whisper_models` Docker volume.

Note: `claude-cli` for the LLM does **not** work in Docker. In the Docker stack you
must use an API-key LLM provider (`google-gla:*`, `openai:*`, `anthropic:*`, or
`ollama:*`).

### 3. Start the stack

Using the PowerShell helper:

```powershell
.\frieren.ps1 up
```

Or with Docker directly:

```powershell
docker compose up -d --build
```

When it is up:

- Frontend: http://localhost:3107
- Backend API: http://localhost:8000 (docs at http://localhost:8000/docs)

### 4. Common commands

```powershell
.\frieren.ps1 status          # show container status
.\frieren.ps1 logs backend    # tail one service's logs
.\frieren.ps1 logs            # tail all logs
.\frieren.ps1 down            # stop everything
```

`frieren.ps1` is a thin convenience wrapper over `docker compose` (just `up`,
`down`, `logs`, `status`, `help`). For anything beyond that, run `docker compose`
directly or use `frieren.sh` from WSL2 / Git Bash.

---

## Path B: native Windows dev (needed for claude-cli)

Use this only if you need the `claude-cli` LLM provider, which requires the backend
to run natively (the `claude` binary must be on `PATH`). It is more involved than
Path A.

Even in this path, the simplest way to get PostgreSQL and Redis is to run just
those two in Docker (see step 4) and run the app processes natively against them.
Redis has no well-maintained native Windows build, so running it in Docker (or
WSL2) is recommended.

### 1. Install the backend toolchain

- **uv** (Python package manager used by the backend):
  `winget install astral-sh.uv` (or the install script from the uv docs).
- **Python 3.11+** (uv can install/manage this for you).
- **ffmpeg** (required for video/audio processing):
  `winget install Gyan.FFmpeg` (or `choco install ffmpeg`). After installing,
  open a new shell and confirm `ffmpeg -version` resolves on `PATH`.

### 2. Install the backend dependencies

```powershell
cd backend
uv venv
uv sync
```

### 3. Install the frontend toolchain

- **Node.js** (LTS).
- **pnpm** (the frontend's declared package manager): `npm install -g pnpm`, or
  `corepack enable` then `corepack prepare pnpm@latest --activate`.

```powershell
cd frontend
pnpm install
```

### 4. Run PostgreSQL and Redis (via Docker)

Run just the two infrastructure services in Docker while everything else runs
natively:

```powershell
docker compose up -d postgres redis
```

When the app runs natively but talks to these Docker containers, use `localhost`
in your `.env`:

```bash
DATABASE_URL=postgresql+asyncpg://supoclip:supoclip_password@localhost:5432/supoclip
REDIS_HOST=localhost
REDIS_PORT=6379
```

(The default credentials and database name come from `docker-compose.yml`:
user `supoclip`, password `supoclip_password`, database `supoclip`.)

### 5. Configure claude-cli (the reason for this path)

1. Install Claude Code so the `claude` binary is available.
2. Run `claude` once interactively to authenticate (it uses its own subscription /
   OAuth login - no `ANTHROPIC_API_KEY` needed).
3. Confirm it is on `PATH`:

   ```powershell
   where claude
   ```

   This must print a path. The backend checks for `claude` on `PATH` and will
   report a clear "claude CLI was not found on PATH" error if it is missing.
4. Set the LLM in `.env`:

   ```bash
   LLM=claude-cli:claude-opus-4-8
   ```

For transcription, you can pair this with local Whisper to avoid the AssemblyAI
key entirely:

```bash
TRANSCRIPTION_PROVIDER=whisper
WHISPER_MODEL_SIZE=base
```

faster-whisper runs on CPU and works out of the box on Windows. On the first run
for a given model size, the weights download from HuggingFace; set `HF_HOME` to
control where that cache lives (otherwise it uses the default user cache).

### 6. Run the app processes

Open three PowerShell windows (the backend, worker, and frontend are long-running).

Backend API (activate the venv first - note this differs from the bash `source`
form in CLAUDE.md):

```powershell
cd backend
.venv\Scripts\Activate.ps1
uvicorn src.main_refactored:app --reload --host 0.0.0.0 --port 8000
```

Worker (second window):

```powershell
cd backend
.venv\Scripts\Activate.ps1
arq src.workers.tasks.WorkerSettings
```

Frontend (third window):

```powershell
cd frontend
pnpm run dev
```

Then open http://localhost:3107.

> PowerShell execution policy: if `.venv\Scripts\Activate.ps1` is blocked, allow
> scripts for the current session with
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned`.

---

## Troubleshooting

### Line endings (CRLF vs LF)

Git on Windows may check out files with CRLF line endings. Shell scripts and `.env`
files expect LF. If `.env` or a script behaves oddly (e.g. an env value appears to
have a trailing carriage return), normalize the line endings to LF. Consider
setting `git config --global core.autocrlf input` before cloning so checked-out
files keep LF endings, and make sure your editor saves `.env` with LF.

### Redis on Windows

There is no well-maintained native Windows build of Redis. Run it in Docker
(`docker compose up -d redis`) or inside WSL2 rather than trying to install a
native Windows binary. The Docker-based Redis is what the rest of this guide
assumes.

### ffmpeg not on PATH

If the backend fails on video or audio steps with a "ffmpeg not found" style error,
ffmpeg is not on your `PATH`. Reinstall it (`winget install Gyan.FFmpeg` or
`choco install ffmpeg`), open a **new** terminal so the updated `PATH` is picked
up, and confirm with `ffmpeg -version`.

### claude-cli does not work in Docker

If you set `LLM=claude-cli:...` and run the Docker stack, analysis will fail
because the `claude` binary is not in the container. Either switch to an API-key
LLM provider for Docker, or use the native Path B above. See
[Handoff: Local Whisper and claude-cli provider](./handoff-local-whisper-and-claude-cli.md).

### More help

See [Troubleshooting](./troubleshooting.md) for startup failures, stuck tasks, and
recovery guidance that applies on all platforms.
