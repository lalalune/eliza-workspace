#!/usr/bin/env bash
# ============================================================================
# run-all.sh - Launch all workspace projects simultaneously (no port conflicts)
#
# Usage:
#   ./run-all.sh            Start all projects
#   ./run-all.sh --stop     Stop all projects started by a previous run
#   ./run-all.sh --status   Show running projects and their ports
#   ./run-all.sh --logs     Tail all project logs
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT/.run-all-logs"
PID_FILE="$ROOT/.run-all.pids"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# PORT ASSIGNMENT MAP (conflict-free)
#
#   Project                     Service            Port
#   --------------------------- ------------------ -----
#   agent-town                  Vite frontend      5173
#   babylon                     Next.js            3000
#     (docker)                  PostgreSQL         5433
#     (docker)                  PgBouncer          6432
#     (docker)                  Redis              6380
#     (docker)                  MinIO API          9000
#     (docker)                  MinIO Console      9001
#     (docker)                  Hardhat            8545
#   dungeons                    Server (Express)   3344
#                               Client (Vite)      3345
#   eliza-3d-hyperfy-starter    ElizaOS            3001
#   eliza-2004scape             Web UI             8880
#                               Management Web     8898
#                               Game Server (TCP)  43594
#                               Gateway (WS)       7780
#                               Login Server       43500
#                               Friend Server      45099
#                               Logger Server      43501
#   eliza-cloud-v2              Next.js            3002
#   hyperfy                     HTTP Server        3003
#   jeju/bazaar                 Frontend           4006
#                               API                4007
#   hyperscape                  Game Server        5555
#                               Asset Forge UI     3400
#                               Asset Forge API    3401
#                               CDN                8080
#   Portal                      Express            4173
#   milaidy                     API Server         31337
#                               UI (Vite)          2138
#
# DB Isolation:
#   babylon           -> PostgreSQL :5433 / DB=babylon (docker)
#   dungeons          -> PostgreSQL :5432 / DB=eliza_dungeons
#   eliza-2004scape   -> PostgreSQL :5432 / DB=lostcity
#   eliza-3d-hyperfy  -> PGLite (embedded, no server needed)
#   eliza-cloud-v2    -> External DB via DATABASE_URL
#   hyperfy           -> SQLite local (DB_URI=local)
#   jeju/bazaar       -> Workerd + local API worker (:4007)
#   hyperscape        -> PostgreSQL :5488 (own docker container)
#   Portal            -> No database
#   milaidy           -> PGLite (embedded, no server needed)
#   agent-town        -> Convex cloud (no local DB)
# ============================================================================

# All ports we manage (for cleanup)
MANAGED_PORTS=(5173 3000 3344 3345 3001 8880 7780 3002 3003 4006 4007 5555 3400 3401 8080 4173 31337 2138)

print_header() {
    echo ""
    echo -e "${BOLD}+------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}|              Workspace Launcher - Port Assignments                |${NC}"
    echo -e "${BOLD}+------------------------------------------------------------------+${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}agent-town${NC}               Vite frontend       ${YELLOW}:5173${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}babylon${NC}                  Next.js             ${YELLOW}:3000${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}dungeons${NC}                 Server / Client     ${YELLOW}:3344${NC} / ${YELLOW}:3345${NC}  ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}eliza-3d-hyperfy-starter${NC} ElizaOS             ${YELLOW}:3001${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}eliza-2004scape${NC}          Web / Gateway       ${YELLOW}:8880${NC} / ${YELLOW}:7780${NC}  ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}eliza-cloud-v2${NC}           Next.js             ${YELLOW}:3002${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}hyperfy${NC}                  HTTP Server         ${YELLOW}:3003${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}jeju/bazaar${NC}              Frontend / API      ${YELLOW}:4006${NC} / ${YELLOW}:4007${NC}  ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}hyperscape${NC}               Server / Forge      ${YELLOW}:5555${NC} / ${YELLOW}:3400${NC}  ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}Portal${NC}                   Express             ${YELLOW}:4173${NC}          ${BOLD}|${NC}"
    echo -e "${BOLD}|${NC}  ${CYAN}milaidy${NC}                  API / UI            ${YELLOW}:31337${NC}/ ${YELLOW}:2138${NC}  ${BOLD}|${NC}"
    echo -e "${BOLD}+------------------------------------------------------------------+${NC}"
    echo ""
}

kill_port() {
    local port="$1"
    local pids
    pids=$(lsof -ti :"$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        echo -e "  ${DIM}Killing stale process on :${port}${NC}"
        echo "$pids" | xargs kill -9 2>/dev/null || true
    fi
}

cleanup_ports() {
    echo -e "${DIM}Cleaning stale processes on managed ports...${NC}"
    for port in "${MANAGED_PORTS[@]}"; do
        kill_port "$port"
    done
}

stop_all() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e "${YELLOW}No PID file found. Nothing to stop.${NC}"
        return 0
    fi

    echo -e "${BOLD}Stopping all projects...${NC}"
    local any_running=false

    while IFS=' ' read -r pid name; do
        [ -z "${pid:-}" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            any_running=true
            echo -e "  ${RED}Stopping${NC} $name ${DIM}(PID $pid)${NC}"
            kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        fi
    done < "$PID_FILE"

    if [ "$any_running" = true ]; then
        sleep 2
        while IFS=' ' read -r pid name; do
            [ -z "${pid:-}" ] && continue
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "  ${RED}Force killing${NC} $name ${DIM}(PID $pid)${NC}"
                kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
            fi
        done < "$PID_FILE"
        echo -e "${GREEN}All projects stopped.${NC}"
    else
        echo -e "${YELLOW}No projects were running.${NC}"
    fi

    rm -f "$PID_FILE"
    cleanup_ports
}

show_status() {
    if [ ! -f "$PID_FILE" ]; then
        echo -e "${YELLOW}No PID file found. No projects launched by run-all.sh.${NC}"
        exit 0
    fi

    echo ""
    echo -e "${BOLD}Project Status:${NC}"
    echo ""

    while IFS=' ' read -r pid name; do
        [ -z "${pid:-}" ] && continue
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "  ${GREEN}RUNNING${NC}  ${BOLD}$name${NC} ${DIM}(PID $pid)${NC}"
        else
            echo -e "  ${RED}STOPPED${NC}  ${BOLD}$name${NC} ${DIM}(PID $pid - exited)${NC}"
        fi
    done < "$PID_FILE"

    echo ""
}

show_logs() {
    if [ ! -d "$LOG_DIR" ]; then
        echo -e "${YELLOW}No log directory found. Run ./run-all.sh first.${NC}"
        exit 0
    fi
    echo -e "${BOLD}Tailing all logs (Ctrl+C to stop)...${NC}"
    echo ""
    exec tail -f "$LOG_DIR"/*.log
}

# -- Docker check with timeout -----------------------------------------------
# `docker info` can hang for 30s+ when Docker is mid-startup, so we wrap
# every probe in a 5-second timeout to keep the poll loop responsive.
docker_is_ready() {
    timeout 5 docker info > /dev/null 2>&1
}

# -- Ensure Docker is running ------------------------------------------------
# babylon and hyperscape require Docker for their database services.
# Checks if Docker is responsive. If not, tries to start Docker Desktop
# (macOS) or the daemon (Linux), then polls up to 90s for readiness.
ensure_docker() {
    echo -e "${BOLD}Checking Docker...${NC}"

    if docker_is_ready; then
        echo -e "  ${GREEN}>>${NC}  Docker is already running"
        return 0
    fi

    echo -e "  ${YELLOW}>>${NC}  Docker is not running. Attempting to start..."

    # --- macOS: launch Docker Desktop ---
    if [ "$(uname)" = "Darwin" ]; then
        if [ -d "/Applications/Docker.app" ]; then
            open -a Docker
        elif [ -d "$HOME/Applications/Docker.app" ]; then
            open -a "$HOME/Applications/Docker.app"
        else
            echo -e "  ${RED}ERROR${NC}  Docker Desktop not found in /Applications."
            echo -e "         Install from ${CYAN}https://docker.com/products/docker-desktop${NC}"
            echo -e "         babylon and hyperscape ${RED}will not start${NC} without Docker."
            return 1
        fi

    # --- Linux: systemd ---
    elif command -v systemctl > /dev/null 2>&1; then
        sudo systemctl start docker 2>/dev/null || {
            echo -e "  ${RED}ERROR${NC}  Failed to start Docker via systemctl."
            echo -e "         Try: ${CYAN}sudo systemctl start docker${NC}"
            return 1
        }

    else
        echo -e "  ${RED}ERROR${NC}  Cannot auto-start Docker on this system."
        echo -e "         Please start Docker manually and re-run."
        return 1
    fi

    # Poll until the daemon responds (5s timeout per probe, up to 90s total)
    echo -e "  ${DIM}Waiting for Docker daemon (up to 90s)...${NC}"
    local elapsed=0
    local max_wait=90
    while [ $elapsed -lt $max_wait ]; do
        if docker_is_ready; then
            echo -e "  ${GREEN}>>${NC}  Docker is ready  ${DIM}(took ~${elapsed}s)${NC}"
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
        # Progress update every ~15s
        if [ $((elapsed % 15)) -eq 0 ]; then
            echo -e "  ${DIM}   Still waiting... ${elapsed}s / ${max_wait}s${NC}"
        fi
    done

    echo -e "  ${RED}ERROR${NC}  Docker did not become ready within ${max_wait} seconds."
    echo -e "         babylon and hyperscape ${RED}will not start${NC} without Docker."
    return 1
}

# -- Handle flags -----------------------------------------------------------
case "${1:-}" in
    --stop)
        stop_all
        exit 0
        ;;
    --status)
        show_status
        exit 0
        ;;
    --logs)
        show_logs
        exit 0
        ;;
    --help|-h)
        echo "Usage: ./run-all.sh [--stop|--status|--logs|--help]"
        echo ""
        echo "  (no args)   Start all 11 projects with unique port assignments"
        echo "  --stop      Stop all projects started by a previous run"
        echo "  --status    Show which projects are currently running"
        echo "  --logs      Tail all project log files"
        echo "  --help      Show this message"
        exit 0
        ;;
esac

# -- Pre-flight checks ------------------------------------------------------

# Stop any previously running instances
if [ -f "$PID_FILE" ]; then
    echo -e "${YELLOW}Found existing run. Stopping previous instances first...${NC}"
    stop_all
    echo ""
fi

# Clean stale processes on all our managed ports
cleanup_ports

# Ensure Docker is up (needed by babylon, hyperscape)
DOCKER_OK=true
ensure_docker || DOCKER_OK=false
echo ""

# Create fresh log directory
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
: > "$PID_FILE"

# -- Cleanup on exit --------------------------------------------------------
cleanup() {
    echo ""
    stop_all
}
trap cleanup SIGINT SIGTERM

# -- Launch function ---------------------------------------------------------
launch() {
    local name="$1"
    local dir="$2"
    local env_overrides="$3"
    shift 3
    local log="$LOG_DIR/${name}.log"

    echo -e "  ${GREEN}>>${NC}  ${BOLD}${name}${NC}"

    if [ "$env_overrides" = "-" ]; then
        ( cd "$ROOT/$dir" && exec "$@" ) > "$log" 2>&1 &
    else
        # shellcheck disable=SC2086
        ( cd "$ROOT/$dir" && export ${env_overrides} && exec "$@" ) > "$log" 2>&1 &
    fi

    echo "$! $name" >> "$PID_FILE"
}

# -- Skip function -----------------------------------------------------------
skip() {
    local name="$1"
    local reason="$2"
    echo -e "  ${YELLOW}--${NC}  ${BOLD}${name}${NC}  ${DIM}(skipped: $reason)${NC}"
}

# -- Print port map ----------------------------------------------------------
print_header

echo -e "${BOLD}Launching all projects...${NC}"
echo ""

# 1. agent-town  (:5173 Vite)
launch "agent-town" "agent-town" "-" npm run dev:frontend

# 2. babylon  (:3000 Next.js)  -- REQUIRES DOCKER
if [ "$DOCKER_OK" = true ]; then
    launch "babylon" "babylon" "-" bun run dev
else
    skip "babylon" "Docker is not running"
fi

# 3. dungeons  (:3344 server, :3345 client)
launch "dungeons" "dungeons" "-" npm run dev

# 4. eliza-3d-hyperfy-starter  (:3001 ElizaOS)
launch "eliza-3d-hyperfy-starter" "eliza-3d-hyperfy-starter" "SERVER_PORT=3001" npm run dev

# 5. eliza-2004scape  (:8880 web, :7780 gateway)
launch "eliza-2004scape" "eliza-2004scape" "WEB_PORT=8880" bun run dev

# 6. eliza-cloud-v2  (:3002 Next.js)
launch "eliza-cloud-v2" "eliza-cloud-v2" "PORT=3002" bun run dev

# 7. hyperfy  (:3003)
launch "hyperfy" "hyperfy" "-" npm run dev

# 8. jeju/bazaar  (:4006 frontend, :4007 API)
launch "jeju-bazaar" "jeju/apps/bazaar" "-" bun run dev

# 9. hyperscape  (:5555 server, :3400 forge)  -- REQUIRES DOCKER
if [ "$DOCKER_OK" = true ]; then
    launch "hyperscape" "hyperscape" "-" bun run dev
else
    skip "hyperscape" "Docker is not running"
fi

# 10. Portal  (:4173 Express)
launch "Portal" "Portal" "-" npm run dev

# 11. milaidy  (:31337 API, :2138 UI)
launch "milaidy" "milaidy" "-" npm run dev

# -- Done --------------------------------------------------------------------
echo ""
if [ "$DOCKER_OK" = true ]; then
    echo -e "${GREEN}All 11 projects launched!${NC}"
else
    echo -e "${YELLOW}9 projects launched (babylon + hyperscape skipped -- no Docker).${NC}"
fi
echo ""
echo -e "  ${DIM}Logs directory:${NC}  $LOG_DIR/"
echo -e "  ${DIM}Follow one:${NC}      tail -f $LOG_DIR/<project>.log"
echo -e "  ${DIM}Follow all:${NC}      tail -f $LOG_DIR/*.log"
echo -e "  ${DIM}Check status:${NC}    ./run-all.sh --status"
echo -e "  ${DIM}Stop all:${NC}        Ctrl+C  or  ./run-all.sh --stop"
echo ""
echo -e "${DIM}Notes:${NC}"
echo -e "  ${DIM}- agent-town: Run 'cd agent-town && npx convex dev' once for Convex auth${NC}"
echo -e "  ${DIM}- eliza-2004scape: Set GROQ_API_KEY or OPENAI_API_KEY in .env for bot AI${NC}"
if [ "$DOCKER_OK" != true ]; then
    echo -e "  ${DIM}- Start Docker Desktop, then re-run to include babylon + hyperscape${NC}"
fi
echo ""

# Keep script alive
wait
