# frieren.ps1 - minimal SupoClip helper for Windows (PowerShell)
#
# This is a small convenience wrapper over `docker compose` for Windows users.
# It mirrors only the most-used subcommands of the bash frieren.sh (up, down,
# logs, status, help). For the full project entrypoint use frieren.sh under
# WSL2 / Git Bash, or run docker compose directly.
#
# See docs/windows.md for the full Windows run guide (Docker and native paths).
#
# Usage:
#   .\frieren.ps1 up               Build + start the full stack (detached)
#   .\frieren.ps1 down             Stop all services
#   .\frieren.ps1 logs [service]   Tail logs (all, or one service)
#   .\frieren.ps1 status           Show container status
#   .\frieren.ps1 help             Show this message

param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Service = ""
)

$ErrorActionPreference = "Stop"

# Run from the repo root (this script's directory) regardless of cwd.
Set-Location -Path $PSScriptRoot

function Require-Compose {
    docker compose version *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "docker compose not found. Install Docker Desktop (with the compose plugin) and enable WSL2."
        exit 1
    }
}

function Show-Help {
    Write-Output @"
SupoClip - frieren.ps1 (Windows helper)

Usage: .\frieren.ps1 <command> [service]

  up               Build + start the full stack (detached)
  down             Stop all services
  logs [service]   Tail logs (all, or one service: backend, worker, frontend, postgres, redis)
  status           Show container status
  help             Show this message

Endpoints when up: frontend http://localhost:3107, backend http://localhost:8000 (docs at /docs)

This is a minimal wrapper over `docker compose`. See docs/windows.md for the
full guide, including native (non-Docker) setup needed for the claude-cli LLM provider.
"@
}

switch ($Command.ToLower()) {
    "up" {
        Require-Compose
        if (-not (Test-Path ".env")) {
            Write-Error ".env not found. Copy .env.example to .env and add your API keys first."
            exit 1
        }
        Write-Output "==> Building and starting the full stack (frontend, backend, worker, postgres, redis)..."
        docker compose up -d --build
        Write-Output ""
        Write-Output "    Frontend:  http://localhost:3107"
        Write-Output "    Backend:   http://localhost:8000"
        Write-Output "    API docs:  http://localhost:8000/docs"
    }
    "down" {
        Require-Compose
        Write-Output "==> Stopping all services..."
        docker compose down
    }
    "logs" {
        Require-Compose
        if ($Service) {
            Write-Output "==> Tailing logs for $Service..."
            docker compose logs -f --tail=100 $Service
        }
        else {
            Write-Output "==> Tailing logs..."
            docker compose logs -f --tail=100
        }
    }
    { $_ -in "status", "ps" } {
        Require-Compose
        docker compose ps
    }
    { $_ -in "help", "--help", "-h" } {
        Show-Help
    }
    default {
        Write-Error "Unknown command: $Command"
        Show-Help
        exit 1
    }
}
