#!/usr/bin/env bash
# frieren.sh — SupoClip project entrypoint
# A single, stable interface over the Docker stack, local dev servers, and tests.
# Usage: ./frieren.sh <command>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Pick the available docker compose invocation (plugin form preferred).
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    DC=""
fi

require_compose() {
    if [ -z "$DC" ]; then
        echo "Error: docker compose not found. Install Docker Desktop or the compose plugin." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_up() {
    require_compose
    if [ ! -f .env ]; then
        echo "Error: .env not found. Run './frieren.sh setup' first (copies .env.example)." >&2
        exit 1
    fi
    echo "==> Building and starting the full stack (frontend, backend, worker, postgres, redis)..."
    $DC up -d --build
    echo ""
    echo "    Frontend:  http://localhost:3107"
    echo "    Backend:   http://localhost:8000"
    echo "    API docs:  http://localhost:8000/docs"
}

cmd_down() {
    require_compose
    echo "==> Stopping all services..."
    $DC down
}

cmd_run() {
    require_compose
    if [ ! -f .env ]; then
        echo "Error: .env not found. Run './frieren.sh setup' first." >&2
        exit 1
    fi
    echo "==> Starting the full stack in the foreground (Ctrl-C to stop)..."
    $DC up --build
}

cmd_logs() {
    require_compose
    local service="${2:-}"
    echo "==> Tailing logs ${service:+for $service}..."
    # shellcheck disable=SC2086
    $DC logs -f --tail=100 $service
}

cmd_status() {
    require_compose
    $DC ps
}

cmd_database() {
    require_compose
    local subcmd="${2:-help}"
    case "$subcmd" in
        up)     echo "==> Starting postgres..."; $DC up -d postgres ;;
        down)   echo "==> Stopping postgres..."; $DC stop postgres ;;
        status) $DC ps postgres ;;
        logs)   $DC logs -f --tail=100 postgres ;;
        shell)  echo "==> Opening psql shell..."; $DC exec postgres psql -U supoclip -d supoclip ;;
        *)      echo "Usage: $(basename "$0") database up|down|status|logs|shell" ;;
    esac
}

cmd_worker() {
    require_compose
    local subcmd="${2:-logs}"
    case "$subcmd" in
        up)     echo "==> Starting worker..."; $DC up -d worker ;;
        down)   echo "==> Stopping worker..."; $DC stop worker ;;
        logs)   $DC logs -f --tail=100 worker ;;
        *)      echo "Usage: $(basename "$0") worker up|down|logs" ;;
    esac
}

cmd_setup() {
    echo "==> First-run setup..."
    if [ ! -f .env ]; then
        if [ -f .env.example ]; then
            cp .env.example .env
            echo "    Created .env from .env.example — edit it and add your API keys"
            echo "    (ASSEMBLY_AI_API_KEY plus one of OPENAI/GOOGLE/ANTHROPIC_API_KEY, or LLM=ollama:<model>)"
        else
            echo "    Warning: no .env.example found; create .env manually." >&2
        fi
    else
        echo "    .env already exists — leaving it untouched"
    fi

    echo "==> Installing backend dependencies (uv sync)..."
    (cd backend && uv sync --all-groups)

    echo "==> Installing frontend dependencies (pnpm install — runs prisma generate)..."
    (cd frontend && pnpm install)

    echo "==> Setup complete. Start everything with: ./frieren.sh up"
}

cmd_local() {
    # Run a single app's dev server locally (outside Docker). Requires postgres+redis up.
    local target="${2:-help}"
    case "$target" in
        backend)
            echo "==> Backend API (local, port 8000)..."
            (cd backend && .venv/bin/uvicorn src.main_refactored:app --reload --host 0.0.0.0 --port 8000)
            ;;
        worker)
            echo "==> Worker (local)..."
            (cd backend && .venv/bin/arq src.workers.tasks.WorkerSettings)
            ;;
        frontend)
            echo "==> Frontend dev server (local, port 3107)..."
            (cd frontend && pnpm run dev)
            ;;
        *)
            echo "Usage: $(basename "$0") local backend|worker|frontend"
            echo "Note: start infra first with './frieren.sh database up' and a running redis."
            ;;
    esac
}

cmd_test() {
    local target="${2:-all}"
    case "$target" in
        all)      echo "==> Running backend + frontend tests..."; make test ;;
        backend)  echo "==> Running backend tests..."; make test-backend ;;
        frontend) echo "==> Running frontend tests..."; make test-frontend ;;
        e2e)      echo "==> Running end-to-end tests..."; make test-e2e ;;
        *)        echo "Usage: $(basename "$0") test all|backend|frontend|e2e" ;;
    esac
}

cmd_lint() {
    echo "==> Linting frontend..."
    (cd frontend && pnpm run lint)
}

cmd_clean() {
    echo "==> Removing build artifacts and caches..."
    rm -rf frontend/.next frontend/coverage frontend/test-results frontend/playwright-report 2>/dev/null || true
    find backend -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
    find . -name ".DS_Store" -delete 2>/dev/null || true
    echo "    Done. (Docker volumes untouched — use '$(basename "$0") nuke' for those.)"
}

cmd_nuke() {
    require_compose
    echo "==> Removing all containers AND named volumes (postgres data, clips, uploads, redis)..."
    read -r -p "    This deletes local data. Continue? [y/N] " ans
    case "$ans" in
        y|Y) $DC down -v; echo "    Volumes removed." ;;
        *)   echo "    Aborted." ;;
    esac
}

cmd_help() {
    cat <<EOF
SupoClip — frieren.sh

Usage: ./frieren.sh <command> [subcommand]

Stack (Docker):
  up                       Build + start the full stack (detached)
  run                      Start the full stack in the foreground
  down                     Stop all services
  status                   Show container status
  logs [service]           Tail logs (all, or one service)

Services:
  database up|down|status|logs|shell   Manage postgres
  worker up|down|logs                  Manage the ARQ worker

Setup & dev:
  setup                    Create .env, install backend (uv) + frontend (pnpm) deps
  local backend|worker|frontend        Run one app's dev server outside Docker

Quality:
  test [all|backend|frontend|e2e]      Run tests via Makefile (default: all)
  lint                     Lint the frontend

Cleanup:
  clean                    Remove build artifacts and caches
  nuke                     Remove containers + named volumes (destroys local data)

  help                     Show this message

Endpoints when up: frontend :3107, backend :8000 (docs at /docs)
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-help}" in
    up)             cmd_up ;;
    down)           cmd_down ;;
    run)            cmd_run ;;
    logs)           cmd_logs "$@" ;;
    status|ps)      cmd_status ;;
    database|db)    cmd_database "$@" ;;
    worker)         cmd_worker "$@" ;;
    setup)          cmd_setup ;;
    local)          cmd_local "$@" ;;
    test)           cmd_test "$@" ;;
    lint)           cmd_lint ;;
    clean)          cmd_clean ;;
    nuke)           cmd_nuke ;;
    help|--help|-h) cmd_help ;;
    *)
        echo "Unknown command: $1" >&2
        cmd_help >&2
        exit 1
        ;;
esac
